# Runs Codex against the local Bonsai server via the bonsai-local profile (see Install-Bonsai.ps1).
#   Invoke-BonsaiCodex.ps1 [codex args...]
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Bonsai.psm1') -Force
Wait-BonsaiReady (Get-BonsaiConfig) 60
$env:BONSAI_LOCAL_API_KEY = 'local-only'
$codex = (Get-Command codex -ErrorAction Stop).Source
& $codex -p bonsai-local @args
exit $LASTEXITCODE
