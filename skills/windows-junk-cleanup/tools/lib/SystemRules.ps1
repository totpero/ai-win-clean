<#
    SystemRules.ps1 - ai-win-clean's own ruleset for core Windows junk.

    winapp2 covers installed applications extremely well but is thin on the OS-level
    caches that actually dominate a full C: drive. These rules fill that gap.

    They are written in winapp2's own INI dialect and parsed by the same parser, so
    there is exactly one engine, one safety gate and one code path.

    Risk levels:
        Normal      regenerated automatically, no user-visible consequence
        Aggressive  safe but has a real trade-off (slower next boot, loses rollback).
                    Requires -Aggressive.

    Deliberately NOT included, and why:
      - Recycle Bin: that is the user's undo buffer holding their own files. -EmptyRecycleBin.
      - Prefetch: recovers ~100 MB and slows app launches until it rebuilds. Cargo cult.
      - pagefile.sys / hiberfil.sys: system configuration, not junk.
      - System Restore points and VSS shadow copies: the machine's rollback path.
      - %LocalAppData%\Packages\*\LocalCache wholesale: holds real Store-app data.
#>

$script:WinCleanSystemRulesIni = @'
[Windows Temporary Files]
Section=Windows System
Risk=Normal
FileKey1=%LocalAppData%\Temp|*|RECURSE
FileKey2=%WinDir%\Temp|*|RECURSE
FileKey3=%SystemDrive%\Temp|*|RECURSE

[Windows Update Cache]
Section=Windows System
Risk=Normal
NeedsAdmin=True
Warning=Windows Update may re-download files it had already staged.
FileKey1=%WinDir%\SoftwareDistribution\Download|*|RECURSE
FileKey2=%WinDir%\SoftwareDistribution\DeliveryOptimization|*|RECURSE

[Windows Update Logs]
Section=Windows System
Risk=Normal
NeedsAdmin=True
FileKey1=%WinDir%\Logs\CBS|*.log;*.cab;*.persist
FileKey2=%WinDir%\Logs\DISM|*.log
FileKey3=%WinDir%\Logs\WindowsUpdate|*.etl
FileKey4=%WinDir%\Logs\MoSetup|*.log
FileKey5=%WinDir%\Panther|*.log;*.xml;*.etl
FileKey6=%WinDir%|*.log

[Windows Error Reporting]
Section=Windows System
Risk=Normal
FileKey1=%LocalAppData%\Microsoft\Windows\WER\ReportQueue|*|RECURSE
FileKey2=%LocalAppData%\Microsoft\Windows\WER\ReportArchive|*|RECURSE
FileKey3=%LocalAppData%\Microsoft\Windows\WER\Temp|*|RECURSE
FileKey4=%ProgramData%\Microsoft\Windows\WER\ReportQueue|*|RECURSE
FileKey5=%ProgramData%\Microsoft\Windows\WER\ReportArchive|*|RECURSE
FileKey6=%ProgramData%\Microsoft\Windows\WER\Temp|*|RECURSE

[Crash Dumps]
Section=Windows System
Risk=Normal
Warning=If you are currently investigating a blue screen, these dumps are the evidence.
FileKey1=%LocalAppData%\CrashDumps|*.dmp;*.hdmp;*.mdmp
FileKey2=%WinDir%\Minidump|*.dmp
FileKey3=%WinDir%|MEMORY.DMP;LiveKernelReports.dmp
FileKey4=%WinDir%\LiveKernelReports|*.dmp

[Thumbnail and Icon Cache]
Section=Windows System
Risk=Normal
Warning=Explorer rebuilds these on demand; folders may briefly redraw slowly afterwards.
FileKey1=%LocalAppData%\Microsoft\Windows\Explorer|thumbcache_*.db;iconcache_*.db
FileKey2=%LocalAppData%|IconCache.db

[Font Cache]
Section=Windows System
Risk=Normal
NeedsAdmin=True
FileKey1=%WinDir%\ServiceProfiles\LocalService\AppData\Local|*FontCache*.dat
FileKey2=%WinDir%\ServiceProfiles\LocalService\AppData\Local\FontCache|*|RECURSE

[DirectX Shader Cache]
Section=Windows System
Risk=Normal
FileKey1=%LocalAppData%\D3DSCache|*|RECURSE
FileKey2=%LocalAppData%\NVIDIA\DXCache|*
FileKey3=%LocalAppData%\NVIDIA\GLCache|*|RECURSE
FileKey4=%LocalAppData%\AMD\DxCache|*
FileKey5=%LocalAppData%\AMD\GLCache|*|RECURSE
FileKey6=%LocalAppData%\Intel\ShaderCache|*|RECURSE

