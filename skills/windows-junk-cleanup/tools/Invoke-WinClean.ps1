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

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($lib in @('Safety.ps1', 'Paths.ps1', 'Winapp2.ps1', 'Engine.ps1', 'SystemRules.ps1', 'Database.ps1', 'Status.ps1')) {
    . (Join-Path $here "lib\$lib")
}

function Write-WinCleanHost {
    param([string] $Message, [string] $Colour = 'Gray')
    if ($Quiet -or $Output -ne 'Text') { return }
    Write-Host $Message -ForegroundColor $Colour
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
$protected = Get-WinCleanProtectedPath -Additional $Protect
$tokenMap  = Get-WinCleanTokenMap
Clear-WinCleanDetectionCache

Write-WinCleanHost "Rules loaded: $($selected.Count)   Elevated: $isAdmin   Mode: $(if ($Apply) { 'APPLY (will delete)' } else { 'DRY RUN (no deletions)' })" $(if ($Apply) { 'Yellow' } else { 'Cyan' })
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
    if (-not $Quiet -and $Output -eq 'Text' -and ($index % 25 -eq 0 -or $index -eq $selected.Count)) {
        Write-Progress -Activity 'Scanning' -Status "$index / $($selected.Count)  $($rule.Name)" `
                       -PercentComplete ([math]::Min(100, 100 * $index / [math]::Max(1, $selected.Count)))
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
Write-Progress -Activity 'Scanning' -Completed
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
            Write-Host ("  Deleted:     {0} files, {1}" -f $removal.Deleted, (Format-WinCleanBytes $removal.BytesFreed)) -ForegroundColor Green
            if ($removal.FailedCount -gt 0) {
                Write-Host ("  Locked/failed: {0} (usually files an app still has open)" -f $removal.FailedCount) -ForegroundColor DarkYellow
            }
        } else {
            Write-Host ("  Would free:  {0} across {1} files in {2} entries" -f $report.TotalSize, $totalFiles, $results.Count) -ForegroundColor Cyan
            Write-Host '  DRY RUN - nothing was deleted. Re-run with -Apply to act on this.' -ForegroundColor Cyan
        }
        if ($allBlocked.Count -gt 0) {
            Write-Host ("  Blocked by safety rules: {0} targets" -f $allBlocked.Count) -ForegroundColor DarkGray
        }
        if (-not $isAdmin) {
            $suffix = if ($adminLimited -gt 0) { " ($adminLimited rule(s) needing elevation ran without it - treat their sizes as a floor)" } else { '' }
            Write-Host "  Not elevated - system-level targets were skipped or partially scanned.$suffix" -ForegroundColor DarkGray
        }
        Write-Host ("  Scan took {0}s" -f $report.ScanSeconds) -ForegroundColor DarkGray

        if ($ReportPath) {
            $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding utf8
            Write-Host "  Report written to $ReportPath" -ForegroundColor DarkGray
        }
    }
}
