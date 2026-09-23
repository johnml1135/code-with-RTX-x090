---
name: herdr
description: "Control Herdr, a terminal multiplexer for coding agents. Use only when the user explicitly mentions Herdr or asks to use Herdr to inspect or control panes, tabs, workspaces, commands, or another agent — including \"use herdr to run a subagent to ...\" / \"have herdr spin a subagent to ...\", which defaults to local Bonsai 2 (pi harness), falls back to Luna when 5 Bonsai workers are live, and sets up a 5-15 minute supervision check. Do not use merely because a task could benefit from a background terminal, delegation, or parallel work. Requires HERDR_ENV=1."
---

# Herdr

Herdr organizes terminals into workspaces, tabs, and panes, recognizes coding agents running inside panes, and exposes the current session through the `herdr` CLI.

Before issuing any control command, verify that this agent is running inside a Herdr-managed pane:

```bash
test "${HERDR_ENV:-}" = 1
```

If the check fails, say that you are not running inside Herdr and stop. Do not inspect or control the focused Herdr session from outside Herdr.

When the check passes, the `herdr` binary in `PATH` talks to the current session. Use it to inspect neighboring work, create terminal layout, start agents and commands, read output, and wait for state changes.

## Learn the current CLI

The installed binary is the authority for command syntax. Start with:

```bash
herdr --help
```

Then print the relevant command group by running the group without a subcommand:

```bash
herdr agent
herdr pane
herdr workspace
herdr tab
herdr worktree
herdr terminal
herdr notification
herdr integration
herdr session
herdr machine
```

Do not run bare `herdr` for discovery; it launches or attaches the TUI. Do not probe a mutating nested command by omitting arguments. Commands such as `herdr workspace create` are valid with defaults and will execute.

Most control commands return JSON. Read identifiers and state from those responses instead of predicting them.

## Understand layout, panes, and agents

Choose the primitive that matches the job:

- Workspace, tab, and pane topology organize terminal locations.
- Pane commands control raw terminals, shells, tests, servers, input, and output.
- Agent commands control the recognized coding agent currently occupying a pane.

A pane exists whether or not it contains an agent. `agent start` requires an existing available shell pane and never creates, splits, or moves layout. Use pane commands for ordinary processes. Use agent commands when Herdr must validate agent identity or interpret `idle`, `working`, `blocked`, `done`, and `unknown` lifecycle states.

Agent commands accept either a unique live agent name or the pane ID currently hosting that agent. They do not accept terminal IDs or bare agent-kind labels. Names must match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents. A name follows the current pane occupant and is cleared when that agent exits, is released, or is replaced.

`idle` and `done` both mean the agent is ready for input. The CLI/API uses the server's seen state to distinguish them; explicit focus commands mark the target seen, while reads do not. Each TUI client tracks viewed completions independently, so its Done badge can differ from the CLI or another client's badge. `blocked` means Herdr recognized an approval or question UI. `unknown` means an agent is present but Herdr cannot classify it confidently; it does not prove completion.

## Use IDs and caller context

Public IDs are opaque stable handles:

- workspace: `w1`
- tab: `w1:t1`
- pane: `w1:p1`

Closed tab and pane IDs are not reused. A pane moved into another workspace receives a new workspace-qualified pane ID. After `pane move`, continue with `.result.move_result.pane.pane_id` or the live agent name. The old value is reported as `.result.move_result.previous_pane_id`; only the moved process's inherited caller context keeps resolving that old ID, so do not use it as a general agent target.

Herdr injects the caller's context into each managed pane:

```bash
printf '%s\n' "$HERDR_WORKSPACE_ID" "$HERDR_TAB_ID" "$HERDR_PANE_ID"
```

Prefer `--current` when a pane command should target the calling pane. An omitted `pane split` target uses the calling pane when `HERDR_PANE_ID` is available, otherwise the focused pane. Other commands may use the UI-focused pane, which can belong to the user or another client.

Discover live state with:

```bash
herdr workspace list
herdr tab list --workspace "$HERDR_WORKSPACE_ID"
herdr pane current --current
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
herdr agent list
```

