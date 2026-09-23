[CmdletBinding()]
param([string]$RepositoryRoot = (Join-Path $PSScriptRoot '..'))
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
$files = @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File -Recurse)
foreach ($file in $files) {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { throw "syntax errors in $($file.FullName): $($errors -join '; ')" }
    $text=Get-Content -LiteralPath $file.FullName -Raw
    if ($text -match '(?i)([A-Z]:\\Users\\[^\\\r\n]+\\|G:\\(?:bonsai-deployment|gguf)\\|sk-[A-Za-z0-9]{12,}|Bearer\s+[A-Za-z0-9._-]{12,})') { throw "machine path or credential-like text in $($file.FullName)" }
}
$template = Get-Content -LiteralPath (Join-Path $root 'config/server.template.json') -Raw | ConvertFrom-Json
if ($template.contextPerSlot -ne 262144) { throw 'each server slot must retain 262144 context tokens' }
if ($template.warmLiveSlots -ne 2 -or $template.preferredParallel -ne 2 -or $template.fallbackParallel -ne 2) { throw 'normal production must keep exactly two live warm/GPU-KV slots' }
if ($template.temporaryTrialSlot -or ($template.PSObject.Properties.Name -contains 'controlledCapacityTrial')) { throw 'the normal production template must not opt into a temporary third slot' }
if ($template.mtp.mode -ne 'none' -or $template.mtp.maxDraftTokens -ne 2) { throw 'MTP must be opt-in and capped at two draft tokens' }
if ($template.reasoningEffort -ne 'medium') { throw 'reasoning effort must be medium' }
if ($template.reasoningBudget -ne -1) { throw 'reasoning budget must remain unlimited' }
if ($template.visionEnabled -ne $false) { throw 'vision must be disabled' }
if ($template.maxWorkingSetGiB -ne 12) { throw 'resident working-set ceiling must be 12 GiB' }
if ($template.maxGpuMemoryPercent -ne 95) { throw 'GPU memory watchdog threshold mismatch' }
if ($template.healthFailureThreshold -ne 10) { throw 'post-ready health recovery must require ten consecutive failed checks' }
if ($template.cacheTypeK -ne 'q4_0' -or $template.cacheTypeV -ne 'q4_0') { throw 'KV cache must use q4_0 for both K and V' }
if ($template.host -ne '127.0.0.1') { throw 'server template is not loopback-only' }
$templateProperties = @($template.PSObject.Properties.Name)
if ($templateProperties -contains 'projector' -or $template.visionEnabled) { throw 'vision/projector configuration must be absent' }
if ($templateProperties -contains 'maxPrivateBytes' -or $templateProperties -contains 'maxCommitGiB') { throw 'do not impose a private-commit ceiling' }
$cacheProperties = @($template.slotCache.PSObject.Properties.Name)
if ($cacheProperties -contains 'warmLimitGiB' -or $cacheProperties -contains 'coldLimitGiB' -or
    $cacheProperties -notcontains 'diskLimitGiB' -or $template.slotCache.diskLimitGiB -ne 100 -or
    $template.slotCache.maxSavedJobs -ne 20) {
    throw 'dormant slot state must use one 100-GiB G: disk budget for at most 20 saved jobs, with no separate RAM snapshot tier'
}
foreach ($p in @($template.executable,$template.model,$template.slotSavePath,$template.logs.supervisor,$template.logs.serverStdout,$template.logs.serverStderr)) {
    if ([IO.Path]::IsPathRooted([string]$p)) { throw "absolute path in safe template: $p" }
}
$bad=@(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object { $_.Extension -in @('.gguf','.exe','.dll','.bin','.safetensors') })
if ($bad.Count -gt 0) { throw "binary/model artifact present: $($bad.FullName -join ', ')" }
Write-Output ("PASS: parsed {0} PowerShell files; checked safe config, paths, secrets, and artifacts" -f $files.Count)
. (Join-Path $root 'scripts/Lib-Bonsai.ps1')
. (Join-Path $root 'scripts/Lib-BonsaiSlots.ps1')
$cfg = Import-BonsaiConfig (Join-Path $root 'config/server.template.json')
if (-not (Test-Path -LiteralPath $cfg.ChatTemplateFile -PathType Leaf)) { throw 'chat template path must resolve to a packaged file' }
$taskTemplatePath = Join-Path $root 'config/scheduled-task.template.xml'
[xml]$taskTemplate = Get-Content -LiteralPath $taskTemplatePath -Raw
if ($taskTemplate.Task.Triggers.ChildNodes.Name -notcontains 'BootTrigger') { throw 'scheduled task template must start at boot' }
if ($taskTemplate.Task.Principals.Principal.LogonType -ne 'S4U' -or $taskTemplate.Task.Principals.Principal.RunLevel -ne 'LeastPrivilege') { throw 'boot task must use a non-elevated S4U principal' }
if ($taskTemplate.Task.Triggers.ChildNodes.Name -contains 'LogonTrigger') { throw 'AtLogon is fallback-only, not a second startup trigger' }
$startupPlan = Get-BonsaiTaskRegistrationPlan -Mode Auto
$fallbackPlan = Get-BonsaiTaskRegistrationPlan -Mode Auto -S4UAvailable $false -FallbackReason 'test: batch logon not granted'
if ($startupPlan.Trigger -ne 'AtStartup' -or $startupPlan.LogonType -ne 'S4U' -or $startupPlan.RunLevel -ne 'Limited') { throw 'default scheduled-task plan must be Limited S4U/AtStartup' }
if ($fallbackPlan.Trigger -ne 'AtLogon' -or $fallbackPlan.LogonType -ne 'Interactive' -or $fallbackPlan.RunLevel -ne 'Limited') { throw 'S4U fallback must be Limited Interactive/AtLogon' }
if (-not (Test-BonsaiS4UFallbackErrorCode -ErrorCode 1314) -or -not (Test-BonsaiS4UFallbackErrorCode -ErrorCode 1385) -or (Test-BonsaiS4UFallbackErrorCode -ErrorCode 5)) { throw 'S4U fallback must be limited to recognized privilege/logon-right errors' }
$registerTaskText = Get-Content -LiteralPath (Join-Path $root 'scripts/Register-BonsaiTask.ps1') -Raw
$unregisterTaskText = Get-Content -LiteralPath (Join-Path $root 'scripts/Unregister-BonsaiTask.ps1') -Raw
if ($registerTaskText -match 'HighestAvailable|RunLevel\s+Highest' -or $registerTaskText -notmatch 'S4U' -or $registerTaskText -notmatch 'AtStartup' -or $registerTaskText -notmatch 'AtLogOn') { throw 'task registration must safely prefer S4U startup with a Limited AtLogon fallback' }
$expectedWatcherJoin = 'Join-Path $root ''scripts\Watch-BonsaiServer.ps1'''
if ($registerTaskText -match '\$watch\s*=\s*Join-Path \$PSScriptRoot' -or -not $registerTaskText.Contains($expectedWatcherJoin)) { throw 'registered task must launch the absolute deployment-root watcher, not a repository worktree' }
$rootTaskPathDeclaration = '[string]$TaskPath = ''\'''
if (-not $unregisterTaskText.Contains($rootTaskPathDeclaration) -or $unregisterTaskText -notmatch '-TaskPath \$TaskPath') { throw 'task unregistration must target only the explicit root task path' }
Write-Output 'PASS: startup task selects non-elevated S4U with an authorization-only AtLogon fallback'
$healthState = Get-BonsaiHealthFailureStatus -ConsecutiveFailures 0 -ServerWasReady $false -HealthOk $false -Threshold $cfg.Raw.healthFailureThreshold
if ($healthState.consecutiveFailures -ne 0 -or $healthState.restartRequired) { throw 'startup/model-loading health failures must not trigger post-ready recovery' }
$healthState = Get-BonsaiHealthFailureStatus -ConsecutiveFailures 0 -ServerWasReady $true -HealthOk $false -Threshold $cfg.Raw.healthFailureThreshold
if ($healthState.consecutiveFailures -ne 1 -or $healthState.restartRequired) { throw 'a single transient post-ready health failure must not restart the server' }
$healthState = Get-BonsaiHealthFailureStatus -ConsecutiveFailures $healthState.consecutiveFailures -ServerWasReady $true -HealthOk $true -Threshold $cfg.Raw.healthFailureThreshold
if ($healthState.consecutiveFailures -ne 0 -or $healthState.restartRequired) { throw 'a recovered health check must reset the consecutive failure count' }
for ($i=1; $i -lt [int]$cfg.Raw.healthFailureThreshold; $i++) {
    $healthState = Get-BonsaiHealthFailureStatus -ConsecutiveFailures $healthState.consecutiveFailures -ServerWasReady $true -HealthOk $false -Threshold $cfg.Raw.healthFailureThreshold
    if ($healthState.restartRequired) { throw 'server recovery triggered before the configured consecutive-failure threshold' }
}
$healthState = Get-BonsaiHealthFailureStatus -ConsecutiveFailures $healthState.consecutiveFailures -ServerWasReady $true -HealthOk $false -Threshold $cfg.Raw.healthFailureThreshold
if ($healthState.consecutiveFailures -ne 10 -or -not $healthState.restartRequired) { throw 'ten consecutive failed health checks must request supervised recovery' }
$apiChecks = Get-BonsaiLiveApiChecks -Response ([pscustomobject]@{output=@(@{type='message'})}) -Chat ([pscustomobject]@{choices=@(@{message=@{content='ok'}})}) -Message ([pscustomobject]@{content=@(@{type='text';text='ok'})})
Assert-BonsaiLiveApiChecks $apiChecks
$missingApiChecks = Get-BonsaiLiveApiChecks -Response ([pscustomobject]@{output=@()}) -Chat ([pscustomobject]@{choices=@()}) -Message ([pscustomobject]@{content=@()})
$apiFailureWasReported = $false
try { Assert-BonsaiLiveApiChecks $missingApiChecks } catch { if ($_.Exception.Message -match 'responses|chat|messages') { $apiFailureWasReported = $true } else { throw } }
if (-not $apiFailureWasReported) { throw 'live API contract must fail when any endpoint returns an empty response' }
Write-Output 'PASS: Live mode asserts non-empty Responses, Chat, and Messages output'
$watcherSource = Get-Content -LiteralPath (Join-Path $root 'scripts/Watch-BonsaiServer.ps1') -Raw
if ($watcherSource -notmatch 'Get-BonsaiHealthFailureStatus' -or $watcherSource -notmatch 'Stop-Process -Id \$child\.Id') { throw 'post-ready health failure recovery must terminate the supervised child job' }
if ($watcherSource -notmatch 'server exited with code' -or $watcherSource -notmatch 'restarting after \{0\} seconds') { throw 'unexpected child exits must retain the existing restart/backoff path' }
Write-Output 'PASS: startup health grace, consecutive unhealthy recovery, and crash restart path'
$benchmarkLibrary = Join-Path $root 'scripts/Lib-BonsaiBenchmark.ps1'
. $benchmarkLibrary
$trackedResponse = [pscustomobject]@{ Disposed = $false }
$trackedResponse | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true }
$trackedRequest = [pscustomobject]@{ Disposed = $false }
$trackedRequest | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true }
$responseTask = [Threading.Tasks.Task[object]]::FromResult([object]$trackedResponse)
$parseFailedAsExpected = $false
try {
    [void](Invoke-BonsaiBenchmarkResponse -RequestTask $responseTask -RequestContent $trackedRequest -ResponseHandler { param($response) throw 'simulated response parse failure' })
} catch {
    if ($_.Exception.Message -ne 'simulated response parse failure') { throw }
    $parseFailedAsExpected = $true
}
if (-not $parseFailedAsExpected -or -not $trackedResponse.Disposed -or -not $trackedRequest.Disposed) { throw 'benchmark response and request content must be disposed after a parse exception' }
Write-Output 'PASS: benchmark HTTP resources are disposed when response parsing fails'
$contextTrialAccepted=$false
try { Assert-BonsaiContextPerSlotPolicy -ContextPerSlot 204800 -ControlledCapacityTrial $true -PreferredParallel 3 -FallbackParallel 2; $contextTrialAccepted=$true } catch { }
if (-not $contextTrialAccepted) { throw 'controlled 204800-token capacity trials must be explicitly supported' }
$contextFloorRejected=$false
try { Assert-BonsaiContextPerSlotPolicy -ContextPerSlot 204799 -ControlledCapacityTrial $true -PreferredParallel 3 -FallbackParallel 2 } catch { $contextFloorRejected=$true }
if (-not $contextFloorRejected) { throw 'capacity trials must never go below 204800 tokens per slot' }
$unmarkedContextRejected=$false
try { Assert-BonsaiContextPerSlotPolicy -ContextPerSlot 204800 -ControlledCapacityTrial $false -PreferredParallel 3 -FallbackParallel 2 } catch { $unmarkedContextRejected=$true }
if (-not $unmarkedContextRejected) { throw '204800-token context must require the explicit controlled-trial marker' }
$normalContextAccepted=$false
try { Assert-BonsaiContextPerSlotPolicy -ContextPerSlot 262144 -ControlledCapacityTrial $false -PreferredParallel 2 -FallbackParallel 2; $normalContextAccepted=$true } catch { }
if (-not $normalContextAccepted) { throw 'normal 2x262144 production configuration must be accepted' }
$unmarkedThirdSlotRejected=$false
try { Assert-BonsaiContextPerSlotPolicy -ContextPerSlot 262144 -ControlledCapacityTrial $false -PreferredParallel 3 -FallbackParallel 2 } catch { $unmarkedThirdSlotRejected=$true }
if (-not $unmarkedThirdSlotRejected) { throw 'normal production must not implicitly enable a third live slot' }
$topologyChecks=@(
    @{Context=262144;Slots=2;Trial=$false;Expected=$true},
    @{Context=204800;Slots=3;Trial=$true;Expected=$true},
    @{Context=204800;Slots=2;Trial=$true;Expected=$true},
    @{Context=262144;Slots=3;Trial=$false;Expected=$false},
    @{Context=204800;Slots=1;Trial=$true;Expected=$false}
)
foreach($case in $topologyChecks){$accepted=$false;try{Assert-BonsaiBenchmarkTopology -ContextPerSlot $case.Context -ActiveParallel $case.Slots -ControlledCapacityTrial $case.Trial;$accepted=$true}catch{};if($accepted -ne $case.Expected){throw "benchmark topology policy mismatch for context=$($case.Context), slots=$($case.Slots)"}}
if ([string]::Join(',',(Get-BonsaiBenchmarkConcurrencyLevels -ActiveParallel 3)) -ne '1,2,3') { throw 'three-slot benchmarks must exercise serial, two-way, and full three-way concurrency' }
if ([string]::Join(',',(Get-BonsaiBenchmarkConcurrencyLevels -ActiveParallel 2)) -ne '1,2') { throw 'two-slot benchmarks must exercise serial and full two-way concurrency' }
if ([string]::Join(',',(Get-BonsaiBenchmarkConcurrencyLevels -ActiveParallel 2 -RequestedLevels @(1))) -ne '1') { throw 'single-row artifact smoke must be able to request exactly one safe concurrency level' }
$invalidConcurrencySelectionRejected=$false
try { [void](Get-BonsaiBenchmarkConcurrencyLevels -ActiveParallel 2 -RequestedLevels @(1,3)) } catch { $invalidConcurrencySelectionRejected=$true }
if (-not $invalidConcurrencySelectionRejected) { throw 'benchmark concurrency selection must reject levels above active slots' }
$promptOne=New-BonsaiBenchmarkPromptText -TargetTokenCount 1024
$promptTwo=New-BonsaiBenchmarkPromptText -TargetTokenCount 1024
if ($promptOne -cne $promptTwo) { throw 'A/B trials must reuse byte-identical prompts independent of labels/configuration' }
$isolatedPrompt=New-BonsaiBenchmarkPromptText -TargetTokenCount 1024 -IsolationTag 'runA-short-c1'
if ($isolatedPrompt -ceq $promptOne -or $isolatedPrompt -notmatch 'runA-short-c1') { throw 'benchmark cases need explicit unique prefixes to prevent accidental prompt-cache reuse' }
$promptCounts=Get-BonsaiBenchmarkPromptCounts -Timings ([pscustomobject]@{prompt_n=4;cache_n=49;prompt_per_second=25.4})
if ($promptCounts.totalPromptTokens -ne 53 -or $promptCounts.processedPromptTokens -ne 4 -or
    $promptCounts.cachedPromptTokens -ne 49 -or $promptCounts.serverPromptTokensPerSecond -ne 25.4) {
    throw 'benchmark must preserve total, newly processed, and cached prompt token counts separately'
}
$aggregate=Get-BonsaiBenchmarkAggregateRates -WallMs 2000 -Responses @(
    [pscustomobject]@{promptTokens=100;processedPromptTokens=80;cachedPromptTokens=20;predictedTokens=20},
    [pscustomobject]@{promptTokens=60;processedPromptTokens=40;cachedPromptTokens=20;predictedTokens=20}
)
if ($aggregate.wallClockTotalPromptTokensPerSecond -ne 80 -or $aggregate.wallClockProcessedPromptTokensPerSecond -ne 60 -or
    $aggregate.wallClockCachedPromptTokensPerSecond -ne 20 -or $aggregate.wallClockAggregateCompletionTokensPerSecond -ne 20 -or
    $aggregate.requestCount -ne 2) { throw 'benchmark must separate total/cached/processed prompt tokens and aggregate decode rates' }
