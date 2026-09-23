[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$MtpMode = '',
    [switch]$RetryPreferred
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lib-Bonsai.ps1')
$cfg = Import-BonsaiConfig $ConfigPath
Ensure-BonsaiDirectories $cfg
[void](Test-BonsaiHelpFlags $cfg)
$stopPath = Join-Path $cfg.RunStatePath 'stop.request'
$pidPath = Join-Path $cfg.RunStatePath 'server.pid'
$activePath = Join-Path $cfg.RunStatePath 'active-slots.json'
$fallbackPath = Join-Path $cfg.RunStatePath 'force-two-slots.request'
$validatedPath = Join-Path $cfg.RunStatePath 'validated-slots.json'
$workingSetLimitBytes = [int64]$cfg.Raw.maxWorkingSetGiB * 1GB

foreach ($requiredFile in @($cfg.Executable,$cfg.Model,$cfg.ChatTemplateFile)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) { throw "required G-drive file is missing: $requiredFile" }
}
$sameExecutable = @((Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($cfg.Executable)) -ErrorAction SilentlyContinue) | Where-Object {
    $_.Path -and [string]::Equals([IO.Path]::GetFullPath($_.Path),$cfg.Executable,[StringComparison]::OrdinalIgnoreCase)
})
if ($sameExecutable.Count -gt 0) { throw "refusing to start duplicate Bonsai process PID $($sameExecutable[0].Id)" }

