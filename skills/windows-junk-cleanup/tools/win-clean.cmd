@echo off
REM ---------------------------------------------------------------------------
REM win-clean.cmd - cmd.exe entry point for ai-win-clean.
REM
REM Lets any agent or shell invoke the cleaner without knowing about PowerShell
REM execution policy. All arguments are forwarded verbatim.
REM
REM   win-clean.cmd                                 dry run, reports only
REM   win-clean.cmd -Output Json -Quiet             machine-readable preview
REM   win-clean.cmd -Apply -Force -OlderThanDays 1  unattended clean
REM ---------------------------------------------------------------------------

setlocal
set "SCRIPT_DIR=%~dp0"

where pwsh.exe >nul 2>&1
if %ERRORLEVEL%==0 (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Invoke-WinClean.ps1" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Invoke-WinClean.ps1" %*
)

exit /b %ERRORLEVEL%
