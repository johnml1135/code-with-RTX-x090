Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Lib-BonsaiJob.ps1')

function Get-BonsaiFullPath {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$BaseDirectory
    )
    if ([IO.Path]::IsPathRooted($Value)) {
        return [IO.Path]::GetFullPath($Value)
    }
    return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Value))
}

function Assert-BonsaiChildPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Label
    )
    $rootFull = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes deploymentRoot: $pathFull"
    }
    return $pathFull
}

function Assert-BonsaiContextPerSlotPolicy {
    param(
        [Parameter(Mandatory)][int]$ContextPerSlot,
        [Parameter(Mandatory)][bool]$ControlledCapacityTrial,
        [Parameter(Mandatory)][int]$PreferredParallel,
        [Parameter(Mandatory)][int]$FallbackParallel
    )
    if ($ContextPerSlot -eq 262144 -and -not $ControlledCapacityTrial -and $PreferredParallel -eq 2 -and $FallbackParallel -eq 2) { return }
    if ($ControlledCapacityTrial -and $ContextPerSlot -eq 204800 -and $PreferredParallel -eq 3 -and $FallbackParallel -eq 2) { return }
    throw 'Production must use 2x262144; only an explicitly marked temporary-third-slot 3-to-2 trial may use 204800; smaller contexts are forbidden'
}

function Import-BonsaiConfig {
    param([Parameter(Mandatory)][string]$ConfigPath)
    $configFull = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).ProviderPath
    $configDir = Split-Path -Parent $configFull
    $raw = Get-Content -LiteralPath $configFull -Raw -ErrorAction Stop | ConvertFrom-Json
    $root = Get-BonsaiFullPath -Value ([string]$raw.deploymentRoot) -BaseDirectory $configDir
    $controlledTrial = if ($raw.PSObject.Properties.Name -contains 'controlledCapacityTrial') { [bool]$raw.controlledCapacityTrial } else { $false }
    $result = [ordered]@{
        Raw = $raw
        ConfigPath = $configFull
        ConfigDirectory = $configDir
        DeploymentRoot = $root
        Executable = Assert-BonsaiChildPath (Get-BonsaiFullPath ([string]$raw.executable) $configDir) $root 'executable'
        Model = Assert-BonsaiChildPath (Get-BonsaiFullPath ([string]$raw.model) $configDir) $root 'model'
        ChatTemplateFile = Assert-BonsaiChildPath (Get-BonsaiFullPath ([string]$raw.chatTemplateFile) $configDir) $root 'chat template'
        SlotSavePath = Assert-BonsaiChildPath (Get-BonsaiFullPath ([string]$raw.slotSavePath) $configDir) $root 'slotSavePath'
        RunStatePath = Assert-BonsaiChildPath (Get-BonsaiFullPath ([string]$raw.runStatePath) $configDir) $root 'runStatePath'
        SupervisorLog = Assert-BonsaiChildPath (Get-BonsaiFullPath ([string]$raw.logs.supervisor) $configDir) $root 'supervisor log'
        ServerStdoutLog = Assert-BonsaiChildPath (Get-BonsaiFullPath ([string]$raw.logs.serverStdout) $configDir) $root 'server stdout log'
        ServerStderrLog = Assert-BonsaiChildPath (Get-BonsaiFullPath ([string]$raw.logs.serverStderr) $configDir) $root 'server stderr log'
    }
    if ([string]$raw.host -notin @('127.0.0.1','localhost')) { throw 'Bonsai server must remain loopback-only' }
    if ([int]$raw.warmLiveSlots -ne 2) { throw 'Bonsai production policy must keep exactly two warm/live slots' }
    if ($controlledTrial) {
        if (-not [bool]$raw.temporaryTrialSlot -or [int]$raw.preferredParallel -ne 3 -or [int]$raw.fallbackParallel -ne 2) {
            throw 'three-slot capacity runs must explicitly mark the temporary third live slot and fall back to two'
        }
    } elseif ([int]$raw.preferredParallel -ne 2 -or [int]$raw.fallbackParallel -ne 2 -or [bool]$raw.temporaryTrialSlot) {
        throw 'normal production must stay at exactly two live slots; mark any temporary third slot as an explicit capacity trial'
    }
    Assert-BonsaiContextPerSlotPolicy -ContextPerSlot ([int]$raw.contextPerSlot) -ControlledCapacityTrial $controlledTrial -PreferredParallel ([int]$raw.preferredParallel) -FallbackParallel ([int]$raw.fallbackParallel)
    if ([int]$raw.maxWorkingSetGiB -ne 12) { throw 'Bonsai process working-set guard must be 12 GiB' }
    if ([int]$raw.maxGpuMemoryPercent -lt 50 -or [int]$raw.maxGpuMemoryPercent -gt 99) { throw 'GPU memory guard must be between 50 and 99 percent' }
    if ([int]$raw.healthFailureThreshold -lt 3 -or [int]$raw.healthFailureThreshold -gt 60) { throw 'post-ready health failure threshold must be between 3 and 60 consecutive checks' }
    if ([bool]$raw.visionEnabled) { throw 'vision must remain disabled for this deployment' }
    if (@($raw.PSObject.Properties.Name) -contains 'projector') { throw 'vision projector must not be configured' }
    if ([string]$raw.cacheTypeK -ne 'q4_0' -or [string]$raw.cacheTypeV -ne 'q4_0') { throw 'both KV cache types must be q4_0' }
    if ([string]$raw.mtp.mode -notin @('draft-mtp','none') -or [int]$raw.mtp.maxDraftTokens -ne 2) { throw 'MTP must use draft-mtp with a maximum draft of two' }
    if ([string]$raw.reasoningEffort -ne 'medium') { throw 'reasoning effort must be medium' }
    if ([string]$raw.alias -ne 'bonsai2-27b') { throw 'unexpected model alias' }
    return [pscustomobject]$result
}

