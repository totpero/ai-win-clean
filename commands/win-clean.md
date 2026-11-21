---
description: Scan Windows for junk files and report what can be freed (deletes nothing unless you approve)
argument-hint: "[status | apply | update | snooze | claude | section <name>]"
---
<!--
  No allowed-tools on purpose. Claude Code's Bash patterns are prefix-based
  (Bash(cmd:*)); a leading wildcard never matches, and the install path differs per
  machine so no fixed prefix would work either. More to the point, this command can
  delete files - the normal permission prompt is the right behaviour, not something
  to pre-approve.
-->

<!--
  Pass `scan` explicitly if you want to be unambiguous; no argument does the same thing.
-->


Run the Windows junk cleaner. Arguments: `$ARGUMENTS`

**Keep this cheap.** Run one command, report the result in a few lines, stop. Do not
read the skill files, do not explore the filesystem, do not write a script. `-Output Brief`
already returns a summary — pass it through, do not re-derive it.

Pick the single command that matches the argument:

| Argument | Command |
|---|---|
| *(empty)* or `scan` | `win-clean.cmd -Output Brief -OlderThanDays 1` |
| `status` | `win-clean.cmd -Status` |
| `update` | `win-clean.cmd -UpdateDatabase -CheckUpdate` |
| `apply` | `win-clean.cmd -Output Brief -OlderThanDays 1` **first**, show it, ask for approval, then `-Apply -Force` |
| `section <name>` | `win-clean.cmd -Output Brief -Section '<name>'` |
| `snooze` | `win-clean.cmd -SnoozeDays 30` |
| `rollback` | `win-clean.cmd -RollbackDatabase` |
| `claude` or `storage` | No script. Follow `claude-storage.md` in the skill folder (see below) |

**`claude` / `storage`** frees the Claude app's own storage and is the one argument that does
not run `win-clean.cmd`. Read the skill's `claude-storage.md` and follow it: report with
`get_storage_usage`, then clean the worktrees of inactive sessions with `clean_up_worktrees`
and discard an archived session's leftover worktree with `discard_kept_worktree` only when
the user names it, then point to Settings › This computer › Storage › Clear cache for app
caches and logs. Never delete anything inside the app's data folder by script, and get an
explicit yes before each destructive step.

The executable is `win-clean.cmd` in the skill's `tools` directory — typically
`%USERPROFILE%\.claude\skills\windows-junk-cleanup\tools\win-clean.cmd`.

**`apply` deletes permanently, with no undo and nothing sent to the Recycle Bin.** Never
pass `-Apply` in the same step as the scan: show the scan output, get an explicit yes for
that scope, and only then run it with `-Force`.

If the output says `NOTE not elevated`, mention that the figure is a floor and that an
elevated shell would see more. Otherwise just report the number and the top few entries.
