<#
.SYNOPSIS
    Install the windows-junk-cleanup skill for one or more AI coding agents.

.DESCRIPTION
    Copies (or symlinks) skills\windows-junk-cleanup into the skills directory of every
    agent you select. The skill folder is self-contained - SKILL.md, reference.md and the
    tools - so a plain copy is all that is needed.

    Symlinks are preferred when the shell is elevated or Windows Developer Mode is on,
    because then a `git pull` in this repo updates every installed agent at once.

.PARAMETER Agent
    Which agents to install for. Default: Claude. Use 'All' for every known location.

.PARAMETER Scope
    User (default) installs to your profile. Project installs into .\.claude\skills etc.

.PARAMETER Copy
    Force a file copy even when a symlink would be possible.

.PARAMETER AddToPath
    Also add the tools directory to your user PATH, so `win-clean` works from any shell.

.EXAMPLE
    .\install.ps1
    Install for Claude Code, into your user profile.

.EXAMPLE
    .\install.ps1 -Agent All -AddToPath
    Install everywhere and put win-clean on your PATH.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Claude', 'Codex', 'Cursor', 'Windsurf', 'Copilot', 'OpenCode', 'All')]
    [string[]] $Agent = @('Claude'),

    [ValidateSet('User', 'Project')]
    [string]   $Scope = 'User',

    [switch]   $Copy,
    [switch]   $AddToPath,
    [switch]   $AddCommand,
    [switch]   $AddHook,
    [switch]   $All
)

if ($All) { $AddCommand = $true; $AddHook = $true; $AddToPath = $true }

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repo      = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillName = 'windows-junk-cleanup'
$source    = Join-Path $repo "skills\$skillName"

if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md'))) {
    throw "Cannot find the skill at $source. Run this from the repository root."
}

# Skills directory per agent. Most agents that support Agent Skills read a 'skills'
# folder; the ones that do not are given the same folder anyway, since SKILL.md is
# plain Markdown and remains readable.
$targets = [ordered] @{
    'Claude'   = @{ User = "$env:USERPROFILE\.claude\skills";   Project = '.claude\skills' }
    'Codex'    = @{ User = "$env:USERPROFILE\.codex\skills";    Project = '.codex\skills' }
    'Cursor'   = @{ User = "$env:USERPROFILE\.cursor\skills";   Project = '.cursor\skills' }
    'Windsurf' = @{ User = "$env:USERPROFILE\.windsurf\skills"; Project = '.windsurf\skills' }
    'Copilot'  = @{ User = "$env:USERPROFILE\.github\skills";   Project = '.github\skills' }
    'OpenCode' = @{ User = "$env:USERPROFILE\.opencode\skills"; Project = '.opencode\skills' }
}

$chosen = if ($Agent -contains 'All') { @($targets.Keys) } else { $Agent }

function Test-CanSymlink {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        if (([Security.Principal.WindowsPrincipal] $id).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)) { return $true }
    } catch { }
    try {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
        return ((Get-ItemProperty -Path $key -ErrorAction Stop).AllowDevelopmentWithoutDevLicense -eq 1)
    } catch { return $false }
}

$useLink = (-not $Copy) -and (Test-CanSymlink)
$installed = 0

foreach ($name in $chosen) {
    $dir = $targets[$name][$Scope]
    if (-not $dir) { continue }

    $dest = Join-Path $dir $skillName

    if (-not (Test-Path -LiteralPath $dir)) {
        if ($PSCmdlet.ShouldProcess($dir, 'Create skills directory')) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    if (Test-Path -LiteralPath $dest) {
        if (-not $PSCmdlet.ShouldProcess($dest, 'Replace existing installation')) { continue }
        # Remove the link itself, not what it points at.
        $existing = Get-Item -LiteralPath $dest -Force
        if ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            [System.IO.Directory]::Delete($dest, $false)
        } else {
            Remove-Item -LiteralPath $dest -Recurse -Force
        }
    }

    if (-not $PSCmdlet.ShouldProcess($dest, "Install $skillName")) { continue }

    if ($useLink) {
        New-Item -ItemType SymbolicLink -Path $dest -Target $source | Out-Null
        Write-Host "  linked  $name -> $dest" -ForegroundColor Green
    } else {
        Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force
        Write-Host "  copied  $name -> $dest" -ForegroundColor Green
    }
    $installed++
}

# ---- /win-clean slash command ---------------------------------------------------------
if ($AddCommand) {
    $cmdSrc = Join-Path $repo 'commands\win-clean.md'
    $cmdDir = if ($Scope -eq 'User') { "$env:USERPROFILE\.claude\commands" } else { '.claude\commands' }

    if (Test-Path -LiteralPath $cmdSrc) {
        if (-not (Test-Path -LiteralPath $cmdDir)) { New-Item -ItemType Directory -Path $cmdDir -Force | Out-Null }
        if ($PSCmdlet.ShouldProcess("$cmdDir\win-clean.md", 'Install slash command')) {
            Copy-Item -LiteralPath $cmdSrc -Destination (Join-Path $cmdDir 'win-clean.md') -Force
            Write-Host "  command /win-clean -> $cmdDir\win-clean.md" -ForegroundColor Green
        }
    } else {
        Write-Host "  command source not found at $cmdSrc" -ForegroundColor Yellow
    }
}

