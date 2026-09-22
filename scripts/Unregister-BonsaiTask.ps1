[CmdletBinding(SupportsShouldProcess)]
param([string]$TaskName = 'Bonsai 2 27B Server')
$ErrorActionPreference = 'Stop'
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -eq $task) { Write-Output 'task absent'; exit 0 }
if ($PSCmdlet.ShouldProcess($TaskName,'unregister Bonsai scheduled task')) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

