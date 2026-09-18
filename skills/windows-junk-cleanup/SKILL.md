---
name: windows-junk-cleanup
description: 'Use when a Windows machine needs disk space reclaimed or junk removed - the C: drive is full or nearly full, "clean up my PC", browser and application caches, temp files, Windows Update leftovers, crash dumps, log files, thumbnail cache, or a request for CCleaner-style cleaning. Also use when asked what is consuming disk space before deleting anything.'
license: MIT
---

# Windows Junk Cleanup

## Fast Path

Most requests need one command and nothing else. Run it, report the output, stop — do not
read the rest of this file, explore the filesystem, or write a script.

```bash
skills/windows-junk-cleanup/tools/win-clean.cmd -Output Brief -OlderThanDays 1
```

`-Output Brief` returns a total plus the top five entries, already summarised. Pass it
through; do not re-derive it. Read on only for `-Apply`, filtering, or troubleshooting.

| Ask | Command |
|---|---|
| "is a cleanup needed?" | `win-clean.cmd -Status` (instant, scans nothing) |
| "what can I free?" | `win-clean.cmd -Output Brief -OlderThanDays 1` |
| "update the rules" | `win-clean.cmd -UpdateDatabase -CheckUpdate` |
| "stop reminding me" | `win-clean.cmd -SnoozeDays 30` |

## Overview

Reclaims disk space on Windows by deleting regenerable junk: caches, temp files, logs,
crash dumps and update leftovers. Driven by **winapp2.ini** — a community-maintained
database of ~4,000 application cleaning rules — plus a built-in ruleset for core Windows
caches that winapp2 does not cover.

**Core principle: preview, then delete.** The tool reports by default and only deletes
when you pass `-Apply`. Everything else follows from that.

Do not hand-roll `Remove-Item` cleanup scripts. A bespoke script covers a dozen paths,
follows junctions out of its own allowlist, and is different every time you write it.
This tool applies ~14,000 audited rules, refuses protected paths by construction, and
produces the same result every run.

## When to Use

- "My C: drive is full", "Windows feels slow", "free up space"
- Clearing browser, application, or shader caches
- Windows Update / `SoftwareDistribution` / Delivery Optimization leftovers
- Crash dumps, WER reports, CBS and DISM logs, `Windows.old`
- Any request for CCleaner/BleachBit-style cleaning
- Finding out *what* is using space before deciding anything

**Do not use for:** uninstalling software, deleting user documents, registry "optimisation",
disabling hibernation/pagefile, or `DISM /StartComponentCleanup` (run that separately —
it takes 10–40 minutes and pegs the disk).

## The Contract

Run these steps in order. Do not collapse them.

1. **Scan.** Run with no `-Apply`. Nothing is deleted.
2. **Show the user** the total and the top entries by size.
3. **Get explicit approval** for the specific scope you are about to delete.
4. **Apply** with `-Apply`, adding `-Force` only because approval already happened in step 3.

`-Apply` permanently deletes files. There is no undo and nothing goes to the Recycle Bin.
Approval in step 3 covers the scope you showed — not a broader one you add afterwards.

```bash
# 1. Scan (dry run, deletes nothing)
skills/windows-junk-cleanup/tools/win-clean.cmd -Output Json -Quiet
```

```bash
# 4. Apply, after the user has approved what step 1 reported
skills/windows-junk-cleanup/tools/win-clean.cmd -Apply -Force -OlderThanDays 1 -LogPath clean.jsonl
```

Use `win-clean.cmd` from cmd/PowerShell, `win-clean.sh` from bash/WSL, or call
`tools/Invoke-WinClean.ps1` directly. All three take identical arguments.

## Quick Reference

| Need | Parameter |
|---|---|
| Actually delete (otherwise it only reports) | `-Apply` |
| Skip the interactive confirmation | `-Force` |
| Leave recently-touched files alone | `-OlderThanDays 1` |
| Machine-readable output | `-Output Json -Quiet` |
| Limit to categories | `-Section 'Google Chrome Web Browser,Windows*'` |
| Limit to named entries | `-Entry '*Cache*'` |
| Exclude something | `-ExcludeSection`, `-ExcludeEntry` |
| Built-in Windows rules only | `-RuleSet System` |
| winapp2 database only | `-RuleSet Winapp2` |
| Include `Windows.old`, Prefetch, Event Logs | `-Aggressive` |
| Include entries carrying a caveat | `-IncludeWarnings` |
| Also clean registry MRU values | `-IncludeRegistry` |
| Empty the Recycle Bin | `-EmptyRecycleBin` |
| Protect extra paths | `-Protect 'D:\Keep'` |
| Audit trail of deletions | `-LogPath clean.jsonl` |
| Refresh the rule database | `-UpdateDatabase` |
| Check for updates without applying | `-CheckUpdate` |
| Undo a bad database update | `-RollbackDatabase` |
| Skip the automatic refresh | `-NoUpdate` |
| Is a cleanup due? (no scan) | `-Status` |
| Mute cleanup reminders | `-SnoozeDays 30` |
| See categories / entries without scanning | `-ListSections`, `-ListEntries` |

## Keeping the Rules Current

The database refreshes itself when the local copy is older than 14 days
(`-MaxDatabaseAgeDays`, `0` disables it). The check is a conditional request, so when
nothing changed upstream it costs a `304` and transfers no bytes — which is what makes
leaving it on reasonable.

