# Runs llama-server in the foreground and restarts it if it exits or stops answering /health.
# The scheduled task created by Install-Bonsai.ps1 runs this at logon.
[CmdletBinding()]
param([string]$ConfigPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Bonsai.psm1') -Force
$cfg = if ($ConfigPath) { Get-BonsaiConfig $ConfigPath } else { Get-BonsaiConfig }

[void][IO.Directory]::CreateDirectory($cfg.logs)
[void][IO.Directory]::CreateDirectory($cfg.sessions)
$log = Join-Path $cfg.logs 'supervisor.log'
function Write-Log([string]$Message) { Add-Content -LiteralPath $log -Value "$(Get-Date -Format o) $Message" }

$serverArgs = @('--host', $cfg.host, '--port', [string]$cfg.port, '--alias', $cfg.alias) + $cfg.args
$failuresBeforeRestart = 8   # 8 x 15 s = 2 minutes of failed health checks
$backoffSeconds = 5

while ($true) {
    if (Get-NetTCPConnection -LocalPort $cfg.port -State Listen -ErrorAction SilentlyContinue) {
        Write-Log "port $($cfg.port) already in use; waiting"
        Start-Sleep -Seconds 30
        continue
    }
    $started = Get-Date
    $proc = Start-Process -FilePath $cfg.server -ArgumentList $serverArgs -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $cfg.logs 'server.stdout.log') `
        -RedirectStandardError (Join-Path $cfg.logs 'server.stderr.log')
    Write-Log "started llama-server pid=$($proc.Id)"
    $ready = $false
    $failures = 0
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 15
        $ok = $false
        try { $ok = (Invoke-Bonsai $cfg '/health' -TimeoutSec 10).status -eq 'ok' } catch { }
        if ($ok) {
            if (-not $ready) { Write-Log 'healthy'; $ready = $true }
            $failures = 0
            $backoffSeconds = 5
        } elseif ($ready -and ++$failures -ge $failuresBeforeRestart) {
            Write-Log "health failed $failures times in a row; killing pid=$($proc.Id)"
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Log "llama-server exited code=$($proc.ExitCode) after $([int]((Get-Date) - $started).TotalSeconds)s; restarting in ${backoffSeconds}s"
    Start-Sleep -Seconds $backoffSeconds
    # A server that dies before becoming healthy is probably misconfigured; back off up to 5 minutes.
    if (-not $ready) { $backoffSeconds = [math]::Min($backoffSeconds * 2, 300) }
}
