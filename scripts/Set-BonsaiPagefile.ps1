# Sets fixed-size pagefiles so Windows' commit limit covers llama-server's VRAM-backed commit
# (see README "Memory"): a small one on the system SSD (crash dumps) and a large one on the G: HDD.
# Run elevated. Writes the PagingFiles list in the given order; shrinking takes effect after a reboot.
#   Set-BonsaiPagefile.ps1                  C: 6 GB, then G: 60 GB
#   Set-BonsaiPagefile.ps1 -Log <file>      write the result to a file (for an elevated child process)
[CmdletBinding()]
param(
    [string[]]$PagingFiles = @('C:\pagefile.sys 6144 6144', 'G:\pagefile.sys 61440 61440'),
    [string]$Log
)
$ErrorActionPreference = 'Stop'
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) { $cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false } }
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    Set-ItemProperty -LiteralPath $key -Name PagingFiles -Type MultiString -Value $PagingFiles
    $result = @('PagingFiles (in order):') + ((Get-ItemProperty -LiteralPath $key).PagingFiles | ForEach-Object { "  $_" })
    $result += 'reboot to apply'
} catch {
    $result = "ERROR: $($_.Exception.Message)"
}
if ($Log) { $result | Out-File -LiteralPath $Log } else { $result }