A refresh never puts a run at risk. The download is validated before it replaces
anything — an HTML error page, a truncated file, or a sudden collapse in entry count is
rejected and the existing database is kept. The previous copy is retained for
`-RollbackDatabase`. If the network is unreachable the run continues on the existing
database and says so.

## Being Told When to Clean

`-Status` answers "is a cleanup worth running?" from free space and the last-clean
timestamp. It scans nothing and returns immediately, so it is safe in a hook or prompt.

`install.ps1 -AddHook` registers a SessionStart hook that prints one line **only** when a
clean is actually due, and nothing otherwise. See `hooks/README.md`. Nothing is ever
deleted on a schedule — the notification exists so a human still sees the scan first.

Full parameter semantics and the winapp2 format: `reference.md`.

## Defaults That Matter

These are off unless you ask, because each is harder to undo than a cache file:

| Off by default | Why | Opt in with |
|---|---|---|
| Deleting anything | Preview first, always | `-Apply` |
| Registry cleaning | Registry edits are hard to reverse and free no space | `-IncludeRegistry` |
| Recycle Bin | Contains the user's own files; it is their undo buffer | `-EmptyRecycleBin` |
| `Windows.old`, Prefetch, Event Logs | Loses rollback / slows launches / loses diagnostics | `-Aggressive` |
| Entries with a `Warning=` | The rule itself flags a caveat | `-IncludeWarnings` |

**Commonly-asked-for targets that need `-IncludeWarnings`:** `Crash Dumps`,
`Windows Update Cache`, `Thumbnail and Icon Cache`. If a user names one of these and the
scan returns nothing, this is why. `-ListEntries` shows every rule with a
`SkippedByDefault` column, so check there rather than assuming a rule does not exist.

Run elevated for system targets (`SoftwareDistribution`, CBS logs, `Windows.old`). An
unelevated run reads only part of those paths and reports no error for the rest, so a
small number can mean "genuinely small" or "mostly invisible" — `AdminLimited` tells you
which.

## Reading the JSON

```json
{ "Mode": "dryrun", "Elevated": false,
  "TotalBytes": 10530000000, "TotalSize": "9.81 GB", "TotalFiles": 43587,
  "RulesSelected": 152, "EntriesDetected": 149, "EntriesMatched": 141,
  "BlockedCount": 9, "AdminLimited": 5,
  "Entries": [ { "Name": "Google Chrome Caches *", "Category": "Google Chrome Web Browser",
                 "Files": 307, "Bytes": 195830000, "Size": "186.76 MB" } ] }
```

| Field | What it tells you |
|---|---|
| `Mode` | `dryrun` or `applied`. Check this before reporting anything as deleted. |
| `AdminLimited` | Rules needing elevation that ran without it. Non-zero ⇒ totals are a **floor**, not a measurement. Say so. |
| `EntriesDetected` vs `EntriesMatched` | The gap is rules that applied but found nothing. Those are absent from `Entries` — a target reported as missing may simply be empty. |
| `BlockedCount` | Targets the safety layer refused. Non-zero is normal and healthy. |
| `FailedCount` | Files that could not be deleted, almost always locked by a running app. |

## Passing Lists

Comma-separate multiple values: `-Section 'Google Chrome Web Browser,Microsoft Edge Web Browser'`.
Quoted-comma form (`'A','B'`) also works. A comma is always a separator, so it cannot
appear inside a value — including in `-Protect` paths.

## Safety Model

The rule database is downloaded from the internet and drives file deletion, so it is
treated as untrusted input. Every resolved path is checked before enumeration and again
immediately before deletion. The tool refuses to:

- operate on a drive root, or on any path with an unresolved `%Token%`
- wholesale-empty or remove `%UserProfile%`, `%AppData%`, `%LocalAppData%`, `%WinDir%`,
  `%ProgramFiles%`, `%ProgramData%`, `C:\Users`, or Documents/Desktop/Downloads/
  Pictures/Videos/Music/OneDrive (redirected locations included)
- recurse from a directory that is an ancestor of any protected path
- traverse or delete through a junction or symlink

A *specific* filter inside a protected directory is still allowed — `%WinDir%|*.log`
deletes stray logs from `C:\Windows` without endangering it. Deleting a named subfolder
deeper inside a protected path is allowed too; that is what most real rules do.

## Common Mistakes

| Mistake | Do this instead |
|---|---|
| Writing a custom `Remove-Item` script | Call this tool — more coverage, audited paths |
| `-Apply` before showing the user the scan | Scan, show, get approval, then apply |
| Cleaning browser caches while the browser is open | Close it first, or expect locked-file failures |
| Omitting `-OlderThanDays` on temp folders | Use `-OlderThanDays 1`; in-flight installers live there |
| Reporting "cleaned X GB" from a dry run | Check `Mode` is `applied` and read `BytesFreed` |
| Treating locked-file failures as errors | Normal — files an app has open; report the count |
| Assuming the tool emptied the Recycle Bin | It never does without `-EmptyRecycleBin` |
| Concluding a named rule "does not exist" from an empty scan | Check `-ListEntries`; it may be warning-gated |
| Quoting a size from an unelevated run as fact | If `AdminLimited` > 0, call it a floor and offer to re-run elevated |

## Verifying

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File skills/windows-junk-cleanup/tools/tests/Test-WinClean.ps1
```

138 tests build a throwaway filesystem and assert exactly which files are deleted and
which survive, including junction traversal, exclusions and protected paths. Run this
after changing anything under `tools/lib/`.
