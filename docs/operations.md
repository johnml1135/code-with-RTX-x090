# Operations

## Foreground start

Prepare a private deployment config from config/server.template.json, then run:

    pwsh -NoProfile -File scripts/Test-Bonsai.ps1 -Mode Contract -ConfigPath <root>\config\server.json
    pwsh -NoProfile -File scripts/Start-BonsaiServer.ps1 -ConfigPath <root>\config\server.json

The start script resolves every relative path from the config directory,
requires all artifacts to stay below deploymentRoot, rejects non-loopback
hosts, and checks the pinned server help for the cache and flash flags before
launching.

## Supervised start and stop

    pwsh -NoProfile -File scripts/Watch-BonsaiServer.ps1 -ConfigPath <root>\config\server.json

Create the deployment root run/stop.request marker to request an intentional
stop. Remove the marker before starting again. The watcher uses one named
mutex, bounded supervisor logging, health polling, and restart delays of 5, 10,
30, and 60 seconds.

## Status and logs

Use Test-Bonsai.ps1 in Live mode for health, model, Responses, and Messages
checks. Review the configured supervisor, server stdout, and server stderr
files. Keep logs under the deployment root and never commit them.

There must be one server process for this architecture. If a process is stuck,
stop only the process whose executable path is inside the deployment root.

## Slot operations

Manage-BonsaiSlots.ps1 supports List, Save, Restore, Erase, Evict, BudgetCheck,
and Test. Save and restore require explicit filenames; restore additionally
requires the same identity text, model fingerprint, aggregate context, and
parallelism. Use Test only against a healthy local server and erase its
temporary file afterward.

