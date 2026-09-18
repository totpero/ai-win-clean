<#
.SYNOPSIS
    Scan for and remove Windows junk files, driven by the winapp2 cleaning database.

.DESCRIPTION
    ai-win-clean is a dry-run-first Windows cleaner. It reads the community-maintained
    winapp2.ini database (~4,000 application cleaning rules) plus its own built-in
    ruleset for core Windows caches, works out which rules apply to this machine, and
    reports what it would delete.

    It NEVER deletes anything unless -Apply is passed. Registry cleaning is off unless
    -IncludeRegistry is passed. The Recycle Bin is never touched unless
    -EmptyRecycleBin is passed.

    Every resolved path is checked against a hard-coded protection list before it can be
    enumerated, and again immediately before deletion.

.PARAMETER Apply
    Actually delete. Without this the script only reports (dry run). This is the single
    switch that separates "look" from "destroy".

.PARAMETER Force
    Skip the interactive confirmation that -Apply normally requires. Intended for
    unattended and agent-driven use. Has no effect without -Apply.

.PARAMETER Section
    Only process these categories. Wildcards allowed. e.g. -Section 'Google Chrome','Windows*'

.PARAMETER ExcludeSection
    Skip these categories. Wildcards allowed.

.PARAMETER Entry
    Only process entries whose name matches. Wildcards allowed.

.PARAMETER ExcludeEntry
    Skip entries whose name matches. Wildcards allowed.

.PARAMETER RuleSet
    Which rules to use: All (default), Winapp2 (database only), System (built-in only).

.PARAMETER Aggressive
    Include built-in rules that are safe but have a real trade-off: Windows.old removal
    (loses rollback), Prefetch (slower app launches), Event Logs (loses diagnostics).

.PARAMETER IncludeWarnings
    Include entries that carry a Warning= caveat. Skipped by default.

.PARAMETER IncludeRegistry
    Also clean RegKey targets. Off by default: registry edits are far harder to undo
    than file deletions, and the space saved is nil.

.PARAMETER OlderThanDays
    Only consider files not modified in this many days. Strongly recommended for temp
    directories, where in-flight installers and unsaved scratch files live.

.PARAMETER EmptyRecycleBin
    Empty the Recycle Bin. Separate from everything else on purpose: its contents are
    the user's own files and their only undo path.

.PARAMETER DatabasePath
    Path to a winapp2.ini. Defaults to the cached copy in %LOCALAPPDATA%\ai-win-clean.

.PARAMETER UpdateDatabase
    Download a fresh copy of the database before running.

.PARAMETER Flavor
    Which winapp2 variant to download: NonCCleaner (default), CCleaner, BleachBit.

.PARAMETER Output
    Text (default), Json, or Csv. Json is the machine-readable contract for agents.

.PARAMETER ReportPath
    Also write the report to this file.

.PARAMETER LogPath
    Append an audit record of every deletion to this JSON-lines file.

.PARAMETER Protect
    Additional paths to protect, beyond the built-in list.

.PARAMETER Top
    How many entries to show in the text report. Default 25, 0 for all.

.PARAMETER ListSections
    List available categories and exit.

.PARAMETER ListEntries
    List matching entries and exit, without scanning the filesystem.

.EXAMPLE
    .\Invoke-WinClean.ps1
    Dry run over everything. Reports what would be freed. Deletes nothing.

.EXAMPLE
    .\Invoke-WinClean.ps1 -Section 'Windows System' -OlderThanDays 7 -Output Json
    Machine-readable preview of core Windows junk older than a week.

.EXAMPLE
    .\Invoke-WinClean.ps1 -Apply -Force -OlderThanDays 1 -LogPath clean.jsonl
    Unattended clean of everything untouched for a day, with an audit trail.

.LINK
    https://github.com/MoscaDotTo/Winapp2
#>

