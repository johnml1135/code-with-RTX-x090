# Save / restore a session's KV state to disk (the G: cold tier).
#
# llama-server already keeps recently idle sessions in RAM (--cache-ram) and picks the slot whose
# cached prompt best matches each request. This script is for sessions that will sit idle for hours
# or days: save the slot to disk, and restore it into an idle slot before the agent resumes.
#
#   Bonsai-Session.ps1 list
#   Bonsai-Session.ps1 save    -Name my-agent [-Slot 1]
#   Bonsai-Session.ps1 restore -Name my-agent [-Slot 2]
#   Bonsai-Session.ps1 remove  -Name my-agent
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('list', 'save', 'restore', 'remove')][string]$Action,
    [ValidatePattern('^[A-Za-z0-9._-]{1,80}$')][string]$Name,
    [int]$Slot = -1,
    [string]$ConfigPath
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Bonsai.psm1') -Force
$cfg = if ($ConfigPath) { Get-BonsaiConfig $ConfigPath } else { Get-BonsaiConfig }
$modelIndex = [array]::IndexOf($cfg.args, '--model')
$model = Get-Item -LiteralPath $cfg.args[$modelIndex + 1]
# Slot files are only valid for the exact model file (and KV type) that produced them.
$modelId = "$($model.Name):$($model.Length)"

function Get-Sessions {
    Get-ChildItem -LiteralPath $cfg.sessions -Filter '*.bin' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | ForEach-Object {
            $metaPath = [IO.Path]::ChangeExtension($_.FullName, '.json')
            $meta = if (Test-Path -LiteralPath $metaPath) { Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json } else { $null }
            [pscustomobject]@{ Name = $_.BaseName; Tokens = $meta.tokens; GiB = [math]::Round($_.Length / 1GB, 2)
                Saved = $_.LastWriteTime; Model = $meta.model; File = $_ }
        }
}

function Remove-Session($session) {
    Remove-Item -LiteralPath $session.File.FullName, ([IO.Path]::ChangeExtension($session.File.FullName, '.json')) -ErrorAction SilentlyContinue
}

function Require-Name { if (-not $Name) { throw "-Name is required for '$Action'" } }

switch ($Action) {
    'list' {
        Get-Sessions | Select-Object Name, Tokens, GiB, Saved | Format-Table -AutoSize
    }
    'save' {
        Require-Name
        if ($Slot -lt 0) {
            # Default to the idle slot holding the most context: usually the session that just finished.
            $Slot = (Get-BonsaiSlots $cfg | Where-Object { -not $_.is_processing } |
                Sort-Object { [int]$_.n_prompt_tokens } -Descending | Select-Object -First 1).id
            if ($null -eq $Slot) { throw 'no idle slot to save' }
        }
        $result = Invoke-Bonsai $cfg "/slots/$Slot`?action=save" Post @{ filename = "$Name.bin" } 600
        @{ model = $modelId; tokens = $result.n_saved; slot = $Slot } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $cfg.sessions "$Name.json")
        "saved slot $Slot as '$Name': $($result.n_saved) tokens in $([int]$result.timings.save_ms) ms"
        # Enforce the disk budget, oldest first, never evicting the session just saved.
        $kept = 0; $bytes = 0L
        foreach ($s in Get-Sessions) {
            $kept++; $bytes += $s.File.Length
            if ($s.Name -ne $Name -and ($kept -gt $cfg.maxSessions -or $bytes -gt $cfg.maxSessionGiB * 1GB)) {
                Remove-Session $s
                $kept--; $bytes -= $s.File.Length
                "evicted '$($s.Name)' (disk budget: $($cfg.maxSessions) sessions / $($cfg.maxSessionGiB) GiB)"
            }
        }
    }
    'restore' {
        Require-Name
        $session = Get-Sessions | Where-Object Name -eq $Name
        if (-not $session) { throw "no saved session '$Name'" }
        if ($session.Model -ne $modelId) { throw "session '$Name' was saved with model '$($session.Model)', server runs '$modelId'" }
        if ($Slot -lt 0) {
            $Slot = (Get-BonsaiSlots $cfg | Where-Object { -not $_.is_processing } |
                Sort-Object { [int]$_.n_prompt_tokens } | Select-Object -First 1).id
            if ($null -eq $Slot) { throw 'no idle slot to restore into' }
        }
        $result = Invoke-Bonsai $cfg "/slots/$Slot`?action=restore" Post @{ filename = "$Name.bin" } 600
        "restored '$Name' into slot $Slot`: $($result.n_restored) tokens in $([int]$result.timings.restore_ms) ms"
    }
    'remove' {
        Require-Name
        $session = Get-Sessions | Where-Object Name -eq $Name
        if (-not $session) { throw "no saved session '$Name'" }
        Remove-Session $session
        "removed '$Name'"
    }
}
