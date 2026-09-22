Set-StrictMode -Version Latest

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

function Import-BonsaiConfig {
    param([Parameter(Mandatory)][string]$ConfigPath)
    $configFull = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).ProviderPath
    $configDir = Split-Path -Parent $configFull
    $raw = Get-Content -LiteralPath $configFull -Raw -ErrorAction Stop | ConvertFrom-Json
    $root = Get-BonsaiFullPath -Value ([string]$raw.deploymentRoot) -BaseDirectory $configDir
    $result = [ordered]@{
        Raw = $raw
        ConfigPath = $configFull
        ConfigDirectory = $configDir
        DeploymentRoot = $root
        Executable = Assert-BonsaiChildPath (Get-BonsaiFullPath ([string]$raw.executable) $configDir) $root 'executable'
        Model = Assert-BonsaiChildPath (Get-BonsaiFullPath ([string]$raw.model) $configDir) $root 'model'
        Projector = Assert-BonsaiChildPath (Get-BonsaiFullPath ([string]$raw.projector) $configDir) $root 'projector'
        SlotSavePath = Assert-BonsaiChildPath (Get-BonsaiFullPath ([string]$raw.slotSavePath) $configDir) $root 'slotSavePath'
        SupervisorLog = Assert-BonsaiChildPath (Get-BonsaiFullPath ([string]$raw.logs.supervisor) $configDir) $root 'supervisor log'
        ServerStdoutLog = Assert-BonsaiChildPath (Get-BonsaiFullPath ([string]$raw.logs.serverStdout) $configDir) $root 'server stdout log'
        ServerStderrLog = Assert-BonsaiChildPath (Get-BonsaiFullPath ([string]$raw.logs.serverStderr) $configDir) $root 'server stderr log'
    }
    if ([string]$raw.host -notin @('127.0.0.1','localhost')) { throw 'Bonsai server must remain loopback-only' }
    if ([int]$raw.context -lt 1 -or [int]$raw.parallel -lt 1) { throw 'context and parallel must be positive' }
    if ([int]$raw.parallel -ne 4) { throw 'This toolkit baseline is locked to four server slots' }
    if ([int]$raw.context -ne 262144) { throw 'This toolkit baseline is locked to aggregate context 262144' }
    if ([string]$raw.alias -ne 'bonsai2-27b') { throw 'unexpected model alias' }
    return [pscustomobject]$result
}

function Get-BonsaiServerArguments {
    param([Parameter(Mandatory)]$Config)
    $r = $Config.Raw
    $args = [Collections.Generic.List[string]]::new()
    $args.Add('--host'); $args.Add([string]$r.host)
    $args.Add('--port'); $args.Add([string]$r.port)
    $args.Add('--alias'); $args.Add([string]$r.alias)
    $args.Add('--ctx-size'); $args.Add([string]$r.context)
    $args.Add('--parallel'); $args.Add([string]$r.parallel)
    $args.Add('--n-gpu-layers'); $args.Add([string]$r.gpuLayers)
    if ([bool]$r.jinja) { $args.Add('--jinja') }
    if ([bool]$r.flashAttention) { $args.Add('--flash-attn') }
    $args.Add('--cache-type-k'); $args.Add([string]$r.cacheTypeK)
    $args.Add('--cache-type-v'); $args.Add([string]$r.cacheTypeV)
    $args.Add('--model'); $args.Add($Config.Model)
    if (Test-Path -LiteralPath $Config.Projector -PathType Leaf) {
        $args.Add('--mmproj'); $args.Add($Config.Projector)
    }
    return @($args)
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
    foreach ($flag in @('--cache-type-k','--cache-type-v','--flash-attn','--parallel','--ctx-size')) {
        if ($help -notmatch [regex]::Escape($flag)) { throw "Pinned server does not advertise required flag $flag" }
    }
    return $help
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

function Ensure-BonsaiDirectories {
    param([Parameter(Mandatory)]$Config)
    foreach ($p in @($Config.SlotSavePath, (Split-Path $Config.SupervisorLog),
                     (Split-Path $Config.ServerStdoutLog), (Split-Path $Config.ServerStderrLog))) {
        New-Item -ItemType Directory -Force -Path $p | Out-Null
    }
}

