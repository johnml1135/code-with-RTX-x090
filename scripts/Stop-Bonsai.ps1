# Stops the supervisor task and the server. Start again with: Start-ScheduledTask 'Bonsai 2 27B Server'
[CmdletBinding()]
param([string]$TaskName = 'Bonsai 2 27B Server')
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" |
    Where-Object CommandLine -like '*Start-Bonsai.ps1*' |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
'stopped'
