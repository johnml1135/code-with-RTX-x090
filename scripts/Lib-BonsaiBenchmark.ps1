function Assert-BonsaiBenchmarkTopology {
    param(
        [Parameter(Mandatory)][int]$ContextPerSlot,
        [Parameter(Mandatory)][int]$ActiveParallel,
        [Parameter(Mandatory)][bool]$ControlledCapacityTrial
    )
    if ($ActiveParallel -notin @(2,3)) { throw 'benchmark concurrency must use two or three active slots' }
    if ($ContextPerSlot -eq 262144 -and $ActiveParallel -eq 2 -and -not $ControlledCapacityTrial) { return }
    if ($ContextPerSlot -eq 204800 -and $ActiveParallel -in @(2,3) -and $ControlledCapacityTrial) { return }
    throw 'benchmark topology must be 2x262144 baseline or an explicitly marked 2/3-slot 204800-token capacity trial'
}

function Get-BonsaiBenchmarkConcurrencyLevels {
    param(
        [Parameter(Mandatory)][ValidateSet(2,3)][int]$ActiveParallel,
        [int[]]$RequestedLevels=@()
    )
    if ($RequestedLevels.Count -eq 0) { return @(1..$ActiveParallel) }
    if (@($RequestedLevels | Select-Object -Unique).Count -ne $RequestedLevels.Count -or
        @($RequestedLevels | Where-Object { $_ -lt 1 -or $_ -gt $ActiveParallel }).Count -gt 0) {
        throw 'requested benchmark concurrency levels must be unique integers between one and the active slot count'
    }
    return @($RequestedLevels | Sort-Object)
}

function New-BonsaiBenchmarkPromptText {
    param(
        [Parameter(Mandatory)][ValidateRange(1,196608)][int]$TargetTokenCount,
        [ValidatePattern('^[A-Za-z0-9_-]{1,48}$')][string]$IsolationTag=''
    )
    $phrase = 'The quick brown fox jumps over the lazy dog. '
    $copies = [Math]::Max(1,[int][Math]::Ceiling(($TargetTokenCount - 20) / 10))
    $preamble = if ($IsolationTag) { "$IsolationTag Bonsai benchmark case. " } else { 'Bonsai benchmark case. ' }
    return $preamble + ($phrase * $copies) + 'Write a short, coherent technical paragraph about checking file hashes and reporting whether they match. Continue until you have written at least seventy words.'
}

function Get-BonsaiBenchmarkPromptCounts {
    param([Parameter(Mandatory)][object]$Timings)
    $processed = if ($Timings.PSObject.Properties.Name -contains 'prompt_n') { [int]$Timings.prompt_n } else { 0 }
    $cached = if ($Timings.PSObject.Properties.Name -contains 'cache_n') { [int]$Timings.cache_n } else { 0 }
    [pscustomobject]@{
        totalPromptTokens=$processed + $cached
        processedPromptTokens=$processed
        cachedPromptTokens=$cached
        serverPromptTokensPerSecond=$(if ($Timings.PSObject.Properties.Name -contains 'prompt_per_second') { [double]$Timings.prompt_per_second } else { 0.0 })
    }
}

function Get-BonsaiBenchmarkAggregateRates {
    param(
        [Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$WallMs,
        [Parameter(Mandatory)][object[]]$Responses
    )
    if ($Responses.Count -lt 1) { throw 'aggregate rates require at least one completed response' }
    $promptTokens = [int64](($Responses | Measure-Object -Property promptTokens -Sum).Sum)
    $predictedTokens = [int64](($Responses | Measure-Object -Property predictedTokens -Sum).Sum)
    $processedPromptTokens = [int64](($Responses | Measure-Object -Property processedPromptTokens -Sum).Sum)
    $cachedPromptTokens = [int64](($Responses | Measure-Object -Property cachedPromptTokens -Sum).Sum)
    [pscustomobject]@{
        requestCount=$Responses.Count
        totalPromptTokens=$promptTokens
        processedPromptTokens=$processedPromptTokens
        cachedPromptTokens=$cachedPromptTokens
        predictedTokens=$predictedTokens
        wallClockTotalPromptTokensPerSecond=[Math]::Round(($promptTokens * 1000.0) / $WallMs,2)
        wallClockProcessedPromptTokensPerSecond=[Math]::Round(($processedPromptTokens * 1000.0) / $WallMs,2)
        wallClockCachedPromptTokensPerSecond=[Math]::Round(($cachedPromptTokens * 1000.0) / $WallMs,2)
        wallClockAggregateCompletionTokensPerSecond=[Math]::Round(($predictedTokens * 1000.0) / $WallMs,2)
    }
}

function Invoke-BonsaiBenchmarkResponse {
    param(
        [Parameter(Mandatory)][object]$RequestTask,
        [Parameter(Mandatory)][object]$RequestContent,
        [Parameter(Mandatory)][scriptblock]$ResponseHandler
    )
    $response = $null
    try {
        $response = $RequestTask.GetAwaiter().GetResult()
        return & $ResponseHandler $response
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $RequestContent) { $RequestContent.Dispose() }
    }
}

function Write-BonsaiBenchmarkReportCheckpoint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Report
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "benchmark output directory does not exist: $directory"
    }
    $temporaryPath = $fullPath + '.tmp'
    try {
        $json = $Report | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($temporaryPath,$json,[Text.UTF8Encoding]::new($false))
        # The sibling temp and final path share a volume; Move(overwrite) publishes
        # each complete JSON snapshot with one filesystem rename operation.
        [IO.File]::Move($temporaryPath,$fullPath,$true)
    } finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
    return $fullPath
}
