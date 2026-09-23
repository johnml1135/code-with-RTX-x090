[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [int[]]$BackoffSeconds = @(5,10,30,60),
    [ValidateSet('draft-mtp','none')][string]$MtpMode = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lib-Bonsai.ps1')
$cfg = Import-BonsaiConfig $ConfigPath
Ensure-BonsaiDirectories $cfg
$workingSetLimitBytes = [int64]$cfg.Raw.maxWorkingSetGiB * 1GB
$serverPidPath = Join-Path $cfg.RunStatePath 'server.pid'
$stopPath = Join-Path $cfg.RunStatePath 'stop.request'
$fallbackPath = Join-Path $cfg.RunStatePath 'force-two-slots.request'
$activePath = Join-Path $cfg.RunStatePath 'active-slots.json'
$validatedPath = Join-Path $cfg.RunStatePath 'validated-slots.json'
$deploymentFingerprint = Get-BonsaiDeploymentFingerprint -Config $cfg -MtpMode $MtpMode
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
$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
if (Clear-BonsaiStopMarkerFromPreviousBoot -MarkerPath $stopPath -LastBootTime ([datetime]$os.LastBootUpTime)) {
    Write-WatchLog 'cleared intentional-stop marker left by a previous Windows boot'
}
try {
    $attempt = 0
    while (-not (Test-Path -LiteralPath $stopPath)) {
        $shell = (Get-Command pwsh.exe,powershell.exe -ErrorAction Stop | Select-Object -First 1).Source
        $launcherArguments = @(Get-BonsaiSupervisorLauncherArguments -ConfigPath $cfg.ConfigPath -MtpMode $MtpMode)
        $modeText = if ([string]::IsNullOrWhiteSpace($MtpMode)) { 'configured' } else { $MtpMode }
        Write-WatchLog "starting foreground launcher; MTP mode=$modeText"
        Remove-Item -LiteralPath $serverPidPath -Force -ErrorAction SilentlyContinue
        $child = Start-Process -FilePath $shell -ArgumentList $launcherArguments -WorkingDirectory $cfg.DeploymentRoot -RedirectStandardOutput $cfg.ServerStdoutLog -RedirectStandardError $cfg.ServerStderrLog -PassThru -WindowStyle Hidden
        $temporarySlotIdleSince = @{}
        $temporarySlotErased = @{}
        $serverPid = $null
        $serverWasReady = $false
        $healthFailureCount = 0
        $healthySince = $null
        $lastMemoryReport = Get-Date
        $lastGpuReport = Get-Date
        $capacityBreach = $false
        $winnerPersisted = $false
        while (-not $child.HasExited) {
            if (Test-Path -LiteralPath $stopPath) {
                Write-WatchLog 'stop marker found; stopping child'
                Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
                break
            }
            if (Test-Path -LiteralPath $serverPidPath) {
                try {
                    $serverPid = [int](Get-Content -LiteralPath $serverPidPath -Raw)
                    $serverProcess = Get-Process -Id $serverPid -ErrorAction Stop
                    $workingSetBytes = [int64]$serverProcess.WorkingSet64
                    $privateBytes = [int64]$serverProcess.PrivateMemorySize64
                    $virtualBytes = [int64]$serverProcess.VirtualMemorySize64
                    $kernelWorkingSetCapApplied = $false
                    if (Test-Path -LiteralPath $activePath) {
                        try {
                            $guardActive = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json
                            if ([int]$guardActive.processId -eq $serverPid -and [string]$guardActive.deploymentFingerprint -eq $deploymentFingerprint) {
                                $kernelWorkingSetCapApplied = [bool]$guardActive.kernelWorkingSetCapApplied
                            }
                        } catch { }
                    }
                    $workingSetEvaluation = Get-BonsaiWorkingSetEvaluation -WorkingSetBytes $workingSetBytes -LimitBytes $workingSetLimitBytes -KernelWorkingSetCapApplied $kernelWorkingSetCapApplied
                    $gpu = if (((Get-Date) - $lastGpuReport).TotalSeconds -ge 5) { Get-BonsaiGpuMemorySnapshot } else { $null }
                    if ($gpu) { $lastGpuReport = Get-Date }
                    if (((Get-Date) - $lastMemoryReport).TotalSeconds -ge 30) {
                        if (-not $gpu) { $gpu = Get-BonsaiGpuMemorySnapshot; $lastGpuReport = Get-Date }
                        $gpuText = if ($gpu.available) { "gpuUsedMiB=$($gpu.usedMiB) gpuTotalMiB=$($gpu.totalMiB) gpuUsedPercent=$($gpu.usedPercent)" } else { "gpuTelemetryUnavailable=$($gpu.reason)" }
                        Write-WatchLog ("memory pid={0} rawWorkingSetBytes={1} privateCommitBytes={2} virtualBytes={3} workingSetLimitBytes={4} toleranceBytes={5} effectiveLimitBytes={6} kernelCapApplied={7} {8}" -f $serverPid,$workingSetEvaluation.rawWorkingSetBytes,$privateBytes,$virtualBytes,$workingSetEvaluation.configuredLimitBytes,$workingSetEvaluation.toleranceBytes,$workingSetEvaluation.effectiveLimitBytes,$workingSetEvaluation.kernelWorkingSetCapApplied,$gpuText)
                        $lastMemoryReport = Get-Date
                    }
                    $workingSetExceeded = [bool]$workingSetEvaluation.breach
                    $gpuExceeded = $gpu -and $gpu.available -and (Test-BonsaiGpuMemoryBreach -UsedMiB $gpu.usedMiB -TotalMiB $gpu.totalMiB -LimitPercent ([int]$cfg.Raw.maxGpuMemoryPercent))
                    if ($workingSetExceeded -or $gpuExceeded) {
                        $reason = if ($workingSetExceeded) { 'working-set' } else { 'GPU-memory' }
                        $gpuText = if ($gpu -and $gpu.available) { " GPU=$($gpu.usedMiB)/$($gpu.totalMiB) MiB ($($gpu.usedPercent)%)" } else { '' }
                        Write-WatchLog ("{0} ceiling breach: pid={1} rawWorkingSetBytes={2} privateCommitBytes={3} virtualBytes={4} workingSetLimitBytes={5} toleranceBytes={6} effectiveLimitBytes={7} kernelCapApplied={8}.{9} terminating job and forcing two-slot fallback" -f $reason,$serverPid,$workingSetEvaluation.rawWorkingSetBytes,$privateBytes,$virtualBytes,$workingSetEvaluation.configuredLimitBytes,$workingSetEvaluation.toleranceBytes,$workingSetEvaluation.effectiveLimitBytes,$workingSetEvaluation.kernelWorkingSetCapApplied,$gpuText)
                        $fallbackState = [pscustomobject]@{ fingerprint=$deploymentFingerprint; reason=$reason; workingSetBytes=$workingSetBytes; privateCommitBytes=$privateBytes; created=(Get-Date).ToString('o') }
                        [IO.File]::WriteAllText($fallbackPath,($fallbackState | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
                        if (Test-Path -LiteralPath $validatedPath) {
                            try {
                                $saved = Get-Content -LiteralPath $validatedPath -Raw | ConvertFrom-Json
                                if ([string]$saved.fingerprint -eq $deploymentFingerprint -and [int]$saved.parallel -eq [int]$cfg.Raw.preferredParallel) {
                                    Remove-Item -LiteralPath $validatedPath -Force
                                    Write-WatchLog 'invalidated previously validated three-slot winner after capacity breach'
                                }
                            } catch { }
                        }
                        $capacityBreach = $true
                        Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
                        break
                    }
                } catch { }
            }
            $serverIsActive = $false
            $healthOk = $false
            $healthError = ''
            try {
                if ($null -ne $serverPid -and (Test-Path -LiteralPath $activePath)) {
                    $active = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json
                    $serverIsActive = ([int]$active.processId -eq $serverPid -and [string]$active.deploymentFingerprint -eq $deploymentFingerprint)
                }
                if ($serverIsActive) {
                    $health = Invoke-BonsaiJson $cfg '/health' Get $null 5
                    $healthOk = ([string]$health.status -eq 'ok')
                }
            } catch { $healthError = $_.Exception.Message }
            $healthState = Get-BonsaiHealthFailureStatus -ConsecutiveFailures $healthFailureCount -ServerWasReady $serverWasReady -HealthOk $healthOk -Threshold ([int]$cfg.Raw.healthFailureThreshold)
            $healthFailureCount = [int]$healthState.consecutiveFailures
            if ($healthOk) {
                if (-not $serverWasReady) { $serverWasReady = $true; Write-WatchLog 'health became ok' }
                if ($null -eq $healthySince) { $healthySince = Get-Date }
                if ([bool]$cfg.Raw.temporaryTrialSlot -and [bool]$active.temporaryThirdSlot -and [int]$active.parallel -gt [int]$cfg.Raw.warmLiveSlots) {
                    try {
                        $slots = @(Invoke-BonsaiJson $cfg '/slots' Get $null 5)
                        $eraseCandidates = @(Get-BonsaiTemporarySlotEraseCandidates -Slots $slots -WarmLiveSlots ([int]$cfg.Raw.warmLiveSlots) -IsTemporaryTrial $true -ActiveParallel ([int]$active.parallel) -Now (Get-Date).ToUniversalTime() -GraceSeconds 15 -IdleSince $temporarySlotIdleSince -ErasedSlots $temporarySlotErased)
                        foreach ($slotId in $eraseCandidates) {
                            # Re-read the target immediately before erase so an in-flight request always wins.
                            $freshSlots = @(Get-BonsaiSlotEntries -Slots @(Invoke-BonsaiJson $cfg '/slots' Get $null 5))
                            $freshSlot = $freshSlots | Where-Object { [int]$_.id -eq [int]$slotId } | Select-Object -First 1
                            if ($null -eq $freshSlot -or [bool]$freshSlot.is_processing) {
                                [void]$temporarySlotIdleSince.Remove([string]$slotId)
                                [void]$temporarySlotErased.Remove([string]$slotId)
                                Write-WatchLog ("temporary slot erase skipped: slot={0} missing or processing" -f $slotId)
                                continue
                            }
                            $eraseResult = Invoke-BonsaiJson $cfg ("/slots/{0}?action=erase" -f $slotId) Post $null 10
                            Complete-BonsaiTemporarySlotErase -SlotId ([int]$slotId) -WarmLiveSlots ([int]$cfg.Raw.warmLiveSlots) -IdleSince $temporarySlotIdleSince -ErasedSlots $temporarySlotErased
                            $erasedCount = if ($null -ne $eraseResult -and $eraseResult.PSObject.Properties.Name -contains 'n_erased') { [string]$eraseResult.n_erased } else { 'unknown' }
                            Write-WatchLog ("temporary slot erase completed: slot={0} idleGraceSeconds=15 n_erased={1}; warm slots below {2} preserved" -f $slotId,$erasedCount,$cfg.Raw.warmLiveSlots)
                        }
                    } catch {
                        Write-WatchLog ("temporary slot erase check failed safely (no slot erased by this check): {0}" -f $_.Exception.Message)
                    }
                }
                if (((Get-Date) - $healthySince).TotalMinutes -ge 10) {
                    $attempt = 0
                    if (-not $winnerPersisted -and (Test-Path -LiteralPath $activePath)) {
                        try {
                            $active = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json
                            if ([string]$active.deploymentFingerprint -eq $deploymentFingerprint -and [int]$active.parallel -in @([int]$cfg.Raw.preferredParallel,[int]$cfg.Raw.fallbackParallel)) {
                                $winner = [pscustomobject]@{ fingerprint=$deploymentFingerprint; parallel=[int]$active.parallel; contextPerSlot=[int]$active.contextPerSlot; aggregateContext=[int]$active.aggregateContext; validatedAt=(Get-Date).ToString('o'); stableMinutes=10; validation='healthy, within process working-set and available GPU memory guards' }
                                $temporary = $validatedPath + '.tmp'
                                [IO.File]::WriteAllText($temporary,($winner | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
                                Move-Item -LiteralPath $temporary -Destination $validatedPath -Force
                                $winnerPersisted = $true
                                Write-WatchLog ("persisted validated slot winner: {0} slots, per-slot context {1}" -f $winner.parallel,$winner.contextPerSlot)
                            }
                        } catch { Write-WatchLog ("could not persist validated slot winner: {0}" -f $_.Exception.Message) }
                    }
                    if ($winnerPersisted -and (Test-Path -LiteralPath $fallbackPath)) {
                        Remove-Item -LiteralPath $fallbackPath -Force
                        Write-WatchLog 'cleared forced two-slot marker after the active mode remained healthy for ten minutes'
                    }
                }
            } else {
                $healthySince = $null
                if ($serverWasReady -and $healthFailureCount -gt 0) {
                    $reason = if ($healthError) { $healthError } else { 'health response did not report status=ok' }
                    if ($healthState.restartRequired) {
                        Write-WatchLog ("post-ready health remained unhealthy for {0} consecutive checks (threshold={1}): {2}; terminating supervised child for restart" -f $healthFailureCount,$cfg.Raw.healthFailureThreshold,$reason)
                        Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
                        break
                    }
                    Write-WatchLog ("post-ready health check failed {0}/{1}: {2}" -f $healthFailureCount,$cfg.Raw.healthFailureThreshold,$reason)
                }
            }
            Start-Sleep -Seconds 1
            $child.Refresh()
        }
        $child.Refresh()
        if (Test-Path -LiteralPath $stopPath) {
            Write-WatchLog 'intentional stop complete'
            break
        }
        Write-WatchLog ("server exited with code {0}" -f $child.ExitCode)
        if ($capacityBreach) { Write-WatchLog 'restart will remain on two slots until the two-slot mode validates and persists' }
        $delay = $BackoffSeconds[[Math]::Min($attempt, $BackoffSeconds.Count - 1)]
        $attempt = [Math]::Min($attempt + 1, $BackoffSeconds.Count - 1)
        Write-WatchLog ("restarting after {0} seconds" -f $delay)
        Start-Sleep -Seconds $delay
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
