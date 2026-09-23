# Smoke test against the running server: slots, and each API the clients use.
[CmdletBinding()]
param([string]$ConfigPath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Bonsai.psm1') -Force
$cfg = if ($ConfigPath) { Get-BonsaiConfig $ConfigPath } else { Get-BonsaiConfig }
$failed = 0
function Check([string]$Name, [scriptblock]$Test) {
    try { $detail = & $Test; "PASS  $Name  $detail" }
    catch { $script:failed++; "FAIL  $Name  $($_.Exception.Message)" }
}

Wait-BonsaiReady $cfg 60
Check 'slots' {
    $slots = @(Get-BonsaiSlots $cfg)
    $parallel = [int]$cfg.args[[array]::IndexOf($cfg.args, '--parallel') + 1]
    if ($slots.Count -ne $parallel) { throw "expected $parallel slots, got $($slots.Count)" }
    "$($slots.Count) slots x $($slots[0].n_ctx) tokens"
}
Check 'chat completions (OpenAI)' {
    $r = Invoke-Bonsai $cfg '/v1/chat/completions' Post @{ model = $cfg.alias; max_tokens = 400
        messages = @(@{ role = 'user'; content = 'Reply with the single word: ready' }) } 120
    if (-not $r.choices[0].message.content) { throw 'empty content' }
    "$([math]::Round($r.timings.predicted_per_second,1)) tok/s"
}
Check 'responses (Codex)' {
    $r = Invoke-Bonsai $cfg '/v1/responses' Post @{ model = $cfg.alias; max_output_tokens = 400
        input = 'Reply with the single word: ready' } 120
    $text = ($r.output | Where-Object type -eq 'message').content.text -join ''
    if (-not $text) { throw 'empty output' }
    'ok'
}
Check 'messages (Claude)' {
    $r = Invoke-Bonsai $cfg '/v1/messages' Post @{ model = $cfg.alias; max_tokens = 400
        messages = @(@{ role = 'user'; content = 'Reply with the single word: ready' }) } 120
    $text = ($r.content | Where-Object type -eq 'text').text -join ''
    if (-not $text) { throw 'empty text' }
    'ok'
}
if ($failed) { exit 1 }
