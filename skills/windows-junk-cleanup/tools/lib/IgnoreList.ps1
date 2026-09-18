<#
    IgnoreList.ps1 - a persistent "never clean this" list.

    -ExcludeEntry and -Protect already skip things, but only for the run you type them
    on. That is the wrong shape for a standing decision: if you have decided your NuGet
    cache is not junk, you should not have to remember to say so every time, and you
    certainly should not discover you forgot only after it was deleted.

    This stores the decision in %LOCALAPPDATA%\ai-win-clean\state.json so every later
    run honours it, including unattended ones and anything an agent launches.

    Two kinds of entry:
      Entries - rule-name or category patterns ("Microsoft NuGet Package Cache *")
      Paths   - directories that become protected, on top of the built-in guards

    Both accept wildcards and are matched case-insensitively, consistent with -Entry
    and -Section.
#>

function Get-WinCleanIgnoreList {
    [CmdletBinding()]
    param()

    $state = Get-WinCleanState

    $entries = @()
    $paths   = @()
    if ($state.PSObject.Properties.Name -contains 'IgnoredEntries' -and $state.IgnoredEntries) {
        $entries = @($state.IgnoredEntries | Where-Object { $_ })
    }
    if ($state.PSObject.Properties.Name -contains 'IgnoredPaths' -and $state.IgnoredPaths) {
        $paths = @($state.IgnoredPaths | Where-Object { $_ })
    }

    return [pscustomobject] @{ Entries = $entries; Paths = $paths }
}

function Save-WinCleanIgnoreList {
    param([string[]] $Entries, [string[]] $Paths)

    $state = Get-WinCleanState
    foreach ($pair in @(@{ N = 'IgnoredEntries'; V = @($Entries) }, @{ N = 'IgnoredPaths'; V = @($Paths) })) {
        if ($state.PSObject.Properties.Name -contains $pair.N) { $state.($pair.N) = $pair.V }
        else { $state | Add-Member -NotePropertyName $pair.N -NotePropertyValue $pair.V -Force }
    }
    Save-WinCleanState $state
}

<#
    Add patterns to the ignore list. Returns what was added and what was already there,
    so the caller can say which of several arguments actually changed anything.
#>
function Add-WinCleanIgnore {
    [CmdletBinding()]
    param([string[]] $Entry, [string[]] $Path)

    $list  = Get-WinCleanIgnoreList
    $added = New-Object System.Collections.Generic.List[string]
    $dupe  = New-Object System.Collections.Generic.List[string]

    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($e in $list.Entries) { $entries.Add($e) }
    foreach ($e in @($Entry | Where-Object { $_ })) {
        $t = $e.Trim()
        if (-not $t) { continue }
        if ($entries -contains $t) { $dupe.Add($t) } else { $entries.Add($t); $added.Add($t) }
    }

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($p in $list.Paths) { $paths.Add($p) }
    foreach ($p in @($Path | Where-Object { $_ })) {
        # Normalise so "C:\Foo\" and "c:/foo" do not both end up in the list.
        $t = ConvertTo-WinCleanNormalPath $p
        if (-not $t) { continue }
        if ($paths -contains $t) { $dupe.Add($t) } else { $paths.Add($t); $added.Add($t) }
    }

    Save-WinCleanIgnoreList -Entries $entries.ToArray() -Paths $paths.ToArray()
    return [pscustomobject] @{ Added = $added.ToArray(); AlreadyPresent = $dupe.ToArray() }
}

<#
    Remove patterns. Matching is exact against what is stored, not wildcard-expanded:
    "remove this rule from my list" should not itself be a pattern that removes others.
#>
function Remove-WinCleanIgnore {
    [CmdletBinding()]
    param([string[]] $Pattern, [switch] $All)

    $list = Get-WinCleanIgnoreList

    if ($All) {
        $n = $list.Entries.Count + $list.Paths.Count
        Save-WinCleanIgnoreList -Entries @() -Paths @()
        return [pscustomobject] @{ Removed = @('(all)'); NotFound = @(); Count = $n }
    }

    $wanted   = @($Pattern | Where-Object { $_ } | ForEach-Object { $_.Trim() })
    $removed  = New-Object System.Collections.Generic.List[string]
    $notFound = New-Object System.Collections.Generic.List[string]

    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($e in $list.Entries) { $entries.Add($e) }
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($p in $list.Paths) { $paths.Add($p) }

    foreach ($w in $wanted) {
        $hit = $false
        for ($i = $entries.Count - 1; $i -ge 0; $i--) {
            if ($entries[$i].Equals($w, [StringComparison]::OrdinalIgnoreCase)) { $entries.RemoveAt($i); $hit = $true }
        }
        $wn = ConvertTo-WinCleanNormalPath $w
        for ($i = $paths.Count - 1; $i -ge 0; $i--) {
            if ($wn -and $paths[$i].Equals($wn, [StringComparison]::OrdinalIgnoreCase)) { $paths.RemoveAt($i); $hit = $true }
        }
        if ($hit) { $removed.Add($w) } else { $notFound.Add($w) }
    }

    Save-WinCleanIgnoreList -Entries $entries.ToArray() -Paths $paths.ToArray()
    return [pscustomobject] @{ Removed = $removed.ToArray(); NotFound = $notFound.ToArray(); Count = $removed.Count }
}

<#
    Does this rule match anything on the ignore list?
    A pattern matches either the rule name or its category, so you can ignore one rule
    ("Google Chrome Caches *") or a whole family ("*Chrome*").
#>
function Test-WinCleanIgnored {
    param([string] $Name, [string] $Category, [string[]] $Patterns)

    foreach ($p in $Patterns) {
        if (-not $p) { continue }
        if ($Name     -and $Name     -like $p) { return $true }
        if ($Category -and $Category -like $p) { return $true }
    }
    return $false
}
