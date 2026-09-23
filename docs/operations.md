# Operations

## Foreground start

Prepare a private deployment config from config/server.template.json, then run:

    pwsh -NoProfile -File scripts/Test-Bonsai.ps1 -Mode Contract -ConfigPath <root>\config\server.json
    pwsh -NoProfile -File scripts/Start-BonsaiServer.ps1 -ConfigPath <root>\config\server.json

The start script resolves every relative path from the config directory,
requires all artifacts to stay below deploymentRoot, rejects non-loopback
hosts, and checks the pinned MTP server help before launching. Normal startup
uses `--spec-type none`; pass `-MtpMode draft-mtp` explicitly only for a
controlled benchmark or opt-in trial. It attempts
three slots at 262144 tokens each (aggregate context 786432), then tries two
slots at the same per-slot context (aggregate 524288) if startup does not
become healthy. A stable winner is persisted under the configured G: run path
and reused after restart; the winner is tied to the runtime/model/template and
context fingerprint. The normal production template is two slots at 262144
tokens each. Three slots are reserved for the explicit temporary capacity
trial at 204800 tokens per slot; that trial falls back to two slots and does
not silently promote a third warm/live session into production.

The process is created suspended, assigned to a kill-on-close Job Object, and
given a best-effort 64-MiB minimum / 12-GiB maximum kernel working-set request
before resume. On the Limited scheduled-task token, Windows can deny that
request with Win32 1314; the launcher then records
kernelWorkingSetCapApplied=false and continues without elevating the server.
The watcher independently samples WorkingSet64 every second, Private Bytes and
virtual bytes separately, and GPU memory through nvidia-smi. Above 12 GiB
working set or 95% GPU memory it terminates the launcher/server job, records
the event on G:, and retries with two slots. The watcher is the active
enforcement if Windows denies the kernel request and may allow brief
overshoot. Private Bytes/commit is reported, not capped; this guard also does
not cover all WDDM/driver-pinned memory.

## Supervised start and stop

    pwsh -NoProfile -File scripts/Watch-BonsaiServer.ps1 -ConfigPath <root>\config\server.json

Create the configured G: run/stop.request marker to request an intentional
stop. Remove the marker before starting again within the same Windows boot.
At the next boot, the watcher clears a marker whose timestamp predates that
boot so an intentional stop does not suppress startup forever. The watcher
uses one named mutex, bounded supervisor logging, health polling, and restart delays of 5, 10,
30, and 60 seconds. A validated two-slot winner remains selected across
restarts instead of repeatedly retrying a known-bad three-slot mode. A changed
model/runtime fingerprint performs a fresh three-slot-first trial.

Before the first `/health` success, loading failures do not count toward
recovery. After readiness, ten consecutive failed health checks terminate the
supervised child and enter the normal restart/backoff path; any successful
check resets the count. This tolerates transient endpoint delays and leaves
long inference alone while `/health` remains responsive.

## Status and logs

Use Test-Bonsai.ps1 in Live mode for health, model, Responses, Chat
Completions, and Anthropic Messages checks. Review the configured supervisor,
server stdout, and server stderr files. Keep logs under the deployment root
and never commit them.

There must be one server process for this architecture. If a process is stuck,
stop only the process whose executable path is inside the deployment root.

## Slot operations

Manage-BonsaiSlots.ps1 supports List, Save, Restore, Release, Erase, Evict,
BudgetCheck, and Test. Save requires a filename and non-empty identity text;
restore also verifies that identity, the effective active deployment
fingerprint, and 262144-token per-slot context. Dormant files are on G: under
one 100-GiB/25-job budget; no warm-RAM tier is configured. A restored entry is
protected as active until explicitly released with the same identity; Evict
selects only inactive entries and protects the save in progress. Save fails
when the disk limits cannot be met without evicting active/protected state.
Use Test only against a healthy local server and erase its temporary file
afterward.
