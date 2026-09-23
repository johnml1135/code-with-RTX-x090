[CmdletBinding()]
param(
    [ValidateSet('Contract','Live')][string]$Mode = 'Contract',
    [Parameter(Mandatory)][string]$ConfigPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lib-Bonsai.ps1')
$cfg = Import-BonsaiConfig $ConfigPath
[void](Test-BonsaiHelpFlags $cfg)
if ($Mode -eq 'Contract') {
    [pscustomobject]@{
        mode=$Mode; config=$cfg.ConfigPath; contextPerSlot=$cfg.Raw.contextPerSlot
        warmLiveSlots=$cfg.Raw.warmLiveSlots; temporaryTrialSlot=[bool]$cfg.Raw.temporaryTrialSlot
        preferredParallel=$cfg.Raw.preferredParallel; fallbackParallel=$cfg.Raw.fallbackParallel
        maxWorkingSetGiB=$cfg.Raw.maxWorkingSetGiB; maxGpuMemoryPercent=$cfg.Raw.maxGpuMemoryPercent
        mtp=$cfg.Raw.mtp; visionEnabled=$false
        requiredFlags=@('--cache-type-k','--cache-type-v','--flash-attn','--no-mmproj','--slot-save-path','--spec-type','--spec-draft-n-max','--reasoning-effort','--reasoning-budget')
    } | ConvertTo-Json -Depth 6
    exit 0
}
$health = Wait-BonsaiHealth $cfg
$activePath = Join-Path $cfg.RunStatePath 'active-slots.json'
$active = if (Test-Path -LiteralPath $activePath) { Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json } else { throw 'active deployment status is missing' }
$props = Invoke-BonsaiJson $cfg '/props' Get $null 15
$models = Invoke-BonsaiJson $cfg '/v1/models' Get $null 15
if ([string]$health.status -ne 'ok') { throw 'health did not return ok' }
$modelRows = @($models.data)
if (-not ($modelRows | Where-Object { $_.id -eq $cfg.Raw.alias })) { throw 'model alias missing from /v1/models' }
$totalSlots = if ($props.PSObject.Properties.Name -contains 'total_slots') { [int]$props.total_slots } elseif ($props.PSObject.Properties.Name -contains 'slots_total') { [int]$props.slots_total } else { 0 }
$slotContext = if ($props.default_generation_settings.PSObject.Properties.Name -contains 'n_ctx') { [int]$props.default_generation_settings.n_ctx } else { 0 }
if ($totalSlots -notin @([int]$cfg.Raw.preferredParallel,[int]$cfg.Raw.fallbackParallel)) { throw "/props reports unsupported slot count $totalSlots" }
if ($slotContext -ne [int]$cfg.Raw.contextPerSlot) { throw "/props reports per-slot context $slotContext; expected $($cfg.Raw.contextPerSlot)" }
$aggregateContext = $slotContext * $totalSlots
$response = Invoke-BonsaiJson $cfg '/v1/responses' Post @{
    model = $cfg.Raw.alias
    input = @(@{ role='user'; content=@(@{type='input_text'; text='Return exactly BONSAI_LIVE_OK'}) })
    max_output_tokens = 16
} 120
$chat = Invoke-BonsaiJson $cfg '/v1/chat/completions' Post @{
    model = $cfg.Raw.alias
    max_tokens = 16
    messages = @(@{ role='user'; content='Return exactly BONSAI_CHAT_OK' })
} 120
$message = Invoke-BonsaiJson $cfg '/v1/messages' Post @{
    model = $cfg.Raw.alias
    max_tokens = 16
    messages = @(@{ role='user'; content='Return exactly BONSAI_MSG_OK' })
} 120
$apiChecks = Get-BonsaiLiveApiChecks -Response $response -Chat $chat -Message $message
Assert-BonsaiLiveApiChecks $apiChecks
[pscustomobject]@{
    mode=$Mode; health=$health.status; modelCount=$modelRows.Count; slots=$totalSlots
    contextPerSlot=$slotContext; aggregateContext=$aggregateContext
    kernelWorkingSetCapApplied=[bool]$active.kernelWorkingSetCapApplied
    workingSetLimitErrorCode=[int]$active.workingSetLimitErrorCode
    residentGuard=$active.residentGuard
    responseHasOutput=$apiChecks.responseHasOutput
    chatHasChoices=$apiChecks.chatHasChoices
    messageHasContent=$apiChecks.messageHasContent
    props=$props
} | ConvertTo-Json -Depth 8
