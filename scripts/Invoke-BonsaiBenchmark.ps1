[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateSet('draft-mtp','none')][string]$ExpectedMtpMode,
    [int[]]$PromptTokenTargets = @(32,1024,8192,196608),
    [int[]]$ConcurrencyLevels = @(),
    [int]$MaxOutputTokens = 96,
    [string]$OutputPath = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lib-Bonsai.ps1')
. (Join-Path $PSScriptRoot 'Lib-BonsaiBenchmark.ps1')
$cfg = Import-BonsaiConfig $ConfigPath
Ensure-BonsaiDirectories $cfg
$controlledCapacityTrial = if ($cfg.Raw.PSObject.Properties.Name -contains 'controlledCapacityTrial') { [bool]$cfg.Raw.controlledCapacityTrial } else { $false }
$activePath = Join-Path $cfg.RunStatePath 'active-slots.json'
$active = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json
if ([string]$active.status -ne 'ready') { throw 'benchmark requires a ready deployment' }
Assert-BonsaiBenchmarkTopology -ContextPerSlot ([int]$cfg.Raw.contextPerSlot) -ActiveParallel ([int]$active.parallel) -ControlledCapacityTrial $controlledCapacityTrial
if ([string]$active.mtpMode -ne $ExpectedMtpMode) {
    throw "active MTP mode '$($active.mtpMode)' differs from expected '$ExpectedMtpMode'"
}
$health = Invoke-BonsaiJson $cfg '/health' Get $null 15
if ([string]$health.status -ne 'ok') { throw 'benchmark requires a healthy server' }
$props = Invoke-BonsaiJson $cfg '/props' Get $null 15
$slots = Invoke-BonsaiJson $cfg '/slots' Get $null 30
$contextPerSlot = [int]$cfg.Raw.contextPerSlot
$selectedConcurrencyLevels = @(Get-BonsaiBenchmarkConcurrencyLevels -ActiveParallel ([int]$active.parallel) -RequestedLevels $ConcurrencyLevels)
if ($slots.Count -ne [int]$active.parallel -or [int]$props.default_generation_settings.n_ctx -ne $contextPerSlot) {
    throw 'live slot count or per-slot context does not match the active deployment status'
}
if ($MaxOutputTokens -lt 8 -or $MaxOutputTokens -gt 256) { throw 'MaxOutputTokens must be between 8 and 256' }
$benchmarkDirectory = Join-Path (Split-Path -Parent $cfg.RunStatePath) 'benchmarks'
[void][IO.Directory]::CreateDirectory($benchmarkDirectory)
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path $benchmarkDirectory ("mtp-{0}-{1}.json" -f $ExpectedMtpMode,$stamp)
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
Assert-BonsaiChildPath $OutputPath $cfg.DeploymentRoot 'benchmark output' | Out-Null
if (Test-Path -LiteralPath $OutputPath) { throw "benchmark output already exists: $OutputPath" }

