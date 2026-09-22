[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(ValueFromRemainingArguments)][string[]]$ArgumentList
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lib-Bonsai.ps1')
$cfg = Import-BonsaiConfig $ConfigPath
[void](Wait-BonsaiHealth $cfg)
$env:ANTHROPIC_BASE_URL = (Get-BonsaiBaseUri $cfg)
$env:ANTHROPIC_AUTH_TOKEN = 'local-only'
$env:ANTHROPIC_MODEL = [string]$cfg.Raw.alias
$claude = (Get-Command claude.exe,claude -ErrorAction Stop | Select-Object -First 1).Source
& $claude @ArgumentList
exit $LASTEXITCODE

