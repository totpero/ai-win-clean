<#
.SYNOPSIS
    Test suite for ai-win-clean.

.DESCRIPTION
    Builds a throwaway filesystem in a temp sandbox, points a synthetic winapp2 database
    at it, and asserts exactly which files are deleted and which survive.

    The sandbox is addressed through a %WINCLEANTESTROOT% token so the rules go through
    the real token-expansion, globbing and safety code paths - nothing is stubbed.

    Run:  powershell -ExecutionPolicy Bypass -File tools\tests\Test-WinClean.ps1
    Exit code 0 = all passed, 1 = failures.
#>

[CmdletBinding()]
param([switch] $KeepSandbox)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$lib  = Join-Path (Split-Path -Parent $here) 'lib'
foreach ($f in @('Safety.ps1', 'Paths.ps1', 'Winapp2.ps1', 'Engine.ps1', 'SystemRules.ps1', 'Database.ps1', 'Status.ps1', 'IgnoreList.ps1')) {
    . (Join-Path $lib $f)
}

# --------------------------------------------------------------------------------------
# Tiny assertion harness
# --------------------------------------------------------------------------------------

$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]
$script:Group  = ''

function Describe { param([string] $Name) $script:Group = $Name; Write-Host "`n$Name" -ForegroundColor Cyan }

function Assert {
    param([string] $Name, [bool] $Condition, [string] $Detail = '')
    if ($Condition) {
        $script:Passed++
        Write-Host "  PASS  $Name" -ForegroundColor DarkGreen
    } else {
        $script:Failed.Add("$script:Group / $Name $(if ($Detail) { "- $Detail" })")
        Write-Host "  FAIL  $Name $(if ($Detail) { "- $Detail" })" -ForegroundColor Red
    }
}

function Assert-Equal {
    param([string] $Name, $Expected, $Actual)
    Assert -Name $Name -Condition ($Expected -eq $Actual) -Detail "expected '$Expected', got '$Actual'"
}

# --------------------------------------------------------------------------------------
# Sandbox
# --------------------------------------------------------------------------------------

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("winclean-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$env:WINCLEANTESTROOT = $sandbox

function New-TestFile {
    param([string] $RelativePath, [int] $SizeBytes = 64, [int] $AgeDays = 0)
    $full = Join-Path $sandbox $RelativePath
    $dir  = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllBytes($full, (New-Object byte[] $SizeBytes))
    if ($AgeDays -gt 0) {
        $t = (Get-Date).AddDays(-$AgeDays)
        (Get-Item -LiteralPath $full).LastWriteTime = $t
    }
    return $full
}

function Test-Exists { param([string] $RelativePath) return (Test-Path -LiteralPath (Join-Path $sandbox $RelativePath)) }

function Invoke-TestScan {
    param([string] $Ini, [int] $OlderThanDays = 0, [string[]] $ExtraProtected = @())
    $entries = ConvertFrom-Winapp2Content -Lines ($Ini -split "`r?`n") -Origin 'test'
    $tm = Get-WinCleanTokenMap
    Clear-WinCleanDetectionCache
    $prot = Get-WinCleanProtectedPath -Additional $ExtraProtected
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in $entries) {
        if (-not (Test-WinCleanDetection -Entry $e -TokenMap $tm)) { continue }
        $out.Add((Get-WinCleanEntryTarget -Entry $e -ProtectedPaths $prot -TokenMap $tm -OlderThanDays $OlderThanDays))
    }
    return ,$out.ToArray()
}

function Invoke-TestApply {
    param($Targets, [string[]] $ExtraProtected = @())
    $prot = Get-WinCleanProtectedPath -Additional $ExtraProtected
    $total = 0
    foreach ($t in $Targets) {
        $r = Remove-WinCleanTarget -Target $t -ProtectedPaths $prot -Confirm:$false
        $total += $r.Deleted
    }
    return $total
}

