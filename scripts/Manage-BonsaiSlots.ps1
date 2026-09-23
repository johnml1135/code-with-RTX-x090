[CmdletBinding()]
param(
    [ValidateSet('List','Save','Restore','Release','Erase','Evict','BudgetCheck','Test')][string]$Operation='List',
    [Parameter(Mandatory)][string]$ConfigPath,
    [int]$SlotId=-1,
    [string]$Filename='',
    [string]$IdentityText=''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Lib-Bonsai.ps1')
. (Join-Path $PSScriptRoot 'Lib-BonsaiSlots.ps1')
$cfg = Import-BonsaiConfig $ConfigPath
Ensure-BonsaiDirectories $cfg
$store = $cfg.SlotSavePath
$manifestPath = Join-Path $store 'slots-manifest.json'
$cacheProperties = @($cfg.Raw.slotCache.PSObject.Properties.Name)
if ($cacheProperties -contains 'warmLimitGiB' -or $cacheProperties -contains 'coldLimitGiB' -or $cacheProperties -contains 'maxWarmMiB') {
    throw 'slotCache warm/cold tiers are obsolete; set only diskLimitGiB and maxSavedJobs'
}
if ($cacheProperties -notcontains 'diskLimitGiB' -or $cacheProperties -notcontains 'maxSavedJobs') {
    throw 'slotCache requires diskLimitGiB and maxSavedJobs'
}
$diskLimit = [int64]$cfg.Raw.slotCache.diskLimitGiB * 1GB
$maxSavedJobs = [int]$cfg.Raw.slotCache.maxSavedJobs
if ($diskLimit -le 0 -or $maxSavedJobs -lt 1) { throw 'slotCache diskLimitGiB and maxSavedJobs must be positive' }
function Read-Manifest {
    if (-not (Test-Path -LiteralPath $manifestPath)) { return @() }
    $x = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($null -eq $x.entries) { return @() }
    return ConvertTo-BonsaiDiskSlotEntries -Entries @($x.entries | Where-Object { $_.filename })
}
function Write-Manifest([object[]]$Entries) {
    $obj = [pscustomobject]@{ schema=3; description='Explicit G: disk-persisted llama-server slot/KV metadata; not transparent GPU paging; no client secrets.'; entries=@(ConvertTo-BonsaiDiskSlotEntries -Entries $Entries) }
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
function Slot-Count {
    $x = Invoke-BonsaiJson $cfg '/slots' Get $null 30
    return @($x).Count
}
function Slot-Api([int]$Id,[string]$Action,[string]$Name) {
    return Invoke-BonsaiJson $cfg ("/slots/{0}?action={1}" -f $Id,$Action) Post @{ filename=$Name } 600
}
function Enforce-Budget([object[]]$Entries,[string]$ProtectedFilename='') {
    $plan = Get-BonsaiDiskCacheBudgetPlan -Entries $Entries -MaxBytes $diskLimit -MaxFiles $maxSavedJobs -ProtectedFilename $ProtectedFilename
    foreach ($name in $plan.evicted) {
        $file = Safe-SlotFile $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    Write-Manifest $plan.entries
    [pscustomobject]@{ bytes=$plan.bytes; limitBytes=$diskLimit; fileCount=$plan.fileCount; maxSavedJobs=$maxSavedJobs; evicted=@($plan.evicted) }
}
function Save-Slot {
    Assert-BonsaiSlotIdentity -IdentityText $IdentityText -Operation Save
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
        filename=$Filename; slotId=$SlotId; state='inactive'; bytes=[int64]$item.Length
        nTokens=$server.n_saved; created=(Get-Date).ToString('o'); lastAccess=(Get-Date).ToString('o')
        identitySha256=(Identity-Hash $IdentityText); deploymentFingerprint=(Get-BonsaiActiveDeploymentFingerprint $cfg)
        contextPerSlot=[int]$cfg.Raw.contextPerSlot; parallel=[int](Slot-Count); saveWallMs=[math]::Round($sw.Elapsed.TotalMilliseconds,2)
    }
    $entries = @($entries + $entry); Write-Manifest $entries
    try {
        $budget = Enforce-Budget $entries $Filename
        Assert-BonsaiSlotSaveRetained -Filename $Filename -Entries (Read-Manifest) -FileExists (Test-Path -LiteralPath $file)
    }
    catch { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue; Write-Manifest (@($entries | Where-Object filename -ne $Filename)); throw }
    [pscustomobject]@{ operation='save'; entry=$entry; server=$server; budget=$budget }
}
function Restore-Slot {
    $file = Safe-SlotFile $Filename; $entries = Read-Manifest
    $entry = @($entries | Where-Object filename -eq $Filename)
    if ($entry.Count -ne 1 -or -not (Test-Path -LiteralPath $file)) { throw 'slot file is not registered and present' }
    Assert-BonsaiSlotIdentity -IdentityText $IdentityText -Operation Restore
    if ((Identity-Hash $IdentityText) -ne [string]$entry[0].identitySha256) { throw 'identity hash mismatch; refusing restore' }
    $savedContext = if ($entry[0].PSObject.Properties.Name -contains 'contextPerSlot') { [int]$entry[0].contextPerSlot } else { 0 }
    $activeFingerprint = Get-BonsaiActiveDeploymentFingerprint $cfg
    if ([string]$entry[0].deploymentFingerprint -ne $activeFingerprint -or $savedContext -ne [int]$cfg.Raw.contextPerSlot) {
        throw 'deployment/per-slot-context fingerprint mismatch; refusing restore'
    }
    $id = if ($SlotId -ge 0) { $SlotId } else { [int]$entry[0].slotId }
    $sw = [Diagnostics.Stopwatch]::StartNew(); $server = Slot-Api $id 'restore' $Filename; $sw.Stop()
    $entries = Set-BonsaiSlotCacheEntryState -Entries $entries -Filename $Filename -State active
    $entry = @($entries | Where-Object filename -eq $Filename)
    $entry[0].lastAccess = (Get-Date).ToString('o')
    Write-Manifest $entries
    [pscustomobject]@{ operation='restore'; entry=$entry[0]; server=$server; restoreWallMs=[math]::Round($sw.Elapsed.TotalMilliseconds,2) }
}
function Release-Slot {
    Assert-BonsaiSlotIdentity -IdentityText $IdentityText -Operation Release
    $file = Safe-SlotFile $Filename; $entries = Read-Manifest
    $entry = @($entries | Where-Object filename -eq $Filename)
    if ($entry.Count -ne 1 -or -not (Test-Path -LiteralPath $file)) { throw 'slot file is not registered and present' }
    if ((Identity-Hash $IdentityText) -ne [string]$entry[0].identitySha256) { throw 'identity hash mismatch; refusing release' }
    if ([string]$entry[0].state -ne 'active') { throw 'slot is not active; nothing to release' }
    $entries = Set-BonsaiSlotCacheEntryState -Entries $entries -Filename $Filename -State inactive
    $entry = @($entries | Where-Object filename -eq $Filename)
    $entry[0].lastAccess = (Get-Date).ToString('o')
    Write-Manifest $entries
    [pscustomobject]@{ operation='release'; entry=$entry[0] }
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
    'List' { Read-Manifest | Select-Object filename,slotId,state,bytes,nTokens,created,lastAccess,contextPerSlot,parallel | ConvertTo-Json -Depth 6 }
    'BudgetCheck' { $e=Read-Manifest; $plan=Get-BonsaiDiskCacheBudgetPlan -Entries $e -MaxBytes $diskLimit -MaxFiles $maxSavedJobs; [pscustomobject]@{ bytes=[int64](($e | Measure-Object -Property bytes -Sum).Sum); limitBytes=$diskLimit; fileCount=@($e).Count; maxSavedJobs=$maxSavedJobs; plannedEvictions=@($plan.evicted); store=$store } | ConvertTo-Json -Depth 5 }
    'Save' { if (-not $Filename) { throw 'Filename is required' }; Save-Slot | ConvertTo-Json -Depth 12 }
    'Restore' { if (-not $Filename) { throw 'Filename is required' }; Restore-Slot | ConvertTo-Json -Depth 12 }
    'Release' { if (-not $Filename) { throw 'Filename is required' }; Release-Slot | ConvertTo-Json -Depth 12 }
    'Erase' { if (-not $Filename) { throw 'Filename is required' }; Erase-Slot | ConvertTo-Json -Depth 12 }
    'Evict' { $e=Read-Manifest; [void](Enforce-Budget $e); Read-Manifest | ConvertTo-Json -Depth 8 }
    'Test' { if (-not $Filename) { $Filename='managed-cycle-test.bin' }; if (-not $IdentityText) { $IdentityText='explicit-managed-cycle-test' }; $save=Save-Slot; $restore=Restore-Slot; $release=Release-Slot; $erase=Erase-Slot; [pscustomobject]@{ operation='test'; save=$save; restore=$restore; release=$release; erase=$erase; note='Persisted slot/KV state with explicit identity; not GPU paging or automatic client session mapping.' } | ConvertTo-Json -Depth 16 }
}
