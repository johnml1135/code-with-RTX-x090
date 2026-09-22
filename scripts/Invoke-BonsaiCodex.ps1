[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(ValueFromRemainingArguments)][string[]]$ArgumentList
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lib-Bonsai.ps1')
$cfg = Import-BonsaiConfig $ConfigPath
[void](Wait-BonsaiHealth $cfg)
$env:BONSAI_LOCAL_API_KEY = 'local-only'
$codex = (Get-Command codex.exe,codex -ErrorAction Stop | Select-Object -First 1).Source
& $codex '--profile' 'bonsai_local' @ArgumentList
exit $LASTEXITCODE

