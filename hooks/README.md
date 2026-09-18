# Notification hooks

Two ways to be told a cleanup is worth running. Both use the same cheap probe: one volume
query plus a small JSON state file, no rule database, no file enumeration. Neither ever
deletes anything.

The probe prints **nothing** unless a clean is actually due — low free space, or a long
gap since the last clean on a drive that is not comfortably empty.

## 1. Claude Code session hook

`install.ps1 -AddHook` writes this into `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\.claude\\hooks\\winclean-notify.ps1\""
          }
        ]
      }
    ]
  }
}
```

When a clean is due, one line is added to the session context:

```
[disk] Disk cleanup may be worth running - 11.4% free on C:. Run /win-clean to see what can be freed, or /win-clean snooze to mute for 30 days.
```

Nothing is printed otherwise, so a healthy machine costs zero tokens.

## 2. Windows scheduled task

For a notification outside Claude entirely:

```powershell
$probe = "$env:USERPROFILE\.claude\hooks\winclean-notify.ps1"
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$probe`""
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 9am
Register-ScheduledTask -TaskName 'ai-win-clean notify' -Action $action -Trigger $trigger -Description 'Check whether a disk cleanup is due'
```

To have the task also refresh the rule database (a conditional request, so ~0 bytes when
nothing changed upstream), point it at the CLI instead:

```powershell
-Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$env:USERPROFILE\.claude\skills\windows-junk-cleanup\tools\Invoke-WinClean.ps1`" -CheckUpdate -Output Brief"
```

## Tuning

| Setting | Default | Change with |
|---|---|---|
| Free-space floor | 15% | `-MinFreePercent 25` |
| Days between prompts | 30 | `-MinDaysSinceClean 14` |
| Mute temporarily | — | `win-clean.cmd -SnoozeDays 30` |

State lives in `%LOCALAPPDATA%\ai-win-clean\state.json`. Running a clean with `-Apply`
resets the timer and clears any snooze.

## Deliberately not a scheduled *clean*

These mechanisms notify. They never run `-Apply` on a timer.

Unattended deletion removes the step that makes this safe — a human looking at what is
about to go. The failure mode is silent and delayed: a rule starts matching something it
should not, and nobody finds out for weeks. If you still want it, schedule
`-Apply -Force -OlderThanDays 7 -LogPath` yourself, with an audit log, and read that log.
