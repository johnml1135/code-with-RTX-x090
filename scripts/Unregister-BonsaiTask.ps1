[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TaskName = 'Bonsai 2 27B Server',
    [string]$TaskPath = '\'
)
$ErrorActionPreference = 'Stop'
$task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
if ($null -eq $task) { Write-Output 'task absent'; exit 0 }
if ($PSCmdlet.ShouldProcess("$TaskPath$TaskName",'unregister Bonsai scheduled task')) {
    Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
}
