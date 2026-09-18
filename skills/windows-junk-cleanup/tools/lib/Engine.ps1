<#
    Engine.ps1 - detection, scanning and removal.

    Flow for every entry:
        Test-WinCleanDetection   is the app even installed?   (cheap, runs first)
            -> Get-WinCleanEntryTarget   expand + resolve + SAFETY CHECK + enumerate
                -> Remove-WinCleanTarget   only ever called when -Apply was passed

    The safety check sits between resolution and enumeration. Nothing reaches the
    removal stage without having passed Test-WinCleanTarget.
#>

# Hive name -> .NET RegistryKey. The PowerShell registry provider (HKLM:\...) is roughly
# an order of magnitude slower than the .NET API, and detection runs it thousands of
# times per invocation, so this path is deliberately .NET.
$script:WinCleanHiveMap = @{
    'HKCU'               = [Microsoft.Win32.Registry]::CurrentUser
    'HKEY_CURRENT_USER'  = [Microsoft.Win32.Registry]::CurrentUser
    'HKLM'               = [Microsoft.Win32.Registry]::LocalMachine
    'HKEY_LOCAL_MACHINE' = [Microsoft.Win32.Registry]::LocalMachine
    'HKCR'               = [Microsoft.Win32.Registry]::ClassesRoot
    'HKEY_CLASSES_ROOT'  = [Microsoft.Win32.Registry]::ClassesRoot
    'HKU'                = [Microsoft.Win32.Registry]::Users
    'HKEY_USERS'         = [Microsoft.Win32.Registry]::Users
    'HKCC'               = [Microsoft.Win32.Registry]::CurrentConfig
}

# Detection results are memoised for the lifetime of a run. The database reuses the same
# probe across many entries - all 22 Chrome entries share one DetectFile - so this turns
# thousands of filesystem and registry hits into a few hundred.
$script:WinCleanRegCache  = @{}
$script:WinCleanFileCache = @{}

function Clear-WinCleanDetectionCache {
    $script:WinCleanRegCache  = @{}
    $script:WinCleanFileCache = @{}
}

