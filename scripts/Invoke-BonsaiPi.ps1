# Runs the pi coding agent (the default Bonsai harness) against the local server.
# pi's system prompt and tools are ~1.2K tokens versus ~20K for Claude Code, so it starts in seconds.
#   Invoke-BonsaiPi.ps1 [pi args...]
#   Invoke-BonsaiPi.ps1 -p --no-session --tools read,grep,find,ls "Review this repo"   # read-only one-shot
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Bonsai.psm1') -Force
Wait-BonsaiReady (Get-BonsaiConfig) 60
$env:PI_OFFLINE = '1'   # skip update/telemetry checks at startup
$pi = (Get-Command pi -ErrorAction Stop).Source
# --no-skills: user skill libraries add thousands of prompt tokens and distract a bounded subagent.
& $pi --provider bonsai --model bonsai2-27b --no-skills @args
exit $LASTEXITCODE
