<#
    Paths.ps1 - winapp2 token expansion and wildcard directory resolution.

    winapp2 paths look like:
        %LocalAppData%\Google\Chrome\User Data\*\*Cache*
    A single entry can therefore fan out to dozens of real directories. Resolution walks
    the path one component at a time so that wildcards in the MIDDLE of a path work, which
    Get-ChildItem -Path cannot do reliably across all PowerShell versions.
#>

# %ProgramFiles% and %CommonProgramFiles% intentionally expand to BOTH the 64-bit and
# 32-bit locations: winapp2 entries are written once and expected to match either.
function Get-WinCleanTokenMap {
    [CmdletBinding()]
    param()

    $localLow = if ($env:UserProfile) { Join-Path $env:UserProfile 'AppData\LocalLow' } else { $null }

    $docs = $null
    try { $docs = [Environment]::GetFolderPath('MyDocuments') } catch { }

    $pf   = @($env:ProgramFiles, ${env:ProgramFiles(x86)})       | Where-Object { $_ } | Select-Object -Unique
    $cpf  = @($env:CommonProgramFiles, ${env:CommonProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique

    $map = [ordered] @{
        'LocalAppData'        = @($env:LocalAppData)
        'AppData'             = @($env:AppData)
        'LocalLowAppData'     = @($localLow)
        'ProgramFiles'        = $pf
        'CommonProgramFiles'  = $cpf
        'ProgramData'         = @($env:ProgramData)
        'CommonAppData'       = @($env:ProgramData)      # legacy alias seen in older entries
        'UserProfile'         = @($env:UserProfile)
        'Documents'           = @($docs)
        'Public'              = @($env:Public)
        'WinDir'              = @($env:SystemRoot)
        'SystemDrive'         = @($env:SystemDrive)
        'SystemRoot'          = @($env:SystemRoot)
        'Temp'                = @($env:Temp)
        'Tmp'                 = @($env:Temp)
        'UserName'            = @($env:UserName)
        'ComputerName'        = @($env:ComputerName)
    }

    $clean = [ordered] @{}
    foreach ($k in $map.Keys) {
        $vals = @($map[$k] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($vals.Count -gt 0) { $clean[$k] = $vals }
    }
    return $clean
}

<#
    Expand every %Token% in a winapp2 path.

    Returns an ARRAY because one token can map to several real locations
    (%ProgramFiles% -> both Program Files and Program Files (x86)).
    Returns an empty array if any token is unknown or unset - callers must treat
    that as "skip", never as "delete the literal string".
#>
function Expand-WinCleanToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path,
        [System.Collections.IDictionary] $TokenMap
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return ,@() }
    if (-not $TokenMap) { $TokenMap = Get-WinCleanTokenMap }

    $results = @($Path)

    while ($true) {
        $pending = @($results | Where-Object { $_ -match '%([A-Za-z_0-9()]+)%' })
        if ($pending.Count -eq 0) { break }

        $next = New-Object System.Collections.Generic.List[string]
        $progressed = $false

        foreach ($candidate in $results) {
            if ($candidate -notmatch '%([A-Za-z_0-9()]+)%') {
                $next.Add($candidate)
                continue
            }

            $token = $Matches[1]
            $key   = $TokenMap.Keys | Where-Object { $_ -eq $token } | Select-Object -First 1

            if (-not $key) {
                # Fall back to a real environment variable of that name before giving up.
                $envVal = [Environment]::GetEnvironmentVariable($token)
                if ([string]::IsNullOrWhiteSpace($envVal)) {
                    # Unknown token: drop this candidate entirely. Never emit a partially
                    # expanded path - "%Foo%\Cache" must not become "\Cache".
                    $progressed = $true
                    continue
                }
                # Plain string replace, not -replace: the regex operator treats '$' in the
                # replacement as a capture-group reference, which mangles real paths.
                $next.Add($candidate.Replace("%$token%", $envVal))
                $progressed = $true
                continue
            }

            foreach ($value in $TokenMap[$key]) {
                $next.Add($candidate.Replace("%$token%", $value))
            }
            $progressed = $true
        }

        $results = @($next)
        if (-not $progressed) { break }
    }

    # Anything still carrying a token failed to resolve - drop it.
    # The leading comma stops PowerShell unrolling a single-element array into a bare
    # string on return, which would make $result[0] index into the string's characters.
    return ,@($results |
        Where-Object { $_ -notmatch '%[A-Za-z_0-9()]+%' } |
        ForEach-Object { ConvertTo-WinCleanNormalPath $_ } |
        Where-Object { $_ } |
        Select-Object -Unique)
}

<#
    Resolve a (possibly wildcarded) directory path to the concrete directories that exist.

    Walks component by component so wildcards work anywhere in the path. Never traverses
    a reparse point: junctions are how a scoped delete escapes its root, and
    %LocalAppData%\Application Data is a self-referential junction on every Windows box.

    -MaxResults caps the fan-out. A pattern like %UserProfile%\* combined with RECURSE
    could otherwise enumerate an entire profile.
#>
function Resolve-WinCleanDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Pattern,
        [int] $MaxResults = 4096
    )

    $norm = ConvertTo-WinCleanNormalPath $Pattern
    if (-not $norm) { return ,@() }

    # No wildcard: just test existence. Much faster, and the common case.
    # Directory.Exists rather than Test-Path: Test-Path throws UnauthorizedAccessException
    # on directories the caller cannot read (Defender's data, System Volume Information),
    # which would abort a run. The .NET call returns false instead.
    if ($norm -notmatch '[*?]') {
        try {
            if ([System.IO.Directory]::Exists($norm)) { return ,@($norm) }
        } catch { }
        return ,@()
    }

    $parts = $norm -split '\\'
    if ($parts.Count -eq 0) { return ,@() }

    # Seed with the drive / UNC root, which never contains a wildcard.
    if ($norm -match '^\\\\') {
        $rootDepth = 4                                  # \\ , '' , server, share
        $current = @(($parts[0..3] -join '\'))
        $startIndex = 4
    } else {
        $current = @($parts[0] + '\')
        $startIndex = 1
    }

    for ($i = $startIndex; $i -lt $parts.Count; $i++) {
        $component = $parts[$i]
        if ([string]::IsNullOrEmpty($component)) { continue }

        $next = New-Object System.Collections.Generic.List[string]

        foreach ($base in $current) {
            if ($next.Count -ge $MaxResults) { break }

            if ($component -notmatch '[\*\?]') {
                $joined = Join-Path $base $component
                try {
                    if ([System.IO.Directory]::Exists($joined)) {
                        $next.Add((ConvertTo-WinCleanNormalPath $joined))
                    }
                } catch { }
                continue
            }

            try {
                $children = Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction Stop |
                            Where-Object { $_.Name -like $component }
            } catch {
                continue
            }

            foreach ($child in $children) {
                if ($next.Count -ge $MaxResults) { break }
                # Do not descend through junctions / symlinks.
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $next.Add((ConvertTo-WinCleanNormalPath $child.FullName))
            }
        }

        $current = @($next | Select-Object -Unique)
        if ($current.Count -eq 0) { return ,@() }
    }

    return ,@($current | Select-Object -Unique)
}

<#
    winapp2 file filters are ';'-separated wildcard patterns: "*.ldb;CURRENT;LOCK;MANIFEST-*"
#>
function ConvertTo-WinCleanFilterList {
    param([string] $Filter)

    if ([string]::IsNullOrWhiteSpace($Filter)) { return ,@('*') }

    $parts = @($Filter -split ';' |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' })

    if ($parts.Count -eq 0) { return ,@('*') }
    return ,@($parts)
}

function Test-WinCleanNameMatch {
    param([string] $Name, [string[]] $Filters)

    foreach ($f in $Filters) {
        if ($f -eq '*' -or $f -eq '*.*') { return $true }
        if ($Name -like $f) { return $true }
    }
    return $false
}