function Get-BonsaiServerArguments {
    param(
        [Parameter(Mandatory)]$Config,
        [int]$Parallel = 0,
        [string]$MtpMode = ''
    )
    $r = $Config.Raw
    if ($Parallel -eq 0) { $Parallel = [int]$r.preferredParallel }
    if ($Parallel -notin @([int]$r.preferredParallel,[int]$r.fallbackParallel)) { throw "unsupported Bonsai slot count: $Parallel" }
    if ([string]::IsNullOrWhiteSpace($MtpMode)) { $MtpMode = [string]$r.mtp.mode }
    if ($MtpMode -notin @('draft-mtp','none')) { throw "unsupported speculative mode: $MtpMode" }
    $aggregateContext = [int64]$r.contextPerSlot * $Parallel
    $args = [Collections.Generic.List[string]]::new()
    $args.Add('--host'); $args.Add([string]$r.host)
    $args.Add('--port'); $args.Add([string]$r.port)
    $args.Add('--alias'); $args.Add([string]$r.alias)
    $args.Add('--ctx-size'); $args.Add([string]$aggregateContext)
    $args.Add('--parallel'); $args.Add([string]$Parallel)
    $args.Add('--n-gpu-layers'); $args.Add([string]$r.gpuLayers)
    if ([bool]$r.jinja) { $args.Add('--jinja') }
    $args.Add('--chat-template-file'); $args.Add($Config.ChatTemplateFile)
    $args.Add('--reasoning-effort'); $args.Add([string]$r.reasoningEffort)
    $args.Add('--reasoning-budget'); $args.Add([string]$r.reasoningBudget)
    if ([bool]$r.continuousBatching) { $args.Add('--cont-batching') }
    if ([bool]$r.flashAttention) { $args.Add('--flash-attn'); $args.Add('on') }
    $args.Add('--cache-type-k'); $args.Add([string]$r.cacheTypeK)
    $args.Add('--cache-type-v'); $args.Add([string]$r.cacheTypeV)
    $args.Add('--model'); $args.Add($Config.Model)
    $args.Add('--no-mmproj')
    $args.Add('--slot-save-path'); $args.Add($Config.SlotSavePath)
    $args.Add('--spec-type'); $args.Add($MtpMode)
    if ($MtpMode -eq 'draft-mtp') {
        $args.Add('--spec-draft-n-max'); $args.Add([string]$r.mtp.maxDraftTokens)
    }
    return @($args)
}