[Internet Explorer and WebView Cache]
Section=Windows System
Risk=Normal
FileKey1=%LocalAppData%\Microsoft\Windows\INetCache\IE|*|RECURSE
FileKey2=%LocalAppData%\Microsoft\Windows\INetCache\Low\IE|*|RECURSE
FileKey3=%LocalAppData%\Microsoft\Windows\WebCache|*.log
FileKey4=%LocalAppData%\Microsoft\Windows\INetCookies\DNTException|*|RECURSE

[Windows Installer Orphans]
Section=Windows System
Risk=Normal
NeedsAdmin=True
FileKey1=%WinDir%\Installer\$PatchCache$\Managed|*|RECURSE
FileKey2=%SystemDrive%\Config.Msi|*|RECURSE

[Delivery Optimization Cache]
Section=Windows System
Risk=Normal
NeedsAdmin=True
FileKey1=%WinDir%\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache|*|RECURSE

[Defender Scan History]
Section=Windows System
Risk=Normal
NeedsAdmin=True
FileKey1=%ProgramData%\Microsoft\Windows Defender\Scans\History\Results|*|RECURSE
FileKey2=%ProgramData%\Microsoft\Windows Defender\Scans\History\Service|*|RECURSE

[Windows Setup Leftovers]
Section=Windows System
Risk=Aggressive
NeedsAdmin=True
Warning=Removes your ability to roll back to the previous Windows build. Windows deletes these automatically after 10 days.
FileKey1=%SystemDrive%\Windows.old|*|REMOVESELF
FileKey2=%SystemDrive%\$WinREAgent|*|REMOVESELF
FileKey3=%SystemDrive%\$Windows.~BT|*|REMOVESELF
FileKey4=%SystemDrive%\$Windows.~WS|*|REMOVESELF
FileKey5=%SystemDrive%\ESD\Download|*|RECURSE

[Prefetch Data]
Section=Windows System
Risk=Aggressive
NeedsAdmin=True
Warning=Recovers little space and makes application launches slower until Windows rebuilds it.
FileKey1=%WinDir%\Prefetch|*.pf

[Event Logs]
Section=Windows System
Risk=Aggressive
NeedsAdmin=True
Warning=Destroys the system's diagnostic history. Do not run this while troubleshooting.
FileKey1=%WinDir%\System32\winevt\Logs|*.evtx
'@

<#
    Returns the built-in rules as parsed entry objects, filtered by risk appetite.
#>
function Get-WinCleanSystemRule {
    [CmdletBinding()]
    param([switch] $IncludeAggressive)

    $lines = $script:WinCleanSystemRulesIni -split "`r?`n"
    $rules = ConvertFrom-Winapp2Content -Lines $lines -Origin 'built-in system ruleset' -SourceLabel 'system'

    if (-not $IncludeAggressive) {
        $rules = @($rules | Where-Object { $_.Risk -ne 'Aggressive' })
    }

    return ,@($rules)
}

<#
    The Recycle Bin is deliberately separate from every other rule.

    Its contents are the user's own files, already deleted by them, and it is their only
    undo path. It is never touched by a normal run - not even with -Apply - and only
    responds to an explicit -EmptyRecycleBin.
#>
function Get-WinCleanRecycleBinSize {
    [CmdletBinding()]
    param()

    $bytes = [int64] 0
    $count = 0

    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady -or $drive.DriveType -ne 'Fixed') { continue }
        $bin = Join-Path $drive.RootDirectory.FullName '$Recycle.Bin'
        if (-not (Test-Path -LiteralPath $bin)) { continue }
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($bin, '*', 'AllDirectories')) {
                try {
                    $bytes += (New-Object System.IO.FileInfo $f).Length
                    $count++
                } catch { }
            }
        } catch { }
    }

    return [pscustomobject] @{ Bytes = $bytes; FileCount = $count }
}

function Clear-WinCleanRecycleBin {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()

    if (-not $PSCmdlet.ShouldProcess('Recycle Bin (all drives)', 'Permanently delete contents')) {
        return [pscustomobject] @{ Emptied = $false; Error = $null }
    }

    try {
        # Clear-RecycleBin exists on PS 5.0+ / Windows 10+. Use the supported API rather
        # than hand-deleting $Recycle.Bin, which corrupts the bin's index.
        Clear-RecycleBin -Force -ErrorAction Stop
        return [pscustomobject] @{ Emptied = $true; Error = $null }
    } catch {
        return [pscustomobject] @{ Emptied = $false; Error = $_.Exception.Message }
    }
}
