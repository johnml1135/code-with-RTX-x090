[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [int[]]$BackoffSeconds = @(5,10,30,60)
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lib-Bonsai.ps1')
$cfg = Import-BonsaiConfig $ConfigPath
Ensure-BonsaiDirectories $cfg
$mutex = [Threading.Mutex]::new($false, 'Local\Bonsai2_27B_Server_Watcher')
if (-not $mutex.WaitOne(0)) { throw 'another Bonsai supervisor is already running' }
function Write-WatchLog([string]$Message) {
    $line = '{0:o} {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $cfg.SupervisorLog -Value $line
    $item = Get-Item -LiteralPath $cfg.SupervisorLog -ErrorAction SilentlyContinue
    if ($item -and $item.Length -gt 10MB) {
        Move-Item -LiteralPath $cfg.SupervisorLog -Destination ($cfg.SupervisorLog + '.1') -Force
    }
}
try {
    $attempt = 0
    while (-not (Test-Path -LiteralPath (Join-Path $cfg.DeploymentRoot 'run\stop.request'))) {
        $shell = (Get-Command pwsh.exe,powershell.exe -ErrorAction Stop | Select-Object -First 1).Source
        Write-WatchLog 'starting foreground launcher'
        $child = Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Start-BonsaiServer.ps1'),'-ConfigPath',$cfg.ConfigPath) -WorkingDirectory $cfg.DeploymentRoot -RedirectStandardOutput $cfg.ServerStdoutLog -RedirectStandardError $cfg.ServerStderrLog -PassThru -WindowStyle Hidden
        $healthySince = $null
        while (-not $child.HasExited) {
            if (Test-Path -LiteralPath (Join-Path $cfg.DeploymentRoot 'run\stop.request')) {
                Write-WatchLog 'stop marker found; stopping child'
                Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
                break
            }
            try {
                $health = Invoke-BonsaiJson $cfg '/health' Get $null 5
                if ([string]$health.status -eq 'ok') {
                    if ($null -eq $healthySince) { $healthySince = Get-Date; Write-WatchLog 'health became ok' }
                    elseif (((Get-Date) - $healthySince).TotalMinutes -ge 10) { $attempt = 0 }
                }
            } catch { }
            Start-Sleep -Seconds 2
            $child.Refresh()
        }
        $child.Refresh()
        if (Test-Path -LiteralPath (Join-Path $cfg.DeploymentRoot 'run\stop.request')) {
            Write-WatchLog 'intentional stop complete'
            break
        }
        Write-WatchLog ("server exited with code {0}" -f $child.ExitCode)
        $delay = $BackoffSeconds[[Math]::Min($attempt, $BackoffSeconds.Count - 1)]
        $attempt = [Math]::Min($attempt + 1, $BackoffSeconds.Count - 1)
        Write-WatchLog ("restarting after {0} seconds" -f $delay)
        Start-Sleep -Seconds $delay
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