function Get-BonsaiSupervisorLauncherArguments {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$MtpMode = ''
    )
    if (-not [string]::IsNullOrWhiteSpace($MtpMode) -and $MtpMode -notin @('draft-mtp','none')) {
        throw "unsupported supervisor MTP override: $MtpMode"
    }
    $launcherArgs = [Collections.Generic.List[string]]::new()
    foreach ($arg in @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Start-BonsaiServer.ps1'),'-ConfigPath',$ConfigPath)) {
        $launcherArgs.Add([string]$arg)
    }
    if (-not [string]::IsNullOrWhiteSpace($MtpMode)) {
        $launcherArgs.Add('-MtpMode')
        $launcherArgs.Add($MtpMode)
    }
    return @($launcherArgs)
}

function Test-BonsaiHelpFlags {
    param([Parameter(Mandatory)]$Config)
    if (-not (Test-Path -LiteralPath $Config.Executable -PathType Leaf)) {
        throw "llama-server executable not found: $($Config.Executable)"
    }
    $help = @(& $Config.Executable '--help' 2>&1 | ForEach-Object { "$_" }) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0 -and $help -notmatch '(?i)usage|options') {
        throw 'llama-server --help did not return usable help'
    }
    foreach ($flag in @('--cache-type-k','--cache-type-v','--flash-attn','--parallel','--ctx-size','--no-mmproj','--slot-save-path','--spec-type','--spec-draft-n-max','--reasoning-effort','--reasoning-budget','--chat-template-file')) {
        if ($help -notmatch [regex]::Escape($flag)) { throw "Pinned server does not advertise required flag $flag" }
    }
    return $help
}

function Get-BonsaiDeploymentFingerprint {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$MtpMode = ''
    )
    if ([string]::IsNullOrWhiteSpace($MtpMode)) { $MtpMode = [string]$Config.Raw.mtp.mode }
    if ($MtpMode -notin @('draft-mtp','none')) { throw "unsupported fingerprint MTP mode: $MtpMode" }
    $items = [Collections.Generic.List[string]]::new()
    foreach ($path in @($Config.Executable,$Config.Model,$Config.ChatTemplateFile)) {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        $items.Add(('{0}|{1}|{2}' -f $item.FullName,$item.Length,$item.LastWriteTimeUtc.Ticks))
    }
    $items.Add(('slotContext={0}|kvK={1}|kvV={2}|mtp={3}|draftMax={4}|reasoning={5}|reasoningBudget={6}' -f
        $Config.Raw.contextPerSlot,$Config.Raw.cacheTypeK,$Config.Raw.cacheTypeV,$MtpMode,
        $Config.Raw.mtp.maxDraftTokens,$Config.Raw.reasoningEffort,$Config.Raw.reasoningBudget))
    $gpuLayers = if ($Config.Raw.PSObject.Properties.Name -contains 'gpuLayers') { [int]$Config.Raw.gpuLayers } else { -1 }
    $flashAttention = if ($Config.Raw.PSObject.Properties.Name -contains 'flashAttention') { [bool]$Config.Raw.flashAttention } else { $true }
    # Preserve the legacy fingerprint for the already-validated defaults while
    # binding any non-default launch override into saved slot state.
    if ($gpuLayers -ne -1) { $items.Add("gpuLayers=$gpuLayers") }
    if (-not $flashAttention) { $items.Add('flashAttention=false') }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($items -join [Environment]::NewLine))
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return (($hash.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $hash.Dispose() }
}

function Get-BonsaiActiveDeploymentFingerprint {
    param([Parameter(Mandatory)]$Config)
    $activePath = Join-Path $Config.RunStatePath 'active-slots.json'
    if (-not (Test-Path -LiteralPath $activePath)) { throw 'active deployment status is missing; cannot bind slot state' }
    $active = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json
    if ([string]$active.status -ne 'ready') { throw 'active deployment is not ready; cannot bind slot state' }
    $fingerprint = Get-BonsaiDeploymentFingerprint -Config $Config -MtpMode ([string]$active.mtpMode)
    if ([string]$active.deploymentFingerprint -ne $fingerprint) { throw 'active deployment fingerprint does not match effective launch settings' }
    return $fingerprint
}

function Get-BonsaiLiveApiChecks {
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)]$Chat,
        [Parameter(Mandatory)]$Message
    )
    [pscustomobject]@{
        responseHasOutput=($null -ne $Response.output -and @($Response.output).Count -gt 0)
        chatHasChoices=($null -ne $Chat.choices -and @($Chat.choices).Count -gt 0)
        messageHasContent=($null -ne $Message.content -and @($Message.content).Count -gt 0)
    }
}

