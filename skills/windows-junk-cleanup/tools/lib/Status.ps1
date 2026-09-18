<#
    Status.ps1 - "is a clean worth running?" without running one.

    A full scan takes ~40 seconds and walks tens of thousands of files. That is far too
    expensive for a shell hook or a session-start notice, which must be effectively free
    or people turn it off.

    This decides from three cheap signals - a volume query, a timestamp, and a file date -
    and completes in milliseconds. It never touches the rule database or enumerates files.
    It is a prompt to consider cleaning, not a measurement of what would be freed.
#>

function Get-WinCleanFreeSpace {
    param([string] $DriveLetter)

    if (-not $DriveLetter) { $DriveLetter = ($env:SystemDrive -replace ':', '') }

    try {
        $d = New-Object System.IO.DriveInfo $DriveLetter
        if (-not $d.IsReady) { return $null }
        return [pscustomobject] @{
            Drive       = $DriveLetter
            TotalBytes  = $d.TotalSize
            FreeBytes   = $d.AvailableFreeSpace
            FreePercent = [math]::Round(100 * $d.AvailableFreeSpace / $d.TotalSize, 1)
        }
    } catch { return $null }
}

<#
    Returns Due/Reason plus the signals behind the decision.

    Thresholds are deliberately conservative. A notice that fires constantly is noise,
    and the cost of a missed prompt is far lower than the cost of a user disabling the
    hook outright.
#>
function Get-WinCleanDueStatus {
    [CmdletBinding()]
    param(
        [int]    $MinFreePercent   = 15,
        [int]    $MinDaysSinceClean = 30,
        [int]    $MaxDatabaseAgeDays = 30,
        [string] $DatabasePath
    )

    $state = Get-WinCleanState
    $disk  = Get-WinCleanFreeSpace

    $now = Get-Date

    # An explicit snooze always wins, so a user can silence the prompt without
    # uninstalling the hook.
    if ($state.SnoozeUntil) {
        try {
            if ([datetime] $state.SnoozeUntil -gt $now) {
                return [pscustomobject] @{
                    Due = $false; Reason = 'Snoozed'; Summary = ''
                    FreePercent = $(if ($disk) { $disk.FreePercent } else { $null })
                    DaysSinceClean = $null; SnoozedUntil = $state.SnoozeUntil
                }
            }
        } catch { }
    }

    $daysSinceClean = $null
    if ($state.LastCleanAt) {
        try { $daysSinceClean = [int]($now - [datetime] $state.LastCleanAt).TotalDays } catch { }
    }

    $dbAgeDays = if ($DatabasePath) { Get-WinCleanDatabaseAgeDays $DatabasePath } else { $null }

    # State can be empty on a database that predates it (or after a manual copy), so fall
    # back to the banner in the file itself rather than reporting a blank version.
    $dbVersion = $state.Version
    if (-not $dbVersion -and $DatabasePath -and (Test-Path -LiteralPath $DatabasePath)) {
        try { $dbVersion = Get-Winapp2Version $DatabasePath } catch { }
    }

    $reasons = New-Object System.Collections.Generic.List[string]

    if ($disk -and $disk.FreePercent -lt $MinFreePercent) {
        $reasons.Add("$($disk.Drive): is $($disk.FreePercent)% free")
    }
    if ($null -eq $daysSinceClean) {
        $reasons.Add('never cleaned on this machine')
    } elseif ($daysSinceClean -ge $MinDaysSinceClean) {
        $reasons.Add("last cleaned $daysSinceClean days ago")
    }

    # Low disk is the only signal strong enough to prompt on its own. Elapsed time alone
    # prompts only when the disk is also not comfortably empty - otherwise a machine with
    # 300 GB free would nag every month for no reason.
    $lowDisk  = $disk -and $disk.FreePercent -lt $MinFreePercent
    $stale    = ($null -eq $daysSinceClean) -or ($daysSinceClean -ge $MinDaysSinceClean)
    $tightish = $disk -and $disk.FreePercent -lt 40

    $due = $lowDisk -or ($stale -and $tightish)

    $summary = ''
    if ($due) {
        $freeText = if ($disk) { "$($disk.FreePercent)% free on $($disk.Drive):" } else { 'disk state unknown' }
        $summary  = "Disk cleanup may be worth running - $freeText" +
                    $(if ($reasons.Count -gt 1) { " ($($reasons[1]))" } else { '' })
    }

    return [pscustomobject] @{
        Due             = $due
        Reason          = ($reasons -join '; ')
        Summary         = $summary
        Drive           = $(if ($disk) { $disk.Drive } else { $null })
        FreePercent     = $(if ($disk) { $disk.FreePercent } else { $null })
        FreeBytes       = $(if ($disk) { $disk.FreeBytes } else { $null })
        DaysSinceClean  = $daysSinceClean
        LastCleanAt     = $state.LastCleanAt
        DatabaseVersion = $dbVersion
        DatabaseAgeDays = $dbAgeDays
        DatabaseStale   = ($null -ne $dbAgeDays -and $dbAgeDays -gt $MaxDatabaseAgeDays)
    }
}

function Set-WinCleanSnooze {
    param([int] $Days = 30)
    $until = (Get-Date).AddDays($Days).ToString('o')
    Set-WinCleanStateField -Name 'SnoozeUntil' -Value $until
    return $until
}

function Clear-WinCleanSnooze {
    Set-WinCleanStateField -Name 'SnoozeUntil' -Value $null
}
