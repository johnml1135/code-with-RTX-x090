[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$DeploymentRoot,
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$TaskName = 'Bonsai 2 27B Server',
    [ValidateSet('Auto','AtStartup','AtLogon')][string]$StartupMode = 'Auto'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lib-Bonsai.ps1')
$root = (Resolve-Path -LiteralPath $DeploymentRoot -ErrorAction Stop).ProviderPath
$watch = Join-Path $root 'scripts\Watch-BonsaiServer.ps1'
if (-not (Test-Path -LiteralPath $watch -PathType Leaf)) { throw "deployment watcher not found: $watch" }
$cfg = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).ProviderPath
if (-not $cfg.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'ConfigPath must be under DeploymentRoot' }
$shell = (Get-Command pwsh.exe,powershell.exe -ErrorAction Stop | Select-Object -First 1).Source
$action = New-ScheduledTaskAction -Execute $shell -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $watch,$cfg) -WorkingDirectory $root
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1)
$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name

function Register-BonsaiTaskPlan($Plan) {
    $trigger = if ($Plan.Trigger -eq 'AtStartup') {
        New-ScheduledTaskTrigger -AtStartup -RandomDelay (New-TimeSpan -Seconds 30)
    } else {
        New-ScheduledTaskTrigger -AtLogOn -RandomDelay (New-TimeSpan -Seconds 30)
    }
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType $Plan.LogonType -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
}

if ($PSCmdlet.ShouldProcess($TaskName,"register Limited $StartupMode Bonsai task")) {
    $plan = Get-BonsaiTaskRegistrationPlan -Mode $StartupMode
    try {
        Register-BonsaiTaskPlan $plan
    } catch {
        $errorCode = [int]($_.Exception.HResult -band 0xFFFF)
        if ($StartupMode -ne 'Auto' -or $plan.LogonType -ne 'S4U' -or -not (Test-BonsaiS4UFallbackErrorCode -ErrorCode $errorCode)) {
            throw
        }
        $reason = "S4U AtStartup registration was denied (Win32 $errorCode): $($_.Exception.Message)"
        $fallback = Get-BonsaiTaskRegistrationPlan -Mode Auto -S4UAvailable $false -FallbackReason $reason
        try { Register-BonsaiTaskPlan $fallback }
        catch { throw "$reason; Limited AtLogon fallback also failed: $($_.Exception.Message)" }
        Write-Warning "$reason. Registered Limited Interactive AtLogon fallback; no credentials or elevation were used."
        Write-Output ("{0}: trigger={1}, logonType={2}, runLevel={3}, fallback=authorization-only" -f $TaskName,$fallback.Trigger,$fallback.LogonType,$fallback.RunLevel)
        return
    }
    Write-Output ("{0}: trigger={1}, logonType={2}, runLevel={3}" -f $TaskName,$plan.Trigger,$plan.LogonType,$plan.RunLevel)
}
