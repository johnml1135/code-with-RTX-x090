[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lib-Bonsai.ps1')
$cfg = Import-BonsaiConfig $ConfigPath
Ensure-BonsaiDirectories $cfg
[void](Test-BonsaiHelpFlags $cfg)
$args = Get-BonsaiServerArguments $cfg
Push-Location $cfg.DeploymentRoot
try {
    & $cfg.Executable @args
    exit $LASTEXITCODE
} finally {
    Pop-Location
}

