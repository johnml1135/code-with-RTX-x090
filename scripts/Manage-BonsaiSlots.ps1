[CmdletBinding()]
param(
    [ValidateSet('List','Save','Restore','Erase','Evict','BudgetCheck','Test')][string]$Operation='List',
    [Parameter(Mandatory)][string]$ConfigPath,
    [int]$SlotId=-1,
    [string]$Filename='',
    [ValidateSet('warm','cold')][string]$Tier='cold',
    [string]$IdentityText=''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lib-Bonsai.ps1')
$cfg = Import-BonsaiConfig $ConfigPath
Ensure-BonsaiDirectories $cfg
$store = $cfg.SlotSavePath
$manifestPath = Join-Path $store 'slots-manifest.json'
$warmProps = @($cfg.Raw.slotCache.PSObject.Properties.Name)
$coldProps = @($cfg.Raw.slotCache.PSObject.Properties.Name)
$warmLimit = if ($warmProps -contains 'warmLimitGiB') { [int64]$cfg.Raw.slotCache.warmLimitGiB * 1GB } elseif ($warmProps -contains 'maxWarmMiB') { [int64]$cfg.Raw.slotCache.maxWarmMiB * 1MB } else { throw 'slotCache needs warmLimitGiB or maxWarmMiB' }
$coldLimit = if ($coldProps -contains 'coldLimitGiB') { [int64]$cfg.Raw.slotCache.coldLimitGiB * 1GB } elseif ($coldProps -contains 'maxBytes') { [int64]$cfg.Raw.slotCache.maxBytes } else { throw 'slotCache needs coldLimitGiB or maxBytes' }
function Read-Manifest {
    if (-not (Test-Path -LiteralPath $manifestPath)) { return @() }
    $x = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($null -eq $x.entries) { return @() }
    return @($x.entries | Where-Object { $_.filename })
}
function Write-Manifest([object[]]$Entries) {
    $obj = [pscustomobject]@{ schema=1; description='Explicit persisted llama-server slot/KV metadata; not transparent GPU paging; no client secrets.'; entries=@($Entries) }
    [IO.File]::WriteAllText($manifestPath, ($obj | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}
function Safe-SlotFile([string]$Name) {
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,180}$') { throw 'Filename must be a safe single basename' }
    $full = [IO.Path]::GetFullPath((Join-Path $store $Name))
    Assert-BonsaiChildPath $full $store 'slot filename'
}
function Identity-Hash([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return (([Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
}
function Model-Fingerprint {
    $item = Get-Item -LiteralPath $cfg.Model
    return '{0}:{1}:{2}' -f $item.FullName,$item.Length,$item.LastWriteTimeUtc.Ticks
}
function Slot-Count {
    $x = Invoke-BonsaiJson $cfg '/slots' Get $null 30
    return @($x).Count
}
function Slot-Api([int]$Id,[string]$Action,[string]$Name) {
    return Invoke-BonsaiJson $cfg ("/slots/{0}?action={1}" -f $Id,$Action) Post @{ filename=$Name } 600
}
function Get-TierBytes([object[]]$Entries,[string]$TierName) {
    $rows = @($Entries | Where-Object { $_ -and $_.PSObject.Properties['tier'] -and [string]$_.tier -eq $TierName })
    if ($rows.Count -eq 0) { return [int64]0 }
    return [int64](($rows | Measure-Object -Property bytes -Sum).Sum)
}
function Enforce-Budget([object[]]$Entries,[string]$BudgetTier) {
    $limit = if ($BudgetTier -eq 'warm') { $warmLimit } else { $coldLimit }
    $current = Get-TierBytes $Entries $BudgetTier
    $evicted = [Collections.Generic.List[string]]::new()
    while ($current -gt $limit) {
        $candidate = @($Entries | Where-Object { $_.tier -eq $BudgetTier -and $_.state -eq 'inactive' } | Sort-Object { [datetime]$_.lastAccess } | Select-Object -First 1)
        if ($candidate.Count -eq 0) { throw "$BudgetTier budget exceeded and no inactive entry is evictable" }
        $file = Safe-SlotFile $candidate[0].filename
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        $current -= [int64]$candidate[0].bytes
        $Entries = @($Entries | Where-Object filename -ne $candidate[0].filename)
        $evicted.Add($candidate[0].filename)
    }
    Write-Manifest $Entries
    [pscustomobject]@{ tier=$BudgetTier; bytes=$current; limitBytes=$limit; evicted=@($evicted) }
}
function Save-Slot {
    if ($SlotId -lt 0 -or $SlotId -ge (Slot-Count)) { throw 'invalid slot id' }
    $file = Safe-SlotFile $Filename
    $entries = Read-Manifest
    if (($entries | Where-Object filename -eq $Filename) -or (Test-Path -LiteralPath $file)) { throw 'target slot file already exists' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $server = Slot-Api $SlotId 'save' $Filename
    $sw.Stop()
    if (-not (Test-Path -LiteralPath $file)) { throw 'server reported save but file is missing' }
    $item = Get-Item -LiteralPath $file
    $entry = [pscustomobject]@{
        filename=$Filename; slotId=$SlotId; tier=$Tier; state='inactive'; bytes=[int64]$item.Length
        nTokens=$server.n_saved; created=(Get-Date).ToString('o'); lastAccess=(Get-Date).ToString('o')
        identitySha256=(Identity-Hash $IdentityText); modelFingerprint=(Model-Fingerprint)
        context=[int]$cfg.Raw.context; parallel=[int]$cfg.Raw.parallel; saveWallMs=[math]::Round($sw.Elapsed.TotalMilliseconds,2)
    }
    $entries = @($entries + $entry); Write-Manifest $entries
    try { $budget = Enforce-Budget $entries $Tier }
    catch { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue; Write-Manifest (@($entries | Where-Object filename -ne $Filename)); throw }
    [pscustomobject]@{ operation='save'; entry=$entry; server=$server; budget=$budget }
}
function Restore-Slot {
    $file = Safe-SlotFile $Filename; $entries = Read-Manifest
    $entry = @($entries | Where-Object filename -eq $Filename)
    if ($entry.Count -ne 1 -or -not (Test-Path -LiteralPath $file)) { throw 'slot file is not registered and present' }
    if ([string]::IsNullOrEmpty($IdentityText)) { throw 'restore requires explicit IdentityText' }
    if ((Identity-Hash $IdentityText) -ne [string]$entry[0].identitySha256) { throw 'identity hash mismatch; refusing restore' }
    if ([string]$entry[0].modelFingerprint -ne (Model-Fingerprint) -or [int]$entry[0].context -ne [int]$cfg.Raw.context -or [int]$entry[0].parallel -ne [int]$cfg.Raw.parallel) { throw 'model/context/parallel fingerprint mismatch' }
    $id = if ($SlotId -ge 0) { $SlotId } else { [int]$entry[0].slotId }
    $sw = [Diagnostics.Stopwatch]::StartNew(); $server = Slot-Api $id 'restore' $Filename; $sw.Stop()
    $entry[0].lastAccess = (Get-Date).ToString('o')
    Write-Manifest (@($entries | ForEach-Object { if ($_.filename -eq $Filename) { $entry[0] } else { $_ } }))
    [pscustomobject]@{ operation='restore'; entry=$entry[0]; server=$server; restoreWallMs=[math]::Round($sw.Elapsed.TotalMilliseconds,2) }
}
function Erase-Slot {
    $file = Safe-SlotFile $Filename; $entries = Read-Manifest
    $entry = @($entries | Where-Object filename -eq $Filename)
    $id = if ($SlotId -ge 0) { $SlotId } elseif ($entry.Count -eq 1) { [int]$entry[0].slotId } else { -1 }
    $server = if ($id -ge 0 -and $id -lt (Slot-Count)) { Slot-Api $id 'erase' $Filename } else { $null }
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    Write-Manifest (@($entries | Where-Object filename -ne $Filename))
    [pscustomobject]@{ operation='erase'; server=$server; existsAfterErase=(Test-Path -LiteralPath $file) }
}
switch ($Operation) {
    'List' { Read-Manifest | Select-Object filename,slotId,tier,state,bytes,nTokens,created,lastAccess,context,parallel | ConvertTo-Json -Depth 6 }
    'BudgetCheck' { $e=Read-Manifest; [pscustomobject]@{ warmBytes=(Get-TierBytes $e 'warm'); warmLimitBytes=$warmLimit; coldBytes=(Get-TierBytes $e 'cold'); coldLimitBytes=$coldLimit; fileCount=@($e).Count; store=$store } | ConvertTo-Json -Depth 5 }
    'Save' { if (-not $Filename) { throw 'Filename is required' }; Save-Slot | ConvertTo-Json -Depth 12 }
    'Restore' { if (-not $Filename) { throw 'Filename is required' }; Restore-Slot | ConvertTo-Json -Depth 12 }
    'Erase' { if (-not $Filename) { throw 'Filename is required' }; Erase-Slot | ConvertTo-Json -Depth 12 }
    'Evict' { $e=Read-Manifest; foreach($t in @('warm','cold')) { [void](Enforce-Budget $e $t); $e=Read-Manifest }; Read-Manifest | ConvertTo-Json -Depth 8 }
    'Test' { if (-not $Filename) { $Filename='managed-cycle-test.bin' }; if (-not $IdentityText) { $IdentityText='explicit-managed-cycle-test' }; $save=Save-Slot; $restore=Restore-Slot; $erase=Erase-Slot; [pscustomobject]@{ operation='test'; save=$save; restore=$restore; erase=$erase; note='Persisted slot/KV state with explicit identity; not GPU paging or automatic client session mapping.' } | ConvertTo-Json -Depth 16 }
}

