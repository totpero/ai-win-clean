<#
    Database.ps1 - keeping the winapp2 rule database current.

    Update strategy, cheapest first:
      1. Conditional GET with the stored ETag. raw.githubusercontent.com honours
         If-None-Match, so an unchanged database costs a 304 and zero bytes instead of
         re-downloading 1.8 MB. This is what makes an auto-update-on-staleness policy
         affordable enough to leave on.
      2. Validate the payload BEFORE it replaces anything.
      3. Keep the previous copy so a bad update can be rolled back.

    State lives in %LOCALAPPDATA%\ai-win-clean\state.json and also carries the
    last-clean timestamp used by the "is a clean due?" check.
#>

$script:WinCleanDbUrl = @{
    'NonCCleaner' = 'https://raw.githubusercontent.com/MoscaDotTo/Winapp2/master/Non-CCleaner/Winapp2.ini'
    'CCleaner'    = 'https://raw.githubusercontent.com/MoscaDotTo/Winapp2/master/Winapp2.ini'
    'BleachBit'   = 'https://raw.githubusercontent.com/MoscaDotTo/Winapp2/master/Non-CCleaner/BleachBit/Winapp2.ini'
}

function Get-WinCleanDataDir {
    $dir = Join-Path $env:LocalAppData 'ai-win-clean'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-WinCleanStatePath { return (Join-Path (Get-WinCleanDataDir) 'state.json') }

function Get-WinCleanState {
    $p = Get-WinCleanStatePath
    if (Test-Path -LiteralPath $p) {
        try { return (Get-Content -LiteralPath $p -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { }
    }
    # A corrupt or missing state file is not an error: it just means "nothing known yet".
    return [pscustomobject] @{
        Etag          = $null
        Version       = $null
        EntryCount    = 0
        Flavor        = $null
        DownloadedAt  = $null
        LastCheckedAt = $null
        LastCleanAt   = $null
        LastCleanBytes = 0
        SnoozeUntil   = $null
    }
}

function Save-WinCleanState {
    param([Parameter(Mandatory)] $State)
    try {
        $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-WinCleanStatePath) -Encoding utf8
    } catch { }
}

function Set-WinCleanStateField {
    param([Parameter(Mandatory)] [string] $Name, $Value)
    $s = Get-WinCleanState
    if ($s.PSObject.Properties.Name -contains $Name) { $s.$Name = $Value }
    else { $s | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
    Save-WinCleanState $s
}

<#
    Reject a payload before it can become the ruleset that drives deletions.

    A truncated download, an HTML error page, or a captive-portal login form would all
    otherwise parse to "zero entries" and silently make the next clean a no-op - or, if a
    section header survived, to something arbitrary. The entry-count floor and the
    regression check against the current database catch both.
#>
function Test-WinCleanDatabaseFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [int] $PreviousEntryCount = 0,
        [int] $MinimumEntries = 100
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject] @{ Valid = $false; Reason = 'File not found'; EntryCount = 0; Version = $null }
    }

    $len = (Get-Item -LiteralPath $Path).Length
    if ($len -lt 10KB) {
        return [pscustomobject] @{ Valid = $false; Reason = "File is only $len bytes - truncated or an error page"; EntryCount = 0; Version = $null }
    }

    $count = 0
    $version = $null
    try {
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            if ($line.Length -gt 0 -and $line[0] -eq '[' -and $line.EndsWith(']')) { $count++ }
            elseif (-not $version -and $line -match '^\s*;\s*Version:\s*(.+)$') { $version = $Matches[1].Trim() }
        }
    } catch {
        return [pscustomobject] @{ Valid = $false; Reason = "Unreadable: $($_.Exception.Message)"; EntryCount = 0; Version = $null }
    }

    if ($count -lt $MinimumEntries) {
        return [pscustomobject] @{ Valid = $false; Reason = "Only $count entries found (expected at least $MinimumEntries) - not a winapp2 database"; EntryCount = $count; Version = $version }
    }

    # A real update adds and removes entries; it does not halve the database. A large
    # drop means a partial download or an upstream accident, not a legitimate release.
    if ($PreviousEntryCount -gt 0 -and $count -lt ($PreviousEntryCount * 0.5)) {
        return [pscustomobject] @{ Valid = $false; Reason = "Entry count dropped from $PreviousEntryCount to $count - refusing a suspicious update"; EntryCount = $count; Version = $version }
    }

    return [pscustomobject] @{ Valid = $true; Reason = 'OK'; EntryCount = $count; Version = $version }
}

