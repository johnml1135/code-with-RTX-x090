# Links each skill in this repo's skills\ folder into the agent skill directories, so the repo copy
# is the single version-controlled source. Uses directory junctions (no admin rights needed).
#   ~/.agents/skills  - Codex and pi
#   ~/.claude/skills  - Claude Code (~/.claude-work/skills points here)
[CmdletBinding()]
param([string[]]$Targets = @("$HOME\.agents\skills", "$HOME\.claude\skills"))
$ErrorActionPreference = 'Stop'
$skillsRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills'

foreach ($skill in Get-ChildItem -LiteralPath $skillsRoot -Directory) {
    foreach ($target in $Targets) {
        [void][IO.Directory]::CreateDirectory($target)
        $link = Join-Path $target $skill.Name
        $existing = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        if ($existing -and $existing.LinkType -and $existing.Target -eq $skill.FullName) { "ok       $link"; continue }
        if ($existing -and $existing.LinkType) {
            $existing.Delete()   # removes only the link, never the target
        } elseif ($existing) {
            throw "$link is a real directory; move it aside (or into $skillsRoot) before linking"
        }
        New-Item -ItemType Junction -Path $link -Target $skill.FullName | Out-Null
        "linked   $link -> $($skill.FullName)"
    }
}
