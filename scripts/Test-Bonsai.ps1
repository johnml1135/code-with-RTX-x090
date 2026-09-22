[CmdletBinding()]
param(
    [ValidateSet('Contract','Live')][string]$Mode = 'Contract',
    [Parameter(Mandatory)][string]$ConfigPath,
    [switch]$SkipVision
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lib-Bonsai.ps1')
$cfg = Import-BonsaiConfig $ConfigPath
[void](Test-BonsaiHelpFlags $cfg)
if ($Mode -eq 'Contract') {
    [pscustomobject]@{ mode=$Mode; config=$cfg.ConfigPath; context=$cfg.Raw.context; parallel=$cfg.Raw.parallel; requiredFlags=@('--cache-type-k','--cache-type-v','--flash-attn') } | ConvertTo-Json -Depth 5
    exit 0
}
$health = Wait-BonsaiHealth $cfg
$props = Invoke-BonsaiJson $cfg '/props' Get $null 15
$models = Invoke-BonsaiJson $cfg '/v1/models' Get $null 15
if ([string]$health.status -ne 'ok') { throw 'health did not return ok' }
$modelRows = @($models.data)
if (-not ($modelRows | Where-Object { $_.id -eq $cfg.Raw.alias })) { throw 'model alias missing from /v1/models' }
$totalSlots = if ($props.PSObject.Properties.Name -contains 'total_slots') { [int]$props.total_slots } elseif ($props.PSObject.Properties.Name -contains 'slots_total') { [int]$props.slots_total } else { 0 }
$slotContext = if ($props.default_generation_settings.PSObject.Properties.Name -contains 'n_ctx') { [int]$props.default_generation_settings.n_ctx } else { 0 }
if ($totalSlots -ne [int]$cfg.Raw.parallel) { throw "/props reports $totalSlots slots; expected $($cfg.Raw.parallel)" }
if ($slotContext -le 0 -or ($slotContext * $totalSlots) -ne [int]$cfg.Raw.context) { throw "/props reports invalid slot context $slotContext for aggregate $($cfg.Raw.context)" }
$response = Invoke-BonsaiJson $cfg '/v1/responses' Post @{
    model = $cfg.Raw.alias
    input = @(@{ role='user'; content=@(@{type='input_text'; text='Return exactly BONSAI_LIVE_OK'}) })
    max_output_tokens = 16
} 120
$message = Invoke-BonsaiJson $cfg '/v1/messages' Post @{
    model = $cfg.Raw.alias
    max_tokens = 16
    messages = @(@{ role='user'; content='Return exactly BONSAI_MSG_OK' })
} 120
[pscustomobject]@{
    mode=$Mode; health=$health.status; modelCount=$modelRows.Count
    responseHasOutput=($null -ne $response.output)
    messageHasContent=($null -ne $message.content)
    props=$props
} | ConvertTo-Json -Depth 8

