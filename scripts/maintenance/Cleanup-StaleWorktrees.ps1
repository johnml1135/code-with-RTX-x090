#Requires -Version 7.0
<#
.SYNOPSIS
    Evict stale git worktrees across every repository under a folder, without losing work.

.DESCRIPTION
    Scans each git repo under -Root, enumerates its linked worktrees, and removes the ones
    that are both STALE and SETTLED:

      stale   = newest activity (HEAD commit date, and the mtime of any uncommitted file)
                is older than -StaleDays.
      settled = either nothing is uncommitted, or you decided what happens to what is.

    A branch ref survives `git worktree remove`, so the only real risks are uncommitted work
    and detached HEADs. Both are handled:
      * uncommitted files are classified Markdown / NonCode / Code, and -Review decides
        which of those you are willing to be ASKED about. Anything above that line is kept.
      * a detached HEAD whose commit is not contained in any branch or tag gets a rescue
        tag (wt-rescue/<name>-<sha>) before the worktree is removed.

    Every stale worktree's uncommitted files are LISTED regardless of -Review, so you always
    see what is there. -Review only controls what you are prompted about.

    Every run writes a JSON manifest under <Root>\.worktree-cleanup\ containing the exact
    `git worktree add` command needed to restore each evicted worktree.

.PARAMETER Root
    Folder holding the repositories. Defaults to the folder containing this script.
    Scanned one level deep.

.PARAMETER StaleDays
    A worktree must be untouched this many days to qualify. Default 3.

.PARAMETER Repo
    Optional wildcard filter on repo folder name, e.g. -Repo PanGloss,Field*

.PARAMETER Worktree
    Optional wildcard filter on individual worktrees. A pattern containing '/' matches
    'Repo/Name'; otherwise it matches the worktree folder name. e.g. -Worktree motif/release-*

.PARAMETER ExcludeWorktree
    Worktrees to leave alone, same pattern rules as -Worktree. Exclusion wins.

.PARAMETER Review
    How far up the file-classification ladder you are willing to be asked:

      ReviewNone      only evict worktrees with nothing uncommitted at all.
      ReviewMarkdown  also ask about worktrees whose uncommitted files are all .md.
      ReviewNonCode   also ask about inert files - .txt .log .diff .patch, images, etc.
      ReviewAll       also ask about source, config and build files.

    Default ReviewMarkdown. An unrecognised extension counts as Code on purpose, so it
    takes ReviewAll to surface it.

.PARAMETER Action
    What to do with the uncommitted files in a worktree you are reviewing:
    Prompt (default), Commit, Discard, or Skip. A non-Prompt value makes the run unattended.
    When no one can answer a prompt (redirected stdin, -NonInteractive, an agent's shell),
    Prompt falls back to Skip instead of waiting forever.

    Discard first copies every file it is about to lose to
    <Root>\.worktree-cleanup\saved-<timestamp>\<repo>\<worktree>\, so it can be undone.

.PARAMETER MeasureSize
    Measure the on-disk size of every stale worktree and print it, with totals, so you can
    pick what to evict to reach a space target. Slower on large trees.

.PARAMETER PassThru
    Emit one object per scanned worktree (verdict, reason, size, uncommitted files, and
    Evicted) to the pipeline, e.g. `| ConvertTo-Json -Depth 4`, for scripts and agents.

.PARAMETER RequirePushed
    Additionally require that a worktree's branch has no commits missing from its upstream.

.PARAMETER DryRun
    Report what would happen and change nothing.

.EXAMPLE
    .\Cleanup-StaleWorktrees.ps1 -DryRun
    See everything, decide nothing.

.EXAMPLE
    .\Cleanup-StaleWorktrees.ps1 -Review ReviewNone
    Only take the pristine ones. No questions asked.

.EXAMPLE
    .\Cleanup-StaleWorktrees.ps1 -Review ReviewNonCode -Action Discard
    Unattended: drop inert leftovers and evict, keep anything with code in it.

.EXAMPLE
    .\Cleanup-StaleWorktrees.ps1 -Review ReviewAll
    Be asked about every stale worktree, including ones holding source changes.

.EXAMPLE
    .\Cleanup-StaleWorktrees.ps1 -DryRun -Review ReviewAll -Action Skip -MeasureSize
    Agent survey: every stale worktree with its size and uncommitted files, no prompts.

.EXAMPLE
    .\Cleanup-StaleWorktrees.ps1 -Worktree motif/release-walkthrough -Review ReviewMarkdown -Action Discard
    Agent eviction of one reviewed worktree; its notes are saved before discarding.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $Root = $PSScriptRoot,
    [int]    $StaleDays = 3,
    [string[]] $Repo,
    [string[]] $Worktree,
    [string[]] $ExcludeWorktree,
    [ValidateSet('ReviewNone', 'ReviewMarkdown', 'ReviewNonCode', 'ReviewAll')]
    [string] $Review = 'ReviewMarkdown',
    [ValidateSet('Prompt', 'Commit', 'Discard', 'Skip')]
    [string] $Action = 'Prompt',
    [switch] $RequirePushed,
    [switch] $MeasureSize,
    [switch] $PassThru,
    [switch] $DryRun
)

