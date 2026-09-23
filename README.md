# code-with-RTX-x090

Personal setup for running local coding models on an RTX 3090 (24 GB) under Windows, and pointing
pi, Claude Code, Codex, and Herdr agents at them. Currently: **PrismML Ternary Bonsai 2 27B**.

This repo is configuration plus a few thin scripts, not a serving stack. The engine is PrismML's
llama.cpp fork, and nearly all the behavior below comes from `llama-server` flags.

## Why llama.cpp and not vLLM

Bonsai 2's weights use custom ternary tensor types (`PQ2_0`, `PTQ1_0`) that only
[PrismML's llama.cpp fork](https://github.com/PrismML-Eng/llama.cpp) can run. Stock llama.cpp,
Ollama, and vLLM reject them. The only vLLM route is an early out-of-tree plugin validated on an
A100 40GB at 2K context, which is not viable on a 3090.

The vLLM behaviors we want are available as llama-server flags:

| vLLM behavior | llama-server equivalent |
|---|---|
| One shared, paged KV pool; idle requests don't reserve memory | `--kv-unified` with `--ctx-size 614400 --parallel 5` |
| Automatic prefix caching; finished requests stay cached | slot prompt cache plus `--slot-prompt-similarity`, which is on by default |
| CPU offload tier for inactive sequences | `--cache-ram` (host-RAM prompt cache; **off here**, see Memory) |
| Disk tier (LMCache-style) | `--slot-save-path`, driven by `scripts/Bonsai-Session.ps1` |

## What runs

`config/bonsai.json` is the single source of truth:

- **5 concurrent sessions, each up to the full 262,144-token context**, drawing on one shared
  614,400-token q4_0 KV pool on the GPU.
- `--checkpoint-min-step 0`: works around a llama.cpp checkpoint-eviction bug that forced short
  prompts to re-prefill every turn on hybrid models like Bonsai. The bug is fixed upstream in
  PR #28302, which Prism's b10709 predates.
- `--cache-ram 0 --ctx-checkpoints 4`: no host-RAM prompt cache and at most 4 checkpoints per slot.
  Both live in host memory and count against Windows commit (see Memory). Each of the 5 slots
  still keeps its own agent's context on the GPU.
- **Cold tier on G:**: up to 17 saved sessions / 100 GiB. Saving is explicit (see below).
- `--no-mmap`: the model loads straight to the GPU. Base RAM is about 1.5 GiB, down from about
  7.7 GiB with mmap.
- Vision projector not loaded, MTP off, reasoning effort `medium`. Prism's model card notes that
  `low` behaves close to `xhigh`.
- `config/bonsai-chat-template.jinja` is Prism's template with one change: a system message
  after the first turn is rendered instead of raising an error. Claude Code and Codex both send
  those.

Files live on `G:\bonsai-deployment` (`bin\` runtime, `models\`, `sessions\`, `logs\`), so nothing
large sits on C:.

### Measured on this machine (RTX 3090, official Prism build b10709)

| Workload | 1 job | 2 jobs | 3 jobs |
|---|---|---|---|
| Short prompt, decode tok/s per job | 64 | 50 | 39 |
| Short prompt, decode tok/s total | 64 | 101 | 115 |
| ~14K-token prompt, decode tok/s per job | 58 | 23 | 13 |

- A single 229K-token session decodes at about 17 tok/s. Its prefill took about 7 minutes.
- VRAM sits at about 22 of 24.5 GB.
- Saving a session to G: takes about 8.5 s per 94K tokens (1.8 GB). Restoring takes about 1.5 s.

Concurrency interleaves on one GPU. More jobs raise total throughput, but each job runs slower.
MTP speculative decoding (community `ProCreations/Ternary-Bonsai-2-27B-MTP`) was measured at
roughly 5× slower on this card and is not used.

## Memory: commit, not RAM

On Windows, the GPU driver (WDDM) charges **commit** for every byte a process allocates in VRAM,
so the pages can be evicted if needed. GeForce cards can't opt out. The server's resident RAM is
small, but its commit is not. Windows refuses new allocations once system-wide commit reaches
RAM + pagefile, even when RAM is free, so large builds fail while Bonsai runs.

Measured llama-server commit on this machine (5 slots):

| Config | Idle | After agent load |
|---|---|---|
| 614K pool, 8 GiB RAM cache, 32 checkpoints/slot (old) | 23.2 GB | 35.9 GB |
| 614K pool, no RAM cache, 4 checkpoints/slot (**current**) | 23.3 GB | 26.3 GB |
| 131K pool, no RAM cache, 4 checkpoints/slot | 12.2 GB | 15.2 GB |

The idle floor tracks the KV pool, at about 23 KB of commit per token of pool. Give Windows a
**fixed** pagefile large enough to cover the server. The system-managed default grows too late,
after builds have already failed. From an elevated PowerShell, run
`scripts\Set-BonsaiPagefile.ps1`, which adds `G:\pagefile.sys` at 32-64 GB. On this machine
it took effect immediately, raising the commit limit from 67.7 GB to 99.7 GB; Windows may otherwise
need a reboot.

This reserved commit is almost never written to the pagefile, so disk speed doesn't matter.
`Stop-Bonsai.ps1` frees all of it when you need it.

## Install

1. Download PrismML's Windows CUDA release of llama.cpp into `G:\bonsai-deployment\bin`, and
   `Ternary-Bonsai-2-27B-PQ2_0.gguf` from
   [prism-ml/Ternary-Bonsai-2-27B-gguf](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf)
   into `G:\bonsai-deployment\models\Ternary-Bonsai-2-27B`. Edit `root` in `config/bonsai.json`
   if you use a different location.
2. `pwsh scripts\Install-Bonsai.ps1`. This registers the `Bonsai 2 27B Server` logon task (30 s
   delay) and installs the Codex profile to `~\.codex\bonsai-local.config.toml`.
3. `Start-ScheduledTask 'Bonsai 2 27B Server'`, then `pwsh scripts\Test-Bonsai.ps1`.

The task runs `scripts\Start-Bonsai.ps1` from this checkout. It restarts llama-server when the
process exits, or after 2 minutes of failed `/health` checks. Task Scheduler restarts the
supervisor itself if it dies. Logs are in `G:\bonsai-deployment\logs`.

The server runs with no window. The task launches through `conhost.exe --headless`, because
Windows Terminal, the default terminal, would otherwise open a window even for a hidden process.

**Service mode:** from an elevated PowerShell, run `Install-Bonsai.ps1 -Service`. The same task
then runs as SYSTEM at boot, so Bonsai is up before anyone logs in and keeps running after
logoff. In that mode, run `Stop-Bonsai.ps1` elevated too.

`scripts\Stop-Bonsai.ps1` stops everything. `Install-Bonsai.ps1 -Uninstall` also removes the task.

## Use

```powershell
scripts\Invoke-BonsaiPi.ps1              # pi (the default harness)
scripts\Invoke-BonsaiClaude.ps1          # Claude Code, endpoint scoped to this process
scripts\Invoke-BonsaiCodex.ps1           # Codex via `codex -p bonsai-local`
```

**pi is the default harness for Bonsai subagents** (`@earendil-works/pi-coding-agent`). Its system
prompt plus tools come to about 1.2K tokens, against about 20K for Claude Code or Codex. At this
card's ~1,000 tok/s prefill, a new agent starts in about 2 s instead of 20-30 s, and it keeps
roughly 20K more tokens of context free. The config is in `config/pi/`, and
`Install-Bonsai.ps1` installs it to `~/.pi/agent/`:

- `models.json`: the `bonsai` provider, with `thinkingFormat: qwen-chat-template` so reasoning
  history stays byte-identical between turns and prefix caching keeps working. The context window
  is set to 131,072 so pi compacts before five agents can exhaust the shared pool.
- `settings.json`: pi defaults to Bonsai with `medium` thinking.
- Herdr's pi integration (`herdr integration install pi`) reports pi panes' idle and working state.

Tool profiles:
- Implement: `--no-skills --tools read,bash,edit,write,grep,find`. Use a worktree, since pi has no
  approval prompts.
- Read-only: `--no-skills --tools read,grep,find,ls`.

`--no-skills` keeps the user's skill library out of a subagent's prompt.

Endpoints on `http://127.0.0.1:8080`: OpenAI `/v1/chat/completions` and `/v1/responses`,
Anthropic `/v1/messages`, plus `/health` and `/slots`. The model alias is `bonsai2-27b`.

### Herdr subagents

The Herdr skill lives in this repo at `skills/herdr/SKILL.md`. `scripts/Link-Skills.ps1`, run by the
installer, junctions it into `~/.agents/skills` (Codex, pi) and `~/.claude/skills` (Claude Code), so
edits are version controlled here. When you say "use herdr to run a subagent to ...", the skill:

- routes to Bonsai with pi, unless 5 Bonsai workers are live;
- otherwise routes to Luna (`gpt-5.6-luna`), or tells you if Luna has no credits;
- supervises the worker every 5-15 minutes;
- re-checks pi, the Herdr hooks, the runtime and the model once a week, using the "Last checked"
  date in the skill.

### Long-lived sessions on G:

```powershell
scripts\Bonsai-Session.ps1 save -Name review-agent     # idle slot with the most context
scripts\Bonsai-Session.ps1 list
scripts\Bonsai-Session.ps1 restore -Name review-agent  # into an idle slot, before the agent resumes
scripts\Bonsai-Session.ps1 remove -Name review-agent
```

After a restore, the agent's next turn reuses the saved context. The server matches it to that
slot by prompt prefix. Verified: 15,861 tokens reused, 14 processed. Saved files are tied to the
exact model file, and `restore` refuses a mismatch.

## Known limits

- **The pool is shared.** Each of the five sessions can reach 262K, but together they can't
  exceed 614,400 tokens. What happens when the pool fills has not been tested.
- **The G: tier is manual.** llama-server moves sessions between the GPU and RAM on its own but
  never spills them to disk.
- **Resuming needs a new turn.** Bonsai is a hybrid linear-attention model, and a restored
  session can only be resumed by *extending* its prompt, which is what agent turns do.
  Re-sending an identical prompt re-prefills from scratch.
- **Stuck requests aren't detected.** If a client disconnects mid-request and a slot stays busy,
  `/health` still passes. Check `/slots`, then restart with `Stop-Bonsai.ps1` followed by
  `Start-ScheduledTask`.

## Other contents

`scripts/maintenance/Cleanup-StaleWorktrees.ps1`: evicts stale, settled git worktrees under a
repos folder. Always start with
`-DryRun -Review ReviewAll -Action Skip -MeasureSize`.

The earlier, heavier toolkit is preserved on the `archive/codex-hardened-toolkit` branch: custom
watchdog, working-set job cap, 3→2 slot fallback, deployment fingerprints, and benchmark harness.