function Split-WinCleanRegistryPath {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $p = $Path.Trim().Replace('/', '\')
    $split = $p.IndexOf('\')
    if ($split -lt 1) { return $null }

    $hive = $p.Substring(0, $split).ToUpperInvariant()
    if (-not $script:WinCleanHiveMap.ContainsKey($hive)) { return $null }

    return [pscustomobject] @{
        Hive    = $script:WinCleanHiveMap[$hive]
        SubKey  = $p.Substring($split + 1)
    }
}

function Test-WinCleanRegistryKeyExists {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($script:WinCleanRegCache.ContainsKey($Path)) { return $script:WinCleanRegCache[$Path] }

    $result = $false
    $parsed = Split-WinCleanRegistryPath $Path

    if ($parsed) {
        # 32-bit applications on 64-bit Windows live under WOW6432Node. Entries are
        # written once against the native path, so check the redirected view too.
        $subKeys = @($parsed.SubKey)
        if ($parsed.SubKey -match '^(?i)Software\\' -and $parsed.SubKey -notmatch '(?i)WOW6432Node') {
            $subKeys += ($parsed.SubKey -replace '^(?i)Software\\', 'Software\WOW6432Node\')
        }

        foreach ($sk in $subKeys) {
            try {
                $key = $parsed.Hive.OpenSubKey($sk, $false)
                if ($key) { $key.Close(); $result = $true; break }
            } catch { }
        }
    }

    $script:WinCleanRegCache[$Path] = $result
    return $result
}

function Test-WinCleanPathExistsCached {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($script:WinCleanFileCache.ContainsKey($Path)) { return $script:WinCleanFileCache[$Path] }

    $result = $false
    try {
        $result = [System.IO.Directory]::Exists($Path) -or [System.IO.File]::Exists($Path)
    } catch { $result = $false }

    $script:WinCleanFileCache[$Path] = $result
    return $result
}

<#
    SpecialDetect maps to well-known applications. Only appears in the CCleaner-flavoured
    database; the Non-CCleaner flavour resolves these to plain DetectFile entries.
#>
$script:WinCleanSpecialDetect = @{
    'DET_CHROME'      = @('%LocalAppData%\Google\Chrome\User Data', '%LocalAppData%\Chromium\User Data')
    'DET_MOZILLA'     = @('%AppData%\Mozilla\Firefox')
    'DET_THUNDERBIRD' = @('%AppData%\Thunderbird')
    'DET_OPERA'       = @('%AppData%\Opera Software', '%LocalAppData%\Opera Software')
    'DET_SEAMONKEY'   = @('%AppData%\Mozilla\SeaMonkey')
    'DET_IE'          = @('%LocalAppData%\Microsoft\Windows\INetCache')
}

function Test-WinCleanDetectOS {
    param([string] $Spec)

    # Format is "min|max", either side optional: "6.1|", "|10.0", "6.1|10.0"
    if ([string]::IsNullOrWhiteSpace($Spec)) { return $true }

    $parts = $Spec -split '\|'
    $os = [Environment]::OSVersion.Version

    try {
        if ($parts.Count -ge 1 -and $parts[0].Trim()) {
            if ($os -lt [version] $parts[0].Trim()) { return $false }
        }
        if ($parts.Count -ge 2 -and $parts[1].Trim()) {
            if ($os -gt [version] $parts[1].Trim()) { return $false }
        }
    } catch {
        return $true      # unparseable range: do not let it suppress the entry
    }
    return $true
}

<#
    Is the application this entry targets actually present?

    This is the single most important filter for both safety and speed: it stops the
    engine touching paths that belong to software the user does not have, and it drops
    ~4,000 entries down to the few hundred that are relevant on a given machine.

    Detect / DetectFile are OR'd - any one match means "installed".
    An entry with no detection keys at all applies unconditionally (typical for core
    Windows entries).
#>
function Test-WinCleanDetection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Entry,
        [System.Collections.IDictionary] $TokenMap
    )

    if (-not (Test-WinCleanDetectOS $Entry.DetectOS)) { return $false }

    $hasDetector = $false

    foreach ($reg in $Entry.Detect) {
        $hasDetector = $true
        if (Test-WinCleanRegistryKeyExists $reg) { return $true }
    }

    foreach ($file in $Entry.DetectFile) {
        $hasDetector = $true
        foreach ($expanded in (Expand-WinCleanToken -Path $file -TokenMap $TokenMap)) {
            # Every filesystem probe is wrapped: the database is untrusted input and a
            # single malformed value must never abort a run.
            try {
                if ($expanded -match '[*?]') {
                    if (@(Resolve-WinCleanDirectory -Pattern $expanded -MaxResults 1).Count -gt 0) { return $true }
                } elseif (Test-WinCleanPathExistsCached $expanded) {
                    return $true
                }
            } catch { continue }
        }
    }

    if ($Entry.SpecialDetect -and $script:WinCleanSpecialDetect.ContainsKey($Entry.SpecialDetect)) {
        $hasDetector = $true
        foreach ($probe in $script:WinCleanSpecialDetect[$Entry.SpecialDetect]) {
            foreach ($expanded in (Expand-WinCleanToken -Path $probe -TokenMap $TokenMap)) {
                try {
                    if (Test-WinCleanPathExistsCached $expanded) { return $true }
                } catch { continue }
            }
        }
    }

    return (-not $hasDetector)
}

<#
    Build the exclusion predicate for an entry.
    Returns a hashtable of normalised prefixes/filters consumed by Test-WinCleanExcluded.
#>
function Build-WinCleanExclusion {
    param($Entry, [System.Collections.IDictionary] $TokenMap)

    $fileRules = New-Object System.Collections.Generic.List[object]
    $pathRules = New-Object System.Collections.Generic.List[object]

    foreach ($ex in $Entry.ExcludeKeys) {
        if ($ex.Type -eq 'REG') { continue }
        foreach ($expanded in (Expand-WinCleanToken -Path $ex.Path -TokenMap $TokenMap)) {
            $rule = [pscustomobject] @{
                Dir     = $expanded
                Filters = ConvertTo-WinCleanFilterList $ex.Filter
            }
            if ($ex.Type -eq 'PATH') { $pathRules.Add($rule) } else { $fileRules.Add($rule) }
        }
    }

    return @{ FileRules = $fileRules.ToArray(); PathRules = $pathRules.ToArray() }
}

function Test-WinCleanExcluded {
    param([string] $FullPath, [string] $FileName, [string] $Directory, $Exclusion)

    if (-not $Exclusion) { return $false }

    # PATH rules exclude an entire subtree.
    foreach ($rule in $Exclusion.PathRules) {
        if ($Directory.Equals($rule.Dir, [StringComparison]::OrdinalIgnoreCase) -or
            (Test-WinCleanIsUnder -Child $Directory -Parent $rule.Dir)) {
            if (Test-WinCleanNameMatch -Name $FileName -Filters $rule.Filters) { return $true }
        }
    }

    # FILE rules exclude named files in one directory.
    foreach ($rule in $Exclusion.FileRules) {
        if ($Directory.Equals($rule.Dir, [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-WinCleanNameMatch -Name $FileName -Filters $rule.Filters) { return $true }
        }
    }

    return $false
}

<#
    Enumerate files under a directory without ever traversing a reparse point.

    Hand-rolled instead of Get-ChildItem -Recurse because PowerShell 5.1 follows
    junctions, which lets a scoped delete escape its root and can recurse forever on
    the self-referential %LocalAppData%\Application Data junction.
#>
function Get-WinCleanFileCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [string[]] $Filters = @('*'),
        [switch]   $Recurse,
        [datetime] $OlderThan = [datetime]::MaxValue,
        [int]      $MaxFiles = 200000
    )

    $found = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Generic.Queue[string]
    $queue.Enqueue($Directory)
    $visited = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)

    while ($queue.Count -gt 0 -and $found.Count -lt $MaxFiles) {
        $dir = $queue.Dequeue()
        if (-not $visited.Add($dir)) { continue }

        try {
            $info = New-Object System.IO.DirectoryInfo $dir
            if (-not $info.Exists) { continue }
            if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        } catch { continue }

        try {
            foreach ($file in $info.EnumerateFiles()) {
                if ($found.Count -ge $MaxFiles) { break }
                if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if (-not (Test-WinCleanNameMatch -Name $file.Name -Filters $Filters)) { continue }
                if ($file.LastWriteTime -ge $OlderThan) { continue }
                $found.Add($file)
            }
        } catch { }

        if ($Recurse) {
            try {
                foreach ($sub in $info.EnumerateDirectories()) {
                    if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $queue.Enqueue($sub.FullName)
                }
            } catch { }
        }
    }

    return ,$found.ToArray()
}