$ErrorActionPreference = 'Continue'
$RunStamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)

# How many uncommitted files to print per worktree before collapsing the rest.
$FileListLimit = 10

# Markdown, then things that cannot execute or configure anything. Everything else -
# including any extension not listed here, and files with no extension - counts as Code,
# because guessing wrong in that direction is the expensive mistake.
$MarkdownExtensions = @('.md', '.markdown', '.mdx')
$NonCodeExtensions = @(
    '.txt', '.log', '.diff', '.patch', '.out', '.err',
    '.bak', '.orig', '.rej', '.tmp', '.swp',
    '.csv', '.tsv', '.pdf', '.rtf',
    '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.ico', '.webp',
    '.zip', '.7z', '.gz', '.tgz'
)

# ------------------------------------------------------------------ helpers ----

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string] $Dir,
        [Parameter(ValueFromRemainingArguments)][string[]] $GitArgs
    )
    $out = & git -C $Dir @GitArgs 2>&1
    $code = $LASTEXITCODE
    # Several calls here are probes that are EXPECTED to fail - `rev-parse @{upstream}` on a
    # branch with no upstream exits 128. Clear it so the last probe does not become the
    # script's exit code and break callers that chain on success.
    $global:LASTEXITCODE = 0
    # Keep stderr out of Lines: a warning such as "could not open directory" would
    # otherwise be parsed as a status entry and misclassified as an uncommitted file.
    $stdout = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    $stderr = @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    $text = if ($code -eq 0) { $stdout } else { $stdout + $stderr }
    [pscustomobject]@{
        Ok    = ($code -eq 0)
        Text  = (@($text) -join "`n").Trim()
        Lines = $stdout
        Err   = $stderr
    }
}

function Test-CanPrompt {
    # False when nobody can answer Read-Host - an agent's shell, CI, piped stdin.
    if (-not [Environment]::UserInteractive) { return $false }
    if ([Console]::IsInputRedirected) { return $false }
    foreach ($a in [Environment]::GetCommandLineArgs()) {
        if ($a -match '^-noni') { return $false }
    }
    return $true
}

function Get-DirSize {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $opts = [System.IO.EnumerationOptions]@{
        RecurseSubdirectories = $true
        IgnoreInaccessible    = $true
        AttributesToSkip      = 'ReparsePoint'
    }
    try {
        [long] $sum = 0
        foreach ($f in [System.IO.DirectoryInfo]::new($Path).EnumerateFiles('*', $opts)) { $sum += $f.Length }
        return $sum
    } catch { return $null }
}

function Test-WorktreeFilter {
    param([string] $RepoName, [string] $Name)
    $full = "$RepoName/$Name"
    $hit = {
        param($Patterns)
        foreach ($p in $Patterns) {
            $subject = if ($p -like '*/*') { $full } else { $Name }
            if ($subject -like $p) { return $true }
        }
        return $false
    }
    if ($ExcludeWorktree -and (& $hit $ExcludeWorktree)) { return $false }
    if ($Worktree) { return (& $hit $Worktree) }
    return $true
}

function ConvertTo-WinPath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    ($Path -replace '/', '\').TrimEnd('\')
}

function Format-Size {
    param($Bytes)
    if ($null -eq $Bytes) { return '-' }
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $v = [double]$Bytes
    $i = 0
    while ($v -ge 1024 -and $i -lt ($units.Count - 1)) { $v = $v / 1024; $i++ }
    return ('{0:0.#} {1}' -f $v, $units[$i])
}

function Get-FreeSpace {
    param([string] $Path)
    try {
        $qualifier = Split-Path -Qualifier (Resolve-Path -LiteralPath $Path).ProviderPath
        return [System.IO.DriveInfo]::new("$qualifier\").AvailableFreeSpace
    } catch { return $null }
}

function Remove-TreeHard {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop } catch { }
    if (Test-Path -LiteralPath $Path) {
        # Long paths and read-only files defeat Remove-Item; rd copes with more of them.
        & cmd.exe /c rd /s /q "$Path" 2>$null | Out-Null
    }
    return (-not (Test-Path -LiteralPath $Path))
}

# ----------------------------------------------------------- classification ----

