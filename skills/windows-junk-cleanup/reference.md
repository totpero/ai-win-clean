# Reference

Full parameter semantics, the winapp2 file format, and the safety model.
For the workflow, see `SKILL.md`.

## Invocation

All three entry points take identical arguments:

| Entry point | Use from |
|---|---|
| `tools/win-clean.cmd` | cmd.exe, PowerShell, any agent shelling out on Windows |
| `tools/win-clean.sh` | bash, Git Bash, WSL, MSYS |
| `tools/Invoke-WinClean.ps1` | PowerShell directly (`-File` or dot-sourced) |

Requires Windows PowerShell 5.1 (present on every Windows 10/11 install) or PowerShell 7+.
No modules to install, no compilation.

### Passing multiple values

`-Section`, `-ExcludeSection`, `-Entry`, `-ExcludeEntry` and `-Protect` take lists.
**Comma-separate them**, quoted as a single argument:

```
-Section 'Google Chrome Web Browser,Microsoft Edge Web Browser'
```

The `'A','B'` form works too, but only when the script is called from inside PowerShell.
Launched via `-File` — which is what the shims and any agent shelling out must use —
PowerShell hands the script the single string `A,B` and never builds an array. The script
therefore splits on commas itself, so both forms behave identically everywhere.

The consequence is that a comma is always a separator and cannot appear inside a value,
including in a `-Protect` path.

## Parameters

### Acting

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `-Apply` | switch | off | Actually delete. Without it the script only reports. |
| `-Force` | switch | off | Skip the `YES` confirmation prompt. No effect without `-Apply`. |
| `-EmptyRecycleBin` | switch | off | Empty the Recycle Bin via `Clear-RecycleBin`. Independent of `-Apply` scope. |

Without `-Force`, `-Apply` prints the totals and requires the literal string `YES`.
Agents running unattended need `-Force`, which is why approval belongs in the conversation
before the command runs.

### Choosing rules

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `-RuleSet` | `All` \| `Winapp2` \| `System` | `All` | Which rule sources to load. |
| `-Section` | string[] | all | Only these categories. Wildcards allowed. |
| `-ExcludeSection` | string[] | none | Skip these categories. |
| `-Entry` | string[] | all | Only entries whose name matches. Wildcards allowed. |
| `-ExcludeEntry` | string[] | none | Skip entries whose name matches. |
| `-Aggressive` | switch | off | Include built-in rules with a real trade-off. |
| `-IncludeWarnings` | switch | off | Include entries carrying a `Warning=`. |
| `-IncludeRegistry` | switch | off | Also clean `RegKey` targets. |

`-Section` matches the category (`Google Chrome Web Browser`, `Windows System`, `Games`).
`-Entry` matches the rule name (`Google Chrome Caches *`). `-ListSections` and
`-ListEntries` print what is available without touching the filesystem.

### Filtering files

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `-OlderThanDays` | int | `0` (no filter) | Only files whose `LastWriteTime` is older than this. |
| `-Protect` | string[] | none | Extra paths to protect, on top of the built-in list. |
| `-MinDepth` | int 1–10 | `1` | Minimum path depth below the drive root before a target is eligible. |

`-OlderThanDays 1` is strongly recommended whenever temp directories are in scope:
installers mid-run and unsaved scratch files live there.

### Database

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `-DatabasePath` | string | `%LOCALAPPDATA%\ai-win-clean\winapp2.ini` | Which winapp2 file to read. |
| `-UpdateDatabase` | switch | off | Force a refresh before running. Honoured for every `-RuleSet`. |
| `-CheckUpdate` | switch | off | Report update status and exit. With `-UpdateDatabase`, updates then reports, without scanning. |
| `-RollbackDatabase` | switch | off | Restore the previous database and exit. |
| `-NoUpdate` | switch | off | Never refresh automatically. An explicit `-UpdateDatabase` still wins. |
| `-MaxDatabaseAgeDays` | int | `14` | Auto-refresh when the local copy is older than this. `0` disables. |
| `-Flavor` | `NonCCleaner` \| `CCleaner` \| `BleachBit` | `NonCCleaner` | Which variant to download. |

`NonCCleaner` is the right variant for this tool: it has `Detect`/`DetectFile` resolved
and omits CCleaner-specific directives.

#### How updating works

1. **Conditional request.** The ETag from the last download is sent as `If-None-Match`.
   `raw.githubusercontent.com` honours it, so an unchanged database returns `304` and
   transfers zero bytes instead of 1.8 MB. That is what makes an automatic refresh cheap
   enough to leave switched on.
