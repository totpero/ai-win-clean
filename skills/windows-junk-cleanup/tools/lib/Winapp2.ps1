<#
    Winapp2.ps1 - parser for the winapp2.ini cleaning-rule database.

    Grammar (derived empirically from the real 4,068-entry database, not from prose docs):

        [Entry Name *]
        LangSecRef=3021                  numeric CCleaner category id
        Section=Google Chrome            named category (preferred when present)
        Detect=HKCU\Software\Vendor      registry key that must exist    (Detect1..N)
        DetectFile=%AppData%\Vendor      file/dir that must exist        (DetectFile1..N)
        DetectOS=6.1|                    OS version range, "min|max"
        SpecialDetect=DET_CHROME         named well-known detector
        Default=False                    whether the entry is on by default
        Warning=...                      human-readable caveat; entry is risky
        FileKey1=<path>|<filter>[|FLAG]  FLAG is RECURSE or REMOVESELF
        RegKey1=<hive\path>[|value]
        ExcludeKey1=FILE|<dir>\|<filter>     also PATH|... and REG|...

    <filter> is a ';'-separated list of wildcard patterns: "*.ldb;CURRENT;LOCK;MANIFEST-*"

    Data notes that drive the implementation:
      - Detect/DetectFile are OR'd across their numbered variants (any match = installed).
      - A path may contain wildcards in any component, not just the last.
      - REMOVESELF deletes the directory itself; RECURSE keeps the directory tree.
#>

# CCleaner's numeric category ids, used when an entry has LangSecRef but no Section.
$script:WinCleanLangSecRef = @{
    '3021' = 'Applications'
    '3022' = 'Internet'
    '3023' = 'Multimedia'
    '3024' = 'Utilities'
    '3025' = 'Windows'
    '3026' = 'Firefox'
    '3027' = 'Opera'
    '3028' = 'Safari'
    '3029' = 'Google Chrome'
    '3030' = 'Thunderbird'
    '3031' = 'Windows Store'
    '3032' = 'Microsoft Edge'
    '3033' = 'Internet Explorer'
    '3034' = 'Microsoft Edge'
}

function ConvertFrom-WinCleanLangSecRef {
    param([string] $Ref)
    if ([string]::IsNullOrWhiteSpace($Ref)) { return $null }
    if ($script:WinCleanLangSecRef.ContainsKey($Ref)) { return $script:WinCleanLangSecRef[$Ref] }
    return "Category $Ref"
}

function New-WinCleanEntry {
    param([string] $Name)
    return [pscustomobject] @{
        Name          = $Name
        Section       = $null
        LangSecRef    = $null
        Category      = 'Uncategorised'
        Detect        = New-Object System.Collections.Generic.List[string]
        DetectFile    = New-Object System.Collections.Generic.List[string]
        DetectOS      = $null
        SpecialDetect = $null
        Default       = $true
        Warning       = $null
        # 'Risk' is an ai-win-clean extension used by the built-in system ruleset.
        # winapp2.ini never sets it, so it defaults to Normal for database entries.
        Risk          = 'Normal'
        NeedsAdmin    = $false
        FileKeys      = New-Object System.Collections.Generic.List[object]
        RegKeys       = New-Object System.Collections.Generic.List[object]
        ExcludeKeys   = New-Object System.Collections.Generic.List[object]
        Source        = 'winapp2'
    }
}

<#
    FileKey value: "<path>|<filter>[|FLAG]"
    Paths legitimately contain no '|', so a plain split is safe.
#>
function ConvertFrom-WinCleanFileKey {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $parts = $Value -split '\|'
    $path  = $parts[0].Trim()
    if (-not $path) { return $null }

    $filter = if ($parts.Count -ge 2 -and $parts[1].Trim()) { $parts[1].Trim() } else { '*' }

    $flag = 'None'
    if ($parts.Count -ge 3) {
        switch -Regex ($parts[2].Trim()) {
            '^(?i)RECURSE$'    { $flag = 'RECURSE' }
            '^(?i)REMOVESELF$' { $flag = 'REMOVESELF' }
        }
    }

    return [pscustomobject] @{ Path = $path; Filter = $filter; Flag = $flag; Raw = $Value }
}

<#
    RegKey value: "HKCU\Software\Vendor\Key[|ValueName]"
    With no ValueName the whole key is the target; with one, only that value.
#>
function ConvertFrom-WinCleanRegKey {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $parts = $Value -split '\|'
    $path  = $parts[0].Trim()
    if (-not $path) { return $null }

    $valueName = if ($parts.Count -ge 2 -and $parts[1].Trim()) { $parts[1].Trim() } else { $null }

    return [pscustomobject] @{ Path = $path; ValueName = $valueName; Raw = $Value }
}

<#
    ExcludeKey value: "FILE|<dir>\|<filter>", "PATH|<dir>\|<filter>", "REG|<hive\path>"
    Note the trailing backslash on the directory before the separator - it is part of the
    real format and has to be trimmed.