function Write-RunJson([string]$Path,[object]$Value) {
    $temporary = $Path + '.tmp'
    [IO.File]::WriteAllText($temporary,($Value | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

$deploymentFingerprint = Get-BonsaiDeploymentFingerprint -Config $cfg -MtpMode $MtpMode
$validatedWinner = $null
if (Test-Path -LiteralPath $validatedPath) {
    try {
        $saved = Get-Content -LiteralPath $validatedPath -Raw | ConvertFrom-Json
        if ([string]$saved.fingerprint -eq $deploymentFingerprint -and [int]$saved.parallel -in @([int]$cfg.Raw.preferredParallel,[int]$cfg.Raw.fallbackParallel)) {
            $validatedWinner = [int]$saved.parallel
        }
    } catch { }
}
$forceTwo = $false
if (Test-Path -LiteralPath $fallbackPath) {
    try {
        $fallbackState = Get-Content -LiteralPath $fallbackPath -Raw | ConvertFrom-Json
        $forceTwo = [string]$fallbackState.fingerprint -eq $deploymentFingerprint
    } catch { }
    if (-not $forceTwo) { Remove-Item -LiteralPath $fallbackPath -Force -ErrorAction SilentlyContinue }
}
if ($forceTwo) { $candidates = @([int]$cfg.Raw.fallbackParallel) }
elseif ($RetryPreferred) { $candidates = @([int]$cfg.Raw.preferredParallel,[int]$cfg.Raw.fallbackParallel) }
elseif ($validatedWinner -eq [int]$cfg.Raw.preferredParallel) { $candidates = @($validatedWinner,[int]$cfg.Raw.fallbackParallel) }
elseif ($validatedWinner -eq [int]$cfg.Raw.fallbackParallel) { $candidates = @($validatedWinner) }
else { $candidates = @([int]$cfg.Raw.preferredParallel,[int]$cfg.Raw.fallbackParallel) }
$candidates = @($candidates | Select-Object -Unique)
$lastFailure = 'no candidate was attempted'
for ($candidateIndex = 0; $candidateIndex -lt $candidates.Count; $candidateIndex++) {
    if (Test-Path -LiteralPath $stopPath) { Write-Output 'Bonsai stop marker found before launch'; exit 0 }
    $parallel = [int]$candidates[$candidateIndex]
    $aggregateContext = [int64]$cfg.Raw.contextPerSlot * $parallel
    $arguments = Get-BonsaiServerArguments -Config $cfg -Parallel $parallel -MtpMode $MtpMode
    Write-Output ("launch attempt: slots={0}, slotContext={1}, aggregateContext={2}, mtp={3}, maxWorkingSetGiB={4}" -f $parallel,$cfg.Raw.contextPerSlot,$aggregateContext,$(if ($MtpMode) {$MtpMode} else {$cfg.Raw.mtp.mode}),$cfg.Raw.maxWorkingSetGiB)
    $server = $null
    try {
        $server = Start-BonsaiLimitedProcess -Executable $cfg.Executable -Arguments $arguments -WorkingDirectory $cfg.DeploymentRoot -MaxWorkingSetGiB ([int]$cfg.Raw.maxWorkingSetGiB)
        if (-not $server.KernelWorkingSetCapApplied) {
            Write-Output ("WARNING: kernel working-set cap was not applied (Win32 {0}: {1}); the 1-second watcher kill guard remains active at {2} GiB. Private Bytes/commit is reported separately and is not capped." -f $server.WorkingSetLimitErrorCode,$server.WorkingSetLimitMessage,$cfg.Raw.maxWorkingSetGiB)
        }
        [IO.File]::WriteAllText($pidPath,[string]$server.ProcessId,[Text.UTF8Encoding]::new($false))
        $deadline = (Get-Date).AddSeconds([int]$cfg.Raw.startupTimeoutSeconds)
        $ready = $false
        while (-not $server.Wait(0)) {
            if (Test-Path -LiteralPath $stopPath) {
                Write-Output 'Bonsai stop marker found; terminating server job'
                $server.Terminate(0)
                [void]$server.Wait(30000)
                exit 0
            }
            $listenerOwnedByServer = $false
            try {
                $listeners = @(Get-NetTCPConnection -LocalPort ([int]$cfg.Raw.port) -State Listen -ErrorAction Stop)
                $listenerOwnedByServer = [bool]($listeners | Where-Object { [int]$_.OwningProcess -eq $server.ProcessId })
                if ($listenerOwnedByServer) {
                    $health = Invoke-BonsaiJson $cfg '/health' Get $null 5
                    if ([string]$health.status -eq 'ok') { $ready = $true; break }
                }
            } catch { }
            if ((Get-Date) -ge $deadline) {
                $lastFailure = "startup timeout after $($cfg.Raw.startupTimeoutSeconds) seconds with $parallel slots"
                Write-Output $lastFailure
                $server.Terminate(1001)
                [void]$server.Wait(30000)
                break
            }
            [void]$server.Wait([Math]::Max(1000,[int]$cfg.Raw.healthPollSeconds * 1000))
        }
        if ($ready) {
            $selected = [pscustomobject]@{
                status='ready'; processId=$server.ProcessId; parallel=$parallel
                warmLiveSlots=[int]$cfg.Raw.warmLiveSlots
                temporaryThirdSlot=([bool]$cfg.Raw.temporaryTrialSlot -and $parallel -eq 3)
                contextPerSlot=[int]$cfg.Raw.contextPerSlot; aggregateContext=$aggregateContext
                mtpMode=$(if ($MtpMode) {$MtpMode} else {$cfg.Raw.mtp.mode}); maxDraftTokens=[int]$cfg.Raw.mtp.maxDraftTokens
                workingSetLimitBytes=$workingSetLimitBytes; kernelWorkingSetCapApplied=[bool]$server.KernelWorkingSetCapApplied
                workingSetLimitErrorCode=[int]$server.WorkingSetLimitErrorCode
                residentGuard='1-second watcher termination'; deploymentFingerprint=$deploymentFingerprint; started=(Get-Date).ToString('o')
            }
            Write-RunJson $activePath $selected
            $slotRole = if ([bool]$cfg.Raw.temporaryTrialSlot -and $parallel -eq 3) { 'two warm/live slots plus one temporary trial slot' } else { 'two warm/live slots' }
            Write-Output ("Bonsai ready: PID={0}, slots={1} ({2}), contextPerSlot={3}, aggregateContext={4}" -f $server.ProcessId,$parallel,$slotRole,$cfg.Raw.contextPerSlot,$aggregateContext)
            while (-not $server.Wait(1000)) {
                if (Test-Path -LiteralPath $stopPath) {
                    Write-Output 'Bonsai stop marker found; terminating server job'
                    $server.Terminate(0)
                    [void]$server.Wait(30000)
                    exit 0
                }
            }
            $exitCode = [int]$server.ExitCode
            Write-Output ("Bonsai server exited with code {0}" -f $exitCode)
            $server.Dispose(); $server = $null
            Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
            exit $exitCode
        }

        if ($server.Wait(0)) {
            $lastFailure = "server exited before health became ready (code $($server.ExitCode)) with $parallel slots"
        }
    } catch {
        $lastFailure = $_.Exception.Message
        Write-Output ("Bonsai launch attempt failed: {0}" -f $lastFailure)
    } finally {
        if ($server) {
            if (-not $server.Wait(0)) { try { $server.Terminate(1001); [void]$server.Wait(30000) } catch { } }
            $server.Dispose()
        }
        Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    }
    if ($parallel -eq [int]$cfg.Raw.preferredParallel -and (Test-Path -LiteralPath $validatedPath)) {
        try {
            $saved = Get-Content -LiteralPath $validatedPath -Raw | ConvertFrom-Json
            if ([string]$saved.fingerprint -eq $deploymentFingerprint -and [int]$saved.parallel -eq $parallel) {
                Remove-Item -LiteralPath $validatedPath -Force
                Write-Output 'discarded previously validated preferred-slot winner after a startup failure'
            }
        } catch { }
    }
    Write-Output ("Bonsai candidate {0} failed: {1}" -f $parallel,$lastFailure)
    if ($candidateIndex + 1 -lt $candidates.Count) { Write-Output ("trying fallback candidate with {0} slots" -f $candidates[$candidateIndex + 1]) }
}
throw "Bonsai failed to start with all permitted slot counts: $lastFailure"
