#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# win-clean.sh - POSIX-shell entry point for ai-win-clean.
#
# For agents driving Windows through Git Bash, WSL or an MSYS shell. Arguments
# are forwarded verbatim to the PowerShell script.
#
#   ./win-clean.sh                                 dry run, reports only
#   ./win-clean.sh -Output Json -Quiet              machine-readable preview
#   ./win-clean.sh -Apply -Force -OlderThanDays 1   unattended clean
# ---------------------------------------------------------------------------
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="$script_dir/Invoke-WinClean.ps1"

# Under WSL the Windows-side script has to be addressed by its Windows path.
if command -v wslpath >/dev/null 2>&1 && [[ "$(uname -r)" == *[Mm]icrosoft* ]]; then
    target="$(wslpath -w "$target")"
fi

if command -v pwsh.exe >/dev/null 2>&1; then
    shell_exe=pwsh.exe
elif command -v powershell.exe >/dev/null 2>&1; then
    shell_exe=powershell.exe
elif command -v pwsh >/dev/null 2>&1; then
    shell_exe=pwsh
else
    echo "win-clean: no PowerShell found (need pwsh.exe or powershell.exe on PATH)." >&2
    exit 127
fi

exec "$shell_exe" -NoProfile -ExecutionPolicy Bypass -File "$target" "$@"