2. **Validate before replacing.** The payload must exceed 10 KB, contain at least 100
   section headers, and not collapse to under half the current entry count. An HTML error
   page, a captive-portal login, or a truncated transfer is rejected and the existing
   database is left untouched.
3. **Keep one generation.** The previous file is copied to `winapp2.ini.bak` before the
   new one lands, so `-RollbackDatabase` can undo a bad release.
4. **Degrade, never block.** An unreachable network on a machine that already has a
   database reports `Offline` and the run continues. Only a missing database *and* a
   failed download is fatal.

Status values: `Updated`, `Current` (304, nothing transferred), `Offline`, `Rejected`,
`Failed`.

State lives in `%LOCALAPPDATA%\ai-win-clean\state.json` — ETag, version, entry count,
flavour, download and check timestamps, plus the last-clean timestamp and any snooze.

### Notification

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `-Status` | switch | off | Report whether a clean is due, and exit. Scans nothing. |
| `-SnoozeDays` | int | — | Mute the due-status prompt for this many days, and exit. |

`-Status` reads one volume and one small JSON file — no rule database, no file
enumeration — so it is cheap enough to run from a hook on every session. A clean is
reported due when free space is under 15%, or when the machine has not been cleaned in 30
days *and* is under 40% free. Running `-Apply` resets the timer and clears any snooze.

See `hooks/README.md` for the SessionStart hook and the scheduled-task variant. Nothing is
ever deleted on a schedule: the notification exists so a human still sees the scan first.

### Output

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `-Output` | `Text` \| `Json` \| `Csv` | `Text` | Report format. |
| `-ReportPath` | string | none | Also write the report to this file. |
| `-LogPath` | string | none | Append a JSON-lines audit record per entry deleted. |
| `-Top` | int | `25` | Entries shown in the text report. `0` shows all. |
| `-Quiet` | switch | off | Suppress progress and status chatter. |
| `-ListSections` / `-ListEntries` | switch | off | Print available rules and exit. |

### Report fields

| Field | Meaning |
|---|---|
| `Mode` | `dryrun` or `applied`. Check this before claiming anything was deleted. |
| `TotalBytes` / `TotalSize` | What the scan found. Deduplicated across overlapping rules. |
| `TotalFiles` / `EntriesMatched` | Files selected, and rules that matched anything. |
| `EntriesDetected` | Rules whose application is installed, so they were scanned. The gap between this and `EntriesMatched` is rules that found nothing — those are omitted from `Entries`, so a "missing" target may simply be empty. |
| `AdminLimited` | Rules that declare they need elevation and ran without it. Non-zero means the totals are a floor, not a measurement. Only the built-in ruleset declares this; winapp2 entries cannot. |
| `Deleted` / `BytesFreed` / `SizeFreed` | Actually removed. Zero in a dry run. |
| `FailedCount` | Files that could not be deleted, almost always locked by a running app. |
| `BlockedCount` / `Blocked` | Targets the safety layer refused, each with a reason. |
| `SkippedWarnings` | Entries held back because they carry a caveat. |
| `Elevated` | Whether the run had admin rights. System targets need it. |
| `RulesLoaded` / `RulesSelected` | Rules available, and rules left after filtering. |

## Exit behaviour

The script does not set a non-zero exit code for locked files or blocked targets — both
are normal. It throws only on unrecoverable conditions: a missing database that cannot be
downloaded, or an unreadable `-DatabasePath`.

## winapp2.ini format

Source: <https://github.com/MoscaDotTo/Winapp2> (CC-BY-SA-4.0). ~4,000 entries.

```ini
[Google Chrome Caches *]
Section=Google Chrome Web Browser
DetectFile=%LocalAppData%\Google\Chrome\User Data
FileKey1=%LocalAppData%\Google\Chrome\User Data\*\*Cache*|*|REMOVESELF
FileKey2=%LocalAppData%\Google\Chrome\User Data\*|*.ldb;CURRENT;LOCK
RegKey1=HKCU\Software\Google\Chrome\BLBeacon|failed_count
ExcludeKey1=FILE|%LocalAppData%\Google\Chrome\User Data\|Local State
Warning=Signs you out of open sessions.
```

### Keys