<#
    Resolve one entry into concrete, safety-approved removal targets.

    Returns [pscustomobject] with Files, Directories (REMOVESELF only), Bytes, Blocked.
    "Blocked" records every target the safety layer refused, with its reason - these are
    surfaced in reports so a bad database entry is visible rather than silently dropped.
#>
function Get-WinCleanEntryTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] [string[]] $ProtectedPaths,
        [System.Collections.IDictionary] $TokenMap,
        [int]      $OlderThanDays = 0,
        [int]      $MinDepth = 1,
        [int]      $MaxDirsPerKey = 4096,
        # Shared across every entry in a run so a file claimed by two rules is counted
        # once. The built-in ruleset and winapp2 genuinely overlap - both cover
        # %LocalAppData%\Temp - and without this the reported total is inflated.
        [System.Collections.Generic.HashSet[string]] $SeenFiles
    )

    $files   = New-Object System.Collections.Generic.List[object]
    $dirs    = New-Object System.Collections.Generic.List[string]
    $blocked = New-Object System.Collections.Generic.List[object]
    $bytes   = [int64] 0

    $cutoff = if ($OlderThanDays -gt 0) { (Get-Date).AddDays(-$OlderThanDays) } else { [datetime]::MaxValue }
    $exclusion = Build-WinCleanExclusion -Entry $Entry -TokenMap $TokenMap

    foreach ($fk in $Entry.FileKeys) {

        $filters = ConvertTo-WinCleanFilterList $fk.Filter
        $bases   = Expand-WinCleanToken -Path $fk.Path -TokenMap $TokenMap

        if ($bases.Count -eq 0) {
            $blocked.Add([pscustomobject] @{ Path = $fk.Path; Reason = 'Unresolvable environment token' })
            continue
        }

        foreach ($base in $bases) {
            foreach ($dir in (Resolve-WinCleanDirectory -Pattern $base -MaxResults $MaxDirsPerKey)) {

                # ---- THE GATE. Nothing below this line runs on an unapproved path. ----
                $verdict = Test-WinCleanTarget -Directory $dir -Filter $fk.Filter -Flag $fk.Flag `
                                               -ProtectedPaths $ProtectedPaths -MinDepth $MinDepth
                if (-not $verdict.Allowed) {
                    $blocked.Add([pscustomobject] @{ Path = $dir; Reason = $verdict.Reason })
                    continue
                }

                $recurse = ($fk.Flag -eq 'RECURSE' -or $fk.Flag -eq 'REMOVESELF')
                $useFilters = if ($fk.Flag -eq 'REMOVESELF') { @('*') } else { $filters }

                foreach ($file in (Get-WinCleanFileCandidate -Directory $dir -Filters $useFilters -Recurse:$recurse -OlderThan $cutoff)) {
                    if (Test-WinCleanExcluded -FullPath $file.FullName -FileName $file.Name `
                                              -Directory $file.DirectoryName -Exclusion $exclusion) { continue }
                    if ($SeenFiles -and -not $SeenFiles.Add($file.FullName)) { continue }
                    $files.Add($file)
                    $bytes += $file.Length
                }

                if ($fk.Flag -eq 'REMOVESELF') { $dirs.Add($dir) }
            }
        }
    }

    return [pscustomobject] @{
        Entry       = $Entry.Name
        Category    = $Entry.Category
        Warning     = $Entry.Warning
        Files       = $files.ToArray()
        Directories = $dirs.ToArray()
        FileCount   = $files.Count
        Bytes       = $bytes
        Blocked     = $blocked.ToArray()
        RegKeys     = $Entry.RegKeys
        Source      = $Entry.Source
    }
}

