# Runs Claude Code against the local Bonsai server. Endpoint settings apply to this process only.
#   Invoke-BonsaiClaude.ps1 [claude args...]
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Bonsai.psm1') -Force
$cfg = Get-BonsaiConfig
Wait-BonsaiReady $cfg 60
$env:ANTHROPIC_BASE_URL = $cfg.baseUrl
$env:ANTHROPIC_AUTH_TOKEN = 'local-only'
$env:ANTHROPIC_MODEL = $cfg.alias
$env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $cfg.alias
# Claude Code doesn't know this model's window; tell it the per-session context llama-server allows.
$env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = '262144'
$claude = (Get-Command claude -ErrorAction Stop).Source
& $claude @args
exit $LASTEXITCODE