function Get-WinCleanDatabaseAgeDays {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [int]::MaxValue }
    try {
        return [int]((Get-Date) - (Get-Item -LiteralPath $Path).LastWriteTime).TotalDays
    } catch { return [int]::MaxValue }
}

<#
    Fetch the database if it changed.

    Returns [pscustomobject] with Status, Message, Version, EntryCount, Changed.
    Status is one of:
        Updated      new content downloaded, validated and installed
        Current      server returned 304, or the ETag matched - nothing transferred
        Offline      network unreachable; the existing database is still in use
        Rejected     downloaded payload failed validation; previous database kept
        Failed       something else went wrong

    Never throws when an existing usable database is present: a failed update must
    degrade to "carry on with what we have", not stop a clean.
#>
function Update-WinCleanDatabaseFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Flavor = 'NonCCleaner',
        [string] $Url,
        [switch] $Force,
        [int]    $TimeoutSec = 60
    )

    if (-not $Url) { $Url = $script:WinCleanDbUrl[$Flavor] }
    if (-not $Url) { return [pscustomobject] @{ Status = 'Failed'; Message = "Unknown flavor '$Flavor'"; Version = $null; EntryCount = 0; Changed = $false } }

    $state  = Get-WinCleanState
    $exists = Test-Path -LiteralPath $Path -PathType Leaf

    # Only trust the stored ETag when it belongs to this file, this flavor and this URL.
    $etag = $null
    if (-not $Force -and $exists -and $state.Flavor -eq $Flavor -and $state.Url -eq $Url) { $etag = $state.Etag }

    $tmp = "$Path.download"
    $headers = @{}
    if ($etag) { $headers['If-None-Match'] = $etag }

    try {
        # Stock Windows PowerShell 5.1 does not negotiate TLS 1.2 by default; GitHub requires it.
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        $params = @{
            Uri             = $Url
            OutFile         = $tmp
            UseBasicParsing = $true
            TimeoutSec      = $TimeoutSec
            ErrorAction     = 'Stop'
            # Without -PassThru, Invoke-WebRequest -OutFile returns nothing at all, so
            # there is no response object to read the ETag from and every subsequent run
            # re-downloads the full file instead of getting a 304.
            PassThru        = $true
        }
        if ($headers.Count -gt 0) { $params['Headers'] = $headers }

        $response = Invoke-WebRequest @params

        $newEtag = $null
        try { $newEtag = $response.Headers['ETag'] } catch { }
        if ($newEtag -is [array]) { $newEtag = $newEtag[0] }

    } catch [System.Net.WebException] {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }

        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

        # 304 Not Modified is the success path for an unchanged database, and
        # Invoke-WebRequest surfaces it as an exception.
        if ($status -eq 304) {
            Set-WinCleanStateField -Name 'LastCheckedAt' -Value ((Get-Date).ToString('o'))
            return [pscustomobject] @{
                Status = 'Current'; Message = 'Already up to date (server returned 304, nothing transferred)'
                Version = $state.Version; EntryCount = $state.EntryCount; Changed = $false
            }
        }

        if ($exists) {
            return [pscustomobject] @{
                Status = 'Offline'; Message = "Could not reach the update server ($($_.Exception.Message)). Continuing with the existing database."
                Version = $state.Version; EntryCount = $state.EntryCount; Changed = $false
            }
        }
        return [pscustomobject] @{ Status = 'Failed'; Message = "Download failed and no local database exists: $($_.Exception.Message)"; Version = $null; EntryCount = 0; Changed = $false }

    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        if ($exists) {
            return [pscustomobject] @{
                Status = 'Offline'; Message = "Update failed ($($_.Exception.Message)). Continuing with the existing database."
                Version = $state.Version; EntryCount = $state.EntryCount; Changed = $false
            }
        }
        return [pscustomobject] @{ Status = 'Failed'; Message = "Download failed and no local database exists: $($_.Exception.Message)"; Version = $null; EntryCount = 0; Changed = $false }
    }

    $check = Test-WinCleanDatabaseFile -Path $tmp -PreviousEntryCount ([int] $state.EntryCount)
    if (-not $check.Valid) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return [pscustomobject] @{
            Status = 'Rejected'; Message = "Downloaded file rejected: $($check.Reason). Existing database left untouched."
            Version = $state.Version; EntryCount = $state.EntryCount; Changed = $false
        }
    }

    $previousVersion = $state.Version
    $previousCount   = [int] $state.EntryCount

    # Keep one generation back so -Rollback has something to restore.
    if ($exists) {
        try { Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force } catch { }
    }

    try {
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return [pscustomobject] @{
            Status = 'Failed'; Message = "Could not replace the database (is it open elsewhere?): $($_.Exception.Message)"
            Version = $previousVersion; EntryCount = $previousCount; Changed = $false
        }
    }

    $now = (Get-Date).ToString('o')
    $state.Etag          = $newEtag
    $state.Version       = $check.Version
    $state.EntryCount    = $check.EntryCount
    $state.Flavor        = $Flavor
    $state.DownloadedAt  = $now
    $state.LastCheckedAt = $now
    if ($state.PSObject.Properties.Name -contains 'Url') { $state.Url = $Url }
    else { $state | Add-Member -NotePropertyName 'Url' -NotePropertyValue $Url -Force }
    if ($state.PSObject.Properties.Name -contains 'PreviousVersion') { $state.PreviousVersion = $previousVersion }
    else { $state | Add-Member -NotePropertyName 'PreviousVersion' -NotePropertyValue $previousVersion -Force }
    Save-WinCleanState $state

    $delta = if ($previousCount -gt 0) { $check.EntryCount - $previousCount } else { 0 }
    $deltaText = if ($previousCount -gt 0) {
        $sign = if ($delta -ge 0) { '+' } else { '' }
        " ($previousVersion -> $($check.Version), $sign$delta entries)"
    } else { '' }

    return [pscustomobject] @{
        Status = 'Updated'; Message = "Database updated to version $($check.Version) with $($check.EntryCount) entries$deltaText"
        Version = $check.Version; EntryCount = $check.EntryCount; Changed = $true
        PreviousVersion = $previousVersion; EntryDelta = $delta
    }
}