| Key | Meaning |
|---|---|
| `Section` | Named category. Preferred over `LangSecRef` when both are present. |
| `LangSecRef` | Numeric CCleaner category id (`3021` Applications … `3029` Google Chrome). |
| `Detect`, `Detect1..N` | Registry key that must exist for the entry to apply. |
| `DetectFile`, `DetectFile1..N` | File or directory that must exist. |
| `DetectOS` | OS version range, `min|max`, either side optional. |
| `SpecialDetect` | Named well-known detector (`DET_CHROME`, `DET_MOZILLA`, …). |
| `Default` | Whether the entry is enabled by default. |
| `Warning` | Human-readable caveat. Entries carrying one are skipped unless `-IncludeWarnings`. |
| `Risk` | *ai-win-clean extension*, built-in ruleset only. `Normal` or `Aggressive`. |
| `NeedsAdmin` | *ai-win-clean extension*, built-in ruleset only. Feeds the `AdminLimited` count. |
| `FileKey1..N` | A file deletion target. |
| `RegKey1..N` | A registry deletion target. |
| `ExcludeKey1..N` | Something to protect from this entry's own rules. |

Detection keys are **OR**'d: any one match means "installed". An entry with no detection
keys applies unconditionally — typical for core Windows entries.

### FileKey

```
FileKey1=<path>|<filter>[|FLAG]
```

- `<path>` — may contain `%Token%` and `*`/`?` wildcards **in any component**, not only
  the last: `%LocalAppData%\Google\Chrome\User Data\*\*Cache*` is valid and common.
- `<filter>` — `;`-separated wildcard patterns: `*.ldb;CURRENT;LOCK;MANIFEST-*`
- `FLAG` — one of:

| Flag | Behaviour |
|---|---|
| *(absent)* | Matching files directly in the directory. No recursion. |
| `RECURSE` | Matching files in the directory and all subdirectories. Directories are kept. |
| `REMOVESELF` | Everything beneath the directory, **and the directory itself**. The filter is ignored. |

### RegKey

```
RegKey1=<hive>\<path>            delete the whole key
RegKey1=<hive>\<path>|<value>    delete just that value
```

Hives: `HKCU`, `HKLM`, `HKCR`, `HKU`, `HKCC` and their long forms. On 64-bit Windows the
`WOW6432Node` redirected view is checked as well as the native path. Only acted on with
`-IncludeRegistry`.

### ExcludeKey

```
ExcludeKey1=FILE|<dir>\|<filter>    protect named files in exactly that directory
ExcludeKey1=PATH|<dir>\|<filter>    protect that directory and everything beneath it
ExcludeKey1=REG|<hive>\<path>       protect a registry key
```

The trailing backslash before the separator is part of the real format.

### Environment tokens

| Token | Expands to |
|---|---|
| `%LocalAppData%` | `C:\Users\<user>\AppData\Local` |
| `%AppData%` | `C:\Users\<user>\AppData\Roaming` |
| `%LocalLowAppData%` | `C:\Users\<user>\AppData\LocalLow` |
| `%UserProfile%` | `C:\Users\<user>` |
| `%Documents%` | The real Documents folder, including redirected/OneDrive locations |
| `%ProgramFiles%` | **Both** `Program Files` and `Program Files (x86)` |
| `%CommonProgramFiles%` | Both Common Files locations |
| `%ProgramData%`, `%CommonAppData%` | `C:\ProgramData` |
| `%WinDir%`, `%SystemRoot%` | `C:\Windows` |
| `%SystemDrive%` | `C:` |
| `%Public%` | `C:\Users\Public` |
| `%Temp%`, `%Tmp%` | The current user's temp directory |
| `%UserName%`, `%ComputerName%` | Literal values |

`%ProgramFiles%` expanding to both locations means one FileKey can produce two base paths.
A token that cannot be resolved causes the whole path to be **dropped**, never partially
expanded — `%Unknown%\Cache` must not become `\Cache`, which would resolve against the
current drive root.

## Safety model

The database is fetched over the network and its ~14,000 FileKeys drive file deletion.
It is treated as untrusted input throughout.

`Test-WinCleanTarget` in `tools/lib/Safety.ps1` gates every resolved directory, before
enumeration and again immediately before deletion. It refuses:

