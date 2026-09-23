# Driving sandboxed Codex workers from Herdr

Field notes for a Claude Code primary that dispatches Codex workers (Luna and
similar) into Git worktrees through `herdr agent`. Each item below cost a
stalled worker at least once.

## The sandbox can write only inside the worker's cwd

Codex runs with a workspace-write sandbox rooted at the pane's working
directory. User-level caches and tool homes are **not writable**, so tools
that keep state in the user profile fail inside the worker even though they
work in your own shell:

- uv: `failed to create directory C:\Users\<you>\AppData\Local\uv\cache`
- uv-managed Python: `uv python install` can't write or download the
  interpreter
- the same pattern applies to pip, npm, and cargo home or registry state

Fix it before the worker needs it, from **your** shell (outside the sandbox,
where the network also works):

```powershell
$wt = '<worktree>'
$common = git -C $wt rev-parse --git-common-dir
Add-Content "$common\info\exclude" ".uv-cache/`n.uv-python/"   # all worktrees share this file
$env:UV_CACHE_DIR = "$wt\.uv-cache"
uv python install 3.12 --install-dir "$wt\.uv-python"
uv run --no-project --python 3.12 --with <pinned deps> python -c "pass"   # warms the package cache
```

Then give the worker the exact environment in its brief:

```text
UV_CACHE_DIR=<wt>\.uv-cache  UV_PYTHON_INSTALL_DIR=<wt>\.uv-python
UV_PYTHON_PREFERENCE=only-managed  PYTHONNOUSERSITE=1   --python 3.12 --offline
If anything still needs the network, stop and give me the exact command.
```

Pre-warm **each** worktree that runs Python. Tell the worker never to commit
these directories; the `info/exclude` entry keeps them out of `git status`.

## A prompt can land pasted but not submitted

`herdr agent prompt <name> "<text>"` without `--wait` sometimes leaves the
Codex input showing `[Pasted Content N chars]`, with the agent still `idle`.
After every prompt, check for that and submit it:

```powershell
Start-Sleep 5
$d = herdr agent read <name> --source detection --lines 4 --format text | Out-String
if ($d -match 'Pasted Content') { herdr agent send-keys <name> enter }
```

A prompt sent while the worker is `working` is queued by Codex as steering
input and needs no Enter.

## Don't block a tool call on long `--wait`s

Claude Code's shell tools cap a call at 10 minutes, and planning or
implementation turns routinely run 20+ minutes. `agent prompt --wait
--timeout <big>` inside a tool call then fails with `timeout` even though the
worker is healthy. Send the prompt without `--wait`, then poll status in a
bounded loop that fits under the cap, and re-arm it as needed:

```powershell
for ($i=0; $i -lt 110; $i++) {
  $s = (herdr agent get <name> | ConvertFrom-Json).result.agent.agent_status
  if ($s -ne 'working') { "status=$s"; break }; Start-Sleep 5 }
```

A failed or timed-out wait never means the prompt was lost. Read the pane
before resending anything.

## Reading a finished worker's answer

Final answers from long turns scroll away quickly. Read a large window and
slice from the last marker you expect (a verdict line, a "Worked for" footer)
rather than the last few lines:

```powershell
$t = herdr agent read <name> --source recent-unwrapped --lines 400 --format text | Out-String -Width 220
$t.Substring([Math]::Max(0, $t.LastIndexOf('<marker>')))
```