# ---- SessionStart notification hook ---------------------------------------------------
if ($AddHook) {
    $hookSrc = Join-Path $repo 'hooks\winclean-notify.ps1'
    $hookDir = "$env:USERPROFILE\.claude\hooks"

    if (-not (Test-Path -LiteralPath $hookSrc)) {
        Write-Host "  hook source not found at $hookSrc" -ForegroundColor Yellow
    } elseif ($PSCmdlet.ShouldProcess('~\.claude\settings.json', 'Register SessionStart hook')) {

        if (-not (Test-Path -LiteralPath $hookDir)) { New-Item -ItemType Directory -Path $hookDir -Force | Out-Null }
        Copy-Item -LiteralPath $hookSrc -Destination (Join-Path $hookDir 'winclean-notify.ps1') -Force

        $settingsPath = "$env:USERPROFILE\.claude\settings.json"
        $settings = [ordered] @{}
        if (Test-Path -LiteralPath $settingsPath) {
            try {
                $raw = Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop
                if ($raw.Trim()) {
                    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                    foreach ($p in $obj.PSObject.Properties) { $settings[$p.Name] = $p.Value }
                }
            } catch {
                # Never clobber a settings file we cannot parse - the user's own config
                # matters more than this convenience hook.
                Write-Host "  settings.json is not valid JSON; skipping hook registration" -ForegroundColor Yellow
                $settings = $null
            }
        }

        if ($null -ne $settings) {
            $cmdLine = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' +
                       (Join-Path $hookDir 'winclean-notify.ps1') + '"'

            # Rebuild the hooks node as a hashtable. ConvertFrom-Json hands back
            # PSCustomObjects whose property bag may be empty, and probing those under
            # StrictMode throws - so normalise once rather than testing shapes.
            $hooks = @{}
            if ($settings.Contains('hooks') -and $settings['hooks']) {
                foreach ($p in @($settings['hooks'].PSObject.Properties)) { $hooks[$p.Name] = $p.Value }
            }

            $existing = @()
            if ($hooks.ContainsKey('SessionStart') -and $hooks['SessionStart']) { $existing = @($hooks['SessionStart']) }

            $already = $false
            foreach ($grp in $existing) {
                foreach ($h in @($grp.hooks)) {
                    if ($h -and $h.command -and "$($h.command)" -like '*winclean-notify*') { $already = $true }
                }
            }

            if ($already) {
                Write-Host '  hook    already registered' -ForegroundColor DarkGray
            } else {
                $entry = [pscustomobject] @{ hooks = @([pscustomobject] @{ type = 'command'; command = $cmdLine }) }
                $hooks['SessionStart'] = @($existing) + $entry
                $settings['hooks'] = [pscustomobject] $hooks

                # Back up before touching the user's settings.
                if (Test-Path -LiteralPath $settingsPath) {
                    Copy-Item -LiteralPath $settingsPath -Destination "$settingsPath.bak" -Force
                }
                ([pscustomobject] $settings) | ConvertTo-Json -Depth 12 |
                    Set-Content -LiteralPath $settingsPath -Encoding utf8
                Write-Host "  hook    SessionStart registered in $settingsPath" -ForegroundColor Green
            }
        }
    }
}

if ($AddToPath) {
    $toolsDir = Join-Path $source 'tools'
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($current -notlike "*$toolsDir*") {
        if ($PSCmdlet.ShouldProcess($toolsDir, 'Add to user PATH')) {
            [Environment]::SetEnvironmentVariable('Path', "$current;$toolsDir", 'User')
            Write-Host "  PATH    added $toolsDir (restart your shell to pick it up)" -ForegroundColor Green
        }
    } else {
        Write-Host "  PATH    already contains $toolsDir" -ForegroundColor DarkGray
    }
}

Write-Host ''
if ($installed -gt 0) {
    Write-Host "Installed for $installed agent location(s)$(if ($useLink) { ' as symlinks - git pull updates them all' })." -ForegroundColor Cyan
    Write-Host 'Verify with:' -ForegroundColor DarkGray
    Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$source\tools\tests\Test-WinClean.ps1`"" -ForegroundColor DarkGray
    Write-Host 'First scan (deletes nothing):' -ForegroundColor DarkGray
    Write-Host "  `"$source\tools\win-clean.cmd`"" -ForegroundColor DarkGray
} else {
    Write-Host 'Nothing installed.' -ForegroundColor Yellow
}