<#
    Remove a directory tree without ever following a reparse point.

    Remove-Item -Recurse is not safe here: in Windows PowerShell 5.1 it can descend into a
    junction nested inside the tree and delete the junction's TARGET. A REMOVESELF entry
    pointed at a cache folder that happens to contain a junction would then destroy data
    well outside the intended scope. Directory.Delete on a reparse point removes the link
    itself and leaves the target alone, which is what we want.

    Returns the number of files deleted.
#>
function Remove-WinCleanDirectoryTree {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [int] $Depth = 0)

    if ($Depth -gt 64) { return 0 }        # cycle guard

    $count = 0
    $info = $null
    try {
        $info = New-Object System.IO.DirectoryInfo $Path
        if (-not $info.Exists) { return 0 }
    } catch { return 0 }

    # A reparse point: unlink it, never walk through it.
    if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        try { [System.IO.Directory]::Delete($Path, $false) } catch { }
        return 0
    }

    try {
        foreach ($file in $info.EnumerateFiles()) {
            try {
                if ($file.Attributes -band [IO.FileAttributes]::ReadOnly) {
                    $file.Attributes = [IO.FileAttributes]::Normal
                }
                $file.Delete()
                $count++
            } catch { }
        }
    } catch { }

    try {
        foreach ($sub in $info.EnumerateDirectories()) {
            $count += Remove-WinCleanDirectoryTree -Path $sub.FullName -Depth ($Depth + 1)
        }
    } catch { }

    # Only succeeds once the directory is empty, which is the behaviour we want: a
    # locked file leaves its parents in place rather than failing silently.
    try { [System.IO.Directory]::Delete($Path, $false) } catch { }

    return $count
}

