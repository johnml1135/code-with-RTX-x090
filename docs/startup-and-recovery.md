# Startup and recovery

Register the task only after manual foreground and API checks pass:

    pwsh -NoProfile -File scripts/Register-BonsaiTask.ps1 -DeploymentRoot <root> -ConfigPath <root>\config\server.json -WhatIf
    pwsh -NoProfile -File scripts/Register-BonsaiTask.ps1 -DeploymentRoot <root> -ConfigPath <root>\config\server.json

The task is named Bonsai 2 27B Server, runs at interactive logon after a
30-second delay, uses IgnoreNew for duplicate launches, starts when available,
has no execution time limit, and requests up to ten one-minute task restarts.
Least privilege is the default. Use HighestAvailable only when a measured
runtime requirement proves it necessary.

The task starts Watch-BonsaiServer.ps1 with the explicit config path. The
watcher owns one mutex and the server launcher owns the foreground process.
Health is polled on loopback. A server failure enters bounded backoff and a
healthy ten-minute interval resets the backoff.

Recovery test:

1. Confirm the task is running and /health is ok.
2. End only the deployment-root llama-server process.
3. Confirm the watcher starts one replacement and /health returns ok.
4. Confirm there is no duplicate server process.
5. Run one Responses or Messages request.
6. Use the stop marker for an intentional shutdown and confirm no orphan.

Boot persistence remains unproven until an actual logoff or reboot is performed.
This toolkit does not reboot the host.

