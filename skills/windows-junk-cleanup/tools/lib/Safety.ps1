<#
    Safety.ps1 - Hard guardrails for ai-win-clean.

    THIS IS THE MOST IMPORTANT FILE IN THE PROJECT.

    winapp2.ini is a ~1.8 MB community-maintained file downloaded over the network.
    Every run feeds ~14,000 filesystem delete instructions from that file into this
    process. It is untrusted data driving destructive actions. A typo'd contribution,
    a malicious PR, or a corrupted download must not be able to erase a user profile.

    These guards run AFTER token expansion and glob resolution, on the final concrete
    path, and nothing in the database can override them.
#>

# NOTE: no Set-StrictMode here on purpose. This file is dot-sourced, so a strict-mode
# setting would leak into the caller's scope. Strict mode is set by Invoke-WinClean.ps1.

<#
    Normalise for comparison: full path, no trailing separator, case-insensitive.
    Deliberately does NOT touch the filesystem - it must work for paths that do not exist.
#>
function ConvertTo-WinCleanNormalPath {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $x = $Path.Trim().Trim('"')
    $x = $x -replace '/', '\'

    # Collapse doubled separators, but preserve a leading UNC "\\".
    $isUnc = $x.StartsWith('\\')
    $x = $x -replace '\\{2,}', '\'
    if ($isUnc) { $x = '\' + $x }

    # Keep the root separator for drive roots ("C:\"), strip it everywhere else.
    if ($x -match '^[A-Za-z]:\\?$') { return ($x.Substring(0, 2) + '\') }

    return $x.TrimEnd('\')
}

# Directories that must never be removed themselves, nor wholesale-emptied.
# Deleting a specific named subtree BENEATH one of these is still allowed - that is
# exactly what legitimate winapp2 entries do (e.g. %UserProfile%\Documents\Proteus\logs).
function Get-WinCleanProtectedPath {
    [CmdletBinding()]
    param([string[]] $Additional)

    $list = New-Object System.Collections.Generic.List[string]

    function Add-P {
        param([string] $P)
        if (-not [string]::IsNullOrWhiteSpace($P)) { $list.Add($P) }
    }

    $sysRoot = $env:SystemRoot
    $sysDrv  = $env:SystemDrive
    $profile = $env:UserProfile

    # --- OS roots -----------------------------------------------------------
    Add-P $sysRoot
    foreach ($sub in @(
        'System32', 'SysWOW64', 'WinSxS', 'Fonts', 'Boot', 'security',
        'System32\config', 'System32\drivers', 'System32\catroot', 'System32\catroot2'
    )) {
        if ($sysRoot) { Add-P (Join-Path $sysRoot $sub) }
    }

    Add-P $env:ProgramFiles
    Add-P ${env:ProgramFiles(x86)}
    Add-P $env:ProgramData
    Add-P $env:CommonProgramFiles
    Add-P ${env:CommonProgramFiles(x86)}

    if ($sysDrv) {
        foreach ($sub in @('Users', 'Recovery', 'System Volume Information', 'PerfLogs', 'Users\Default', 'Users\Public')) {
            Add-P (Join-Path $sysDrv $sub)
        }
    }

    # --- Profile roots ------------------------------------------------------
    Add-P $profile
    Add-P $env:AppData                 # ...\AppData\Roaming
    Add-P $env:LocalAppData            # ...\AppData\Local
    Add-P $env:Public
    if ($profile) {
        Add-P (Join-Path $profile 'AppData')
        Add-P (Join-Path $profile 'AppData\LocalLow')
    }

    # --- User data: never wholesale-cleaned, whatever the database says ------
    $userFolders = @(
        'Documents', 'Desktop', 'Downloads', 'Pictures', 'Videos', 'Music',
        'Favorites', 'Contacts', 'Links', 'Searches', 'Saved Games', '3D Objects',
        'OneDrive', 'Dropbox', 'Google Drive', 'Nextcloud', 'iCloudDrive'
    )
    foreach ($leaf in $userFolders) {
        if ($profile)     { Add-P (Join-Path $profile $leaf) }
        if ($env:Public)  { Add-P (Join-Path $env:Public $leaf) }
    }

    # Known-folder lookup catches redirected / OneDrive-backed Documents and Desktop,
    # which do NOT live under %UserProfile% when Folder Redirection is in play.
    foreach ($sf in @('MyDocuments', 'Desktop', 'DesktopDirectory', 'MyPictures', 'MyVideos', 'MyMusic', 'Favorites', 'Personal')) {
        try {
            $resolved = [Environment]::GetFolderPath($sf)
            if ($resolved) { Add-P $resolved }
        } catch { }
    }

    # Package roots: individual caches inside are fair game, the root is not.
    if ($env:LocalAppData) {
        Add-P (Join-Path $env:LocalAppData 'Packages')
        Add-P (Join-Path $env:LocalAppData 'Microsoft\WindowsApps')
    }

    foreach ($extra in $Additional) { Add-P $extra }

    # Normalise and dedupe.
    $set = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $list) {
        $n = ConvertTo-WinCleanNormalPath $item
        if ($n) { [void] $set.Add($n) }
    }
    return @($set)
}

function Test-WinCleanIsDriveRoot {
    param([string] $Path)
    $n = ConvertTo-WinCleanNormalPath $Path
    if (-not $n) { return $true }                       # empty path -> treat as root -> deny
    if ($n -match '^[A-Za-z]:\\?$') { return $true }
    if ($n -match '^\\\\[^\\]+\\[^\\]+$') { return $true }   # \\server\share
    return $false
}

function Get-WinCleanPathDepth {
    param([string] $Path)
    $n = ConvertTo-WinCleanNormalPath $Path
    if (-not $n) { return 0 }
    $n = $n -replace '^[A-Za-z]:', ''
    return @($n -split '\\' | Where-Object { $_ -ne '' }).Count
}

function Test-WinCleanIsUnder {
    param([string] $Child, [string] $Parent)
    $c = ConvertTo-WinCleanNormalPath $Child
    $p = ConvertTo-WinCleanNormalPath $Parent
    if (-not $c -or -not $p) { return $false }
    if ($c.Equals($p, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $pp = if ($p.EndsWith('\')) { $p } else { $p + '\' }
    return $c.StartsWith($pp, [StringComparison]::OrdinalIgnoreCase)
}

<#
    The core decision.

    Returns [pscustomobject] @{ Allowed; Reason } for one resolved target directory,
    given the file filter and flag that will be applied to it.

    Filter and flag matter. "%WinDir%|*.log" is a legitimate surgical entry that ships
    in the real database; "%WinDir%|*|RECURSE" would destroy the operating system.
    A depth or path check alone cannot tell those apart - the verb has to be considered
    alongside the noun.
#>
function Test-WinCleanTarget {
    [CmdletBinding()]
    param(
        # AllowEmptyString so an empty path reaches the check below and returns a proper
        # "denied" verdict. A safety gate must fail closed, never throw at the binder.
        [Parameter(Mandatory)] [AllowEmptyString()] [AllowNull()] [string] $Directory,
        [string] $Filter = '*',
        [ValidateSet('None', 'RECURSE', 'REMOVESELF')] [string] $Flag = 'None',
        [string[]] $ProtectedPaths = @(),
        # User-declared "hands off": -Protect and -IgnorePath. Unlike $ProtectedPaths
        # these admit NO exemption. See the block below for why the two differ.
        [string[]] $ExcludedPaths = @(),
        [int] $MinDepth = 1
    )

    $dir = ConvertTo-WinCleanNormalPath $Directory

    if (-not $dir) {
        return [pscustomobject] @{ Allowed = $false; Reason = 'Empty path after expansion' }
    }

    # An unexpanded token means a variable did not resolve. "%LocalAppData%\Temp" with an
    # empty LocalAppData would otherwise collapse to "\Temp" -> the current drive root.
    #
    # The token must start with a letter and be at least 4 characters. A looser pattern
    # misfires on percent-encoding in real directory names: Firefox storage folders look
    # like "https+++www.google.com^partitionKey=%28https%2Csingularlabs.com%29", where
    # "%28https%2C" would otherwise read as a token and get the directory refused.
    if ($dir -match '%[A-Za-z][A-Za-z_0-9()]{2,}%') {
        return [pscustomobject] @{ Allowed = $false; Reason = "Unresolved environment token: $dir" }
    }

    if ($dir -notmatch '^([A-Za-z]:\\|\\\\)') {
        return [pscustomobject] @{ Allowed = $false; Reason = "Path is not fully qualified: $dir" }
    }

    # '|', '<', '>', '"' and control characters are illegal in Windows paths. Their
    # presence means the database line was malformed - the live database does contain
    # such lines - and a malformed path must never reach the filesystem.
    if ($dir -match '[|<>"]' -or $dir -match '[\x00-\x1F]') {
        return [pscustomobject] @{ Allowed = $false; Reason = "Illegal character in path: $dir" }
    }

    if (Test-WinCleanIsDriveRoot $dir) {
        return [pscustomobject] @{ Allowed = $false; Reason = "Refusing to operate on a drive root: $dir" }
    }

    $depth = Get-WinCleanPathDepth $dir
    if ($depth -lt $MinDepth) {
        return [pscustomobject] @{ Allowed = $false; Reason = "Path depth $depth below minimum ${MinDepth}: $dir" }
    }

    # "Wholesale" = this operation empties the directory rather than picking named files.
    $wholesale = ($Flag -eq 'REMOVESELF') -or
                 [string]::IsNullOrWhiteSpace($Filter) -or
                 ($Filter -eq '*') -or
                 ($Filter -eq '*.*')

    <#
        User exclusions are absolute. This is the one place the rules deliberately differ
        from $ProtectedPaths.

        A built-in protected directory still permits a surgical, non-recursive filter,
        because real rules depend on it - "%WinDir%|*.log" must keep working or the
        database is crippled. That exemption is correct for paths WE chose to protect.

        It is wrong for a path the USER named. "-IgnorePath D:\Projects" means "never
        touch anything in here", and a rule targeting "D:\Projects|*.tmp" would sail
        straight through the exemption. So these deny at the directory, anywhere beneath
        it, and from any ancestor that would recurse into it - with no filter or flag
        able to earn an exception.
    #>
    foreach ($ex in $ExcludedPaths) {
        if (-not $ex) { continue }

        if ($dir.Equals($ex, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject] @{ Allowed = $false; Reason = "Excluded by user: $dir" }
        }
        if (Test-WinCleanIsUnder -Child $dir -Parent $ex) {
            return [pscustomobject] @{ Allowed = $false; Reason = "Inside user-excluded path '$ex': $dir" }
        }
        if ((Test-WinCleanIsUnder -Child $ex -Parent $dir) -and ($Flag -eq 'RECURSE' -or $Flag -eq 'REMOVESELF')) {
            return [pscustomobject] @{ Allowed = $false; Reason = "Recursive delete would descend into user-excluded path '$ex': $dir" }
        }
    }

    foreach ($prot in $ProtectedPaths) {

        if ($dir.Equals($prot, [StringComparison]::OrdinalIgnoreCase)) {
            if ($Flag -eq 'REMOVESELF') {
                return [pscustomobject] @{ Allowed = $false; Reason = "REMOVESELF on protected directory: $dir" }
            }
            if ($wholesale) {
                return [pscustomobject] @{ Allowed = $false; Reason = "Wholesale delete ('$Filter') in protected directory: $dir" }
            }
            if ($Flag -eq 'RECURSE') {
                return [pscustomobject] @{ Allowed = $false; Reason = "RECURSE inside protected directory: $dir" }
            }
            # Specific filter, directly inside, non-recursive: this is the %WinDir%|*.log case.
            return [pscustomobject] @{ Allowed = $true; Reason = "Specific filter '$Filter' in protected directory - permitted" }
        }

        # Target is an ANCESTOR of something protected: recursing from here descends into it.
        # e.g. dir = C:\Users, protected = C:\Users\me\Documents
        if (Test-WinCleanIsUnder -Child $prot -Parent $dir) {
            if ($Flag -eq 'RECURSE' -or $Flag -eq 'REMOVESELF') {
                return [pscustomobject] @{ Allowed = $false; Reason = "Recursive delete from an ancestor of protected path '$prot': $dir" }
            }
        }
    }

    return [pscustomobject] @{ Allowed = $true; Reason = 'OK' }
}

<#
    Reparse points (junctions / symlinks) are how a delete escapes its allowlisted root.
    %LocalAppData%\Application Data is a self-referential junction on every Windows box;
    recursing through it never terminates. We never traverse or delete through one.
#>
function Test-WinCleanIsReparsePoint {
    param([string] $Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return [bool] ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } catch {
        return $false
    }
}