function Get-FileClass {
    param([string] $Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    if ($ext) { $ext = $ext.ToLowerInvariant() }
    if ($MarkdownExtensions -contains $ext) { return 'Markdown' }
    if ($NonCodeExtensions -contains $ext) { return 'NonCode' }
    return 'Code'
}

function Get-ClassRank {
    param([string] $Class)
    switch ($Class) {
        'Markdown' { 1 }
        'NonCode'  { 2 }
        'Code'     { 3 }
        default    { 3 }
    }
}

function Get-ReviewRank {
    param([string] $Level)
    switch ($Level) {
        'ReviewNone'     { 0 }
        'ReviewMarkdown' { 1 }
        'ReviewNonCode'  { 2 }
        'ReviewAll'      { 3 }
        default          { 0 }
    }
}

function Get-ReviewLevelForRank {
    param([int] $Rank)
    switch ($Rank) {
        1 { 'ReviewMarkdown' }
        2 { 'ReviewNonCode' }
        3 { 'ReviewAll' }
        default { 'ReviewNone' }
    }
}

function Get-ClassForRank {
    param([int] $Rank)
    switch ($Rank) {
        1 { 'Markdown' }
        2 { 'NonCode' }
        3 { 'Code' }
        default { 'Clean' }
    }
}

function Write-FileList {
    param(
        $Entries,
        [string] $Indent = '          ',
        [string] $Color = 'DarkYellow'
    )
    # Heaviest class first, tracked edits before untracked additions - so the truncated
    # tail is the least interesting part, not a random slice.
    $sorted = @($Entries | Sort-Object -Property `
        @{ Expression = { Get-ClassRank $_.Class }; Descending = $true },
        @{ Expression = { $_.Untracked }; Descending = $false },
        @{ Expression = { $_.Path }; Descending = $false })

    foreach ($e in @($sorted | Select-Object -First $FileListLimit)) {
        Write-Host ("{0}{1} {2,-8} {3}" -f $Indent, $e.Code, $e.Class, $e.Path) -ForegroundColor $Color
    }
    $extra = $sorted.Count - $FileListLimit
    if ($extra -gt 0) {
        Write-Host ("{0}+{1} more file(s)" -f $Indent, $extra) -ForegroundColor $Color
    }
}

function Write-StatusWarnings {
    param($State, [string] $Indent = '          ')
    foreach ($w in @($State.StatusWarnings)) {
        Write-Host "$Indent(git status: $w)" -ForegroundColor DarkGray
    }
}

function Format-SizeCell {
    param($State)
    if (-not $MeasureSize) { return '' }
    return ('{0,9}  ' -f (Format-Size $State.SizeBytes))
}

# ----------------------------------------------------------- repo discovery ----

function Get-RepoRoot {
    # Resolve any folder to the root of its MAIN worktree, or $null.
    param([string] $Dir)
    if (-not (Test-Path -LiteralPath (Join-Path $Dir '.git'))) { return $null }
    $r = Invoke-Git $Dir rev-parse --path-format=absolute --git-common-dir
    if (-not $r.Ok) { return $null }
    $common = ConvertTo-WinPath $r.Text
    if ($common -match '\\\.git$') { return (Split-Path -Parent $common) }
    return $null   # bare repo, or a layout worth not guessing at
}

function Get-Repos {
    param([string] $Root, [string[]] $Filter)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $dirs = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($d in $dirs) {
        if ($Filter) {
            $match = $false
            foreach ($f in $Filter) { if ($d.Name -like $f) { $match = $true; break } }
            if (-not $match) { continue }
        }
        $root = Get-RepoRoot $d.FullName
        if (-not $root) { continue }
        if ($seen.Add($root)) {
            [pscustomobject]@{ Name = (Split-Path -Leaf $root); Path = $root }
        }
    }
}

# ------------------------------------------------------ worktree enumeration ----

function Get-Worktrees {
    param([string] $RepoPath)

    $r = Invoke-Git $RepoPath worktree list --porcelain
    if (-not $r.Ok) {
        Write-Warning "  cannot list worktrees in $RepoPath : $($r.Text)"
        return @()
    }

    $list = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    foreach ($line in $r.Lines) {
        if ($line -match '^worktree (.+)$') {
            if ($cur) { $list.Add($cur) }
            $cur = [pscustomobject]@{
                Path     = ConvertTo-WinPath $Matches[1]
                Head     = $null
                Branch   = $null
                Detached = $false
                Bare     = $false
                Locked   = $false
            }
        } elseif ($null -ne $cur) {
            if ($line -match '^HEAD (.+)$')        { $cur.Head = $Matches[1] }
            elseif ($line -match '^branch (.+)$')  { $cur.Branch = ($Matches[1] -replace '^refs/heads/', '') }
            elseif ($line -match '^detached')      { $cur.Detached = $true }
            elseif ($line -match '^bare')          { $cur.Bare = $true }
            elseif ($line -match '^locked')        { $cur.Locked = $true }
        }
    }
    if ($cur) { $list.Add($cur) }

    # The first stanza is always the main worktree - never a candidate.
    for ($i = 0; $i -lt $list.Count; $i++) {
        $list[$i] | Add-Member -NotePropertyName IsMain -NotePropertyValue ($i -eq 0) -Force
    }
    return $list
}

function Get-DirtyEntries {
    param([string] $Wt)

    $r = Invoke-Git $Wt -c core.quotePath=false status --porcelain=v1 -uall --no-renames
    if (-not $r.Ok) { return $null }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $r.Lines) {
        if ($line.Length -lt 4) { continue }
        $code = $line.Substring(0, 2)
        $path = $line.Substring(3)
        if ($path.StartsWith('"') -and $path.EndsWith('"')) {
            $path = $path.Substring(1, $path.Length - 2)
        }
        $entries.Add([pscustomobject]@{
            Code      = $code
            Path      = $path
            Untracked = ($code -eq '??')
            Class     = (Get-FileClass $path)
        })
    }
    return [pscustomobject]@{
        Entries  = @($entries)
        Warnings = @($r.Err | ForEach-Object { ($_ -replace '^warning:\s*', '').Trim() } | Where-Object { $_ })
    }
}

function Get-WorktreeState {
    param([pscustomobject] $Wt, [string] $RepoPath)

    $path = $Wt.Path
    $state = [pscustomobject]@{
        Repo      = (Split-Path -Leaf $RepoPath)
        RepoPath  = $RepoPath
        Path      = $path
        Name      = (Split-Path -Leaf $path)
        Branch    = $Wt.Branch
        Head      = $Wt.Head
        Detached  = $Wt.Detached
        Exists    = (Test-Path -LiteralPath $path)
        AgeDays   = $null
        Dirty     = @()
        DirtyRank = 0
        DirtyClass = 'Clean'
        NeedsLevel = 'ReviewNone'
        Ahead     = $null
        Upstream  = $null
        StatusWarnings = @()
        SizeBytes = $null
        SavedTo   = $null
        Verdict   = 'unknown'
        Reason    = ''
        Evicted   = $false
    }

    if (-not $state.Exists) {
        $state.Verdict = 'prunable'
        $state.Reason = 'directory is gone; needs git worktree prune'
        return $state
    }
    if ($Wt.Locked) {
        $state.Verdict = 'skip'
        $state.Reason = 'worktree is locked'
        return $state
    }

    # --- newest activity: HEAD commit date, plus the mtime of anything uncommitted ---
    $newest = [datetime]::MinValue
    $ct = Invoke-Git $path log -1 --format=%ct HEAD
    if ($ct.Ok -and $ct.Text -match '^\d+$') {
        $newest = [datetimeoffset]::FromUnixTimeSeconds([long]$ct.Text).LocalDateTime
    }

    $status = Get-DirtyEntries $path
    if ($null -eq $status) {
        $state.Verdict = 'skip'
        $state.Reason = 'git status failed'
        return $state
    }
    $dirty = $status.Entries
    $state.StatusWarnings = $status.Warnings

    $rank = 0
    foreach ($e in $dirty) {
        $full = Join-Path $path ($e.Path -replace '/', '\')
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
            if ($item -and $item.LastWriteTime -gt $newest) { $newest = $item.LastWriteTime }
        }
        $r = Get-ClassRank $e.Class
        if ($r -gt $rank) { $rank = $r }
    }

    $state.Dirty = @($dirty)
    $state.DirtyRank = $rank
    $state.DirtyClass = Get-ClassForRank $rank
    $state.NeedsLevel = Get-ReviewLevelForRank $rank

    if ($newest -gt [datetime]::MinValue) {
        $state.AgeDays = [math]::Floor(((Get-Date) - $newest).TotalDays)
    }

    # --- upstream position (informational unless -RequirePushed) ---
    if (-not $Wt.Detached -and $Wt.Branch) {
        $up = Invoke-Git $path rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
        if ($up.Ok) {
            $state.Upstream = $up.Text
            $cnt = Invoke-Git $path rev-list --count '@{upstream}..HEAD'
            if ($cnt.Ok -and $cnt.Text -match '^\d+$') { $state.Ahead = [int]$cnt.Text }
        }
    }

    # --- verdict ---
    $reviewRank = Get-ReviewRank $Review
    if ($null -eq $state.AgeDays) {
        $state.Verdict = 'skip'
        $state.Reason = 'could not determine age'
    } elseif ($state.AgeDays -lt $StaleDays) {
        $state.Verdict = 'fresh'
        $state.Reason = "active $($state.AgeDays)d ago"
    } elseif (@($state.StatusWarnings | Where-Object { $_ -match 'Permission denied' }).Count -gt 0) {
        # git could not look inside something, so "clean" is unproven.
        $state.Verdict = 'kept'
        $state.Reason = 'git status could not read part of the tree - check it by hand'
    } elseif ($rank -gt $reviewRank) {
        $state.Verdict = 'kept'
        $state.Reason = "$(@($dirty).Count) uncommitted file(s), heaviest is $($state.DirtyClass) - needs -Review $($state.NeedsLevel)"
    } elseif ($RequirePushed -and -not $Wt.Detached -and (($null -eq $state.Upstream) -or ($state.Ahead -gt 0))) {
        $state.Verdict = 'kept'
        if ($null -eq $state.Upstream) { $state.Reason = 'branch has no upstream (-RequirePushed)' }
        else { $state.Reason = "$($state.Ahead) commit(s) not pushed (-RequirePushed)" }
    } else {
        $state.Verdict = 'candidate'
        $state.Reason = "stale $($state.AgeDays)d"
    }
    return $state
}

# ------------------------------------------------------- safety and removal ----

function Protect-Branch {
    # Ensure nothing becomes unreachable once the worktree is gone. Returns a note.
    param([pscustomobject] $State)

    if (-not $State.Detached) {
        return "branch '$($State.Branch)' kept in $($State.Repo)"
    }

    $sha = $State.Head
    $short = if ($sha) { $sha.Substring(0, [math]::Min(9, $sha.Length)) } else { 'unknown' }

    $br = Invoke-Git $State.Path branch -a --contains $sha
    $holders = @($br.Lines |
        Where-Object { $_ -notmatch '\(HEAD detached' } |
        ForEach-Object { ($_ -replace '^\*?\s*', '').Trim() } |
        Where-Object { $_ })
    $tg = Invoke-Git $State.Path tag --contains $sha
    $tags = @($tg.Lines | ForEach-Object { "$_".Trim() } | Where-Object { $_ })

    if ($holders.Count -gt 0) { return "detached $short already on: $($holders -join ', ')" }
    if ($tags.Count -gt 0) { return "detached $short already tagged: $($tags -join ', ')" }

    $tag = "wt-rescue/$($State.Name)-$short"
    if ($DryRun) { return "detached $short is UNREACHABLE - would tag $tag" }

    $mk = Invoke-Git $State.RepoPath tag $tag $sha
    if ($mk.Ok) { return "detached $short rescued as tag $tag" }
    return "FAILED to rescue detached $short : $($mk.Text)"
}

function Resolve-DirtyFiles {
    # Commit or discard the reviewed files. $true if the tree is settled.
    param([pscustomobject] $State, [string] $Decision)

    $dirty = @($State.Dirty)
    if ($dirty.Count -eq 0) { return $true }
    $paths = @($dirty | ForEach-Object { $_.Path })

    if ($Decision -eq 'Commit') {
        if ($DryRun) {
            Write-Host "      would commit $($dirty.Count) file(s) to '$($State.Branch)'" -ForegroundColor DarkGray
            return $true
        }
        $add = Invoke-Git $State.Path add -- @paths
        if (-not $add.Ok) { Write-Warning "      git add failed: $($add.Text)"; return $false }
        $msg = "chore: save uncommitted files before worktree eviction`n`n" +
               (($paths | ForEach-Object { "- $_" }) -join "`n")
        $ci = Invoke-Git $State.Path commit -m $msg
        if (-not $ci.Ok) { Write-Warning "      git commit failed: $($ci.Text)"; return $false }
        Write-Host "      committed $($dirty.Count) file(s) to '$($State.Branch)'" -ForegroundColor Green
        return $true
    }

    if ($Decision -eq 'Discard') {
        $code = @($dirty | Where-Object { $_.Class -eq 'Code' })
        if ($code.Count -gt 0) {
            Write-Host "      WARNING: discarding $($code.Count) file(s) classified Code" -ForegroundColor Red
        }
        $saveTo = Join-Path $Root ".worktree-cleanup\saved-$RunStamp\$($State.Repo)\$($State.Name)"
        if ($DryRun) {
            Write-Host "      would save then discard $($dirty.Count) file(s) (to $saveTo)" -ForegroundColor DarkGray
            return $true
        }
        # Save first; a discard that cannot be backed up does not happen.
        foreach ($e in $dirty) {
            $src = Join-Path $State.Path ($e.Path -replace '/', '\')
            if (-not (Test-Path -LiteralPath $src)) { continue }   # a deletion - restore brings it back
            $dst = Join-Path $saveTo ($e.Path -replace '/', '\')
            try {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
                Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force -ErrorAction Stop
            } catch {
                Write-Warning "      could not save $($e.Path) : $_ - not discarding"
                return $false
            }
        }
        $State.SavedTo = $saveTo
        Write-Host "      saved $($dirty.Count) file(s) to $saveTo" -ForegroundColor DarkGray
        $tracked =@($dirty | Where-Object { -not $_.Untracked } | ForEach-Object { $_.Path })
        if ($tracked.Count -gt 0) { Invoke-Git $State.Path restore -- @tracked | Out-Null }
        foreach ($e in @($dirty | Where-Object { $_.Untracked })) {
            $full = Join-Path $State.Path ($e.Path -replace '/', '\')
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "      discarded $($dirty.Count) file(s)" -ForegroundColor DarkYellow
        return $true
    }

    return $false
}

function Request-Decision {
    param([pscustomobject] $State, [ref] $StickyDecision)

    if ($StickyDecision.Value) { return $StickyDecision.Value }
    if ($Action -ne 'Prompt') { return $Action }

    $label = if ($State.Branch) { $State.Branch } else { 'detached' }
    Write-Host ''
    Write-Host "  $($State.Repo)/$($State.Name)" -ForegroundColor Cyan -NoNewline
    Write-Host "  [$label]  stale $($State.AgeDays)d  $(@($State.Dirty).Count) uncommitted, heaviest $($State.DirtyClass)"
    Write-FileList -Entries $State.Dirty -Indent '      ' -Color Yellow

    while ($true) {
        Write-Host '      [C]ommit  [D]iscard  [S]kip worktree  |  [A]ll commit  [X] all discard  [Q]uit : ' -NoNewline
        # Closed stdin returns $null (or throws under -NonInteractive); treat it as Quit
        # rather than re-asking forever.
        try { $raw = Read-Host } catch { $raw = $null }
        if ($null -eq $raw) { Write-Host ''; return 'Quit' }
        $answer = $raw.Trim().ToUpperInvariant()
        switch ($answer) {
            'C' { return 'Commit' }
            'D' { return 'Discard' }
            'S' { return 'Skip' }
            'A' { $StickyDecision.Value = 'Commit'; return 'Commit' }
            'X' { $StickyDecision.Value = 'Discard'; return 'Discard' }
            'Q' { return 'Quit' }
            default { Write-Host '      choose C, D, S, A, X or Q' -ForegroundColor Red }
        }
    }
}

function Remove-Worktree {
    param([pscustomobject] $State)

    if ($DryRun) { return $true }

    $rm = Invoke-Git $State.RepoPath worktree remove -- $State.Path
    if ($rm.Ok) { return $true }

    # Cleanliness is already established above, so escalate rather than give up.
    $rm2 = Invoke-Git $State.RepoPath worktree remove --force -- $State.Path
    if ($rm2.Ok) { return $true }

    Write-Warning "      git worktree remove failed: $($rm2.Text)"
    if (Remove-TreeHard $State.Path) {
        Invoke-Git $State.RepoPath worktree prune | Out-Null
        Write-Host '      removed on disk and pruned' -ForegroundColor DarkYellow
        return $true
    }
    return $false
}

function Invoke-Eviction {
    # Settle files, guarantee reachability, remove. Returns a manifest row or $null.
    param([pscustomobject] $State, [string] $Decision)

    $label = if ($State.Branch) { $State.Branch } else { 'detached' }
    $target = "$($State.Repo)/$($State.Name) [$label]"
    if (-not $DryRun -and -not $PSCmdlet.ShouldProcess($target, 'remove worktree')) { return $null }

    $dirty = @($State.Dirty)
    if ($dirty.Count -gt 0) {
        if (-not (Resolve-DirtyFiles -State $State -Decision $Decision)) {
            Write-Host "      left $($State.Repo)/$($State.Name) alone - could not settle its files" -ForegroundColor Red
            return $null
        }
    }

    $safety = Protect-Branch -State $State
    if ($safety -like 'FAILED*') {
        Write-Host "      $safety" -ForegroundColor Red
        return $null
    }

    if (-not (Remove-Worktree -State $State)) { return $null }

    $State.Evicted = -not $DryRun
    $verb = if ($DryRun) { 'would evict' } else { 'evicted' }
    Write-Host ('  {0} {1,-48} {2}' -f $verb, $target, $safety) -ForegroundColor Green

    $restoreRef = if ($State.Branch) { $State.Branch } else { $State.Head }
    return [pscustomobject]@{
        Repo           = $State.Repo
        Worktree       = $State.Path
        Branch         = $State.Branch
        Head           = $State.Head
        Detached       = $State.Detached
        AgeDays        = $State.AgeDays
        Upstream       = $State.Upstream
        CommitsAhead   = $State.Ahead
        DirtyClass     = $State.DirtyClass
        Decision       = $Decision
        SizeBytes      = $State.SizeBytes
        DirtyFiles     = @($dirty | ForEach-Object { "$($_.Class) $($_.Path)" })
        SavedTo        = $State.SavedTo
        Safety         = $safety
        RestoreCommand = "git -C `"$($State.RepoPath)`" worktree add `"$($State.Path)`" $restoreRef"
    }
}

# --------------------------------------------------------------------- main ----

if (-not $Root) { $Root = (Get-Location).Path }
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath

Write-Host ''
Write-Host 'Stale worktree cleanup' -ForegroundColor White
Write-Host "  root        : $Root"
Write-Host "  stale after : $StaleDays day(s)"
$reviewCeiling = Get-ClassForRank (Get-ReviewRank $Review)
if ($Review -eq 'ReviewNone') {
    Write-Host '  review      : ReviewNone (only worktrees with nothing uncommitted)'
} else {
    Write-Host "  review      : $Review (asked about uncommitted files up to $reviewCeiling)"
}
if ($Action -eq 'Prompt' -and -not (Test-CanPrompt)) {
    # Nobody is there to answer. Skipping is the only choice that cannot lose work.
    $Action = 'Skip'
    Write-Host '  action      : Skip (no interactive console - pass -Action Commit|Discard to settle files)' -ForegroundColor Yellow
} else {
    Write-Host "  action      : $Action"
}
if ($Worktree) { Write-Host "  worktrees   : $($Worktree -join ', ')" }
if ($ExcludeWorktree) { Write-Host "  excluding   : $($ExcludeWorktree -join ', ')" }
if ($DryRun) { Write-Host '  MODE        : DRY RUN - nothing will change' -ForegroundColor Yellow }
if ($RequirePushed) { Write-Host '  requiring   : branches fully pushed' -ForegroundColor Yellow }
Write-Host ''

$freeBefore = Get-FreeSpace $Root
$repos = @(Get-Repos -Root $Root -Filter $Repo)
if ($repos.Count -eq 0) {
    Write-Host 'No git repositories found.' -ForegroundColor Yellow
    return
}

$all = [System.Collections.Generic.List[object]]::new()
foreach ($r in $repos) {
    $wts = @(Get-Worktrees $r.Path | Where-Object {
            -not $_.IsMain -and -not $_.Bare -and (Test-WorktreeFilter $r.Name (Split-Path -Leaf $_.Path))
        })
    if ($wts.Count -eq 0) { continue }
    Write-Host "$($r.Name): $($wts.Count) linked worktree(s)" -ForegroundColor DarkCyan
    foreach ($w in $wts) { $all.Add((Get-WorktreeState -Wt $w -RepoPath $r.Path)) }
}

if ($all.Count -eq 0) {
    Write-Host 'No linked worktrees found.' -ForegroundColor Yellow
    return
}

$candidates = @($all | Where-Object { $_.Verdict -eq 'candidate' } | Sort-Object Repo, Name)
$kept       = @($all | Where-Object { $_.Verdict -eq 'kept' } | Sort-Object Repo, Name)
$fresh      = @($all | Where-Object { $_.Verdict -eq 'fresh' })
$prunable   = @($all | Where-Object { $_.Verdict -eq 'prunable' })
$skipped    = @($all | Where-Object { $_.Verdict -eq 'skip' })
# Clean and stale is unconditional - no question, no -Review level, no -Action.
# Dirty and stale within -Review is the review queue.
$autoEvict = @($candidates | Where-Object { @($_.Dirty).Count -eq 0 })
$toReview  = @($candidates | Where-Object { @($_.Dirty).Count -gt 0 })

if ($MeasureSize) {
    Write-Host 'Measuring stale worktrees...' -ForegroundColor DarkGray
    foreach ($s in @($candidates) + @($kept)) { $s.SizeBytes = Get-DirSize $s.Path }
}

Write-Host ''
Write-Host ("Scanned {0} worktree(s): {1} clean+stale (evict), {2} to review, {3} skipped, {4} still active" -f `
    $all.Count, $autoEvict.Count, $toReview.Count, $kept.Count, $fresh.Count) -ForegroundColor White
if ($MeasureSize) {
    $sumOf = { param($set) [long](@($set | ForEach-Object { [long]$_.SizeBytes }) | Measure-Object -Sum).Sum }
    Write-Host ("  size: clean {0}, to review {1}, skipped {2}" -f `
        (Format-Size (& $sumOf $autoEvict)), (Format-Size (& $sumOf $toReview)), (Format-Size (& $sumOf $kept))) -ForegroundColor White
}

if ($autoEvict.Count -gt 0) {
    Write-Host ''
    Write-Host 'Stale and clean - evicting, nothing to decide:' -ForegroundColor Green
    foreach ($c in $autoEvict) {
        $label = if ($c.Branch) { $c.Branch } else { '(detached)' }
        Write-Host ('  {0,4}d  {1}{2,-44} {3}' -f $c.AgeDays, (Format-SizeCell $c), "$($c.Repo)/$($c.Name)", $label)
        Write-StatusWarnings $c
    }
}

if ($toReview.Count -gt 0) {
    Write-Host ''
    Write-Host "Stale with uncommitted content at or below -Review $Review - will ask:" -ForegroundColor Cyan
    foreach ($c in $toReview) {
        $label = if ($c.Branch) { $c.Branch } else { '(detached)' }
        Write-Host ('  {0,4}d  {1}{2,-44} {3,-46}  {4} uncommitted, heaviest {5}' -f `
            $c.AgeDays, (Format-SizeCell $c), "$($c.Repo)/$($c.Name)", $label, @($c.Dirty).Count, $c.DirtyClass)
        Write-FileList -Entries $c.Dirty -Color DarkGray
        Write-StatusWarnings $c
    }
}

if ($kept.Count -gt 0) {
    Write-Host ''
    Write-Host '################################################################' -ForegroundColor Red
    Write-Host " SKIPPED - $($kept.Count) worktree(s) NOT touched and NOT asked about" -ForegroundColor Red
    Write-Host " Uncommitted content sits above -Review $Review." -ForegroundColor Red
    Write-Host '################################################################' -ForegroundColor Red
    foreach ($k in $kept) {
        $label = if ($k.Branch) { $k.Branch } else { '(detached)' }
        Write-Host ('  SKIP {0,4}d  {1}{2,-44} {3,-46}{4}' -f $k.AgeDays, (Format-SizeCell $k), "$($k.Repo)/$($k.Name)", $label, $k.Reason) -ForegroundColor Yellow
        if (@($k.Dirty).Count -gt 0) { Write-FileList -Entries $k.Dirty }
        Write-StatusWarnings $k
    }
}

if ($prunable.Count -gt 0) {
    Write-Host ''
    Write-Host 'Stale administrative entries (directory already gone):' -ForegroundColor DarkGray
    foreach ($p in $prunable) { Write-Host "  $($p.Repo)/$($p.Name)" }
    if (-not $DryRun -and $PSCmdlet.ShouldProcess('stale worktree metadata', 'git worktree prune')) {
        foreach ($rp in @($prunable | Select-Object -ExpandProperty RepoPath -Unique)) {
            Invoke-Git $rp worktree prune | Out-Null
        }
        Write-Host '  pruned' -ForegroundColor Green
    }
}

foreach ($s in $skipped) {
    Write-Host "  skipped $($s.Repo)/$($s.Name): $($s.Reason)" -ForegroundColor DarkGray
}

if ($candidates.Count -eq 0) {
    Write-Host ''
    Write-Host 'Nothing to evict.' -ForegroundColor Green
    if ($PassThru) { $all }
    return
}

# ------------------------------------------------------------------- act ----
Write-Host ''
$evicted = [System.Collections.Generic.List[object]]::new()
$sticky = $null

# Phase 1 - clean and stale. Unconditional, and done BEFORE any prompting so that
# quitting the review queue can never cost you these.
foreach ($c in $autoEvict) {
    $row = Invoke-Eviction -State $c -Decision 'none'
    if ($row) { $evicted.Add($row) }
}

# Phase 2 - the review queue.
if ($toReview.Count -gt 0) {
    foreach ($c in $toReview) {
        $decision = Request-Decision -State $c -StickyDecision ([ref]$sticky)
        if ($decision -eq 'Quit') {
            Write-Host '  stopping the review queue at your request.' -ForegroundColor Yellow
            break
        }
        if ($decision -eq 'Skip') {
            Write-Host "      skipped $($c.Repo)/$($c.Name)" -ForegroundColor DarkGray
            continue
        }
        $row = Invoke-Eviction -State $c -Decision $decision
        if ($row) { $evicted.Add($row) }
    }
}

# ---------------------------------------------------------------- report ----
$freeAfter = Get-FreeSpace $Root
Write-Host ''
if ($DryRun) {
    Write-Host "Dry run: $($evicted.Count) worktree(s) would be evicted." -ForegroundColor Yellow
} else {
    Write-Host "Evicted $($evicted.Count) worktree(s)." -ForegroundColor Green
    if ($freeBefore -and $freeAfter -and $freeAfter -gt $freeBefore) {
        Write-Host "Reclaimed $(Format-Size ($freeAfter - $freeBefore)). Free on drive: $(Format-Size $freeAfter)." -ForegroundColor Green
    } elseif ($freeAfter) {
        Write-Host "Free on drive: $(Format-Size $freeAfter)." -ForegroundColor Green
    }
}

if ($evicted.Count -gt 0 -and -not $DryRun) {
    $logDir = Join-Path $Root '.worktree-cleanup'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
    $logFile = Join-Path $logDir "evicted-$RunStamp.json"
    [pscustomobject]@{
        RanAt      = (Get-Date).ToString('o')
        Root       = $Root
        StaleDays  = $StaleDays
        Review     = $Review
        FreedBytes = if ($freeBefore -and $freeAfter) { $freeAfter - $freeBefore } else { $null }
        Evicted    = @($evicted)
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $logFile -Encoding utf8
    Write-Host "Manifest (includes restore commands): $logFile" -ForegroundColor DarkCyan
}

if ($kept.Count -gt 0) {
    # Highest level any kept worktree would need - the single flag that surfaces them all.
    [int] $next = 0
    foreach ($k in $kept) {
        $r = Get-ReviewRank $k.NeedsLevel
        if ($r -gt $next) { $next = $r }
    }
    Write-Host ''
    Write-Host "$($kept.Count) worktree(s) kept above your -Review line. Re-run with -Review $(Get-ReviewLevelForRank $next) to be asked about them." -ForegroundColor Yellow
}

if ($PassThru) { $all }