[CmdletBinding()]
param(
    [switch]   $Apply,
    [switch]   $Force,

    [string[]] $Section,
    [string[]] $ExcludeSection,
    [string[]] $Entry,
    [string[]] $ExcludeEntry,

    [ValidateSet('All', 'Winapp2', 'System')]
    [string]   $RuleSet = 'All',

    [switch]   $Aggressive,
    [switch]   $IncludeWarnings,
    [switch]   $IncludeRegistry,

    [ValidateRange(0, 3650)]
    [int]      $OlderThanDays = 0,

    [switch]   $EmptyRecycleBin,

    [string]   $DatabasePath,
    [switch]   $UpdateDatabase,
    [switch]   $CheckUpdate,
    [switch]   $RollbackDatabase,
    [switch]   $NoUpdate,

    # Auto-refresh the database when the local copy is older than this. The check is a
    # conditional GET, so an unchanged database costs a 304 and no transfer.
    # 0 disables automatic refresh entirely.
    [ValidateRange(0, 3650)]
    [int]      $MaxDatabaseAgeDays = 14,

    [ValidateSet('NonCCleaner', 'CCleaner', 'BleachBit')]
    [string]   $Flavor = 'NonCCleaner',

    [switch]   $Status,
    [int]      $SnoozeDays,

    # Persistent "never clean this" list, remembered across runs.
    [string[]] $Ignore,
    [string[]] $IgnorePath,
    [string[]] $Unignore,
    [switch]   $ClearIgnored,
    [switch]   $ListIgnored,
    [switch]   $NoIgnoreList,

    [ValidateSet('Text', 'Json', 'Csv', 'Brief')]
    [string]   $Output = 'Text',

    [string]   $ReportPath,
    [string]   $LogPath,
    [string[]] $Protect,

    [ValidateRange(1, 10)]
    [int]      $MinDepth = 1,

    [int]      $Top = 25,

    [switch]   $ListSections,
    [switch]   $ListEntries,
    [switch]   $Quiet
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

<#
    Normalise a list argument.

    PowerShell only parses "-Section 'A','B'" into an array when the script is invoked
    from inside PowerShell. Launched with -File - which is how the .cmd and .sh shims and
    every agent shelling out must do it - the same text arrives as the single string
    "A,B". Left alone that matches nothing, exits 0, and reports a confident zero.

    Splitting on commas here makes every invocation path behave identically.
    Consequence: a comma in a value is a separator, including in -Protect paths.
#>
function Expand-WinCleanListArg {
    param([string[]] $Value)

    if (-not $Value) { return ,@() }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($v in $Value) {
        if ($null -eq $v) { continue }
        foreach ($part in ($v -split ',')) {
            $p = $part.Trim().Trim("'").Trim('"').Trim()
            if ($p) { $out.Add($p) }
        }
    }
    return ,$out.ToArray()
}

$Section        = Expand-WinCleanListArg $Section
$ExcludeSection = Expand-WinCleanListArg $ExcludeSection
$Entry          = Expand-WinCleanListArg $Entry
$ExcludeEntry   = Expand-WinCleanListArg $ExcludeEntry
$Protect        = Expand-WinCleanListArg $Protect
$Ignore         = Expand-WinCleanListArg $Ignore
$IgnorePath     = Expand-WinCleanListArg $IgnorePath
$Unignore       = Expand-WinCleanListArg $Unignore

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($lib in @('Safety.ps1', 'Paths.ps1', 'Winapp2.ps1', 'Engine.ps1', 'SystemRules.ps1', 'Database.ps1', 'Status.ps1', 'IgnoreList.ps1')) {
    . (Join-Path $here "lib\$lib")
}

function Write-WinCleanHost {
    param([string] $Message, [string] $Colour = 'Gray')
    if ($Quiet -or $Output -ne 'Text') { return }
    Write-Host $Message -ForegroundColor $Colour
}

# Only Text output is for humans. Json/Csv/Brief must stay byte-clean for whatever is
# parsing them, so every piece of chrome below is gated on this.
$script:Pretty = ($Output -eq 'Text') -and (-not $Quiet)

if ($script:Pretty) {
    # Without this, box-drawing characters and the icons come out as mojibake under the
    # console's default OEM codepage.
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
}

# [char] is 16-bit, so anything above U+FFFF (the padlock and broom) has to be built as a
# surrogate pair via ConvertFromUtf32 - assigning the raw codepoint throws.
$script:Icon = @{
    Ok      = [string][char]0x2713                   # check
    Fail    = [string][char]0x2717                   # ballot X
    Warn    = [string][char]0x26A0                   # warning sign
    Ignored = [string][char]0x2298                   # circled division slash
    Lock    = [char]::ConvertFromUtf32(0x1F512)      # padlock
    Broom   = [char]::ConvertFromUtf32(0x1F9F9)      # broom
}

$script:ProgressWidth = 24
$script:ProgressShown = $false

# A progress bar redraws itself with a carriage return, which only works on a live
# console. When the output is piped or captured - which is how every agent and both
# shims run this - the CR is just another character and each redraw is appended, turning
# a 4,000-rule scan into 100 KB of bar. So: only animate when a human is actually watching.
$script:ShowProgress = $script:Pretty
try { if ([Console]::IsOutputRedirected) { $script:ShowProgress = $false } } catch { }

<#
    An in-place progress bar. Write-Progress alone is invisible when the script is
    launched with -File from another process, which is exactly how the shims and any
    agent run it - so the long pause in the middle of a scan looked like a hang.
#>
function Show-WinCleanProgress {
    param([int] $Current, [int] $Total, [string] $Label)

    if (-not $script:ShowProgress -or $Total -le 0) { return }

    $pct    = [math]::Min(100, [int](100 * $Current / $Total))
    $filled = [int]($script:ProgressWidth * $pct / 100)
    $bar    = ([string][char]0x2588) * $filled + ([string][char]0x2591) * ($script:ProgressWidth - $filled)

    # Keep the whole line inside the window so it overwrites cleanly instead of wrapping.
    $room = 40
    try { $room = [math]::Max(20, [Console]::WindowWidth - $script:ProgressWidth - 22) } catch { }
    if ($Label.Length -gt $room) { $Label = $Label.Substring(0, $room - 1) + [char]0x2026 }

    Write-Host ("`r  [{0}] {1,3}%  {2}" -f $bar, $pct, $Label.PadRight($room)) -NoNewline -ForegroundColor DarkCyan
    $script:ProgressShown = $true
}

function Clear-WinCleanProgress {
    if (-not $script:ShowProgress -or -not $script:ProgressShown) { return }
    $w = 80
    try { $w = [Console]::WindowWidth - 1 } catch { }
    Write-Host ("`r" + (' ' * $w) + "`r") -NoNewline
    $script:ProgressShown = $false
}

function Format-WinCleanBytesShort {
    param([int64] $Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Format-WinCleanBytes {
    param([int64] $Bytes)
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Test-WinCleanIsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal] $id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-WinCleanNameFilter {
    param([string] $Value, [string[]] $Include, [string[]] $Exclude)

    if ($Include -and $Include.Count -gt 0) {
        $hit = $false
        foreach ($p in $Include) { if ($Value -like $p) { $hit = $true; break } }
        if (-not $hit) { return $false }
    }
    if ($Exclude -and $Exclude.Count -gt 0) {
        foreach ($p in $Exclude) { if ($Value -like $p) { return $false } }
    }
    return $true
}

# --------------------------------------------------------------------------------------
# Load rules
# --------------------------------------------------------------------------------------

$dataDir = Get-WinCleanDataDir
if (-not $DatabasePath) { $DatabasePath = Join-Path $dataDir 'winapp2.ini' }

# ---- Standalone modes: these do their job and exit without scanning anything ----------

if ($Ignore.Count -gt 0 -or $IgnorePath.Count -gt 0) {
    $r = Add-WinCleanIgnore -Entry $Ignore -Path $IgnorePath
    if ($Output -eq 'Json') { $r | ConvertTo-Json -Compress }
    else {
        foreach ($a in $r.Added)          { Write-Output "ignored: $a" }
        foreach ($a in $r.AlreadyPresent) { Write-Output "already ignored: $a" }
        $l = Get-WinCleanIgnoreList
        Write-Output "Ignore list now holds $($l.Entries.Count) entry pattern(s) and $($l.Paths.Count) path(s)."
    }
    return
}

if ($Unignore.Count -gt 0 -or $ClearIgnored) {
    $r = Remove-WinCleanIgnore -Pattern $Unignore -All:$ClearIgnored
    if ($Output -eq 'Json') { $r | ConvertTo-Json -Compress }
    else {
        if ($ClearIgnored) { Write-Output "Ignore list cleared ($($r.Count) item(s) removed)." }
        else {
            foreach ($a in $r.Removed)  { Write-Output "no longer ignored: $a" }
            foreach ($a in $r.NotFound) { Write-Output "not on the list: $a" }
        }
    }
    return
}

if ($ListIgnored) {
    $l = Get-WinCleanIgnoreList
    if ($Output -eq 'Json') {
        $l | ConvertTo-Json -Compress
    } elseif ($l.Entries.Count -eq 0 -and $l.Paths.Count -eq 0) {
        Write-Output 'Ignore list is empty. Add to it with -Ignore <pattern> or -IgnorePath <dir>.'
    } else {
        if ($l.Entries.Count) { Write-Output 'Ignored entries/categories:'; $l.Entries | ForEach-Object { Write-Output "  $_" } }
        if ($l.Paths.Count)   { Write-Output 'Ignored paths:';              $l.Paths   | ForEach-Object { Write-Output "  $_" } }
    }
    return
}

if ($SnoozeDays -gt 0) {
    $until = Set-WinCleanSnooze -Days $SnoozeDays
    Write-Output "Cleanup reminders snoozed until $until"
    return
}

if ($RollbackDatabase) {
    $r = Restore-WinCleanDatabase -Path $DatabasePath
    if ($Output -eq 'Json') { $r | ConvertTo-Json -Compress } else { Write-Output $r.Message }
    return
}

if ($CheckUpdate) {
    # Combining the two is the "just update, don't scan" path: apply first, then report
    # the resulting state.
    if ($UpdateDatabase) {
        $res = Update-WinCleanDatabaseFile -Path $DatabasePath -Flavor $Flavor -Force
        if ($Output -ne 'Json') { Write-Output $res.Message }
    }

    $info = Test-WinCleanDatabaseUpdate -Path $DatabasePath -Flavor $Flavor
    if ($Output -eq 'Json') {
        $info | ConvertTo-Json -Compress
    } elseif ($Output -eq 'Brief') {
        if (-not $info.Reachable)        { Write-Output "offline; local v$($info.LocalVersion), $($info.LocalAgeDays)d old" }
        elseif ($info.UpdateAvailable)   { Write-Output "update available (local v$($info.LocalVersion), $($info.LocalAgeDays)d old)" }
        else                             { Write-Output "up to date (v$($info.LocalVersion), $($info.LocalEntryCount) entries)" }
    } else {
        Write-Output "Local:  version $($info.LocalVersion), $($info.LocalEntryCount) entries, $($info.LocalAgeDays) day(s) old"
        Write-Output "Remote: $(if (-not $info.Reachable) { 'unreachable' } elseif ($info.UpdateAvailable) { 'UPDATE AVAILABLE' } else { 'no change' })"
        Write-Output "Source: $($info.Url)"
        if ($info.UpdateAvailable) { Write-Output 'Run with -UpdateDatabase to apply.' }
    }
    return
}

if ($Status) {
    $s = Get-WinCleanDueStatus -MaxDatabaseAgeDays $MaxDatabaseAgeDays -DatabasePath $DatabasePath
    if ($Output -eq 'Json') {
        $s | ConvertTo-Json -Compress
    } elseif ($Output -eq 'Brief') {
        Write-Output $(if ($s.Due) { $s.Summary } else { '' })
    } else {
        Write-Output "Drive $($s.Drive): $($s.FreePercent)% free"
        Write-Output "Last clean: $(if ($s.LastCleanAt) { "$($s.DaysSinceClean) day(s) ago" } else { 'never' })"
        Write-Output "Database:   v$($s.DatabaseVersion), $($s.DatabaseAgeDays) day(s) old$(if ($s.DatabaseStale) { ' (stale)' })"
        Write-Output "Cleanup due: $($s.Due)$(if ($s.Reason) { " - $($s.Reason)" })"
    }
    return
}

# ---- Load rules -----------------------------------------------------------------------

$rules = New-Object System.Collections.Generic.List[object]
$dbVersion = $null

$missing = -not (Test-Path -LiteralPath $DatabasePath -PathType Leaf)
$ageDays = Get-WinCleanDatabaseAgeDays $DatabasePath
$stale   = ($MaxDatabaseAgeDays -gt 0) -and ($ageDays -gt $MaxDatabaseAgeDays)

# An explicit -UpdateDatabase runs whatever the ruleset is: "-RuleSet System
# -UpdateDatabase" silently doing nothing would be a trap. The database is only *needed*
# for the winapp2 ruleset, but refreshing it is a separate, always-honoured request.
$needsDb      = $RuleSet -in @('All', 'Winapp2')
$shouldUpdate = $UpdateDatabase -or ($needsDb -and ($missing -or ($stale -and -not $NoUpdate)))

if ($shouldUpdate) {
    if ($missing)            { Write-WinCleanHost 'No local rule database - downloading...' 'Cyan' }
    elseif ($UpdateDatabase) { Write-WinCleanHost 'Checking for database updates...' 'Cyan' }
    else                     { Write-WinCleanHost "Rule database is $ageDays days old - checking for updates..." 'DarkGray' }

    $res = Update-WinCleanDatabaseFile -Path $DatabasePath -Flavor $Flavor -Force:$UpdateDatabase

    $colour = switch ($res.Status) {
        'Updated'  { 'Green' }
        'Current'  { 'DarkGray' }
        'Rejected' { 'Yellow' }
        'Offline'  { 'DarkYellow' }
        default    { 'Red' }
    }
    Write-WinCleanHost "  $($res.Message)" $colour

    if ($res.Status -eq 'Failed' -and $missing -and $needsDb) { throw $res.Message }

    # A stale-triggered check counts as a check even when nothing was downloaded, so an
    # unreachable network does not re-probe on every single run.
    if (-not $missing -and -not $UpdateDatabase) {
        Set-WinCleanStateField -Name 'LastCheckedAt' -Value ((Get-Date).ToString('o'))
    }
}

if ($needsDb) {
    $dbVersion = Get-Winapp2Version $DatabasePath
    Write-WinCleanHost "Database: $DatabasePath (version $dbVersion)" 'DarkGray'
    foreach ($r in (Read-Winapp2Database -Path $DatabasePath)) { $rules.Add($r) }
}

if ($RuleSet -in @('All', 'System')) {
    foreach ($r in (Get-WinCleanSystemRule -IncludeAggressive:$Aggressive)) { $rules.Add($r) }
}

# --------------------------------------------------------------------------------------
# Filter rules
# --------------------------------------------------------------------------------------

$selected = @($rules | Where-Object {
    (Test-WinCleanNameFilter -Value $_.Category -Include $Section -Exclude $ExcludeSection) -and
    (Test-WinCleanNameFilter -Value $_.Name     -Include $Entry   -Exclude $ExcludeEntry)
})

# The persistent ignore list. Applied after the per-run filters and before anything is
# scanned, so an ignored rule is never even resolved to paths - it cannot be deleted by
# a mistake further down. -NoIgnoreList exists so you can audit what the list is hiding
# without having to empty it.
$ignoreList   = Get-WinCleanIgnoreList
$ignoredRules = @()

if (-not $NoIgnoreList -and $ignoreList.Entries.Count -gt 0) {
    $ignoredRules = @($selected |
        Where-Object { Test-WinCleanIgnored -Name $_.Name -Category $_.Category -Patterns $ignoreList.Entries })
    $selected = @($selected |
        Where-Object { -not (Test-WinCleanIgnored -Name $_.Name -Category $_.Category -Patterns $ignoreList.Entries) })
}
$ignoredCount = $ignoredRules.Count

# The listings run BEFORE the warning filter on purpose. Filtering them too would hide
# entries the caller explicitly asked about - "Crash Dumps" and "Windows Update Cache"
# both carry a Warning - and make the ruleset look smaller than it is. The listing shows
# what would be skipped instead of omitting it.
if ($ListSections) {
    $rules | Group-Object Category | Sort-Object Name |
        Select-Object @{n = 'Category'; e = { $_.Name }}, @{n = 'Entries'; e = { $_.Count }} |
        Format-Table -AutoSize
    return
}

if ($ListEntries) {
    $selected | Sort-Object Category, Name |
        Select-Object Name, Category, Risk,
            @{n = 'NeedsAdmin'; e = { $_.NeedsAdmin }},
            @{n = 'SkippedByDefault'; e = {
                    if ($_.Warning -and -not $IncludeWarnings) { 'Warning' }
                    elseif ($_.Risk -eq 'Aggressive' -and -not $Aggressive) { 'Aggressive' }
                    else { '' }
                }},
            @{n = 'FileKeys'; e = { $_.FileKeys.Count }},
            @{n = 'RegKeys';  e = { $_.RegKeys.Count }},
            @{n = 'Warning';  e = { $_.Warning }} |
        Format-Table -AutoSize
    return
}

if (-not $IncludeWarnings) {
    $withWarning = @($selected | Where-Object { $_.Warning })
    $selected = @($selected | Where-Object { -not $_.Warning })
} else {
    $withWarning = @()
}

# --------------------------------------------------------------------------------------
# Scan
# --------------------------------------------------------------------------------------

$isAdmin   = Test-WinCleanIsAdmin
$extraProtected = @($Protect)
if (-not $NoIgnoreList -and $ignoreList.Paths.Count -gt 0) { $extraProtected += $ignoreList.Paths }
$protected = Get-WinCleanProtectedPath -Additional $extraProtected
$tokenMap  = Get-WinCleanTokenMap
Clear-WinCleanDetectionCache

Write-WinCleanHost ("{0} ai-win-clean  -  {1} rule(s) selected, elevated: {2}, mode: {3}" -f `
    $script:Icon.Broom, $selected.Count, $isAdmin, $(if ($Apply) { 'APPLY (will delete)' } else { 'DRY RUN (no deletions)' })) `
    $(if ($Apply) { 'Yellow' } else { 'Cyan' })
if ($withWarning.Count -gt 0) {
    Write-WinCleanHost "$($withWarning.Count) entries skipped because they carry a warning (use -IncludeWarnings to include them)." 'DarkYellow'
}

$results   = New-Object System.Collections.Generic.List[object]
$allBlocked = New-Object System.Collections.Generic.List[object]
# Shared across the whole run so overlapping rules (the built-in Temp rule and winapp2's
# own) each report the files they uniquely claim, and the total is not double-counted.
$seenFiles = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
$index = 0
$scanned = 0
$adminLimited = 0
$stopwatch = [Diagnostics.Stopwatch]::StartNew()

foreach ($rule in $selected) {
    $index++
    if ($index % 5 -eq 0 -or $index -eq $selected.Count) {
        Show-WinCleanProgress -Current $index -Total $selected.Count -Label $rule.Name
    }

    if (-not (Test-WinCleanDetection -Entry $rule -TokenMap $tokenMap)) { continue }
    $scanned++

    # Without elevation these rules read a fraction of their targets, or none. Counting
    # them is the only way a caller can tell "this really is 800 KB" from "I could not
    # see most of it" - both otherwise look like a small number with no errors.
    if ($rule.NeedsAdmin -and -not $isAdmin) { $adminLimited++ }

    $target = Get-WinCleanEntryTarget -Entry $rule -ProtectedPaths $protected -TokenMap $tokenMap `
                                      -OlderThanDays $OlderThanDays -MinDepth $MinDepth -SeenFiles $seenFiles

    foreach ($b in $target.Blocked) { $allBlocked.Add($b) }

    if ($target.FileCount -gt 0 -or $target.Directories.Count -gt 0) {
        $results.Add($target)
    }
}
Clear-WinCleanProgress

# Ignored rules are scanned too, but ONLY to report what they are holding. They never
# enter $results, so nothing here can be deleted - the point is to answer "what is my
# ignore list costing me?" without the user having to disable it to find out.
# A separate seen-set: sharing the active one would let an ignored rule claim files and
# silently suppress an active rule that also covers them.
$ignoredSeen    = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
$ignoredReport  = New-Object System.Collections.Generic.List[object]
$ignoredBytes   = [int64] 0
$ignoredFiles   = 0

$ii = 0
foreach ($rule in $ignoredRules) {
    $ii++
    Show-WinCleanProgress -Current $ii -Total $ignoredRules.Count -Label "(ignored) $($rule.Name)"
    if (-not (Test-WinCleanDetection -Entry $rule -TokenMap $tokenMap)) { continue }
    $t = Get-WinCleanEntryTarget -Entry $rule -ProtectedPaths $protected -TokenMap $tokenMap `
                                 -OlderThanDays $OlderThanDays -MinDepth $MinDepth -SeenFiles $ignoredSeen
    if ($t.FileCount -eq 0) { continue }
    $ignoredBytes += $t.Bytes
    $ignoredFiles += $t.FileCount
    $ignoredReport.Add([pscustomobject] @{
        Name = $t.Entry; Category = $t.Category; Files = $t.FileCount
        Bytes = $t.Bytes; Size = Format-WinCleanBytes $t.Bytes
    })
}
Clear-WinCleanProgress
$stopwatch.Stop()

# Measure-Object -Property returns nothing at all for an empty collection, so reading
# .Sum off it throws under StrictMode. Sum by hand instead of special-casing the result.
$totalBytes = [int64] 0
$totalFiles = 0
foreach ($r in $results) {
    $totalBytes += $r.Bytes
    $totalFiles += $r.FileCount
}

$recycle = $null
if ($EmptyRecycleBin) { $recycle = Get-WinCleanRecycleBinSize }

# --------------------------------------------------------------------------------------
# Apply
# --------------------------------------------------------------------------------------

$removal = [pscustomobject] @{ Deleted = 0; BytesFreed = [int64] 0; FailedCount = 0; Failed = @() }
$applied = $false

# -Apply with nothing to delete still counts as having run: reporting it as a dry run
# would wrongly suggest there is a pending deletion the caller still has to make.
if ($Apply -and $results.Count -eq 0 -and -not $EmptyRecycleBin) { $applied = $true }

if ($Apply -and ($results.Count -gt 0 -or $EmptyRecycleBin)) {

    # Read-Host would hang forever in a pipeline, a CI job or an agent shelling out.
    # Fail loudly instead of blocking on a prompt nobody can answer.
    if (-not $Force -and ($Output -ne 'Text' -or $Quiet)) {
        throw 'Refusing to prompt for confirmation in non-interactive mode. Pass -Force if the user has already approved this deletion, or drop -Apply to preview.'
    }

    $proceed = $Force
    if (-not $proceed) {
        Write-Host ''
        Write-Host "About to permanently delete $totalFiles files ($(Format-WinCleanBytes $totalBytes)) across $($results.Count) entries." -ForegroundColor Yellow
        if ($EmptyRecycleBin -and $recycle) {
            Write-Host "Plus the Recycle Bin: $($recycle.FileCount) items ($(Format-WinCleanBytes $recycle.Bytes)). This cannot be undone." -ForegroundColor Red
        }
        $answer = Read-Host 'Type YES to continue'
        $proceed = ($answer -ceq 'YES')
        if (-not $proceed) { Write-Host 'Aborted. Nothing was deleted.' -ForegroundColor Green }
    }

    if ($proceed) {
        $applied = $true
        $deleted = 0; $freed = [int64] 0
        $failed = New-Object System.Collections.Generic.List[object]
        $logLines = New-Object System.Collections.Generic.List[string]

        foreach ($target in $results) {
            $r = Remove-WinCleanTarget -Target $target -ProtectedPaths $protected -MinDepth $MinDepth -Confirm:$false
            $deleted += $r.Deleted
            $freed   += $r.BytesFreed
            foreach ($f in $r.Failed) { $failed.Add($f) }

            if ($LogPath) {
                $logLines.Add(([pscustomobject] @{
                    timestamp = (Get-Date).ToString('o')
                    entry     = $target.Entry
                    category  = $target.Category
                    deleted   = $r.Deleted
                    bytes     = $r.BytesFreed
                    failed    = $r.FailedCount
                } | ConvertTo-Json -Compress))
            }
        }

        if ($EmptyRecycleBin) {
            $binResult = Clear-WinCleanRecycleBin -Confirm:$false
            if ($binResult.Emptied -and $recycle) { $freed += $recycle.Bytes; $deleted += $recycle.FileCount }
            elseif ($binResult.Error) { $failed.Add([pscustomobject] @{ Path = 'Recycle Bin'; Error = $binResult.Error }) }
        }

        if ($LogPath -and $logLines.Count -gt 0) {
            Add-Content -LiteralPath $LogPath -Value $logLines -Encoding utf8
        }

        $removal = [pscustomobject] @{
            Deleted     = $deleted
            BytesFreed  = $freed
            FailedCount = $failed.Count
            Failed      = $failed.ToArray()
        }

        # Recorded so the notifier can answer "when was this last cleaned?" without
        # scanning anything.
        $st = Get-WinCleanState
        $st.LastCleanAt    = (Get-Date).ToString('o')
        $st.LastCleanBytes = $freed
        $st.SnoozeUntil    = $null
        Save-WinCleanState $st
    }
}

# --------------------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------------------

$report = [pscustomobject] @{
    Mode            = if ($applied) { 'applied' } else { 'dryrun' }
    Timestamp       = (Get-Date).ToString('o')
    Elevated        = $isAdmin
    DatabaseVersion = $dbVersion
    RulesLoaded     = $rules.Count
    RulesSelected   = $selected.Count
    # Detected = the app is installed and the rule was scanned. Matched = it found files.
    # A rule that is detected but matches nothing is real information ("that cache is
    # already empty"), and without both numbers it just disappears from the report.
    EntriesDetected = $scanned
    EntriesMatched  = $results.Count
    # Rules that declare they need elevation and ran without it. Non-zero means the
    # totals below are a floor, not a measurement.
    AdminLimited    = $adminLimited
    TotalFiles      = $totalFiles
    TotalBytes      = $totalBytes
    TotalSize       = Format-WinCleanBytes $totalBytes
    ScanSeconds     = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    Deleted         = $removal.Deleted
    BytesFreed      = $removal.BytesFreed
    SizeFreed       = Format-WinCleanBytes $removal.BytesFreed
    FailedCount     = $removal.FailedCount
    BlockedCount    = $allBlocked.Count
    SkippedWarnings = $withWarning.Count
    # Rules held back by the persistent ignore list. Non-zero explains a total
    # that is smaller than expected without the caller having to guess why.
    # Rules held back by the persistent ignore list, and what they are holding. Measured
    # but never deletable - this answers "what is my ignore list costing me?" without
    # the user having to turn the list off to find out.
    IgnoredCount    = $ignoredCount
    IgnoredBytes    = $ignoredBytes
    IgnoredSize     = Format-WinCleanBytes $ignoredBytes
    IgnoredFiles    = $ignoredFiles
    IgnoredEntries  = @($ignoredReport | Sort-Object Bytes -Descending)
    Entries         = @($results | Sort-Object Bytes -Descending | ForEach-Object {
                          [pscustomobject] @{
                              Name      = $_.Entry
                              Category  = $_.Category
                              Files     = $_.FileCount
                              Bytes     = $_.Bytes
                              Size      = Format-WinCleanBytes $_.Bytes
                              Source    = $_.Source
                              Removes   = $_.Directories.Count
                          }
                      })
    Blocked         = @($allBlocked | Select-Object -First 200)
}

switch ($Output) {

    'Json' {
        $json = $report | ConvertTo-Json -Depth 6
        if ($ReportPath) { Set-Content -LiteralPath $ReportPath -Value $json -Encoding utf8 }
        Write-Output $json
    }

    'Csv' {
        $csv = $report.Entries | ConvertTo-Csv -NoTypeInformation
        if ($ReportPath) { Set-Content -LiteralPath $ReportPath -Value $csv -Encoding utf8 }
        Write-Output $csv
    }

    # The cheapest useful output: everything an agent needs to report back, in a few
    # lines instead of a few hundred. Use this for routine runs so the model does not
    # pay to read 140 entry rows it will only summarise anyway.
    'Brief' {
        $lines = New-Object System.Collections.Generic.List[string]
        if ($applied) {
            $lines.Add("CLEANED $(Format-WinCleanBytesShort $removal.BytesFreed) ($($removal.Deleted) files)$(if ($removal.FailedCount) { "; $($removal.FailedCount) locked" })")
        } else {
            $lines.Add("DRYRUN $(Format-WinCleanBytesShort $totalBytes) reclaimable ($totalFiles files, $($results.Count) entries)")
        }
        foreach ($e in ($report.Entries | Select-Object -First 5)) {
            $lines.Add("  $($e.Size)`t$($e.Name)")
        }
        if ($report.Entries.Count -gt 5) { $lines.Add("  +$($report.Entries.Count - 5) more") }
        if (-not $isAdmin -and $adminLimited -gt 0) { $lines.Add("NOTE not elevated; $adminLimited rule(s) undercounted") }
        if ($ignoredCount -gt 0) {
            $top = @($ignoredReport | Sort-Object Bytes -Descending | Select-Object -First 3 |
                     ForEach-Object { "$($_.Name) ($($_.Size))" })
            $lines.Add("IGNORED $(Format-WinCleanBytesShort $ignoredBytes) kept by your ignore list ($ignoredCount rule(s)): $($top -join ', ')")
        }
        $text = ($lines -join [Environment]::NewLine)
        if ($ReportPath) { Set-Content -LiteralPath $ReportPath -Value $text -Encoding utf8 }
        Write-Output $text
    }

    default {
        Write-Host ''
        if ($report.Entries.Count -eq 0) {
            Write-Host 'Nothing to clean.' -ForegroundColor Green
        } else {
            $show = if ($Top -gt 0) { $report.Entries | Select-Object -First $Top } else { $report.Entries }
            $show | Format-Table -AutoSize @{n='Size';e={$_.Size};a='right'}, @{n='Files';e={$_.Files};a='right'}, Category, Name
            if ($Top -gt 0 -and $report.Entries.Count -gt $Top) {
                Write-Host "  ... and $($report.Entries.Count - $Top) more entries (use -Top 0 to show all)" -ForegroundColor DarkGray
            }
        }

        Write-Host ''
        Write-Host ('-' * 62) -ForegroundColor DarkGray
        if ($applied) {
            Write-Host ("  {0} Cleaned {1} across {2} files" -f $script:Icon.Ok, (Format-WinCleanBytes $removal.BytesFreed), $removal.Deleted) -ForegroundColor Green
            if ($removal.FailedCount -gt 0) {
                Write-Host ("  {0} {1} file(s) were locked by a running app and left in place" -f $script:Icon.Warn, $removal.FailedCount) -ForegroundColor DarkYellow
            }
        } else {
            Write-Host ("  {0} Would free {1} across {2} files in {3} entries" -f $script:Icon.Ok, $report.TotalSize, $totalFiles, $results.Count) -ForegroundColor Cyan
            Write-Host '    DRY RUN - nothing was deleted. Re-run with -Apply to act on this.' -ForegroundColor Cyan
        }

        # What the ignore list is holding back, and what it costs. Shown every run so the
        # list never quietly becomes the reason a cleanup "stopped working".
        if ($ignoredCount -gt 0) {
            Write-Host ''
            Write-Host ("  {0} Kept by your ignore list: {1} across {2} rule(s)" -f $script:Icon.Ignored, (Format-WinCleanBytes $ignoredBytes), $ignoredCount) -ForegroundColor DarkYellow
            foreach ($ig in ($ignoredReport | Sort-Object Bytes -Descending | Select-Object -First 8)) {
                Write-Host ("      {0,10}  {1}" -f $ig.Size, $ig.Name) -ForegroundColor DarkGray
            }
            if ($ignoredReport.Count -gt 8) {
                Write-Host ("      ... and {0} more" -f ($ignoredReport.Count - 8)) -ForegroundColor DarkGray
            }
            Write-Host '      Manage with -ListIgnored / -Unignore <pattern>, or -NoIgnoreList for one run.' -ForegroundColor DarkGray
            Write-Host ''
        }

        if ($allBlocked.Count -gt 0) {
            Write-Host ("  {0} {1} target(s) refused by the safety rules" -f $script:Icon.Lock, $allBlocked.Count) -ForegroundColor DarkGray
        }
        if (-not $isAdmin) {
            $suffix = if ($adminLimited -gt 0) { " - $adminLimited rule(s) needing elevation ran without it, so their sizes are a floor" } else { '' }
            Write-Host ("  {0} Not elevated; system-level targets were skipped or partly scanned{1}" -f $script:Icon.Warn, $suffix) -ForegroundColor DarkGray
        }
        Write-Host ("    Scan took {0}s" -f $report.ScanSeconds) -ForegroundColor DarkGray

        if ($ReportPath) {
            $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding utf8
            Write-Host "  Report written to $ReportPath" -ForegroundColor DarkGray
        }
    }
}