Creation responses expose the IDs to use next. `workspace create` returns `.result.workspace`, `.result.tab`, and `.result.root_pane`. `tab create` returns `.result.tab` and `.result.root_pane`. `pane split` returns the new pane as `.result.pane`.

IDs and live agent names are scoped to one server. Two saved SSH machines can both have `w1:p1` or an agent named `reviewer`. Selecting a machine in the TUI does not retarget commands running in your pane: without `--machine`, they still use the inherited session and socket context.

To control a saved SSH machine, use the same global prefix for discovery and every later command:

```bash
herdr --machine <label-or-id> agent list
herdr --machine <label-or-id> pane list
herdr --machine <label-or-id> agent prompt <remote-agent-name> "Reply with your current status." --wait --timeout 120000
```

The selector must be an enabled saved profile ID or a unique, case-sensitive label, not an arbitrary SSH hostname. Commands use that profile's remote session without an open TUI. Do not combine `--machine` with `--session` or `--remote`. Discover IDs on that machine; inherited local IDs and `--current` do not identify remote panes.

Both installations must support machine API forwarding, and the remote server must already be running and API-compatible. Forwarding never installs, starts, or restarts a server and never falls back to Local. Local configuration, session management, installation commands, and interactive attachment are not forwarded. Remote worktree paths must be absolute, `~`, or start with `~/`; plugin link paths must be absolute. A connection failure does not prove a mutation was not applied: inspect remote state before retrying.

`herdr machine list` lists saved connection profiles, not a cross-machine pane inventory; add `--json` for scripts. Only add, remove, enable, or disable profiles when the user asks. Removing a profile disconnects the client but does not stop remote sessions. Adding a machine uses the remote default session unless `--remote-session` is explicitly supplied. Setup asks before stopping an incompatible server and defaults to No; do not approve replacement without the user's consent. Experimental handoff is not part of `machine add`.

## Start and coordinate an agent

Default to a sibling pane in the current tab and the current working directory. Do not create a workspace, tab, worktree, or different cwd unless the user explicitly requests that topology or location.

Honor a direction requested by the user. Otherwise inspect the caller pane:

```bash
herdr pane layout --pane "$HERDR_PANE_ID"
```

Split a wide pane to the right and a narrow or tall pane down. Avoid repeated same-direction splits that create unusably narrow columns or short rows. Keep the user's focus in the calling pane and explicitly preserve the caller's working directory:

```bash
herdr pane split --current --direction right --cwd "$PWD" --no-focus
```

Replace `right` with `down` when appropriate. Read the new pane ID from `.result.pane.pane_id`.

An available shell pane must be at its interactive prompt, with the shell itself in the foreground and no foreground command, editor, or agent running. Start a supported agent in that pane with a useful unique name:

```bash
herdr agent start reviewer --kind codex --pane <returned-pane-id>
```

Use the kind requested by the user. Run `herdr agent` to inspect the installed kind list and options. Pass native agent arguments only after `--`:

```bash
herdr agent start reviewer --kind codex --pane <returned-pane-id> -- <agent-args...>
```

A successful `agent start` returns only after Herdr detects the expected agent in the same pane and considers it ready for interactive input. If the agent is blocked during startup, the command returns `agent_not_ready` immediately but keeps the name available for `agent read` and `agent send-keys`. Wait until the agent becomes idle before prompting it. Startup defaults to a 30-second timeout.

Submit work through the agent surface:

```bash
herdr agent prompt reviewer "Review the current diff and report only actionable findings." --wait --timeout 120000
```

`agent prompt` honors the pane's live bracketed-paste mode and sends text followed by encoded Enter as one ordered submission. It reports successful submission only after both have been written; that alone does not prove the agent started a turn. For Codex on Windows, Herdr sends a paste boundary before Enter so submission does not depend on prompt size. It rejects an agent already waiting at an approval or question dialog with `agent_blocked` before sending any input. Inspect the blocked UI and ask the user before answering it. For normal agent work, `--wait` is enough: it waits for the first settled `idle`, `done`, or `blocked` state. Do not repeat those defaults with `--until`.

