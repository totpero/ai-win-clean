<div align="center">

<img src="assets/logo.svg" alt="ai-win-clean" width="128" height="128">

# ai-win-clean

**🧹 An AI agent skill that reclaims Windows disk space from the command line.**

Scans and reports by default. Deletes only when you say so.

```bash
npx skills add totpero/ai-win-clean
```

[![Agent Skill](https://img.shields.io/badge/agent-skill-0EA5E9?style=flat-square)](https://www.skills.sh)
[![Rules](https://img.shields.io/badge/winapp2-~4%2C000%20rules-38BDF8?style=flat-square)](https://github.com/MoscaDotTo/Winapp2)
[![Tests](https://img.shields.io/badge/tests-138%20passing-22C55E?style=flat-square)](#tests)
[![License](https://img.shields.io/badge/license-MIT-64748B?style=flat-square)](LICENSE)

</div>

---

Driven by [winapp2](https://github.com/MoscaDotTo/Winapp2) — a community-maintained
database of ~4,000 application cleaning rules — plus a built-in ruleset for the core
Windows caches winapp2 does not cover.

Works with any agent that supports [Agent Skills](https://agentskills.io) (Claude Code,
Codex, Cursor, Windsurf, Copilot, OpenCode), and as a plain CLI with no agent at all.

> **Windows only.** The engine is PowerShell and targets Windows paths, services and the
> registry; there is nothing useful here on macOS or Linux.

## Why

Ask an AI agent to "clean up my C: drive" and it writes a bespoke `Remove-Item` script:
a dozen hard-coded paths, different every time, following junctions straight out of its
own allowlist, with nothing machine-readable at the end.

This replaces that with one audited tool: ~14,000 rules, protected paths refused by
construction, deterministic output, 138 tests.

## Install

Via the [skills.sh](https://www.skills.sh) package manager — installs into whichever
agents you have:

```bash
npx skills add totpero/ai-win-clean
```

Or clone, which additionally gives you the `/win-clean` slash command and the hook:

```powershell
git clone https://github.com/totpero/ai-win-clean
cd ai-win-clean
.\install.ps1 -AddCommand          # skill + /win-clean slash command
.\install.ps1 -Agent All -All      # every agent, + hook, + PATH
```

| Flag | Adds |
|---|---|
| *(none)* | The skill itself |
| `-AddCommand` | A `/win-clean` slash command in Claude Code |
| `-AddHook` | A SessionStart hook that mentions cleanup only when it's due |
| `-AddToPath` | `win-clean` on your PATH |
| `-All` | All of the above |

Symlinks are used when possible, so `git pull` updates every installed agent at once.

No dependencies. Windows PowerShell 5.1 (on every Windows 10/11 box) or PowerShell 7+.

## Use

```powershell
# Preview. Deletes nothing. This is the default.
skills\windows-junk-cleanup\tools\win-clean.cmd

# Machine-readable, for agents
skills\windows-junk-cleanup\tools\win-clean.cmd -Output Json -Quiet

# Delete, after you have looked at the preview
skills\windows-junk-cleanup\tools\win-clean.cmd -Apply -OlderThanDays 1
```

From bash or WSL, use `win-clean.sh` with identical arguments. In Claude Code, type
`/win-clean` (or `/win-clean status`, `/win-clean update`, `/win-clean apply`).

`-Output Brief` is the cheap path — a total plus the top five entries, so an agent doesn't
pay to read 140 rows it would only summarise anyway.

```
     Size Files Category                  Name
     ---- ----- --------                  ----
  3.44 GB  4407 Applications              Microsoft NuGet Package Cache *
  2.55 GB 11466 Windows                   Windows Temporary Files *
739.26 MB     7 Applications              Squirrel.Windows *
704.19 MB   508 Windows System            Windows Installer Orphans
441.02 MB   979 Windows                   Windows Event Logs *
186.76 MB   307 Google Chrome Web Browser Google Chrome Caches *

--------------------------------------------------------------
  Would free:  9.81 GB across 43587 files in 141 entries
  DRY RUN - nothing was deleted. Re-run with -Apply to act on this.
  Blocked by safety rules: 9 targets
```

## Staying current

The rule database refreshes itself when the local copy is over 14 days old. The check is a
conditional request, so an unchanged database costs a `304` and **zero bytes** rather than
re-downloading 1.8 MB — which is what makes leaving it enabled reasonable.

```powershell
win-clean.cmd -CheckUpdate                  # is there anything new?
win-clean.cmd -UpdateDatabase -CheckUpdate  # update, don't scan
win-clean.cmd -RollbackDatabase             # undo a bad update
win-clean.cmd -NoUpdate                     # never auto-refresh
```

A download is validated before it replaces anything: an HTML error page, a truncated
transfer, or a sudden collapse in entry count is rejected and the existing database is
kept. The previous copy is retained for rollback. If the network is down, the run
continues on what's already there and says so.

## Being told when to clean

```powershell
win-clean.cmd -Status        # instant: reads one volume and one JSON file, scans nothing
win-clean.cmd -SnoozeDays 30 # mute it
```

`install.ps1 -AddHook` registers a SessionStart hook that prints a single line **only**
when a clean is actually due, and nothing otherwise — so a healthy machine costs no
tokens. Details and a scheduled-task variant in [hooks/README.md](hooks/README.md).

Nothing is ever deleted on a schedule. The notification exists precisely so a human still
sees the scan first.

## Safety

Deleting is opt-in. So is every irreversible category:

| Off by default | Opt in with |
|---|---|
| Deleting anything at all | `-Apply` |
| Registry cleaning | `-IncludeRegistry` |
| Recycle Bin | `-EmptyRecycleBin` |
| `Windows.old`, Prefetch, Event Logs | `-Aggressive` |
| Rules carrying a caveat | `-IncludeWarnings` |

The rule database is downloaded over the network and its FileKeys drive file deletion, so
it is treated as untrusted input. Every resolved path is gated before enumeration and
again immediately before deletion. The tool refuses to operate on a drive root, to
wholesale-empty or remove a profile/OS/user-data root, to recurse from an ancestor of a
protected path, or to traverse a junction. Surgical targets *inside* protected
directories stay allowed, because real rules need them.

Details and rationale: [`reference.md`](skills/windows-junk-cleanup/reference.md).

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File skills\windows-junk-cleanup\tools\tests\Test-WinClean.ps1
```

138 tests build a throwaway filesystem and assert exactly which files are deleted and
which survive — flags, filters, exclusions, detection gating, age filters, mid-path
wildcards, junction traversal, protected paths, and that a dry run deletes nothing.

## Layout

```
install.ps1
commands/win-clean.md          /win-clean slash command
hooks/winclean-notify.ps1      cheap "is a clean due?" probe
skills/windows-junk-cleanup/
  SKILL.md                     what an agent reads
  reference.md                 parameters, winapp2 format, safety model
  tools/
    Invoke-WinClean.ps1        CLI
    win-clean.cmd / .sh        cmd and bash/WSL shims
    lib/                       Safety, Paths, Winapp2, Engine,
                               SystemRules, Database, Status
    tests/                     138 sandbox tests
```

## Licence

Tool: MIT (see [LICENSE](LICENSE)).

Cleaning rules: [winapp2](https://github.com/MoscaDotTo/Winapp2), **CC-BY-SA-4.0**.
The database is downloaded at runtime rather than vendored; redistributing it or a
derivative requires the same licence and attribution to the winapp2 project.