#>
function ConvertFrom-WinCleanExcludeKey {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $parts = $Value -split '\|'
    if ($parts.Count -lt 2) { return $null }

    $type = $parts[0].Trim().ToUpperInvariant()
    if ($type -notin @('FILE', 'PATH', 'REG')) { return $null }

    $path   = $parts[1].Trim().TrimEnd('\')
    $filter = if ($parts.Count -ge 3 -and $parts[2].Trim()) { $parts[2].Trim() } else { '*' }

    return [pscustomobject] @{ Type = $type; Path = $path; Filter = $filter; Raw = $Value }
}

<#
    Parse a winapp2.ini file into entry objects.

    Tolerant by design: a malformed line is skipped, never fatal. The database is
    community-maintained and a single bad contribution must not break a whole run.
#>
function Read-Winapp2Database {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "winapp2 database not found: $Path"
    }

    return ,(ConvertFrom-Winapp2Content -Lines ([System.IO.File]::ReadLines($Path)) -Origin $Path)
}

<#
    Line-source-agnostic parser core, so the built-in system ruleset can be written in
    the same INI syntax as the database and go through exactly the same code path.
#>
function ConvertFrom-Winapp2Content {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IEnumerable] $Lines,
        [string] $Origin = 'winapp2',
        [string] $SourceLabel = 'winapp2'
    )

    $entries = New-Object System.Collections.Generic.List[object]
    $current = $null
    $skipped = 0

    foreach ($rawLine in $Lines) {

        $line = $rawLine.Trim()
        if ($line.Length -eq 0) { continue }
        if ($line[0] -eq ';' -or $line[0] -eq '#') { continue }

        # Section header
        if ($line[0] -eq '[' -and $line.EndsWith(']')) {
            if ($current) { $entries.Add($current) }
            $name = $line.Substring(1, $line.Length - 2).Trim()
            $current = New-WinCleanEntry -Name $name
            continue
        }

        if (-not $current) { continue }

        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { $skipped++; continue }

        $key   = $line.Substring(0, $eq).Trim()
        $value = $line.Substring($eq + 1).Trim()
        if ($value.Length -eq 0) { continue }

        # Strip the numeric suffix: FileKey12 -> FileKey
        $baseKey = $key -replace '\d+$', ''

        switch ($baseKey) {
            'Section'       { $current.Section       = $value }
            'LangSecRef'    { $current.LangSecRef    = $value }
            'DetectOS'      { $current.DetectOS      = $value }
            'SpecialDetect' { $current.SpecialDetect = $value }
            'Warning'       { $current.Warning       = $value }
            'Risk'          { $current.Risk          = $value }
            'NeedsAdmin'    { $current.NeedsAdmin    = ($value -match '^(?i)(true|1|yes)$') }
            'Default'       { $current.Default       = ($value -notmatch '^(?i)(false|0|no)$') }
            'Detect'        { $current.Detect.Add(($value -split '\|')[0].Trim()) }

            # '|' is illegal in a Windows path, but the live database contains a
            # DetectFile that was copy-pasted from a FileKey ("%WinDir%|SIGVERIF.TXT").
            # Take the path portion rather than discarding an otherwise valid entry.
            'DetectFile'    { $current.DetectFile.Add(($value -split '\|')[0].Trim()) }

            'FileKey' {
                $fk = ConvertFrom-WinCleanFileKey $value
                if ($fk) { $current.FileKeys.Add($fk) } else { $skipped++ }
            }
            'RegKey' {
                $rk = ConvertFrom-WinCleanRegKey $value
                if ($rk) { $current.RegKeys.Add($rk) } else { $skipped++ }
            }
            'ExcludeKey' {
                $ek = ConvertFrom-WinCleanExcludeKey $value
                if ($ek) { $current.ExcludeKeys.Add($ek) } else { $skipped++ }
            }
            default { $skipped++ }
        }
    }

    if ($current) { $entries.Add($current) }

    # Resolve a display category, and flatten the accumulator lists to plain arrays.
    # PowerShell 5.1 throws "Argument types do not match" on ,@(<generic list>), so no
    # generic List is allowed to escape this function.
    $out = New-Object object[] $entries.Count
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]

        if ($e.Section) {
            $e.Category = $e.Section
        } elseif ($e.LangSecRef) {
            $e.Category = ConvertFrom-WinCleanLangSecRef $e.LangSecRef
        }

        $e.Detect      = $e.Detect.ToArray()
        $e.DetectFile  = $e.DetectFile.ToArray()
        $e.FileKeys    = $e.FileKeys.ToArray()
        $e.RegKeys     = $e.RegKeys.ToArray()
        $e.ExcludeKeys = $e.ExcludeKeys.ToArray()
        $e.Source      = $SourceLabel

        $out[$i] = $e
    }

    Write-Verbose "Parsed $($out.Count) entries from $Origin ($skipped unrecognised lines)"
    return ,$out
}

<#
    Read the "; Version: 260915" banner the database ships with, for reporting.
#>
function Get-Winapp2Version {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $count = 0
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ($line -match '^\s*;\s*Version:\s*(.+)$') { return $Matches[1].Trim() }
        if (++$count -gt 40) { break }
    }
    return $null
}