<#
    Restore the previous database after a bad update.
#>
function Restore-WinCleanDatabase {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $bak = "$Path.bak"
    if (-not (Test-Path -LiteralPath $bak -PathType Leaf)) {
        return [pscustomobject] @{ Status = 'Failed'; Message = 'No previous database to roll back to.' }
    }

    $check = Test-WinCleanDatabaseFile -Path $bak
    if (-not $check.Valid) {
        return [pscustomobject] @{ Status = 'Failed'; Message = "The backup is not usable: $($check.Reason)" }
    }

    try {
        Copy-Item -LiteralPath $bak -Destination $Path -Force -ErrorAction Stop
    } catch {
        return [pscustomobject] @{ Status = 'Failed'; Message = "Could not restore: $($_.Exception.Message)" }
    }

    $s = Get-WinCleanState
    $s.Version    = $check.Version
    $s.EntryCount = $check.EntryCount
    $s.Etag       = $null          # force a full fetch next time; we no longer match upstream
    Save-WinCleanState $s

    return [pscustomobject] @{ Status = 'RolledBack'; Message = "Restored version $($check.Version) with $($check.EntryCount) entries."; Version = $check.Version }
}

<#
    Report what an update would do, without changing anything.
#>
function Test-WinCleanDatabaseUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [string] $Flavor = 'NonCCleaner')

    $state = Get-WinCleanState
    $url   = $script:WinCleanDbUrl[$Flavor]
    $local = Test-WinCleanDatabaseFile -Path $Path

    $remoteEtag = $null
    $reachable  = $false
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $head = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        $remoteEtag = $head.Headers['ETag']
        if ($remoteEtag -is [array]) { $remoteEtag = $remoteEtag[0] }
        $reachable = $true
    } catch { }

    $upToDate = $reachable -and $state.Etag -and ($state.Etag -eq $remoteEtag)

    return [pscustomobject] @{
        LocalVersion    = $local.Version
        LocalEntryCount = $local.EntryCount
        LocalAgeDays    = Get-WinCleanDatabaseAgeDays $Path
        Reachable       = $reachable
        UpToDate        = $upToDate
        UpdateAvailable = ($reachable -and -not $upToDate)
        LastCheckedAt   = $state.LastCheckedAt
        Url             = $url
    }
}