try {

# ======================================================================================
Describe 'Parser'
# ======================================================================================

$ini = @'
[Test App *]
Section=Testing
DetectFile=%WINCLEANTESTROOT%
FileKey1=%WINCLEANTESTROOT%\cache|*.tmp;*.log
FileKey2=%WINCLEANTESTROOT%\deep|*|RECURSE
FileKey3=%WINCLEANTESTROOT%\gone|*|REMOVESELF
RegKey1=HKCU\Software\Test\Key
RegKey2=HKCU\Software\Test\Key|ValueName
ExcludeKey1=FILE|%WINCLEANTESTROOT%\cache\|keep.log
ExcludeKey2=PATH|%WINCLEANTESTROOT%\deep\sub\|*
Warning=Test warning
'@
$parsed = ConvertFrom-Winapp2Content -Lines ($ini -split "`r?`n") -Origin 'test'

Assert-Equal 'one entry parsed'            1              $parsed.Count
Assert-Equal 'entry name'                  'Test App *'   $parsed[0].Name
Assert-Equal 'category from Section'       'Testing'      $parsed[0].Category
Assert-Equal 'three FileKeys'              3              $parsed[0].FileKeys.Count
Assert-Equal 'two RegKeys'                 2              $parsed[0].RegKeys.Count
Assert-Equal 'two ExcludeKeys'             2              $parsed[0].ExcludeKeys.Count
Assert-Equal 'warning captured'            'Test warning' $parsed[0].Warning
Assert-Equal 'filter parsed'               '*.tmp;*.log'  $parsed[0].FileKeys[0].Filter
Assert-Equal 'no flag reads as None'       'None'         $parsed[0].FileKeys[0].Flag
Assert-Equal 'RECURSE flag'                'RECURSE'      $parsed[0].FileKeys[1].Flag
Assert-Equal 'REMOVESELF flag'             'REMOVESELF'   $parsed[0].FileKeys[2].Flag
Assert-Equal 'RegKey without value'        $null          $parsed[0].RegKeys[0].ValueName
Assert-Equal 'RegKey with value'           'ValueName'    $parsed[0].RegKeys[1].ValueName
Assert-Equal 'ExcludeKey FILE type'        'FILE'         $parsed[0].ExcludeKeys[0].Type
Assert-Equal 'ExcludeKey PATH type'        'PATH'         $parsed[0].ExcludeKeys[1].Type
Assert-Equal 'filter list split'           2              (ConvertTo-WinCleanFilterList '*.tmp;*.log').Count

# LangSecRef fallback when there is no Section
$ini2 = "[X *]`nLangSecRef=3029`nFileKey1=%WINCLEANTESTROOT%\a|*"
Assert-Equal 'LangSecRef maps to name' 'Google Chrome' (ConvertFrom-Winapp2Content -Lines ($ini2 -split "`n") -Origin 't')[0].Category

# The real database contains this malformed line; it must not crash the parser.
$ini3 = "[Y *]`nDetectFile=%WinDir%|SIGVERIF.TXT`nFileKey1=%WinDir%|SIGVERIF.TXT"
$p3 = ConvertFrom-Winapp2Content -Lines ($ini3 -split "`n") -Origin 't'
Assert-Equal 'pipe stripped from DetectFile' '%WinDir%' $p3[0].DetectFile[0]

# ======================================================================================
Describe 'Token expansion'
# ======================================================================================

Assert-Equal 'sandbox token expands'   $sandbox  (Expand-WinCleanToken '%WINCLEANTESTROOT%')[0]
Assert-Equal 'unknown token dropped'   0         (Expand-WinCleanToken '%NoSuchTokenAnywhere%\Cache').Count
Assert       'ProgramFiles fans out to both' ((Expand-WinCleanToken '%ProgramFiles%').Count -ge 1)
Assert-Equal 'always returns an array' 'Object[]' (Expand-WinCleanToken '%WINCLEANTESTROOT%').GetType().Name

# ======================================================================================
Describe 'Safety gate'
# ======================================================================================

$prot = Get-WinCleanProtectedPath

function Deny { param($d, $f, $g) return -not (Test-WinCleanTarget -Directory $d -Filter $f -Flag $g -ProtectedPaths $prot).Allowed }

Assert 'drive root refused'                  (Deny 'C:\' '*' 'RECURSE')
Assert 'profile root wholesale refused'      (Deny $env:UserProfile '*' 'RECURSE')
Assert 'Documents REMOVESELF refused'        (Deny (Join-Path $env:UserProfile 'Documents') '*' 'REMOVESELF')
Assert 'Windows wholesale refused'           (Deny $env:SystemRoot '*' 'RECURSE')
Assert 'C:\Users recursive refused'          (Deny 'C:\Users' '*' 'RECURSE')
Assert 'LocalAppData REMOVESELF refused'     (Deny $env:LocalAppData '*' 'REMOVESELF')
Assert 'ProgramFiles wholesale refused'      (Deny $env:ProgramFiles '*' 'RECURSE')
Assert 'unresolved token refused'            (Deny '%Nope%\Cache' '*' 'RECURSE')
Assert 'illegal pipe char refused'           (Deny 'C:\Windows|SIGVERIF.TXT' '*' 'None')
Assert 'relative path refused'               (Deny 'not\a\full\path' '*' 'None')
Assert 'empty path refused'                  (Deny '' '*' 'None')
Assert 'ancestor-of-protected recurse refused' (Deny (Split-Path -Parent $env:UserProfile) '*' 'RECURSE')

Assert 'specific filter in Windows allowed'  (-not (Deny $env:SystemRoot '*.log' 'None'))
Assert 'deep path under Documents allowed'   (-not (Deny (Join-Path $env:UserProfile 'Documents\App\logs') '*' 'REMOVESELF'))
Assert 'LocalAppData\Temp recurse allowed'   (-not (Deny (Join-Path $env:LocalAppData 'Temp') '*' 'RECURSE'))
Assert 'sandbox allowed'                     (-not (Deny $sandbox '*' 'RECURSE'))

Assert-Equal 'depth of C:\a\b'  2 (Get-WinCleanPathDepth 'C:\a\b')
Assert-Equal 'normalise slashes' 'C:\a\b' (ConvertTo-WinCleanNormalPath 'C:/a//b\')
Assert       'IsUnder true'  (Test-WinCleanIsUnder -Child 'C:\a\b\c' -Parent 'C:\a')
Assert       'IsUnder false for self' (-not (Test-WinCleanIsUnder -Child 'C:\a' -Parent 'C:\a'))
Assert       'IsUnder false for sibling prefix' (-not (Test-WinCleanIsUnder -Child 'C:\abc' -Parent 'C:\ab'))

# ======================================================================================
Describe 'Scanning: filters and flags'
# ======================================================================================

New-TestFile 'cache\a.tmp'          | Out-Null
New-TestFile 'cache\b.log'          | Out-Null
New-TestFile 'cache\keep.txt'       | Out-Null
New-TestFile 'cache\sub\nested.tmp' | Out-Null

$t = Invoke-TestScan @'
[Filters *]
DetectFile=%WINCLEANTESTROOT%
FileKey1=%WINCLEANTESTROOT%\cache|*.tmp;*.log
'@
$names = @($t[0].Files | ForEach-Object { $_.Name } | Sort-Object)
Assert-Equal 'matches two files'            2 $t[0].FileCount
Assert       'a.tmp matched'                ($names -contains 'a.tmp')
Assert       'b.log matched'                ($names -contains 'b.log')
Assert       'keep.txt NOT matched'         ($names -notcontains 'keep.txt')
Assert       'no flag does not recurse'     ($names -notcontains 'nested.tmp')

$t = Invoke-TestScan @'
[Recurse *]
DetectFile=%WINCLEANTESTROOT%
FileKey1=%WINCLEANTESTROOT%\cache|*.tmp|RECURSE
'@
$names = @($t[0].Files | ForEach-Object { $_.Name })
Assert 'RECURSE reaches subdirectory' ($names -contains 'nested.tmp')
Assert 'RECURSE still honours filter'  ($names -notcontains 'keep.txt')
Assert-Equal 'RECURSE marks no dirs for removal' 0 $t[0].Directories.Count

$t = Invoke-TestScan @'
[RemoveSelf *]
DetectFile=%WINCLEANTESTROOT%
FileKey1=%WINCLEANTESTROOT%\cache|*|REMOVESELF
'@
Assert-Equal 'REMOVESELF marks the directory' 1 $t[0].Directories.Count
Assert 'REMOVESELF ignores the filter and takes everything' ($t[0].FileCount -ge 4)

# ======================================================================================
Describe 'Scanning: exclusions'
# ======================================================================================

New-TestFile 'ex\drop.log'          | Out-Null
New-TestFile 'ex\keep.log'          | Out-Null
New-TestFile 'ex\safe\precious.log' | Out-Null
New-TestFile 'ex\other\drop2.log'   | Out-Null

$t = Invoke-TestScan @'
[Excl *]
DetectFile=%WINCLEANTESTROOT%
FileKey1=%WINCLEANTESTROOT%\ex|*.log|RECURSE
ExcludeKey1=FILE|%WINCLEANTESTROOT%\ex\|keep.log
ExcludeKey2=PATH|%WINCLEANTESTROOT%\ex\safe\|*
'@
$full = @($t[0].Files | ForEach-Object { $_.FullName })
Assert 'FILE exclusion preserves named file' ($full -notcontains (Join-Path $sandbox 'ex\keep.log'))
Assert 'PATH exclusion preserves subtree'    ($full -notcontains (Join-Path $sandbox 'ex\safe\precious.log'))
Assert 'non-excluded file still matched'     ($full -contains (Join-Path $sandbox 'ex\drop.log'))
Assert 'other subdir still matched'          ($full -contains (Join-Path $sandbox 'ex\other\drop2.log'))

# ======================================================================================
Describe 'Detection gating'
# ======================================================================================

New-TestFile 'ghost\junk.tmp' | Out-Null

$t = Invoke-TestScan @'
[Not Installed *]
DetectFile=%WINCLEANTESTROOT%\no-such-app-directory
FileKey1=%WINCLEANTESTROOT%\ghost|*.tmp
'@
Assert-Equal 'undetected app yields no targets' 0 $t.Count
Assert 'undetected app file untouched' (Test-Exists 'ghost\junk.tmp')

$t = Invoke-TestScan @'
[Registry Detect *]
Detect=HKCU\Software\ThisKeyDoesNotExistAnywhere12345
FileKey1=%WINCLEANTESTROOT%\ghost|*.tmp
'@
Assert-Equal 'missing registry key gates entry out' 0 $t.Count

$t = Invoke-TestScan @'
[Always Applies *]
FileKey1=%WINCLEANTESTROOT%\ghost|*.tmp
'@
Assert-Equal 'entry with no detector always applies' 1 $t[0].FileCount

# ======================================================================================
Describe 'Age filter'
# ======================================================================================

New-TestFile 'age\old.tmp'   -AgeDays 30 | Out-Null
New-TestFile 'age\fresh.tmp' -AgeDays 0  | Out-Null

$t = Invoke-TestScan -OlderThanDays 7 -Ini @'
[Age *]
DetectFile=%WINCLEANTESTROOT%
FileKey1=%WINCLEANTESTROOT%\age|*.tmp
'@
$names = @($t[0].Files | ForEach-Object { $_.Name })
Assert 'old file selected'      ($names -contains 'old.tmp')
Assert 'recent file preserved'  ($names -notcontains 'fresh.tmp')

# ======================================================================================
Describe 'Wildcard path resolution'
# ======================================================================================

New-TestFile 'glob\p1\Cache\x.dat'  | Out-Null
New-TestFile 'glob\p2\Cache\y.dat'  | Out-Null
New-TestFile 'glob\p2\Other\z.dat'  | Out-Null

$t = Invoke-TestScan @'
[Glob *]
DetectFile=%WINCLEANTESTROOT%
FileKey1=%WINCLEANTESTROOT%\glob\*\Cache|*.dat
'@
$names = @($t[0].Files | ForEach-Object { $_.Name } | Sort-Object)
Assert-Equal 'mid-path wildcard matched both profiles' 2 $t[0].FileCount
Assert 'non-matching sibling directory ignored' ($names -notcontains 'z.dat')

# ======================================================================================
Describe 'Junctions are not followed'
# ======================================================================================

New-TestFile 'junc\real\secret.tmp' | Out-Null
New-Item -ItemType Directory -Path (Join-Path $sandbox 'junc\src') -Force | Out-Null
$mk = cmd /c mklink /J "$(Join-Path $sandbox 'junc\src\link')" "$(Join-Path $sandbox 'junc\real')" 2>&1
$junctionMade = (Test-Path -LiteralPath (Join-Path $sandbox 'junc\src\link'))

if ($junctionMade) {
    $t = Invoke-TestScan @'
[Junction *]
DetectFile=%WINCLEANTESTROOT%
FileKey1=%WINCLEANTESTROOT%\junc\src|*.tmp|RECURSE
'@
    $full = @($(if ($t.Count) { $t[0].Files | ForEach-Object { $_.FullName } }))
    Assert 'RECURSE does not traverse a junction' ($full.Count -eq 0)
    Assert 'file behind the junction survives'    (Test-Exists 'junc\real\secret.tmp')
    # REMOVESELF on a tree that CONTAINS a junction must unlink it, not delete through it.
    # Remove-Item -Recurse gets this wrong on PowerShell 5.1 and destroys the target.
    New-TestFile 'jt\outside\precious.txt' | Out-Null
    New-TestFile 'jt\doomed\ordinary.tmp'  | Out-Null
    cmd /c mklink /J "$(Join-Path $sandbox 'jt\doomed\escape')" "$(Join-Path $sandbox 'jt\outside')" 2>&1 | Out-Null

    if (Test-Path -LiteralPath (Join-Path $sandbox 'jt\doomed\escape')) {
        $t = Invoke-TestScan @'
[JunctionInTree *]
DetectFile=%WINCLEANTESTROOT%
FileKey1=%WINCLEANTESTROOT%\jt\doomed|*|REMOVESELF
'@
        Invoke-TestApply $t | Out-Null
        Assert 'REMOVESELF removed the target directory'      (-not (Test-Exists 'jt\doomed'))
        Assert 'data behind a nested junction survived'       (Test-Exists 'jt\outside\precious.txt')
    } else {
        Write-Host '  SKIP  nested junction test (mklink unavailable)' -ForegroundColor DarkYellow
    }
} else {
    Write-Host '  SKIP  junction tests (mklink unavailable)' -ForegroundColor DarkYellow
}

# ======================================================================================
Describe 'Dry run deletes nothing'
# ======================================================================================

New-TestFile 'dry\a.tmp' | Out-Null
New-TestFile 'dry\b.tmp' | Out-Null

$t = Invoke-TestScan @'
[Dry *]
DetectFile=%WINCLEANTESTROOT%
FileKey1=%WINCLEANTESTROOT%\dry|*.tmp
'@
Assert-Equal 'scan found both files' 2 $t[0].FileCount
Assert 'scanning alone left file a' (Test-Exists 'dry\a.tmp')
Assert 'scanning alone left file b' (Test-Exists 'dry\b.tmp')

# ======================================================================================
Describe 'Apply actually deletes'
# ======================================================================================

$deleted = Invoke-TestApply $t
Assert-Equal 'reported two deletions' 2 $deleted
Assert 'file a gone'          (-not (Test-Exists 'dry\a.tmp'))
Assert 'file b gone'          (-not (Test-Exists 'dry\b.tmp'))
Assert 'parent dir preserved' (Test-Exists 'dry')

New-TestFile 'self\x.tmp' | Out-Null
$t = Invoke-TestScan @'
[Self *]
DetectFile=%WINCLEANTESTROOT%
FileKey1=%WINCLEANTESTROOT%\self|*|REMOVESELF
'@
Invoke-TestApply $t | Out-Null
Assert 'REMOVESELF removed the directory itself' (-not (Test-Exists 'self'))

# Read-only files must still be removable: apps mark cache files read-only.
$ro = New-TestFile 'ro\locked.tmp'
Set-ItemProperty -LiteralPath $ro -Name IsReadOnly -Value $true
$t = Invoke-TestScan @'
[RO *]
DetectFile=%WINCLEANTESTROOT%
FileKey1=%WINCLEANTESTROOT%\ro|*.tmp
'@
Invoke-TestApply $t | Out-Null
Assert 'read-only file deleted' (-not (Test-Exists 'ro\locked.tmp'))

# ======================================================================================
Describe 'Protected paths block removal end to end'
# ======================================================================================

New-TestFile 'guarded\important.txt' | Out-Null
$guard = Join-Path $sandbox 'guarded'

$t = Invoke-TestScan -ExtraProtected @($guard) -Ini @'
[Guarded *]
DetectFile=%WINCLEANTESTROOT%
FileKey1=%WINCLEANTESTROOT%\guarded|*|REMOVESELF
'@
$blocked = @($t | ForEach-Object { $_.Blocked })
Assert-Equal 'no files selected inside a protected dir' 0 (@($t | ForEach-Object { $_.FileCount }) | Measure-Object -Sum).Sum
Assert 'refusal was recorded with a reason' ($blocked.Count -ge 1)
Assert 'protected file survives'            (Test-Exists 'guarded\important.txt')

# ======================================================================================
Describe 'Built-in system ruleset'
# ======================================================================================

$sys    = Get-WinCleanSystemRule
$sysAgg = Get-WinCleanSystemRule -IncludeAggressive
Assert 'system rules present'                   ($sys.Count -gt 0)
Assert 'aggressive rules hidden by default'     ($sysAgg.Count -gt $sys.Count)
Assert 'no aggressive rule in the default set'  (@($sys | Where-Object { $_.Risk -eq 'Aggressive' }).Count -eq 0)
Assert 'every system rule has a category'       (@($sysAgg | Where-Object { -not $_.Category }).Count -eq 0)
Assert 'Windows.old rule is marked aggressive'  ((@($sysAgg | Where-Object { $_.Name -eq 'Windows Setup Leftovers' })[0]).Risk -eq 'Aggressive')
Assert 'system rules tagged with source'        ((@($sys)[0]).Source -eq 'system')

# Every built-in rule must survive the safety gate on a real machine: if one of my own
# rules resolves to a protected path, that is a bug in the ruleset, not in the input.
$tm = Get-WinCleanTokenMap
$protAll = Get-WinCleanProtectedPath
$selfBlocked = New-Object System.Collections.Generic.List[string]
foreach ($rule in $sysAgg) {
    foreach ($fk in $rule.FileKeys) {
        foreach ($base in (Expand-WinCleanToken -Path $fk.Path -TokenMap $tm)) {
            foreach ($d in (Resolve-WinCleanDirectory -Pattern $base -MaxResults 32)) {
                $v = Test-WinCleanTarget -Directory $d -Filter $fk.Filter -Flag $fk.Flag -ProtectedPaths $protAll
                if (-not $v.Allowed) { $selfBlocked.Add("$($rule.Name): $($v.Reason)") }
            }
        }
    }
}
Assert 'no built-in rule is refused by the safety gate' ($selfBlocked.Count -eq 0) ($selfBlocked -join ' | ')

# ======================================================================================
Describe 'CLI end to end'
# ======================================================================================

$cli = Join-Path (Split-Path -Parent $here) 'Invoke-WinClean.ps1'
$cliIni = Join-Path $sandbox 'cli.ini'
@"
[CLI Test *]
Section=SandboxTest
DetectFile=%WINCLEANTESTROOT%
FileKey1=%WINCLEANTESTROOT%\clitest|*.tmp|RECURSE
"@ | Set-Content -LiteralPath $cliIni -Encoding utf8

# Child CLI processes inherit LOCALAPPDATA, and the CLI writes its state file there.
# Without redirecting it, a test that runs -Apply would stamp "last cleaned: now" into the
# real user's state file and make the notifier report something that never happened.
$script:SandboxAppData = Join-Path $sandbox 'appdata'
if (-not (Test-Path -LiteralPath $script:SandboxAppData)) {
    New-Item -ItemType Directory -Path $script:SandboxAppData -Force | Out-Null
}

function Invoke-CliRaw {
    param([string[]] $AllArgs)
    # Some cases deliberately make the CLI write to stderr. With ErrorActionPreference
    # set to Stop, a native command's stderr becomes a terminating error and would abort
    # the suite instead of being captured as the output under test.
    $prevEap  = $ErrorActionPreference
    $prevData = $env:LOCALAPPDATA
    $ErrorActionPreference = 'Continue'
    $env:LOCALAPPDATA = $script:SandboxAppData
    try {
        return (& powershell -NoProfile -ExecutionPolicy Bypass -File $cli @AllArgs 2>&1 | Out-String)
    } finally {
        $ErrorActionPreference = $prevEap
        $env:LOCALAPPDATA = $prevData
    }
}

function Invoke-Cli {
    param([string[]] $CliArgs)
    return (Invoke-CliRaw (@('-RuleSet', 'Winapp2', '-DatabasePath', $cliIni) + $CliArgs))
}

New-TestFile 'clitest\one.tmp'      | Out-Null
New-TestFile 'clitest\sub\two.tmp'  | Out-Null
New-TestFile 'clitest\keep.doc'     | Out-Null

$out = Invoke-Cli @('-Output', 'Json', '-Quiet')
$parsed = $null
try { $parsed = $out | ConvertFrom-Json } catch { }
Assert       'JSON output parses'              ($null -ne $parsed)
Assert-Equal 'dry run reports mode dryrun'     'dryrun' $parsed.Mode
Assert-Equal 'dry run finds both tmp files'    2 $parsed.TotalFiles
Assert-Equal 'dry run deletes nothing'         0 $parsed.Deleted
Assert       'files still on disk after dry run' (Test-Exists 'clitest\one.tmp')

# Regression: Measure-Object -Property returns nothing for an empty collection, and
# reading .Sum off that threw under StrictMode.
$out = Invoke-Cli @('-Entry', 'NoSuchEntryAnywhere', '-Output', 'Json', '-Quiet')
$empty = $null
try { $empty = $out | ConvertFrom-Json } catch { }
Assert       'empty result set does not crash'  ($null -ne $empty)
Assert-Equal 'empty result set totals zero'     0 $empty.TotalBytes

# Regression: Read-Host would hang forever when no human can answer it.
$out = Invoke-Cli @('-Apply', '-Output', 'Json')
Assert 'non-interactive -Apply without -Force is refused' ($out -match 'Refusing to prompt')
Assert 'refusal left the files alone'                     (Test-Exists 'clitest\one.tmp')

# Regression: launched with -File, PowerShell hands "-Section A,B" to the script as one
# string. Before the script split it, multi-value filters matched nothing and reported a
# confident zero with exit code 0 - a silent wrong answer, in the exact form the docs
# demonstrate. Both shims and every agent shelling out go through this path.
$multiIni = Join-Path $sandbox 'multi.ini'
@"
[Alpha Entry *]
Section=CatAlpha
FileKey1=%WINCLEANTESTROOT%\multi|*.tmp
[Beta Entry *]
Section=CatBeta
FileKey1=%WINCLEANTESTROOT%\multi|*.tmp
[Gamma Entry *]
Section=CatGamma
FileKey1=%WINCLEANTESTROOT%\multi|*.tmp
"@ | Set-Content -LiteralPath $multiIni -Encoding utf8

function Invoke-CliDb {
    param([string[]] $CliArgs)
    return (Invoke-CliRaw (@('-RuleSet', 'Winapp2', '-DatabasePath', $multiIni) + $CliArgs))
}

$listOne = Invoke-CliDb @('-ListEntries', '-Section', 'CatAlpha')
$listTwo = Invoke-CliDb @('-ListEntries', '-Section', 'CatAlpha,CatBeta')
Assert 'single -Section value matches'            ($listOne -match 'Alpha Entry')
Assert 'comma-separated -Section matches first'   ($listTwo -match 'Alpha Entry')
Assert 'comma-separated -Section matches second'  ($listTwo -match 'Beta Entry')
Assert 'comma-separated -Section excludes others' ($listTwo -notmatch 'Gamma Entry')

$excl = Invoke-CliDb @('-ListEntries', '-ExcludeSection', 'CatAlpha,CatBeta')
Assert 'comma-separated -ExcludeSection excludes both' ($excl -notmatch 'Alpha Entry' -and $excl -notmatch 'Beta Entry')
Assert 'comma-separated -ExcludeSection keeps the rest' ($excl -match 'Gamma Entry')

# Regression: -ListEntries applied the warning filter, so entries carrying a Warning were
# invisible in the listing as well as excluded from runs. The built-in ruleset looked
# like 9 entries when it has 15, and asking about "Crash Dumps" returned nothing at all.
# Its own helper: Invoke-Cli pins -RuleSet Winapp2, which would collide here.
function Invoke-CliSystem {
    param([string[]] $CliArgs)
    return (Invoke-CliRaw (@('-RuleSet', 'System') + $CliArgs))
}

$sysList = Invoke-CliSystem @('-ListEntries')
Assert 'warning-gated entry appears in the listing' ($sysList -match 'Crash Dumps')
Assert 'listing marks what is skipped by default'   ($sysList -match 'SkippedByDefault')

$sysAggList = Invoke-CliSystem @('-ListEntries', '-Aggressive')
Assert 'aggressive entry appears when requested' ($sysAggList -match 'Prefetch Data')

# Regression: an unelevated run could not be told apart from a complete one - small
# numbers and "could not read most of it" looked identical.
$sysJson = $null
try { $sysJson = (Invoke-CliSystem @('-Output', 'Json', '-Quiet')) | ConvertFrom-Json } catch { }
Assert 'report exposes AdminLimited'    ($null -ne $sysJson -and $null -ne $sysJson.AdminLimited)
Assert 'report exposes EntriesDetected' ($null -ne $sysJson -and $null -ne $sysJson.EntriesDetected)
Assert 'detected count is at least matched count' ($sysJson.EntriesDetected -ge $sysJson.EntriesMatched)

$out = Invoke-Cli @('-Apply', '-Force', '-Output', 'Json', '-Quiet')
$applied = $null
try { $applied = $out | ConvertFrom-Json } catch { }
Assert-Equal 'apply reports mode applied' 'applied' $applied.Mode
Assert-Equal 'apply deleted both files'   2 $applied.Deleted
Assert 'recursive file gone'     (-not (Test-Exists 'clitest\sub\two.tmp'))
Assert 'filtered file preserved' (Test-Exists 'clitest\keep.doc')

# ======================================================================================
Describe 'Database update mechanism'
# ======================================================================================

# Redirect LOCALAPPDATA so state.json lands in the sandbox and the real one is untouched.
$realLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $sandbox 'appdata'
New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null

# --- validation: the gate between a download and it becoming the deletion ruleset ---
$goodDb = Join-Path $sandbox 'good.ini'
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('; Version: 999999')
for ($i = 1; $i -le 150; $i++) {
    [void]$sb.AppendLine("[Entry $i *]")
    [void]$sb.AppendLine('FileKey1=%WINCLEANTESTROOT%\x|*')
}
# Pad past the 10 KB floor that catches truncated downloads.
[void]$sb.AppendLine('; ' + ('x' * 12000))
Set-Content -LiteralPath $goodDb -Value $sb.ToString() -Encoding utf8

$v = Test-WinCleanDatabaseFile -Path $goodDb
Assert       'valid database accepted'   $v.Valid $v.Reason
Assert-Equal 'entry count read'          150 $v.EntryCount
Assert-Equal 'version banner read'       '999999' $v.Version

$htmlDb = Join-Path $sandbox 'err.html'
Set-Content -LiteralPath $htmlDb -Value ('<html><body>404 Not Found</body></html>' + ("`n" + ('p' * 200)) * 80) -Encoding utf8
$v = Test-WinCleanDatabaseFile -Path $htmlDb
Assert 'HTML error page rejected' (-not $v.Valid) $v.Reason

$tinyDb = Join-Path $sandbox 'tiny.ini'
Set-Content -LiteralPath $tinyDb -Value "[One *]`nFileKey1=%Temp%\x|*" -Encoding utf8
$v = Test-WinCleanDatabaseFile -Path $tinyDb
Assert 'truncated file rejected' (-not $v.Valid) $v.Reason

# A real update adds and removes entries; it does not halve the database.
$v = Test-WinCleanDatabaseFile -Path $goodDb -PreviousEntryCount 4000
Assert 'suspicious entry-count collapse rejected' (-not $v.Valid) $v.Reason
$v = Test-WinCleanDatabaseFile -Path $goodDb -PreviousEntryCount 160
Assert 'ordinary entry-count drift accepted' $v.Valid $v.Reason

Assert-Equal 'missing file reports max age' ([int]::MaxValue) (Get-WinCleanDatabaseAgeDays (Join-Path $sandbox 'nope.ini'))
Assert-Equal 'fresh file reports age 0'     0 (Get-WinCleanDatabaseAgeDays $goodDb)

# --- state round-trip ---
Set-WinCleanStateField -Name 'Version' -Value '123456'
Set-WinCleanStateField -Name 'EntryCount' -Value 4242
$s = Get-WinCleanState
Assert-Equal 'state persists version'     '123456' $s.Version
Assert-Equal 'state persists entry count' 4242 $s.EntryCount

# --- rollback ---
$dbForRollback = Join-Path $sandbox 'roll.ini'
$r = Restore-WinCleanDatabase -Path $dbForRollback
Assert 'rollback with no backup fails cleanly' ($r.Status -eq 'Failed')

Copy-Item -LiteralPath $goodDb -Destination "$dbForRollback.bak" -Force
Set-Content -LiteralPath $dbForRollback -Value 'corrupted' -Encoding utf8
$r = Restore-WinCleanDatabase -Path $dbForRollback
Assert 'rollback restores the backup' ($r.Status -eq 'RolledBack') $r.Message
Assert-Equal 'restored database is valid' $true (Test-WinCleanDatabaseFile -Path $dbForRollback).Valid
Assert 'rollback clears the etag so the next fetch is full' ($null -eq (Get-WinCleanState).Etag)

# ======================================================================================
Describe 'Cleanup-due notification'
# ======================================================================================

$disk = Get-WinCleanFreeSpace
Assert 'free space readable'            ($null -ne $disk)
Assert 'free percent is a percentage'   ($disk.FreePercent -ge 0 -and $disk.FreePercent -le 100)

# Threshold above any real disk => always due. Proves the signal fires at all.
$s = Get-WinCleanDueStatus -MinFreePercent 101 -DatabasePath $goodDb
Assert 'low disk marks a clean due' $s.Due
Assert 'due status carries a summary' ([bool]$s.Summary)

# Threshold below any real disk, and cleaned recently => not due.
Set-WinCleanStateField -Name 'LastCleanAt' -Value ((Get-Date).ToString('o'))
$s = Get-WinCleanDueStatus -MinFreePercent 0 -MinDaysSinceClean 3650 -DatabasePath $goodDb
Assert 'healthy machine is not due'      (-not $s.Due)
Assert 'recent clean is reflected'       ($s.DaysSinceClean -eq 0)
Assert 'summary is empty when not due'   ([string]::IsNullOrEmpty($s.Summary))

# Snooze must win over every other signal, or people uninstall the hook.
Set-WinCleanSnooze -Days 30 | Out-Null
$s = Get-WinCleanDueStatus -MinFreePercent 101 -DatabasePath $goodDb
Assert-Equal 'snooze suppresses an otherwise-due prompt' $false $s.Due
Assert-Equal 'snooze is reported as the reason'          'Snoozed' $s.Reason

Clear-WinCleanSnooze
$s = Get-WinCleanDueStatus -MinFreePercent 101 -DatabasePath $goodDb
Assert 'clearing the snooze restores the prompt' $s.Due

# ======================================================================================
Describe 'Persistent ignore list'
# ======================================================================================

# Still running against the sandboxed LOCALAPPDATA from the block above.
$l = Get-WinCleanIgnoreList
Assert-Equal 'starts empty (entries)' 0 $l.Entries.Count
Assert-Equal 'starts empty (paths)'   0 $l.Paths.Count

$r = Add-WinCleanIgnore -Entry @('Microsoft NuGet Package Cache *', '*Squirrel*') -Path @('D:\Keep')
Assert-Equal 'three items added' 3 $r.Added.Count
$l = Get-WinCleanIgnoreList
Assert-Equal 'two entry patterns stored' 2 $l.Entries.Count
Assert-Equal 'one path stored'           1 $l.Paths.Count

# Adding the same thing twice must not duplicate it.
$r = Add-WinCleanIgnore -Entry @('*Squirrel*')
Assert-Equal 'duplicate not added again'  0 $r.Added.Count
Assert-Equal 'duplicate reported as such' 1 $r.AlreadyPresent.Count
Assert-Equal 'list length unchanged'      2 (Get-WinCleanIgnoreList).Entries.Count

# Paths are normalised, so the same directory written differently is one entry.
Add-WinCleanIgnore -Path @('d:/keep/') | Out-Null
Assert-Equal 'path normalised, not duplicated' 1 (Get-WinCleanIgnoreList).Paths.Count

# Matching: by exact name, by wildcard, and by category.
$pat = (Get-WinCleanIgnoreList).Entries
Assert 'matches an exact-ish rule name' (Test-WinCleanIgnored -Name 'Microsoft NuGet Package Cache *' -Category 'Applications' -Patterns $pat)
Assert 'matches by wildcard'            (Test-WinCleanIgnored -Name 'Squirrel.Windows *' -Category 'Applications' -Patterns $pat)
Assert 'does not match unrelated rule'  (-not (Test-WinCleanIgnored -Name 'Google Chrome Caches *' -Category 'Google Chrome Web Browser' -Patterns $pat))

Add-WinCleanIgnore -Entry @('Games') | Out-Null
Assert 'a pattern can match the category' (Test-WinCleanIgnored -Name 'Some Game *' -Category 'Games' -Patterns (Get-WinCleanIgnoreList).Entries)

# Removal is exact, not wildcard-expanded: taking one item off the list must not
# silently take others with it.
$r = Remove-WinCleanIgnore -Pattern @('*Squirrel*')
Assert-Equal 'removal reports one removed' 1 $r.Removed.Count
$l = Get-WinCleanIgnoreList
Assert 'removed pattern is gone'    ($l.Entries -notcontains '*Squirrel*')
Assert 'other patterns survive'     ($l.Entries -contains 'Microsoft NuGet Package Cache *')

$r = Remove-WinCleanIgnore -Pattern @('never-was-on-the-list')
Assert-Equal 'unknown pattern reported as not found' 1 $r.NotFound.Count

$r = Remove-WinCleanIgnore -All
$l = Get-WinCleanIgnoreList
Assert-Equal 'clear empties entries' 0 $l.Entries.Count
Assert-Equal 'clear empties paths'   0 $l.Paths.Count

# End to end through the CLI: an ignored rule must not appear in the scan at all.
$ignIni = Join-Path $sandbox 'ign.ini'
# Each rule gets its own directory. Pointing both at the same files would make the
# second one match nothing - cross-entry deduplication claims a file once - and the
# test would be measuring dedupe rather than the ignore list.
@"
[Keeper Entry *]
Section=IgnoreTest
FileKey1=%WINCLEANTESTROOT%\ign\keep|*.tmp
[Droppable Entry *]
Section=IgnoreTest
FileKey1=%WINCLEANTESTROOT%\ign\drop|*.tmp
"@ | Set-Content -LiteralPath $ignIni -Encoding utf8
New-TestFile 'ign\keep\a.tmp' | Out-Null
New-TestFile 'ign\drop\b.tmp' | Out-Null

function Invoke-CliIgnore {
    param([string[]] $CliArgs)
    return (Invoke-CliRaw (@('-RuleSet', 'Winapp2', '-DatabasePath', $ignIni) + $CliArgs))
}

$before = (Invoke-CliIgnore @('-Output', 'Json', '-Quiet')) | ConvertFrom-Json
Assert-Equal 'both rules match before ignoring' 2 $before.EntriesMatched

Invoke-CliIgnore @('-Ignore', 'Keeper Entry *') | Out-Null
$after = (Invoke-CliIgnore @('-Output', 'Json', '-Quiet')) | ConvertFrom-Json
Assert-Equal 'ignored rule is excluded from the scan' 1 $after.EntriesMatched
Assert-Equal 'report states how many were ignored'    1 $after.IgnoredCount
# IgnoredEntries carries objects, not names: each one reports the size it is holding so
# the user can see what the ignore list costs without disabling it.
$ignoredNamesOut = @($after.IgnoredEntries | ForEach-Object { $_.Name })
Assert 'report names what was ignored'      ($ignoredNamesOut -contains 'Keeper Entry *')
Assert 'report sizes what was ignored'      ($after.IgnoredBytes -gt 0)
Assert 'ignored size is human readable'     ([bool]$after.IgnoredSize)
Assert 'ignored file count reported'        ($after.IgnoredFiles -ge 1)

$bypass = (Invoke-CliIgnore @('-Output', 'Json', '-Quiet', '-NoIgnoreList')) | ConvertFrom-Json
Assert-Equal 'NoIgnoreList restores the rule' 2 $bypass.EntriesMatched
Assert-Equal 'NoIgnoreList reports nothing ignored' 0 $bypass.IgnoredCount

# The whole point of the split: the ignored rule's bytes are measured and reported, but
# are NOT part of the deletable total. Bypassing the list moves them back into it.
Assert 'ignored bytes are kept out of the deletable total' ($after.TotalBytes -lt $bypass.TotalBytes)
Assert 'ignored + deletable accounts for the whole set'    (($after.TotalBytes + $after.IgnoredBytes) -eq $bypass.TotalBytes)

Assert 'ignored rule deleted nothing' (Test-Exists 'ign\keep\a.tmp')

$env:LOCALAPPDATA = $realLocalAppData

} finally {
    if ($realLocalAppData) { $env:LOCALAPPDATA = $realLocalAppData }
    Remove-Item Env:\WINCLEANTESTROOT -ErrorAction SilentlyContinue
    if ($KeepSandbox) {
        Write-Host "`nSandbox kept at $sandbox" -ForegroundColor DarkGray
    } else {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------------------------------

Write-Host ''
Write-Host ('=' * 62) -ForegroundColor DarkGray
if ($script:Failed.Count -eq 0) {
    Write-Host "  ALL $script:Passed TESTS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "  $script:Passed passed, $($script:Failed.Count) FAILED" -ForegroundColor Red
    $script:Failed | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
}
