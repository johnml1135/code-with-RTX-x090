# Registers the task that keeps Bonsai running, and installs the client configs.
#   Install-Bonsai.ps1              logon task as the current user (no admin needed)
#   Install-Bonsai.ps1 -Service     boot task as SYSTEM: starts before logon, survives logoff (run elevated)
#   Install-Bonsai.ps1 -Uninstall   remove the task and stop the server
# Either way the server runs windowless: conhost --headless keeps Windows Terminal (the default
# terminal) from opening a window for it, which it otherwise does even with -WindowStyle Hidden.
[CmdletBinding()]
param([switch]$Service, [switch]$Uninstall, [string]$TaskName = 'Bonsai 2 27B Server')
$ErrorActionPreference = 'Stop'

if ($Uninstall) {
    & (Join-Path $PSScriptRoot 'Stop-Bonsai.ps1') -TaskName $TaskName
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    "removed task '$TaskName'"
    return
}

$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$start = Join-Path $PSScriptRoot 'Start-Bonsai.ps1'
$action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" -WorkingDirectory $PSScriptRoot `
    -Argument "--headless `"$pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$start`""
# Start-Bonsai.ps1 restarts llama-server itself; the task-level restart covers the supervisor.
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew
if ($Service) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw '-Service registers a SYSTEM task; run this from an elevated PowerShell' }
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $when = 'at boot as SYSTEM'
} else {
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $trigger.Delay = 'PT30S'
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $when = "at logon as $env:USERNAME"
}
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
"registered task '$TaskName' (runs $start $when, windowless)"

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
if (Test-Path -LiteralPath $codexHome) {
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\codex\bonsai-local.config.toml') `
        -Destination (Join-Path $codexHome 'bonsai-local.config.toml') -Force
    "installed Codex profile: codex -p bonsai-local"
}

& (Join-Path $PSScriptRoot 'Link-Skills.ps1')

# pi is the default Bonsai harness: provider config, defaults, and Herdr's lifecycle hook.
$piDir = Join-Path $HOME '.pi\agent'
[void][IO.Directory]::CreateDirectory($piDir)
foreach ($file in 'models.json', 'settings.json') {
    $dest = Join-Path $piDir $file
    if (-not (Test-Path -LiteralPath $dest)) {
        Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) "config\pi\$file") -Destination $dest
        "installed pi $file"
    } elseif (-not (Select-String -LiteralPath $dest -Pattern 'bonsai' -Quiet)) {
        "$dest exists without Bonsai settings; merge config\pi\$file into it by hand"
    }
}
if (Get-Command herdr -ErrorAction SilentlyContinue) { herdr integration install pi }
