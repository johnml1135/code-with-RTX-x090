[CmdletBinding()]
param([string]$RepositoryRoot = (Join-Path $PSScriptRoot '..'))
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
$files = @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File -Recurse)
foreach ($file in $files) {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { throw "syntax errors in $($file.FullName): $($errors -join '; ')" }
    $text=Get-Content -LiteralPath $file.FullName -Raw
    if ($text -match '(?i)([A-Z]:\\Users\\[^\\\r\n]+\\|G:\\(?:bonsai-deployment|gguf)\\|sk-[A-Za-z0-9]{12,}|Bearer\s+[A-Za-z0-9._-]{12,})') { throw "machine path or credential-like text in $($file.FullName)" }
}
$template = Get-Content -LiteralPath (Join-Path $root 'config/server.template.json') -Raw | ConvertFrom-Json
if ($template.context -ne 262144 -or $template.parallel -ne 4) { throw 'server template baseline mismatch' }
if ($template.host -ne '127.0.0.1') { throw 'server template is not loopback-only' }
foreach ($p in @($template.executable,$template.model,$template.projector,$template.slotSavePath)) {
    if ([IO.Path]::IsPathRooted([string]$p)) { throw "absolute path in safe template: $p" }
}
$bad=@(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Where-Object { $_.Extension -in @('.gguf','.exe','.dll','.bin','.safetensors') })
if ($bad.Count -gt 0) { throw "binary/model artifact present: $($bad.FullName -join ', ')" }
Write-Output ("PASS: parsed {0} PowerShell files; checked safe config, paths, secrets, and artifacts" -f $files.Count)

