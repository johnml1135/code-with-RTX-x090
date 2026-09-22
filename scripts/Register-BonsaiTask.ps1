[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$DeploymentRoot,
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$TaskName = 'Bonsai 2 27B Server',
    [switch]$HighestAvailable
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $DeploymentRoot -ErrorAction Stop).ProviderPath
$watch = Join-Path $PSScriptRoot 'Watch-BonsaiServer.ps1'
$cfg = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).ProviderPath
if (-not $cfg.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'ConfigPath must be under DeploymentRoot' }
$shell = (Get-Command pwsh.exe,powershell.exe -ErrorAction Stop | Select-Object -First 1).Source
$action = New-ScheduledTaskAction -Execute $shell -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $watch,$cfg) -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -AtLogOn -RandomDelay (New-TimeSpan -Seconds 30)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1)
$runLevel = if ($HighestAvailable) { 'Highest' } else { 'Limited' }
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel $runLevel
if ($PSCmdlet.ShouldProcess($TaskName,'register or replace Bonsai scheduled task')) {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Write-Output $TaskName
}

