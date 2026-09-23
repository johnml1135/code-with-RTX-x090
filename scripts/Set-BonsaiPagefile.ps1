# Adds a fixed-size pagefile so Windows' commit limit covers llama-server's VRAM-backed commit
# (see README "Memory"). Run elevated; takes effect after a reboot.
#   Set-BonsaiPagefile.ps1 [-Path G:\pagefile.sys] [-InitialMB 32768] [-MaximumMB 65536]
[CmdletBinding()]
param([string]$Path = 'G:\pagefile.sys', [uint32]$InitialMB = 32768, [uint32]$MaximumMB = 65536, [string]$Log)
$ErrorActionPreference = 'Stop'
try {
    $existing = Get-CimInstance Win32_PageFileSetting | Where-Object Name -eq $Path
    if ($existing) {
        $existing | Set-CimInstance -Property @{ InitialSize = $InitialMB; MaximumSize = $MaximumMB }
    } else {
        New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = $Path; InitialSize = $InitialMB; MaximumSize = $MaximumMB } | Out-Null
    }
    $result = Get-CimInstance Win32_PageFileSetting | ForEach-Object { "$($_.Name) initial=$($_.InitialSize)MB max=$($_.MaximumSize)MB" }
    $result += 'reboot to apply'
} catch {
    $result = "ERROR: $($_.Exception.Message)"
}
if ($Log) { $result | Out-File -LiteralPath $Log } else { $result }
