# Shared helpers: load config/bonsai.json and expand {root} / {repo} placeholders.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

function Get-BonsaiConfig {
    param([string]$Path = (Join-Path $script:RepoRoot 'config\bonsai.json'))
    $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $expand = { param($s) $s.Replace('{root}', $cfg.root).Replace('{repo}', $script:RepoRoot) }
    foreach ($key in 'server', 'sessions', 'logs') { $cfg.$key = & $expand $cfg.$key }
    $cfg.args = @($cfg.args | ForEach-Object { & $expand $_ })
    $cfg | Add-Member -NotePropertyName baseUrl -NotePropertyValue "http://$($cfg.host):$($cfg.port)"
    $cfg
}

function Invoke-Bonsai {
    param($Config, [string]$Path, [string]$Method = 'Get', $Body = $null, [int]$TimeoutSec = 30)
    $params = @{ Uri = "$($Config.baseUrl)$Path"; Method = $Method; TimeoutSec = $TimeoutSec }
    if ($null -ne $Body) { $params.ContentType = 'application/json'; $params.Body = ($Body | ConvertTo-Json -Depth 10) }
    Invoke-RestMethod @params
}

function Get-BonsaiSlots {
    param($Config)
    # Invoke-RestMethod emits a JSON array as a single object; pipe it to enumerate the slots.
    (Invoke-Bonsai $Config '/slots') | ForEach-Object { $_ }
}

function Wait-BonsaiReady {
    param($Config, [int]$TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { if ((Invoke-Bonsai $Config '/health' -TimeoutSec 5).status -eq 'ok') { return } } catch { }
        Start-Sleep -Seconds 2
    }
    throw "Bonsai server at $($Config.baseUrl) was not healthy within $TimeoutSec seconds"
}

Export-ModuleMember -Function Get-BonsaiConfig, Invoke-Bonsai, Get-BonsaiSlots, Wait-BonsaiReady
