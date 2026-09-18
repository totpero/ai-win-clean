<#
    winclean-notify.ps1 - cheap "is a clean due?" probe for a Claude Code hook.

    Designed to cost effectively nothing. It queries one volume, reads one small JSON
    state file and exits; it never loads the rule database or enumerates files, and it
    prints NOTHING unless a clean is actually worth suggesting. A hook that chatters on
    every session gets uninstalled, so silence is the default.

    Wire it up as a SessionStart hook - see hooks/README.md.

    Exit code is always 0: a hook must never break the session it is attached to.
#>

[CmdletBinding()]
param(
    [int]    $MinFreePercent    = 15,
    [int]    $MinDaysSinceClean = 30,
    [switch] $Json
)

try {
    $toolsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\windows-junk-cleanup\tools'
    if (-not (Test-Path -LiteralPath $toolsDir)) {
        # Installed layout: hooks live beside the skill in ~/.claude
        $toolsDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills\windows-junk-cleanup\tools'
    }

    . (Join-Path $toolsDir 'lib\Winapp2.ps1')
    . (Join-Path $toolsDir 'lib\Database.ps1')
    . (Join-Path $toolsDir 'lib\Status.ps1')

    $dbPath = Join-Path (Get-WinCleanDataDir) 'winapp2.ini'
    $s = Get-WinCleanDueStatus -MinFreePercent $MinFreePercent `
                               -MinDaysSinceClean $MinDaysSinceClean `
                               -DatabasePath $dbPath

    if ($Json) {
        $s | ConvertTo-Json -Compress
        exit 0
    }

    if ($s.Due) {
        # One line, and only when it matters. The agent decides whether to surface it.
        Write-Output "[disk] $($s.Summary). Run /win-clean to see what can be freed, or /win-clean snooze to mute for 30 days."
    }

} catch {
    # Never fail the session because a convenience probe broke.
}

exit 0