| Condition | Rationale |
|---|---|
| Drive root (`C:\`, `\\server\share`) | A mistake here is unbounded. Costs a handful of stray log files; worth it. |
| Unresolved `%Token%` | An empty variable would collapse the path to a drive root. |
| Not fully qualified | Relative paths resolve against the current directory. |
| Illegal path character (`\| < > "`) | Indicates a malformed database line. The live database contains one. |
| Path depth below `-MinDepth` | Blunt backstop against over-broad targets. |
| `REMOVESELF` on a protected directory | Would remove the directory itself. |
| Wholesale filter (`*`) in a protected directory | Would empty it. |
| `RECURSE` inside a protected directory | Would empty it depth-first. |
| `RECURSE`/`REMOVESELF` from an ancestor of a protected path | Would descend into it. |

Protected paths cover OS roots (`%WinDir%` and its critical subdirectories,
`%ProgramFiles%`, `%ProgramData%`, `C:\Users`, `C:\Recovery`), profile roots
(`%UserProfile%`, `%AppData%`, `%LocalAppData%`, `%Public%`) and user data folders
(Documents, Desktop, Downloads, Pictures, Videos, Music, OneDrive, Dropbox and friends).
User folders are resolved through `[Environment]::GetFolderPath` as well as by name, so
Folder Redirection and OneDrive-backed Documents are covered.

**Deliberately still allowed**, because real rules depend on it:

- a *specific* filter directly inside a protected directory — `%WinDir%|*.log`
- any target deeper inside a protected path — `%UserProfile%\Documents\Proteus\logs`

Junctions and symlinks are never traversed or deleted through: a reparse point is how a
scoped delete escapes its root, and `%LocalAppData%\Application Data` is a
self-referential junction present on every Windows install.

## Built-in system ruleset

`tools/lib/SystemRules.ps1`, written in winapp2's own dialect and parsed by the same
parser, so there is one engine and one safety gate.

"Needs flag" is what you must pass for the rule to run at all. Three otherwise-ordinary
rules carry a `Warning=` and are therefore gated behind `-IncludeWarnings` — they are
among the most commonly asked for, so check this column before concluding a rule is missing.

| Rule | Risk | Admin | Needs flag |
|---|---|---|---|
| Windows Temporary Files | Normal | no | — |
| Windows Update Cache | Normal | **yes** | `-IncludeWarnings` |
| Windows Update Logs (CBS, DISM, Panther) | Normal | **yes** | — |
| Windows Error Reporting | Normal | no | — |
| Crash Dumps | Normal | no | `-IncludeWarnings` |
| Thumbnail and Icon Cache | Normal | no | `-IncludeWarnings` |
| Font Cache | Normal | **yes** | — |
| DirectX / NVIDIA / AMD / Intel Shader Cache | Normal | no | — |
| Internet Explorer and WebView Cache | Normal | no | — |
| Windows Installer Orphans | Normal | **yes** | — |
| Delivery Optimization Cache | Normal | **yes** | — |
| Defender Scan History | Normal | **yes** | — |
| Windows Setup Leftovers (`Windows.old`) | Aggressive | **yes** | `-Aggressive` + `-IncludeWarnings` |
| Prefetch Data | Aggressive | **yes** | `-Aggressive` + `-IncludeWarnings` |
| Event Logs | Aggressive | **yes** | `-Aggressive` + `-IncludeWarnings` |

`-ListEntries` prints this live, including a `SkippedByDefault` column, and deliberately
ignores the warning and aggressive filters so nothing is invisible in the listing.

Deliberately excluded, with reasons:

- **Recycle Bin** — the user's own files and their only undo path. `-EmptyRecycleBin`.
- **`pagefile.sys` / `hiberfil.sys`** — system configuration, not junk. Removing hibernation
  is a settings change the user should make.
- **System Restore points / VSS shadow copies** — the machine's rollback path.
- **`%LocalAppData%\Packages\*\LocalCache` wholesale** — holds real Store-app data.
- **Registry "optimisation"** — frees no space and risks breakage.

## Layout

```
skills/windows-junk-cleanup/
  SKILL.md                     workflow and contract
  reference.md                 this file
  tools/
    Invoke-WinClean.ps1        CLI entry point
    win-clean.cmd              cmd shim
    win-clean.sh               bash/WSL shim
    lib/
      Safety.ps1               protected paths and the gate
      Paths.ps1                token expansion, wildcard resolution
      Winapp2.ps1              database parser
      Engine.ps1               detection, scanning, removal
      SystemRules.ps1          built-in Windows ruleset
    tests/
      Test-WinClean.ps1        138 sandbox tests
```

## Attribution

Cleaning rules come from [winapp2](https://github.com/MoscaDotTo/Winapp2), licensed
**CC-BY-SA-4.0**. Redistributing the database, or a derivative of it, requires the same
licence and attribution to the winapp2 project. The tool downloads the database at
runtime rather than vendoring it.

The parser, safety model, built-in ruleset and CLI are original to this project. No code
or data from any other cleaning tool is used.