$client = [Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromHours(2)
$baseUri = Get-BonsaiBaseUri $cfg
$samples = [Collections.Generic.List[object]]::new()
$runNonce = [Guid]::NewGuid().ToString('N').Substring(0,8)
$lastGpuSample = [DateTime]::MinValue
$gpuSnapshot = $null
function Add-ResourceSample {
    $process = Get-Process -Id ([int]$active.processId) -ErrorAction Stop
    if ($process.Path -and -not [string]::Equals([IO.Path]::GetFullPath($process.Path),$cfg.Executable,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'active server PID no longer resolves to the configured G-drive runtime'
    }
    if (((Get-Date) - $script:lastGpuSample).TotalSeconds -ge 5 -or $null -eq $script:gpuSnapshot) {
        $script:gpuSnapshot = Get-BonsaiGpuMemorySnapshot
        $script:lastGpuSample = Get-Date
    }
    $script:samples.Add([pscustomobject]@{
        timestamp=(Get-Date).ToString('o'); processId=[int]$process.Id
        workingSetBytes=[int64]$process.WorkingSet64
        privateCommitBytes=[int64]$process.PrivateMemorySize64
        virtualBytes=[int64]$process.VirtualMemorySize64
        gpuUsedMiB=$(if ($script:gpuSnapshot.available) { [int]$script:gpuSnapshot.usedMiB } else { $null })
        gpuTotalMiB=$(if ($script:gpuSnapshot.available) { [int]$script:gpuSnapshot.totalMiB } else { $null })
        gpuUsedPercent=$(if ($script:gpuSnapshot.available) { [double]$script:gpuSnapshot.usedPercent } else { $null })
    })
}
function New-BenchmarkPrompt([int]$TargetTokens,[string]$IsolationTag) {
    $text = New-BonsaiBenchmarkPromptText -TargetTokenCount $TargetTokens -IsolationTag $IsolationTag
    $tokenized = Invoke-BonsaiJson $cfg '/tokenize' Post @{ content=$text; add_special=$false; parse_special=$false } 120
    $actual = @($tokenized.tokens).Count
    if ($actual -gt ($contextPerSlot - 1024)) { throw "tokenized prompt $actual exceeds the safe per-slot test bound" }
    [pscustomobject]@{ text=$text; tokens=$actual; targetTokens=$TargetTokens; isolationTag=$IsolationTag }
}
function Invoke-BenchmarkTrial([object]$Prompt,[int]$Concurrency,[string]$Label) {
    if ($Concurrency -notin (Get-BonsaiBenchmarkConcurrencyLevels -ActiveParallel ([int]$active.parallel))) { throw 'benchmark concurrency cannot exceed the active slot count' }
    $payload = [ordered]@{
        model=[string]$cfg.Raw.alias; max_tokens=$MaxOutputTokens
        messages=@(@{ role='user'; content=[string]$Prompt.text })
    }
    $json = $payload | ConvertTo-Json -Depth 8 -Compress
    $requestContents = [Collections.Generic.List[object]]::new()
    $requestTasks = [Collections.Generic.List[object]]::new()
    $sampleStart = $script:samples.Count
    $startedAt = Get-Date
    $timer = [Diagnostics.Stopwatch]::StartNew()
    for ($i=0; $i -lt $Concurrency; $i++) {
        $content = [Net.Http.StringContent]::new($json,[Text.Encoding]::UTF8,'application/json')
        $requestContents.Add($content)
        $requestTasks.Add($client.PostAsync(($baseUri + '/v1/chat/completions'),$content))
    }
    while (@($requestTasks | Where-Object { -not $_.IsCompleted }).Count -gt 0) {
        Add-ResourceSample
        Start-Sleep -Milliseconds 500
    }
    $timer.Stop()
    Add-ResourceSample
    $results = [Collections.Generic.List[object]]::new()
    $trialError = $null
    for ($i=0; $i -lt $requestTasks.Count; $i++) {
        try {
            $responseHandler = {
                param($response)
                $responseText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if (-not $response.IsSuccessStatusCode) { throw "HTTP $([int]$response.StatusCode): $responseText" }
                $completion = $responseText | ConvertFrom-Json
                $timings = $completion.timings
                $message = $completion.choices[0].message
                $contentText = [string]$message.content
                $reasoningText = if ($message.PSObject.Properties.Name -contains 'reasoning_content') { [string]$message.reasoning_content } elseif ($message.PSObject.Properties.Name -contains 'reasoning') { [string]$message.reasoning } else { '' }
                $promptCounts = Get-BonsaiBenchmarkPromptCounts -Timings $timings
                [pscustomobject]@{
                    promptTokens=[int]$promptCounts.totalPromptTokens
                    processedPromptTokens=[int]$promptCounts.processedPromptTokens
                    cachedPromptTokens=[int]$promptCounts.cachedPromptTokens
                    promptMs=[double]$timings.prompt_ms
                    serverProcessedPromptTokensPerSecond=[double]$promptCounts.serverPromptTokensPerSecond
                    predictedTokens=[int]$timings.predicted_n; predictedMs=[double]$timings.predicted_ms
                    serverDecodeTokensPerSecond=[double]$timings.predicted_per_second
                    draftTokens=$(if ($timings.PSObject.Properties.Name -contains 'draft_n') { [int]$timings.draft_n } else { 0 })
                    acceptedDraftTokens=$(if ($timings.PSObject.Properties.Name -contains 'draft_n_accepted') { [int]$timings.draft_n_accepted } else { 0 })
                    finishReason=[string]$completion.choices[0].finish_reason
                    outputVisible=(-not [string]::IsNullOrWhiteSpace($contentText))
                    outputPreview=$contentText.Substring(0,[Math]::Min(100,$contentText.Length))
                    reasoningPreview=$reasoningText.Substring(0,[Math]::Min(100,$reasoningText.Length))
                }
            }
            $parsedResponse = Invoke-BonsaiBenchmarkResponse -RequestTask $requestTasks[$i] -RequestContent $requestContents[$i] -ResponseHandler $responseHandler
            $results.Add($parsedResponse)
        } catch {
            if ($null -eq $trialError) { $trialError = $_.Exception }
        }
    }
    if ($null -ne $trialError) { throw $trialError }
    $aggregateRates = Get-BonsaiBenchmarkAggregateRates -WallMs ([Math]::Max(1,[int]$timer.Elapsed.TotalMilliseconds)) -Responses @($results.ToArray())
    $timerSample = @($script:samples | Select-Object -Skip $sampleStart)
    [pscustomobject]@{
        label=$Label; targetPromptTokens=[int]$Prompt.targetTokens; tokenizedTextTokens=[int]$Prompt.tokens
        isolationTag=[string]$Prompt.isolationTag
        concurrency=$Concurrency; maxOutputTokens=$MaxOutputTokens; wallMs=[Math]::Round($timer.Elapsed.TotalMilliseconds,2)
        wallClockTotalPromptTokensPerSecond=[double]$aggregateRates.wallClockTotalPromptTokensPerSecond
        wallClockProcessedPromptTokensPerSecond=[double]$aggregateRates.wallClockProcessedPromptTokensPerSecond
        wallClockCachedPromptTokensPerSecond=[double]$aggregateRates.wallClockCachedPromptTokensPerSecond
        wallClockAggregateCompletionTokensPerSecond=[double]$aggregateRates.wallClockAggregateCompletionTokensPerSecond
        aggregatePromptTokens=[int64]$aggregateRates.totalPromptTokens
        aggregateProcessedPromptTokens=[int64]$aggregateRates.processedPromptTokens
        aggregateCachedPromptTokens=[int64]$aggregateRates.cachedPromptTokens
        aggregatePredictedTokens=[int64]$aggregateRates.predictedTokens
        responses=@($results); peakWorkingSetBytes=[int64](($timerSample | Measure-Object workingSetBytes -Maximum).Maximum)
        peakPrivateCommitBytes=[int64](($timerSample | Measure-Object privateCommitBytes -Maximum).Maximum)
        peakVirtualBytes=[int64](($timerSample | Measure-Object virtualBytes -Maximum).Maximum)
        peakGpuUsedMiB=$(($timerSample | Measure-Object gpuUsedMiB -Maximum).Maximum)
        peakGpuUsedPercent=$(($timerSample | Measure-Object gpuUsedPercent -Maximum).Maximum)
        sampleCount=$timerSample.Count; samples=$timerSample
    }
}

function Write-CurrentBenchmarkCheckpoint([bool]$Completed) {
    $checkpointReport = [pscustomobject]@{
        schema=1; recorded=(Get-Date).ToString('o'); runId=$runNonce; model=[string]$cfg.Raw.alias
        executable=$cfg.Executable; modelFile=$cfg.Model; deploymentFingerprint=[string]$active.deploymentFingerprint
        mtpMode=$ExpectedMtpMode; maxDraftTokens=[int]$cfg.Raw.mtp.maxDraftTokens
        warmLiveSlots=[int]$cfg.Raw.warmLiveSlots; temporaryThirdSlot=[bool]$cfg.Raw.temporaryTrialSlot
        parallel=[int]$active.parallel; contextPerSlot=$contextPerSlot; aggregateContext=[int]$active.aggregateContext
        concurrencyLevels=@($selectedConcurrencyLevels)
        kvCache="K=$($cfg.Raw.cacheTypeK), V=$($cfg.Raw.cacheTypeV)"
        vision=[pscustomobject]@{ enabled=$false; modalities=$props.modalities }
        kernelWorkingSetCapApplied=[bool]$active.kernelWorkingSetCapApplied
        workingSetLimitErrorCode=[int]$active.workingSetLimitErrorCode
        workingSetLimitBytes=[int64]$active.workingSetLimitBytes
        checkpoint=[pscustomobject]@{
            status=$(if ($Completed) { 'completed' } else { 'in-progress' })
            completedCases=$trialResults.Count
            expectedCases=($PromptTokenTargets.Count * $selectedConcurrencyLevels.Count)
            lastCompletedCase=$(if ($trialResults.Count -gt 0) { $trialResults[$trialResults.Count - 1].label } else { $null })
        }
        promptMetrics='total prompt tokens=prompt_n+cache_n; processed and cached counts are reported separately; every measured case has a unique arm/case prefix to prevent prior prefix-cache reuse.'
        note='Private commit is recorded separately and is not capped. Samples are approximately 500ms snapshots while each measured HTTP trial was in flight. Server per-request rates and wall-clock aggregate rates are distinct.'
        trials=@($trialResults.ToArray()); allSamples=@($samples.ToArray())
    }
    [void](Write-BonsaiBenchmarkReportCheckpoint -Path $OutputPath -Report $checkpointReport)
    return $checkpointReport
}

try {
    # Warm up each deployment before recording comparable requests.
    $warmPrompt = New-BenchmarkPrompt 32 "$([Guid]::NewGuid().ToString('N').Substring(0,8))-warmup"
    $warmBody = @{ model=$cfg.Raw.alias; max_tokens=12; messages=@(@{ role='user'; content=$warmPrompt.text }) } | ConvertTo-Json -Depth 8 -Compress
    [void](Invoke-RestMethod -Uri ($baseUri + '/v1/chat/completions') -Method Post -ContentType 'application/json' -Body $warmBody -TimeoutSec 120)
    $trialResults = [Collections.Generic.List[object]]::new()
    foreach ($target in $PromptTokenTargets) {
        foreach ($concurrency in $selectedConcurrencyLevels) {
            $isolationTag = "$([Guid]::NewGuid().ToString('N').Substring(0,8))-$ExpectedMtpMode-p$($active.parallel)-t$target-c$concurrency"
            $prompt = New-BenchmarkPrompt ([int]$target) $isolationTag
            $trialResults.Add((Invoke-BenchmarkTrial $prompt ([int]$concurrency) "tokens-$target-concurrency-$concurrency"))
            [void](Write-CurrentBenchmarkCheckpoint -Completed $false)
        }
        Write-Output ("benchmark complete: mode={0}; target={1}; tokenized={2}; concurrency={3}" -f $ExpectedMtpMode,$target,$prompt.tokens,($selectedConcurrencyLevels -join ','))
    }
    $report = Write-CurrentBenchmarkCheckpoint -Completed $true
    $summary = foreach ($trial in $trialResults) {
        foreach ($result in $trial.responses) {
            [pscustomobject]@{
                label=$trial.label; concurrency=$trial.concurrency; promptTokens=$result.promptTokens
                processedPromptTokens=$result.processedPromptTokens; cachedPromptTokens=$result.cachedPromptTokens; predictedTokens=$result.predictedTokens
                serverProcessedPromptTokensPerSecond=$result.serverProcessedPromptTokensPerSecond
                serverDecodeTokensPerSecond=$result.serverDecodeTokensPerSecond
                wallClockTotalPromptTokensPerSecond=$trial.wallClockTotalPromptTokensPerSecond
                wallClockProcessedPromptTokensPerSecond=$trial.wallClockProcessedPromptTokensPerSecond
                wallClockCachedPromptTokensPerSecond=$trial.wallClockCachedPromptTokensPerSecond
                wallClockAggregateCompletionTokensPerSecond=$trial.wallClockAggregateCompletionTokensPerSecond
                draftTokens=$result.draftTokens; acceptedDraftTokens=$result.acceptedDraftTokens
                peakWorkingSetGiB=[Math]::Round($trial.peakWorkingSetBytes / 1GB,2)
                peakPrivateCommitGiB=[Math]::Round($trial.peakPrivateCommitBytes / 1GB,2)
                peakGpuUsedMiB=$trial.peakGpuUsedMiB; finishReason=$result.finishReason
            }
        }
    }
    [pscustomobject]@{ status='completed'; output=$OutputPath; mode=$ExpectedMtpMode; slots=$active.parallel; contextPerSlot=$contextPerSlot; summary=@($summary) } | ConvertTo-Json -Depth 8
} finally { $client.Dispose() }
