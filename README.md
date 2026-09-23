# code-with-RTX-x090

Personal setup for running local coding models on an RTX 3090 (24 GB) under Windows, and pointing
Claude Code, Codex, and Herdr agents at them. Currently: **PrismML Ternary Bonsai 2 27B**.

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
| One shared, paged KV pool; idle requests don't reserve memory | `--kv-unified` with `--ctx-size 614400 --parallel 3` |
| Automatic prefix caching; finished requests stay cached | slot prompt cache plus `--slot-prompt-similarity`, which is on by default |
| CPU offload tier for inactive sequences | `--cache-ram 8192` (host-RAM prompt cache) |
| Disk tier (LMCache-style) | `--slot-save-path`, driven by `scripts/Bonsai-Session.ps1` |

## What runs

`config/bonsai.json` is the single source of truth:

- **3 concurrent sessions, each up to the full 262,144-token context**, drawing on one shared
  614,400-token q4_0 KV pool on the GPU.
- **Warm tier in RAM**: llama-server moves idle sessions to an 8 GiB host prompt cache and
  restores them automatically when their agent returns (measured: 20K-token resume in 0.8 s vs
  18 s re-prefill).
- **Cold tier on G:**: up to 20 saved sessions / 100 GiB. Saving is explicit (see below).
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
- Server RAM peaks at about 9 GiB under load (1.5 GiB base plus the 8 GiB cache cap).
- VRAM sits at about 22 of 24.5 GB.
- Saving a session to G: takes about 8.5 s per 94K tokens (1.8 GB). Restoring takes about 1.5 s.

Concurrency interleaves on one GPU. More jobs raise total throughput, but each job runs slower.
MTP speculative decoding (community `ProCreations/Ternary-Bonsai-2-27B-MTP`) was measured at
roughly 5× slower on this card and is not used.

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

`scripts\Stop-Bonsai.ps1` stops everything. `Install-Bonsai.ps1 -Uninstall` also removes the task.

## Use

```powershell
scripts\Invoke-BonsaiClaude.ps1          # Claude Code, endpoint scoped to this process
scripts\Invoke-BonsaiCodex.ps1           # Codex via `codex -p bonsai-local`
```

Endpoints on `http://127.0.0.1:8080`: OpenAI `/v1/chat/completions` and `/v1/responses`,
Anthropic `/v1/messages`, plus `/health` and `/slots`. The model alias is `bonsai2-27b`.

Herdr: run one wrapper per pane. The Bonsai section of the Herdr skill has the dispatch rules.

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

- **The pool is shared.** Three sessions can each reach 262K, but the three together can't
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
