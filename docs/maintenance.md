# Maintenance utility

scripts/maintenance/Cleanup-StaleWorktrees.ps1 is the existing stale-worktree
cleanup utility included for this lab. It scans repositories one level below
the supplied root, identifies linked worktrees that are stale and settled, and
keeps uncommitted code above the selected review threshold.

Recommended survey:

    pwsh -NoProfile -File scripts/maintenance/Cleanup-StaleWorktrees.ps1 -Root <repos-root> -DryRun -Review ReviewAll -Action Skip -MeasureSize

The utility defaults Root to the folder containing the script. Always use
DryRun first, review the listed worktrees, and use -RequirePushed when branch
publication is required. Discard mode saves files under the selected root's
worktree-cleanup directory before removing them, but destructive operations
still require an explicit choice. Never point Root at a drive root, home
directory, or an unresolved variable. Run the repository syntax test before
upgrading this utility.