function Assert-BonsaiLiveApiChecks {
    param([Parameter(Mandatory)]$Checks)
    $missing = @($Checks.PSObject.Properties | Where-Object { -not [bool]$_.Value } | ForEach-Object { $_.Name })
    if ($missing.Count -gt 0) { throw ("Live API acceptance failed: {0}" -f ($missing -join ', ')) }
}

function Get-BonsaiTaskRegistrationPlan {
    param(
        [ValidateSet('Auto','AtStartup','AtLogon')][string]$Mode = 'Auto',
        [bool]$S4UAvailable = $true,
        [string]$FallbackReason = ''
    )
    if ($Mode -eq 'AtLogon') {
        return [pscustomobject]@{ Mode='AtLogon'; Trigger='AtLogon'; LogonType='Interactive'; RunLevel='Limited'; FallbackReason='' }
    }
    if ($S4UAvailable) {
        return [pscustomobject]@{ Mode='AtStartup'; Trigger='AtStartup'; LogonType='S4U'; RunLevel='Limited'; FallbackReason='' }
    }
    if ($Mode -eq 'AtStartup') { throw 'AtStartup requires a Limited S4U principal; no automatic fallback was requested' }
    return [pscustomobject]@{ Mode='AtLogon'; Trigger='AtLogon'; LogonType='Interactive'; RunLevel='Limited'; FallbackReason=$FallbackReason }
}

function Test-BonsaiS4UFallbackErrorCode {
    param([Parameter(Mandatory)][int]$ErrorCode)
    return $ErrorCode -in @(1314,1326,1385)
}

function Get-BonsaiBaseUri {
    param([Parameter(Mandatory)]$Config)
    return "http://$($Config.Raw.host):$($Config.Raw.port)"
}

function Invoke-BonsaiJson {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Get','Post')][string]$Method = 'Get',
        [object]$Body,
        [int]$TimeoutSec = 120
    )
    $params = @{ Uri = (Get-BonsaiBaseUri $Config) + $Path; Method = $Method; TimeoutSec = $TimeoutSec }
    if ($null -ne $Body) {
        $params.ContentType = 'application/json'
        $params.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    return Invoke-RestMethod @params
}

function Get-BonsaiSlotEntries {
    # PowerShell 7 Invoke-RestMethod emits a JSON array as one Object[], so @(...) around it nests;
    # flatten nested arrays and { slots = [...] } wrappers into a single list of slot objects.
    param([AllowNull()][object[]]$Slots)
    if ($null -eq $Slots) { return @() }
    $pendingSlots = [Collections.Generic.Stack[object]]::new()
    for ($index = $Slots.Count - 1; $index -ge 0; $index--) { $pendingSlots.Push($Slots[$index]) }
    $normalizedSlotList = [Collections.Generic.List[object]]::new()
    while ($pendingSlots.Count -gt 0) {
        $item = $pendingSlots.Pop()
        if ($null -eq $item) { continue }
        if ($item -is [array]) {
            for ($index = $item.Length - 1; $index -ge 0; $index--) { $pendingSlots.Push($item[$index]) }
            continue
        }
        if ($item.PSObject.Properties.Name -contains 'slots') {
            $nestedSlots = @($item.slots)
            for ($index = $nestedSlots.Count - 1; $index -ge 0; $index--) { $pendingSlots.Push($nestedSlots[$index]) }
            continue
        }
        $normalizedSlotList.Add($item)
    }
    return @($normalizedSlotList.ToArray())
}