$checkpointPath = Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('bonsai-benchmark-checkpoint-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $partialReport = [pscustomobject]@{ checkpoint=[pscustomobject]@{status='in-progress';completedCases=1}; trials=@([pscustomobject]@{label='short-c1'}) }
    [void](Write-BonsaiBenchmarkReportCheckpoint -Path $checkpointPath -Report $partialReport)
    $savedPartial = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
    if ($savedPartial.checkpoint.status -ne 'in-progress' -or $savedPartial.checkpoint.completedCases -ne 1 -or $savedPartial.trials.Count -ne 1) { throw 'benchmark partial case checkpoint must be valid JSON with all finished rows' }
    $completeReport = [pscustomobject]@{ checkpoint=[pscustomobject]@{status='completed';completedCases=2}; trials=@([pscustomobject]@{label='short-c1'},[pscustomobject]@{label='1k-c3'}) }
    [void](Write-BonsaiBenchmarkReportCheckpoint -Path $checkpointPath -Report $completeReport)
    $savedComplete = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
    if ($savedComplete.checkpoint.status -ne 'completed' -or $savedComplete.checkpoint.completedCases -ne 2 -or $savedComplete.trials.Count -ne 2) { throw 'benchmark atomic checkpoint must replace prior partial data with the final report' }
    if (Test-Path -LiteralPath ($checkpointPath + '.tmp')) { throw 'benchmark checkpoint must not leave its temporary file behind' }
} finally {
    Remove-Item -LiteralPath $checkpointPath,($checkpointPath + '.tmp') -Force -ErrorAction SilentlyContinue
}
Write-Output 'PASS: benchmark checkpoints are valid and atomically replaced after each completed case'
Write-Output 'PASS: 204800-token controlled context floor, 2/3-slot topology, identical prompts, and aggregate rates'
$slotManagerText = Get-Content -LiteralPath (Join-Path $root 'scripts/Manage-BonsaiSlots.ps1') -Raw
$liveTestText = Get-Content -LiteralPath (Join-Path $root 'scripts/Test-Bonsai.ps1') -Raw
if ($slotManagerText -match 'Get-TierBytes|\$warmLimit|\$coldLimit|\$Tier|tier=') { throw 'slot manager must not configure or maintain a warm-RAM tier' }
if ($slotManagerText -notmatch 'warm/cold tiers are obsolete' -or $slotManagerText -notmatch 'diskLimitGiB' -or $slotManagerText -notmatch 'maxSavedJobs') { throw 'slot manager must reject legacy RAM-tier config and require bounded disk-only settings' }
if ($liveTestText -notmatch "requiredFlags=@\([^\r\n]*'--slot-save-path'") { throw 'contract output must report the required slot-save-path flag' }
if ($slotManagerText -notmatch 'deploymentFingerprint=\(Get-BonsaiActiveDeploymentFingerprint \$cfg\)' -or
    $slotManagerText -notmatch 'deploymentFingerprint -ne \$activeFingerprint') {
    throw 'slot persistence must save and verify the complete deployment fingerprint'
}
$slotRows = @(
    [pscustomobject]@{ filename='restored.kv'; tier='cold'; state='inactive'; lastAccess='2026-01-01T00:00:00Z'; identitySha256='hash' },
    [pscustomobject]@{ filename='other.kv'; tier='warm'; state='inactive'; lastAccess='2026-01-02T00:00:00Z'; identitySha256='other' }
)
$slotRows = Set-BonsaiSlotCacheEntryState -Entries $slotRows -Filename 'restored.kv' -State active
if ((Select-BonsaiInactiveSlot -Entries $slotRows).filename -ne 'other.kv') { throw 'disk eviction must ignore legacy tier labels and skip a restored/active slot' }
$slotRows = Set-BonsaiSlotCacheEntryState -Entries $slotRows -Filename 'restored.kv' -State inactive
if ((Select-BonsaiInactiveSlot -Entries $slotRows).filename -ne 'restored.kv') { throw 'explicit release must make a restored slot eligible for disk eviction' }
$diskRows = ConvertTo-BonsaiDiskSlotEntries -Entries $slotRows
if (@($diskRows | Where-Object { $_.PSObject.Properties['tier'] }).Count -ne 0) { throw 'legacy warm/cold labels must be discarded as obsolete metadata, not treated as separate stores' }
$diskPlan = Get-BonsaiDiskCacheBudgetPlan -Entries @(
    [pscustomobject]@{filename='old.kv';state='inactive';bytes=80;lastAccess='2026-01-01'},
    [pscustomobject]@{filename='active.kv';state='active';bytes=80;lastAccess='2026-01-02'},
    [pscustomobject]@{filename='new.kv';state='inactive';bytes=80;lastAccess='2026-01-03'}
) -MaxBytes 160 -MaxFiles 2 -ProtectedFilename 'new.kv'
if ([string]::Join(',', $diskPlan.evicted) -ne 'old.kv' -or $diskPlan.bytes -ne 160 -or $diskPlan.fileCount -ne 2) { throw 'disk eviction must jointly enforce bytes and saved-job count while protecting the new save and active entries' }
$blockedDiskPlan = $false
try {
    [void](Get-BonsaiDiskCacheBudgetPlan -Entries @(
        [pscustomobject]@{filename='active-a.kv';state='active';bytes=80;lastAccess='2026-01-01'},
        [pscustomobject]@{filename='new.kv';state='inactive';bytes=80;lastAccess='2026-01-02'}
    ) -MaxBytes 100 -MaxFiles 1 -ProtectedFilename 'new.kv')
} catch { $blockedDiskPlan = $true }
if (-not $blockedDiskPlan) { throw 'disk budget must fail without deleting protected new or active state when no safe eviction can satisfy it' }
Assert-BonsaiSlotIdentity -IdentityText 'session-identity' -Operation Save
$emptyIdentityRejected = $false
try { Assert-BonsaiSlotIdentity -IdentityText '  ' -Operation Save } catch { $emptyIdentityRejected = $true }
if (-not $emptyIdentityRejected) { throw 'Save must reject an empty identity because Restore requires one' }
$retainedCheckPassed = $false
try { Assert-BonsaiSlotSaveRetained -Filename 'oversize.kv' -Entries @() -FileExists $false } catch { $retainedCheckPassed = $true }
if (-not $retainedCheckPassed) { throw 'Save must fail when budget enforcement immediately evicts its new file' }
Assert-BonsaiSlotSaveRetained -Filename 'kept.kv' -Entries @([pscustomobject]@{filename='kept.kv'}) -FileExists $true
if ($slotManagerText -notmatch "'Release'\s*\{" -or $slotManagerText -notmatch 'Assert-BonsaiSlotSaveRetained' -or $slotManagerText -notmatch "Assert-BonsaiSlotIdentity.*Operation Save") { throw 'slot manager must expose safe release, require Save identity, and detect immediate budget eviction' }
Write-Output 'PASS: restored slot state, disk-only cache, identity, and budget eviction protections'
$fingerprintTemp = Join-Path ([IO.Path]::GetFullPath($env:TEMP)) ('bonsai-fingerprint-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fingerprintTemp)
try {
    $fingerprintExe = Join-Path $fingerprintTemp 'llama-server.exe'
    $fingerprintModel = Join-Path $fingerprintTemp 'model.gguf'
    $fingerprintTemplate = Join-Path $fingerprintTemp 'chat-template.jinja'
    [IO.File]::WriteAllText($fingerprintExe,'runtime')
    [IO.File]::WriteAllText($fingerprintModel,'model')
    [IO.File]::WriteAllText($fingerprintTemplate,'template-v1')
    $fingerprintConfig = [pscustomobject]@{
        Executable=$fingerprintExe; Model=$fingerprintModel; ChatTemplateFile=$fingerprintTemplate; RunStatePath=$fingerprintTemp
        Raw=[pscustomobject]@{
            contextPerSlot=262144; cacheTypeK='q4_0'; cacheTypeV='q4_0';
            gpuLayers=-1; flashAttention=$true;
            mtp=[pscustomobject]@{mode='none';maxDraftTokens=2}; reasoningEffort='medium'; reasoningBudget=-1
        }
    }
    $fingerprintBase = Get-BonsaiDeploymentFingerprint $fingerprintConfig
    [IO.File]::WriteAllText($fingerprintTemplate,'template-v2')
    if ((Get-BonsaiDeploymentFingerprint $fingerprintConfig) -eq $fingerprintBase) { throw 'template changes must invalidate saved slot state' }
    [IO.File]::WriteAllText($fingerprintTemplate,'template-v1')
    if ((Get-BonsaiDeploymentFingerprint $fingerprintConfig -MtpMode 'draft-mtp') -eq $fingerprintBase) { throw 'effective MTP override must invalidate slot state' }
    $fingerprintConfig.Raw.gpuLayers=42
    if ((Get-BonsaiDeploymentFingerprint $fingerprintConfig) -eq $fingerprintBase) { throw 'GPU layer setting must invalidate slot state' }
    $fingerprintConfig.Raw.gpuLayers=-1; $fingerprintConfig.Raw.flashAttention=$false
    if ((Get-BonsaiDeploymentFingerprint $fingerprintConfig) -eq $fingerprintBase) { throw 'flash-attention setting must invalidate slot state' }
    $fingerprintConfig.Raw.flashAttention=$true
    $fingerprintConfig.Raw.mtp.mode='draft-mtp'
    if ((Get-BonsaiDeploymentFingerprint $fingerprintConfig) -eq $fingerprintBase) { throw 'MTP mode changes must invalidate saved slot state' }
    $fingerprintConfig.Raw.mtp.mode='none'; $fingerprintConfig.Raw.contextPerSlot=131072
    if ((Get-BonsaiDeploymentFingerprint $fingerprintConfig) -eq $fingerprintBase) { throw 'per-slot context changes must invalidate saved slot state' }
    $fingerprintConfig.Raw.contextPerSlot=262144
    $effectiveMtpFingerprint = Get-BonsaiDeploymentFingerprint -Config $fingerprintConfig -MtpMode 'draft-mtp'
    $activeFingerprintState = [pscustomobject]@{ status='ready'; mtpMode='draft-mtp'; deploymentFingerprint=$effectiveMtpFingerprint }
    [IO.File]::WriteAllText((Join-Path $fingerprintTemp 'active-slots.json'),($activeFingerprintState | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    if ((Get-BonsaiActiveDeploymentFingerprint $fingerprintConfig) -ne $effectiveMtpFingerprint) { throw 'slot persistence must bind to the active effective MTP mode' }
    $activeFingerprintState.deploymentFingerprint=$fingerprintBase
    [IO.File]::WriteAllText((Join-Path $fingerprintTemp 'active-slots.json'),($activeFingerprintState | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    $mismatchedActiveFingerprintRejected=$false
    try { [void](Get-BonsaiActiveDeploymentFingerprint $fingerprintConfig) } catch { $mismatchedActiveFingerprintRejected=$true }
    if (-not $mismatchedActiveFingerprintRejected) { throw 'slot persistence must reject an active fingerprint that does not match effective launch settings' }
} finally {
    $tempRootFull = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    $fingerprintFull = [IO.Path]::GetFullPath($fingerprintTemp)
    if ($fingerprintFull.StartsWith($tempRootFull,[StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $fingerprintFull -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Output 'PASS: slot cache fingerprints bind runtime, model, template, effective MTP, GPU layers, flash attention, KV, reasoning, and context'
$trialRaw = $template | ConvertTo-Json -Depth 12 | ConvertFrom-Json
$trialRaw.contextPerSlot=204800
$trialRaw.preferredParallel=3
$trialRaw.fallbackParallel=2
$trialRaw | Add-Member -NotePropertyName controlledCapacityTrial -NotePropertyValue $true
$trialRaw.temporaryTrialSlot=$true
$trialConfig = [pscustomobject]@{}
foreach ($property in $cfg.PSObject.Properties) { $trialConfig | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value }
$trialConfig.Raw=$trialRaw
$threeArgs = @(Get-BonsaiServerArguments -Config $trialConfig -Parallel 3)
$twoArgs = @(Get-BonsaiServerArguments -Config $cfg -Parallel 2)
$mtpArgs = @(Get-BonsaiServerArguments -Config $cfg -Parallel 2 -MtpMode 'draft-mtp')
$normalLauncher = @(Get-BonsaiSupervisorLauncherArguments -ConfigPath $cfg.ConfigPath)
$watcherDefaultLauncher = @(Get-BonsaiSupervisorLauncherArguments -ConfigPath $cfg.ConfigPath -MtpMode '')
$launcherMtpOptIn = @(Get-BonsaiSupervisorLauncherArguments -ConfigPath $cfg.ConfigPath -MtpMode 'draft-mtp')
function Get-ArgumentValue([string[]]$Values,[string]$Flag) {
    $index = [Array]::IndexOf($Values,$Flag)
    if ($index -lt 0 -or $index + 1 -ge $Values.Count) { throw "missing argument pair $Flag" }
    return $Values[$index + 1]
}
if ((Get-ArgumentValue $threeArgs '--ctx-size') -ne '614400' -or (Get-ArgumentValue $threeArgs '--parallel') -ne '3') { throw 'temporary third-slot trial aggregate context must be 614400' }
if ((Get-ArgumentValue $twoArgs '--ctx-size') -ne '524288' -or (Get-ArgumentValue $twoArgs '--parallel') -ne '2') { throw 'two-slot aggregate context must be 524288' }
$expectedThreeArgs = @('--host','127.0.0.1','--port','8080','--alias','bonsai2-27b','--ctx-size','614400','--parallel','3','--n-gpu-layers','-1','--jinja','--chat-template-file',$trialConfig.ChatTemplateFile,'--reasoning-effort','medium','--reasoning-budget','-1','--cont-batching','--flash-attn','on','--cache-type-k','q4_0','--cache-type-v','q4_0','--model',$trialConfig.Model,'--no-mmproj','--slot-save-path',$trialConfig.SlotSavePath,'--spec-type','none')
if ([string]::Join([char]0,$threeArgs) -ne [string]::Join([char]0,$expectedThreeArgs)) { throw "three-slot launch arguments diverged from the pinned MTP CLI: $($threeArgs -join ' ')" }
if ((Get-ArgumentValue $twoArgs '--spec-type') -ne 'none' -or $twoArgs -contains '--spec-draft-n-max') { throw 'normal production launch must leave MTP disabled' }
if ((Get-ArgumentValue $threeArgs '--slot-save-path') -ne $cfg.SlotSavePath) { throw 'slot/KV persistence path must be passed to llama-server' }
if ((Get-ArgumentValue $threeArgs '--reasoning-effort') -ne 'medium' -or (Get-ArgumentValue $threeArgs '--reasoning-budget') -ne '-1') { throw 'reasoning arguments mismatch' }
if ((Get-ArgumentValue $threeArgs '--flash-attn') -ne 'on') { throw 'flash attention must pass its explicit on value' }
if ((Get-ArgumentValue $threeArgs '--cache-type-k') -ne 'q4_0' -or (Get-ArgumentValue $threeArgs '--cache-type-v') -ne 'q4_0') { throw 'KV cache arguments mismatch' }
if ($threeArgs -notcontains '--no-mmproj' -or $threeArgs -contains '--mmproj') { throw 'vision flags are enabled or projector is passed' }
if ((Get-ArgumentValue $mtpArgs '--spec-type') -ne 'draft-mtp' -or (Get-ArgumentValue $mtpArgs '--spec-draft-n-max') -ne '2') { throw 'explicit MTP opt-in arguments mismatch' }
$expectedNormalLauncher = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'scripts/Start-BonsaiServer.ps1'),'-ConfigPath',$cfg.ConfigPath)
$expectedLauncherMtpOptIn = @($expectedNormalLauncher + @('-MtpMode','draft-mtp'))
if ([string]::Join([char]0,$normalLauncher) -ne [string]::Join([char]0,$expectedNormalLauncher)) { throw "normal supervisor launch must keep MTP disabled by default: $($normalLauncher -join ' ')" }
if ([string]::Join([char]0,$watcherDefaultLauncher) -ne [string]::Join([char]0,$expectedNormalLauncher)) { throw 'watcher default must pass an empty MTP override without validation failure' }
if ([string]::Join([char]0,$launcherMtpOptIn) -ne [string]::Join([char]0,$expectedLauncherMtpOptIn)) { throw "MTP opt-in mode must reach Start-BonsaiServer: $($launcherMtpOptIn -join ' ')" }
$limitBytes = [int64]12 * 1GB
if (Test-BonsaiWorkingSetBreach -WorkingSetBytes $limitBytes -LimitBytes $limitBytes) { throw 'working-set threshold rejected an exact 12-GiB value' }
if (-not (Test-BonsaiWorkingSetBreach -WorkingSetBytes ($limitBytes + 1) -LimitBytes $limitBytes)) { throw 'working-set threshold missed a value above 12 GiB' }
$kernelNoise = Get-BonsaiWorkingSetEvaluation -WorkingSetBytes ($limitBytes + 65536) -LimitBytes $limitBytes -KernelWorkingSetCapApplied $true
$kernelOver = Get-BonsaiWorkingSetEvaluation -WorkingSetBytes ($limitBytes + 65537) -LimitBytes $limitBytes -KernelWorkingSetCapApplied $true
$limitedOver = Get-BonsaiWorkingSetEvaluation -WorkingSetBytes ($limitBytes + 1) -LimitBytes $limitBytes -KernelWorkingSetCapApplied $false
if ($kernelNoise.breach -or $kernelNoise.toleranceBytes -ne 65536 -or $kernelNoise.effectiveLimitBytes -ne ($limitBytes + 65536)) { throw 'kernel-cap counter noise allowance must be exactly 64 KiB, not a larger RAM budget' }
if (-not $kernelOver.breach -or $kernelOver.toleranceBytes -ne 65536) { throw 'kernel-cap working-set guard must still breach immediately above its 64-KiB tolerance' }
if (-not $limitedOver.breach -or $limitedOver.toleranceBytes -ne 0) { throw 'working-set guard must remain strict when the kernel cap was not applied' }
Write-Output 'PASS: working-set ceiling and 64-KiB kernel-cap tolerance boundaries'
$slotIdleState=@{}
$slotErasedState=@{}
$baseTime=[DateTime]::UtcNow
$trialSlots=@(
    [pscustomobject]@{id=0;is_processing=$false},
    [pscustomobject]@{id=1;is_processing=$false},
    [pscustomobject]@{id=2;is_processing=$false}
)
if (@(Get-BonsaiTemporarySlotEraseCandidates -Slots $trialSlots -WarmLiveSlots 2 -IsTemporaryTrial $true -ActiveParallel 3 -Now $baseTime -GraceSeconds 15 -IdleSince $slotIdleState -ErasedSlots $slotErasedState).Count -ne 0) { throw 'temporary slot must first accumulate its idle grace period' }
if (@(Get-BonsaiTemporarySlotEraseCandidates -Slots $trialSlots -WarmLiveSlots 2 -IsTemporaryTrial $true -ActiveParallel 3 -Now $baseTime.AddSeconds(14) -GraceSeconds 15 -IdleSince $slotIdleState -ErasedSlots $slotErasedState).Count -ne 0) { throw 'temporary slot must not erase before the full idle grace period' }
$eraseReady=@(Get-BonsaiTemporarySlotEraseCandidates -Slots $trialSlots -WarmLiveSlots 2 -IsTemporaryTrial $true -ActiveParallel 3 -Now $baseTime.AddSeconds(15) -GraceSeconds 15 -IdleSince $slotIdleState -ErasedSlots $slotErasedState)
if ($eraseReady.Count -ne 1 -or $eraseReady[0] -ne 2) { throw 'only slot id 2 or greater may become an erase candidate after 15 idle seconds' }
Complete-BonsaiTemporarySlotErase -SlotId 2 -WarmLiveSlots 2 -IdleSince $slotIdleState -ErasedSlots $slotErasedState
if (@(Get-BonsaiTemporarySlotEraseCandidates -Slots $trialSlots -WarmLiveSlots 2 -IsTemporaryTrial $true -ActiveParallel 3 -Now $baseTime.AddSeconds(30) -GraceSeconds 15 -IdleSince $slotIdleState -ErasedSlots $slotErasedState).Count -ne 0) { throw 'a successfully erased idle slot must not be repeatedly erased' }
$busyThird=@($trialSlots | ForEach-Object { if ($_.id -eq 2) { [pscustomobject]@{id=2;is_processing=$true} } else { $_ } })
if (@(Get-BonsaiTemporarySlotEraseCandidates -Slots $busyThird -WarmLiveSlots 2 -IsTemporaryTrial $true -ActiveParallel 3 -Now $baseTime.AddSeconds(31) -GraceSeconds 15 -IdleSince $slotIdleState -ErasedSlots $slotErasedState).Count -ne 0) { throw 'temporary slot cache must never be erased while that slot is processing' }
if (@(Get-BonsaiTemporarySlotEraseCandidates -Slots $trialSlots -WarmLiveSlots 2 -IsTemporaryTrial $true -ActiveParallel 3 -Now $baseTime.AddSeconds(32) -GraceSeconds 15 -IdleSince $slotIdleState -ErasedSlots $slotErasedState).Count -ne 0) { throw 'slot idle grace must restart after a busy interval' }
if (@(Get-BonsaiTemporarySlotEraseCandidates -Slots $trialSlots -WarmLiveSlots 2 -IsTemporaryTrial $true -ActiveParallel 3 -Now $baseTime.AddSeconds(47) -GraceSeconds 15 -IdleSince $slotIdleState -ErasedSlots $slotErasedState).Count -ne 1) { throw 'temporary slot should become eligible after a fresh 15-second idle interval' }
$apiSlotValues = @(
    [pscustomobject]@{id=0;n_ctx=204800;speculative=$false;is_processing=$false;n_prompt_tokens=8335;n_prompt_tokens_processed=0;n_prompt_tokens_cache=0},
    [pscustomobject]@{id=1;n_ctx=204800;speculative=$false;is_processing=$false;n_prompt_tokens=8335;n_prompt_tokens_processed=0;n_prompt_tokens_cache=0},
    [pscustomobject]@{id=2;n_ctx=204800;speculative=$false;is_processing=$false;n_prompt_tokens=8335;n_prompt_tokens_processed=0;n_prompt_tokens_cache=0}
)
$nestedApiSlots = [object[]]::new(1)
$nestedApiSlots[0] = $apiSlotValues
$normalizedApiSlots = @(Get-BonsaiSlotEntries -Slots $nestedApiSlots)
if ($normalizedApiSlots.Count -ne 3 -or (@($normalizedApiSlots | ForEach-Object { [int]$_.id }) -join ',') -ne '0,1,2') { throw 'nested llama-server /slots response must normalize to three ordered slot objects' }
$apiIdleSince = @{}
$apiErased = @{}
$apiFirst = @(Get-BonsaiTemporarySlotEraseCandidates -Slots $nestedApiSlots -WarmLiveSlots 2 -IsTemporaryTrial $true -ActiveParallel 3 -Now $baseTime -GraceSeconds 15 -IdleSince $apiIdleSince -ErasedSlots $apiErased)
if ($apiFirst.Count -ne 0 -or -not $apiIdleSince.Contains('2')) { throw 'llama-server /slots response nested by PowerShell must start the third-slot idle timer' }
$apiReady = @(Get-BonsaiTemporarySlotEraseCandidates -Slots $nestedApiSlots -WarmLiveSlots 2 -IsTemporaryTrial $true -ActiveParallel 3 -Now $baseTime.AddSeconds(15) -GraceSeconds 15 -IdleSince $apiIdleSince -ErasedSlots $apiErased)
if ($apiReady.Count -ne 1 -or $apiReady[0] -ne 2) { throw 'nested live /slots response must yield only idle temporary slot 2 after grace' }
$watcherSource = Get-Content -LiteralPath (Join-Path $root 'scripts/Watch-BonsaiServer.ps1') -Raw
if ($watcherSource -notmatch '\$freshSlots = @\(Get-BonsaiSlotEntries ') { throw 'watcher must flatten the pre-erase /slots re-read (PowerShell nests the JSON array)' }
if ($watcherSource -notmatch 'Get-BonsaiTemporarySlotEraseCandidates' -or $watcherSource -notmatch 'action=erase' -or $watcherSource -notmatch 'temporary slot erase') { throw 'watcher must erase only idle temporary slots and log that policy' }
Write-Output 'PASS: temporary third-slot erase grace, processing guard, and warm slot preservation'
$markerPath = [IO.Path]::GetTempFileName()
try {
    $bootTime = [DateTime]::UtcNow.AddMinutes(-2)
    [IO.File]::WriteAllText($markerPath,'')
    [IO.File]::SetLastWriteTimeUtc($markerPath,[DateTime]::UtcNow.AddMinutes(-3))
    if (-not (Clear-BonsaiStopMarkerFromPreviousBoot -MarkerPath $markerPath -LastBootTime $bootTime) -or (Test-Path -LiteralPath $markerPath)) { throw 'previous-boot stop marker was not cleared' }
    [IO.File]::WriteAllText($markerPath,'')
    [IO.File]::SetLastWriteTimeUtc($markerPath,[DateTime]::UtcNow.AddMinutes(-1))
    if ((Clear-BonsaiStopMarkerFromPreviousBoot -MarkerPath $markerPath -LastBootTime $bootTime) -or -not (Test-Path -LiteralPath $markerPath)) { throw 'current-boot stop marker was cleared unexpectedly' }
} finally { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
Write-Output 'PASS: stop-marker behavior across boot boundaries'
$gpuTotal = [int64]24576
if (Test-BonsaiGpuMemoryBreach -UsedMiB 23347 -TotalMiB $gpuTotal -LimitPercent 95) { throw 'GPU threshold rejected a value below 95 percent' }
if (-not (Test-BonsaiGpuMemoryBreach -UsedMiB 23348 -TotalMiB $gpuTotal -LimitPercent 95)) { throw 'GPU threshold missed the 95-percent boundary' }
$gpuState = Get-BonsaiGpuMemorySnapshot
if (-not $gpuState.available -or $gpuState.totalMiB -le 0) { throw 'nvidia-smi VRAM telemetry must be available for this deployment' }
$job = Start-BonsaiLimitedProcess -Executable (Join-Path $env:SystemRoot 'System32/cmd.exe') -Arguments @('/d','/c','exit','0') -WorkingDirectory $root -MaxWorkingSetGiB 12
try {
    if ($job.KernelWorkingSetCapApplied -and [int]$job.WorkingSetLimitErrorCode -ne 0) { throw 'working-set cap status has an inconsistent error code' }
    if (-not $job.KernelWorkingSetCapApplied -and [int]$job.WorkingSetLimitErrorCode -ne 1314) { throw "unexpected working-set cap failure code $($job.WorkingSetLimitErrorCode)" }
    if (-not $job.Wait(30000)) { throw 'lightweight job-object child did not exit' }
    if ($job.ExitCode -ne 0) { throw "lightweight job-object child exited with code $($job.ExitCode)" }
} finally { $job.Dispose() }
Write-Output ("PASS: process creation, VRAM threshold, and working-set status (kernelCapApplied={0}, error={1})" -f $job.KernelWorkingSetCapApplied,$job.WorkingSetLimitErrorCode)
