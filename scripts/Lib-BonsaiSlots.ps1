function Assert-BonsaiSlotIdentity {
    param(
        [string]$IdentityText,
        [ValidateSet('Save','Restore','Release')][string]$Operation
    )
    if ([string]::IsNullOrWhiteSpace($IdentityText)) { throw "$Operation requires explicit IdentityText" }
}

function Set-BonsaiSlotCacheEntryState {
    param(
        [Parameter(Mandatory)][object[]]$Entries,
        [Parameter(Mandatory)][string]$Filename,
        [Parameter(Mandatory)][ValidateSet('active','inactive')][string]$State
    )
    $matches = @($Entries | Where-Object { [string]$_.filename -eq $Filename })
    if ($matches.Count -ne 1) { throw "slot cache entry '$Filename' must exist exactly once" }
    $matches[0].state = $State
    return ,@($Entries)
}

function Select-BonsaiInactiveSlot {
    param(
        [Parameter(Mandatory)][object[]]$Entries,
        [string]$ExcludeFilename=''
    )
    $candidate = @($Entries | Where-Object {
        [string]$_.state -eq 'inactive' -and [string]$_.filename -ne $ExcludeFilename
    } | Sort-Object { [datetime]$_.lastAccess } | Select-Object -First 1)
    if ($candidate.Count -eq 0) { return $null }
    return $candidate[0]
}

function ConvertTo-BonsaiDiskSlotEntries {
    param([AllowNull()][object[]]$Entries)
    $normalized = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($Entries)) {
        if (-not $entry) { continue }
        $properties = [ordered]@{}
        foreach ($property in $entry.PSObject.Properties) {
            if ($property.Name -ne 'tier') { $properties[$property.Name] = $property.Value }
        }
        $normalized.Add([pscustomobject]$properties)
    }
    return ,@($normalized)
}

function Get-BonsaiDiskCacheBudgetPlan {
    param(
        [Parameter(Mandatory)][object[]]$Entries,
        [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long]$MaxBytes,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$MaxFiles,
        [string]$ProtectedFilename=''
    )
    $remaining = [Collections.Generic.List[object]]::new()
    foreach ($entry in (ConvertTo-BonsaiDiskSlotEntries -Entries $Entries)) { $remaining.Add($entry) }
    $bytes = [long]0
    foreach ($entry in $remaining) {
        $entryBytes = if ($entry.PSObject.Properties['bytes']) { [long]$entry.bytes } else { 0L }
        if ($entryBytes -lt 0) { throw "slot '$($entry.filename)' has a negative byte count" }
        $bytes += $entryBytes
    }
    $evicted = [Collections.Generic.List[string]]::new()
    while ($bytes -gt $MaxBytes -or $remaining.Count -gt $MaxFiles) {
        $candidate = Select-BonsaiInactiveSlot -Entries @($remaining) -ExcludeFilename $ProtectedFilename
        if ($null -eq $candidate) { throw 'disk cache budget exceeded and no inactive, unprotected entry is evictable' }
        $candidateBytes = if ($candidate.PSObject.Properties['bytes']) { [long]$candidate.bytes } else { 0L }
        $bytes -= $candidateBytes
        $evicted.Add([string]$candidate.filename)
        for ($index=$remaining.Count-1; $index -ge 0; $index--) {
            if ([string]$remaining[$index].filename -eq [string]$candidate.filename) { $remaining.RemoveAt($index) }
        }
    }
    [pscustomobject]@{ bytes=$bytes; fileCount=$remaining.Count; evicted=@($evicted); entries=@($remaining) }
}

function Assert-BonsaiSlotSaveRetained {
    param(
        [Parameter(Mandatory)][string]$Filename,
        [Parameter(Mandatory)][object[]]$Entries,
        [Parameter(Mandatory)][bool]$FileExists
    )
    $retained = @($Entries | Where-Object { [string]$_.filename -eq $Filename }).Count -eq 1
    if (-not $FileExists -or -not $retained) {
        throw "new slot '$Filename' was immediately evicted by the disk budget; increase the budget or save less state"
    }
}