function Get-BonsaiTemporarySlotEraseCandidates {
    param(
        [Parameter(Mandatory)][object[]]$Slots,
        [Parameter(Mandatory)][int]$WarmLiveSlots,
        [Parameter(Mandatory)][bool]$IsTemporaryTrial,
        [Parameter(Mandatory)][int]$ActiveParallel,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][ValidateRange(1,3600)][int]$GraceSeconds,
        [Parameter(Mandatory)][System.Collections.IDictionary]$IdleSince,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ErasedSlots
    )
    if ($WarmLiveSlots -lt 0) { throw 'warm live slot count must be nonnegative' }
    if (-not $IsTemporaryTrial -or $ActiveParallel -le $WarmLiveSlots) { return @() }
    $normalizedSlots = @(Get-BonsaiSlotEntries -Slots $Slots)
    $present = @{}
    $candidates = [Collections.Generic.List[int]]::new()
    foreach ($slot in $normalizedSlots) {
        if ($null -eq $slot -or $slot.PSObject.Properties.Name -notcontains 'id' -or $slot.PSObject.Properties.Name -notcontains 'is_processing') { continue }
        $slotId = 0
        if (-not [int]::TryParse([string]$slot.id,[ref]$slotId)) { continue }
        $present[[string]$slotId] = $true
        if ($slotId -lt $WarmLiveSlots) { continue }
        $key = [string]$slotId
        if ([bool]$slot.is_processing) {
            $IdleSince.Remove($key)
            $ErasedSlots.Remove($key)
            continue
        }
        if ($ErasedSlots.Contains($key)) { continue }
        if (-not $IdleSince.Contains($key)) {
            $IdleSince[$key] = $Now
            continue
        }
        $idleAt = [datetime]$IdleSince[$key]
        if (($Now - $idleAt).TotalSeconds -ge $GraceSeconds) { $candidates.Add($slotId) }
    }
    foreach ($key in @($IdleSince.Keys)) {
        if (-not $present.Contains([string]$key)) { $IdleSince.Remove($key) }
    }
    foreach ($key in @($ErasedSlots.Keys)) {
        if (-not $present.Contains([string]$key)) { $ErasedSlots.Remove($key) }
    }
    return @($candidates.ToArray())
}

function Complete-BonsaiTemporarySlotErase {
    param(
        [Parameter(Mandatory)][int]$SlotId,
        [Parameter(Mandatory)][int]$WarmLiveSlots,
        [Parameter(Mandatory)][System.Collections.IDictionary]$IdleSince,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ErasedSlots
    )
    if ($SlotId -lt $WarmLiveSlots) { throw 'refusing to mark a warm/live slot as an erasable temporary slot' }
    $key = [string]$SlotId
    $IdleSince.Remove($key)
    $ErasedSlots[$key] = $true
}

function Wait-BonsaiHealth {
    param(
        [Parameter(Mandatory)]$Config,
        [int]$Attempts = 30,
        [int]$DelaySeconds = 2
    )
    $lastError = 'no response'
    for ($i = 0; $i -lt $Attempts; $i++) {
        try {
            $health = Invoke-BonsaiJson $Config '/health' Get $null 10
            if ([string]$health.status -eq 'ok') { return $health }
            $lastError = "health status was $($health.status)"
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds $DelaySeconds
    }
    throw "Bonsai health did not become ok after $($Attempts * $DelaySeconds) seconds: $lastError"
}

function Get-BonsaiHealthFailureStatus {
    param(
        [int]$ConsecutiveFailures,
        [bool]$ServerWasReady,
        [bool]$HealthOk,
        [int]$Threshold = 10
    )
    if ($Threshold -lt 1) { throw 'health failure threshold must be positive' }
    $nextFailures = [Math]::Max(0,$ConsecutiveFailures)
    if (-not $ServerWasReady -or $HealthOk) { $nextFailures = 0 }
    else { $nextFailures++ }
    return [pscustomobject]@{
        consecutiveFailures = $nextFailures
        restartRequired = ($ServerWasReady -and -not $HealthOk -and $nextFailures -ge $Threshold)
    }
}

function Ensure-BonsaiDirectories {
    param([Parameter(Mandatory)]$Config)
    foreach ($p in @($Config.SlotSavePath, $Config.RunStatePath, (Split-Path $Config.SupervisorLog),
                     (Split-Path $Config.ServerStdoutLog), (Split-Path $Config.ServerStderrLog))) {
        New-Item -ItemType Directory -Force -Path $p | Out-Null
    }
}

function Clear-BonsaiStopMarkerFromPreviousBoot {
    param(
        [Parameter(Mandatory)][string]$MarkerPath,
        [Parameter(Mandatory)][datetime]$LastBootTime
    )
    if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) { return $false }
    $marker = Get-Item -LiteralPath $MarkerPath -ErrorAction Stop
    if ($marker.LastWriteTimeUtc -lt $LastBootTime.ToUniversalTime()) {
        Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction Stop
        return $true
    }
    return $false
}
