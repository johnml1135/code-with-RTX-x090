# Registers the logon task that keeps Bonsai running, and installs the Codex profile.
#   Install-Bonsai.ps1              install / update
#   Install-Bonsai.ps1 -Uninstall   remove the task and stop the server
[CmdletBinding()]
param([switch]$Uninstall, [string]$TaskName = 'Bonsai 2 27B Server')
$ErrorActionPreference = 'Stop'

if ($Uninstall) {
    & (Join-Path $PSScriptRoot 'Stop-Bonsai.ps1') -TaskName $TaskName
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    "removed task '$TaskName'"
    return
}

$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$start = Join-Path $PSScriptRoot 'Start-Bonsai.ps1'
$action = New-ScheduledTaskAction -Execute $pwsh -WorkingDirectory $PSScriptRoot `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$start`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$trigger.Delay = 'PT30S'
# Start-Bonsai.ps1 restarts llama-server itself; the task-level restart covers the supervisor.
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
"registered task '$TaskName' (runs $start at logon)"

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
if (Test-Path -LiteralPath $codexHome) {
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\codex\bonsai-local.config.toml') `
        -Destination (Join-Path $codexHome 'bonsai-local.config.toml') -Force
    "installed Codex profile: codex -p bonsai-local"
}