With `--wait`, a prompt sent from a non-working state must produce observed `working` or `blocked` activity. After submission, Herdr waits up to five seconds for that activity; unrelated `idle`, `done`, or session changes do not satisfy this gate. It returns `agent_prompt_stalled` if no activity is observed, or `timeout` if the caller's timeout expires first. The caller timeout includes submission time. Without a timeout, the settled-state wait is indefinite after activity is observed. This wait tracks lifecycle state, not an individual turn; if the agent is already working, completion of the active turn may satisfy it.

Use `--until` only for a state-specific workflow, such as waiting for an already-running agent to request input:

```bash
herdr agent wait reviewer --until blocked --timeout 120000
```

Without `--until`, standalone `agent wait` uses the same settled-state defaults as `agent prompt --wait`.

Use logical keys for interactive agent UI controls:

```bash
herdr agent send-keys reviewer esc
herdr agent send-keys reviewer ctrl+c
```

Herdr validates all keys before writing any bytes. Read the result through the resolved agent:

```bash
herdr agent get reviewer
herdr agent read reviewer --source recent-unwrapped --lines 120
```

If a wait fails or returns `blocked`, inspect `agent get` and `agent read` before deciding what input to send. A timeout or stalled response does not prove the prompt was never delivered; do not blindly submit it again. Use the pane surface only when raw terminal control is intentional.

## Run an ordinary command in another pane

Create a sibling pane with the same geometry rule, preserve the caller's working directory, and keep user focus unchanged:

```bash
herdr pane split --current --direction right --cwd "$PWD" --no-focus
```

Read the new pane ID from `.result.pane.pane_id`, then run and inspect the command:

```bash
herdr pane run <returned-pane-id> "just test"
herdr pane wait-output <returned-pane-id> --match "test result" --timeout 120000
herdr pane read <returned-pane-id> --source recent-unwrapped --lines 120
```

`pane run` atomically sends command text and Enter. `pane wait-output` searches the selected snapshot immediately, so output that already exists can match. Use `--match <text>` for a literal substring or `--regex <pattern>` for a Rust regular expression. Omitting `--timeout` allows an indefinite wait.

Use the read source that matches the task:

- `visible`: the currently rendered viewport.
- `recent`: recent rendered output, including soft wraps.
- `recent-unwrapped`: recent output with soft wraps joined; prefer it for logs and transcripts.
- `detection`: the plain-text bottom-buffer snapshot used for agent detection.

Use `--format ansi` when colors and terminal styling are evidence. Otherwise use text.

`--lines` asks Herdr for more rows from the pane's available screen and host scrollback. Alternate-screen rows do not enter ordinary host scrollback. For supported idle agents, Herdr can collect application-owned history and restore the viewport afterward, but not every application or response can be recovered this way.

If a larger recent read still does not reveal the completed response, ask the agent to write it as Markdown in a temporary directory and reply only with the file path, then read that file on the same machine. Use this only as a fallback; do not request file output in the initial prompt.

## Safety and coordination rules

- Use `--no-focus` for background work unless the user asked to switch context.
- Use `--current`, an explicit pane ID, or a unique agent name. Do not rely on another client's focused pane.
- Parse IDs from JSON responses. Do not derive them from sidebar order or examples.
- Do not close workspaces, tabs, panes, or sessions you did not create unless the user explicitly asked. `workspace close --group` closes the primary workspace and its linked worktree workspaces; never add it merely to bypass `workspace_group_close_required`.
- Use `--trust-repository` only after the user has verified the repository. It grants per-request Git trust; it is not a routine retry for a failed worktree command.
- Client and server versions can differ after an update. Check `herdr status` before relying on new server features. A missing method is not permission to stop or upgrade a server.
- Never run `herdr server stop` from an active session unless the user explicitly intends to stop the server and its pane processes.
- Never kill the main Herdr process. Use named test sessions for experiments that need an isolated server.
- CLI server errors are JSON on stderr with exit status 1. CLI syntax errors exit with status 2.

