# Startup and recovery

Register the task only after manual foreground and API checks pass:

    pwsh -NoProfile -File scripts/Register-BonsaiTask.ps1 -DeploymentRoot <root> -ConfigPath <root>\config\server.json -WhatIf
    pwsh -NoProfile -File scripts/Register-BonsaiTask.ps1 -DeploymentRoot <root> -ConfigPath <root>\config\server.json

The default `Auto` registration prefers a 30-second-delayed AtStartup trigger
under the current user's S4U principal at Limited run level. It stores no
password and does not need an interactive desktop. S4U tasks cannot access
network resources or encrypted files, so the model, runtime, logs, cache, and
configuration must be on local fixed volumes with absolute paths; this
deployment uses local G:. It does not depend on a mapped drive, user profile,
or cloud credential. Microsoft documents these S4U restrictions in the
[Task Scheduler logonType reference](https://learn.microsoft.com/en-us/windows/win32/taskschd/taskschedulerschema-logontype-simpletype).

If S4U registration fails specifically for a recognized privilege, batch-logon,
or credential error (Win32 1314, 1385, or 1326), `Auto` warns and registers a
Limited Interactive AtLogon fallback instead. Other registration failures are
reported without changing modes. `-StartupMode AtStartup` requires S4U and does
not fall back; use `-StartupMode AtLogon` to explicitly request the fallback.
The task is named Bonsai 2 27B Server, uses IgnoreNew for duplicate launches,
starts when available, has no execution time limit, and requests up to ten
one-minute task restarts. The task never runs as SYSTEM or Highest.

The task starts Watch-BonsaiServer.ps1 with absolute deployment/config paths.
The watcher owns one mutex and the server launcher owns the foreground process.
The mutex prevents a duplicate even if startup and a manual launch overlap.
Health is polled on loopback. A server failure enters bounded backoff and a
healthy ten-minute interval resets the backoff.

Recovery test:

1. Confirm the task is running and /health is ok.
2. End only the deployment-root llama-server process.
3. Confirm the watcher starts one replacement and /health returns ok.
4. Confirm there is no duplicate server process.
5. Run one Responses or Messages request.
6. Use the stop marker for an intentional shutdown and confirm no orphan.

After registration, manually start the exact task once and verify the task,
`/health`, `/slots`, and single process tree. This validates the selected logon
principal without rebooting. Boot persistence remains unproven until an actual
reboot is performed; an AtLogon fallback additionally requires user logon.
This toolkit does not reboot the host.