<#
    Actually delete. Only reached when the caller passed -Apply.

    Re-validates every path against the safety layer immediately before deletion rather
    than trusting the scan result: scan and apply can be separated in time, and this is
    the last point at which a mistake is still preventable.
#>
function Remove-WinCleanTarget {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] [string[]] $ProtectedPaths,
        [int] $MinDepth = 1
    )

    $deleted = 0
    $freed   = [int64] 0
    $failed  = New-Object System.Collections.Generic.List[object]

    foreach ($file in $Target.Files) {
        $verdict = Test-WinCleanTarget -Directory $file.DirectoryName -Filter $file.Name -Flag 'None' `
                                       -ProtectedPaths $ProtectedPaths -MinDepth $MinDepth
        if (-not $verdict.Allowed) {
            $failed.Add([pscustomobject] @{ Path = $file.FullName; Error = "Blocked at apply time: $($verdict.Reason)" })
            continue
        }

        try {
            $size = $file.Length
            if ($PSCmdlet.ShouldProcess($file.FullName, 'Delete file')) {
                # Clear read-only/system/hidden so the delete does not fail on cache files
                # that apps mark read-only.
                if ($file.Attributes -band [IO.FileAttributes]::ReadOnly) {
                    $file.Attributes = [IO.FileAttributes]::Normal
                }
                [System.IO.File]::Delete($file.FullName)
                $deleted++
                $freed += $size
            }
        } catch {
            $failed.Add([pscustomobject] @{ Path = $file.FullName; Error = $_.Exception.Message })
        }
    }

    # REMOVESELF directories, deepest first so children are gone before parents.
    $sortedDirs = @($Target.Directories | Sort-Object -Property { (Get-WinCleanPathDepth $_) } -Descending)
    foreach ($dir in $sortedDirs) {
        $verdict = Test-WinCleanTarget -Directory $dir -Filter '*' -Flag 'REMOVESELF' `
                                       -ProtectedPaths $ProtectedPaths -MinDepth $MinDepth
        if (-not $verdict.Allowed) {
            $failed.Add([pscustomobject] @{ Path = $dir; Error = "Blocked at apply time: $($verdict.Reason)" })
            continue
        }
        if (Test-WinCleanIsReparsePoint $dir) {
            $failed.Add([pscustomobject] @{ Path = $dir; Error = 'Refusing to remove a reparse point' })
            continue
        }

        try {
            if ($PSCmdlet.ShouldProcess($dir, 'Remove directory')) {
                $deleted += Remove-WinCleanDirectoryTree -Path $dir
                # Very common and benign: the folder still holds files an app has open,
                # so it survives. Record it rather than claiming success.
                if ([System.IO.Directory]::Exists($dir)) {
                    $failed.Add([pscustomobject] @{ Path = $dir; Error = 'Directory not empty after cleanup (files in use)' })
                }
            }
        } catch {
            $failed.Add([pscustomobject] @{ Path = $dir; Error = $_.Exception.Message })
        }
    }

    return [pscustomobject] @{
        Deleted     = $deleted
        BytesFreed  = $freed
        Failed      = $failed.ToArray()
        FailedCount = $failed.Count
    }
}