## "Use herdr to run a subagent to ..." — pick the model automatically

"Use herdr to run a subagent to ..." and "have herdr spin a subagent to ..." are the whole request.
Do not ask which model; choose, say which and why in one line, then dispatch. A model or harness the
user names explicitly always wins (for example "... with claude", "... on luna", "... read-only").

1. **Keep the setup current.** If the "Last checked" date in the maintenance section below is more
   than 7 days old, run that check first and update the date.
2. **Measure Bonsai load.** `GET http://127.0.0.1:8080/health` must return `{"status":"ok"}`.
   Load = the larger of (a) slots with `is_processing: true` in `GET /slots`, and (b) live
   `herdr agent list` entries named `bonsai-*` (an idle worker still holds a context in the pool).
3. **Choose.** Health ok and load < 5 → **Bonsai** (the default). Load ≥ 5, or health failing →
   **Luna**. Never start a second llama-server and never wait for a slot to free up.
   If Luna fails to start or its first turn reports a usage, credit, or rate limit, stop it, tell
   the user, and offer to queue the task on Bonsai (a 6th worker's requests wait for a free slot).
   Do not silently substitute any other model.
4. **Name and launch** in a sibling pane (`pane split --current ... --no-focus`). Bonsai workers are
   named `bonsai-<task>` so step 2 can count them; Luna workers use any other name.
   - **Bonsai, pi harness (default).** Pick the tool profile from the task:
     ```
     herdr pane run <pane> "$env:PI_OFFLINE='1'"
     # implement / build / test (use a worktree: pi has no approval prompts)
     herdr agent start bonsai-<task> --kind pi --pane <pane> -- --no-skills --tools read,bash,edit,write,grep,find
     # read-only review / research (no bash, so it cannot modify anything)
     herdr agent start bonsai-<task> --kind pi --pane <pane> -- --no-skills --tools read,grep,find,ls
     ```
     `~/.pi/agent/settings.json` defaults pi to provider `bonsai`, model `bonsai2-27b`, thinking
     `medium`. Add `bash` to the read-only profile only if the review must run tests. Add `-nc` when
     the brief is self-contained and the repo's AGENTS.md/CLAUDE.md is irrelevant.
   - **Bonsai, other harness** (only when asked, or the task needs Codex's or Claude Code's own
     tools). Both carry a ~20K-token harness prompt, so a cold start takes ~20-30 s longer:
     ```
     herdr pane run <pane> "$env:BONSAI_LOCAL_API_KEY='local-only'"
     herdr agent start bonsai-<task> --kind codex --pane <pane> -- -p bonsai-local
     # Claude Code: run <repo>/scripts/Invoke-BonsaiClaude.ps1 in the pane
     ```
   - **Luna:** the command in the Luna section below.
5. **Prompt** with a bounded, self-contained brief: worktree, plan/spec path, exit criteria, which
   build commands are allowed, "no merge/push", where to write its evidence, and "end with a final
   report". A pi pane never shows `blocked` (no approval dialogs); supervise it by reading.
6. **Arm supervision** (next section) in the same turn.

If a Bonsai worker proves too weak for the task (repeated wrong edits, loops, lost context),
stop it, say so, and re-dispatch the same brief to Luna; do not keep correcting it indefinitely.

## Supervise every dispatched worker on a 5-15 minute check

The user wants dispatched workers checked on a fixed cadence with ongoing advice, not a single
wait. Pick the interval by job shape:

| Job | Interval |
|---|---|
| Active implementation, refactor, or anything with drift risk; just-sent course corrections | 5 min |
| Mostly compiling/testing, long builds, quiet but consequential | 10 min |
| Research, review, long batch runs, low drift risk | 15 min |

In Claude Code, schedule it with `CronCreate` (recurring, e.g. `*/5 * * * *`) or `/loop 5m ...`;
elsewhere, loop `herdr agent wait <name> --timeout <interval-ms>`. Each check:

1. `herdr agent read <name> --source recent-unwrapped --lines 80`, plus `git -C <worktree>
   status/log` and a targeted grep of the diff for what the brief asked to add or remove.
2. Compare against the plan and every correction already sent. Verify by effect (symbols gone,
   tests present, red evidence captured), not by the agent's narration.
3. **Decide whether it has lost its way** (see the table below) and act on that verdict. For
   ordinary drift, send one concise correction with `herdr agent prompt <name> "..."`, naming the
   file:line and the decided fix. Resolve factual blockers yourself when cheap (e.g. find the
   citation it could not) instead of letting it ship a conservative stub.
4. Give the user a 2-4 line status: done since last check, in progress, and the verdict or
   correction (if any).
5. When the worker reports done or goes idle with its exit criteria met, delete the schedule and
   move to verification (rerun its gates with the fix reverted, review the diff). Reap stray
   build processes.

Tighten to 5 minutes after any correction; relax toward 15 only after two quiet on-track checks.

### Has it lost its way?

Judge by evidence, not by the worker's narration. Signs it is lost: no new diff, test, or finding
across two checks; repeating the same command, edit, or failed approach; undoing its own or your
earlier fixes; ignoring a correction it acknowledged; working outside the brief; hallucinated tool
calls or tool names printed as text; context near its window with compaction losing the plan; a
stuck `/slots` entry with no live output. Then pick one:

| Situation | Action |
|---|---|
| Plan is sound and the worker is healthy; it misread one thing | **Correct** in place (one prompt). |
| Useful progress exists, but its context is polluted: loops, stale assumptions, near the window, ignored corrections | **Restart**: record what is done and what is left, kill it (`herdr agent send-keys <name> ctrl+c`, then close the pane you created), and dispatch a fresh worker with a brief that names the finished parts, the remaining steps, and the trap it fell into. Reuse the same worktree. |
| Little work remains, or the remaining step is subtle and explaining it costs more than doing it | **Kill and finish it yourself** in the worktree, then verify as usual. |
| The task is beyond this worker: a Bonsai worker failing on reasoning-heavy work after one restart, or the same failure twice | **Kill and escalate**: re-dispatch to Luna (or ask the user if Luna has no credits). |
| The brief itself was wrong or the goal changed | **Stop** the worker and tell the user before re-planning. |

Allow at most one restart per worker before finishing it yourself or escalating; do not keep
nudging a lost worker. Before killing, save anything useful: its diff stays in the worktree, and a
Bonsai worker's context can be saved with `scripts/Bonsai-Session.ps1 save` if a later worker should
resume from it. Tell the user which action you took and why in one line.

## Luna: this user's standard subagent

"Luna" is not a Herdr kind. It is `codex` running the `gpt-5.6-luna` model at `xhigh` reasoning
effort. When the user asks for Luna subagents, start them exactly this way:

```bash
herdr agent start <name> --kind codex --pane <returned-pane-id> -- -m gpt-5.6-luna -c model_reasoning_effort="xhigh"
```

The account default is `gpt-6-astra` (Astra), so omitting `-m` silently gives the wrong agent. If a
running agent's footer reads `gpt-6-astra`, it is not Luna — restart it.

Luna agents belong **next to the main chat**: split a sibling pane in the caller's current tab with
`herdr pane split --current --direction right --cwd "$PWD" --no-focus`. Never create a new tab or
workspace for them unless the user asks for that topology.

Claude Code panes show a folder-trust prompt on first start in a directory. That is a blocked
startup, not a failure: read it, and if it is the user's own repository, answer it with
`herdr agent send-keys <name> down` then `enter`.

## Bonsai local inference agents

Use this branch when the user asks for the local Bonsai deployment, or when the auto-selection
above picks it. Bonsai is an ordinary `pi`, `codex`, or `claude` client routed to a shared local
server, not a special Herdr agent kind. Keep the normal cloud profiles intact and do not silently
fall back to cloud when Bonsai is unavailable.

The deployment lives in the repo `code-with-RTX-x090` (this skill's home; config
`config/bonsai.json`; README for details). One llama-server on the RTX 3090 serves 5 slots sharing
a 614,400-token KV pool (`--kv-unified`): each worker may grow to 262,144 tokens, but all live
workers together cannot exceed the pool, so pi's context window is set to 131,072 to compact early.
Concurrent workers share one GPU: ~60 tok/s decode alone, much less each when several are busy.
Never start a second server.

Prefix caching is automatic: idle workers move to an 8 GiB host-RAM prompt cache and resume by
prompt prefix, and the chat template renders tools before the system prompt, so a harness prompt
is shared across projects. Keep one tool profile per harness where you can: a different `--tools`
list changes the prefix and costs a fresh harness prefill.

Launch helpers in the repo's `scripts/`: `Invoke-BonsaiPi.ps1`, `Invoke-BonsaiCodex.ps1`,
`Invoke-BonsaiClaude.ps1` (each waits for health and scopes endpoint settings to its process;
Claude's also sets its context window to 262,144). Use `medium` reasoning (`low` behaves like
`xhigh` on Bonsai). For Claude/Codex workers keep permission prompts enabled: plan mode for
review-only work, `acceptEdits` only when the user authorized edits; never `bypassPermissions`,
`--dangerously-skip-permissions`, or an automatic cloud fallback.

For headless one-shots outside Herdr (`pi -p`), quote the tool list (`--tools 'read,grep,find,ls'`:
unquoted commas become a PowerShell array) and pass a multi-line brief as `@<file>`, because npm's
`pi.cmd` shim goes through cmd.exe, which cuts arguments at the first newline. Close stdin
(`$null | pi ...`) or pi waits for it. `herdr agent prompt` has none of these problems.

For a worker that will sit idle for hours, save its context to G: with
`scripts/Bonsai-Session.ps1 save -Name <worker>` and `restore -Name <worker>` before resuming it
(17 saved sessions / 100 GiB). If a client times out or is interrupted, inspect `/slots` before
resending. A slot that stays busy with no live client is an orphaned request: restart with
`scripts/Stop-Bonsai.ps1` then `Start-ScheduledTask 'Bonsai 2 27B Server'` rather than killing
Herdr or launching a duplicate.

## Keep the subagent setup current

**Last checked: 2026-09-22.** If that is more than 7 days ago when this skill is used, check each
item, upgrade what is safe, then replace the date above with today's date:

1. **pi:** `npm view @earendil-works/pi-coding-agent version` vs `pi --version`. Upgrade with
   `npm install -g @earendil-works/pi-coding-agent@latest` after reading its CHANGELOG for changes to
   `models.json`, `settings.json`, `--tools`, or `thinkingFormat`. (`@mariozechner/pi-coding-agent`
   is deprecated.)
2. **Herdr hooks:** `herdr integration status`; if `pi` is not `current`, run
   `herdr integration install pi`. Note `herdr --version` changes that affect `agent start`.
3. **Runtime:** `gh release list -R PrismML-Eng/llama.cpp -L 3` vs `llama-server --version` in
   `G:\bonsai-deployment\bin`. Upgrading means downloading the Windows CUDA asset, stopping the
   server, swapping `bin\`, and running `scripts/Test-Bonsai.ps1`: ask the user first. Once the fork
   includes upstream llama.cpp PR #28302 (checkpoint eviction fix, upstream b10864+), drop
   `--checkpoint-min-step 0` from the config.
4. **Model:** check https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf for a newer GGUF or
   changed recommended settings; report rather than swap.
5. Commit changes to this skill or the deployment in the `code-with-RTX-x090` repo.

Primary references: [Herdr agent automation](https://herdr.dev/docs/agent-automation/) and
[CLI reference](https://herdr.dev/docs/cli-reference/) describe separate panes, agent prompts, and
bounded waits; [Claude Code gateway configuration](https://code.claude.com/docs/en/llm-gateway-connect)
documents process-scoped endpoint/credential configuration and connection checks;
[Claude Code CLI reference](https://code.claude.com/docs/en/cli-usage) documents explicit model
and effort selection; [llama.cpp server docs](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
document `/health` and `/slots`.
