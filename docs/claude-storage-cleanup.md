# Claude app storage cleanup

Tracking issue: [#1](https://github.com/totpero/ai-win-clean/issues/1)

## What it is

A second mode for the skill. The main scan reclaims Windows junk; this one reclaims space
used by the Claude desktop app itself: the git worktrees it makes for Code sessions, and
its caches and logs. They are different jobs, because the app's data folder holds sessions,
settings and sign-in and must not be cleaned by script.

So the Windows engine is untouched. The new mode is a workflow in
`skills/windows-junk-cleanup/claude-storage.md` that drives the app's own supported tools
(`get_storage_usage`, `clean_up_worktrees`, `discard_kept_worktree`), each destructive step
behind an explicit yes. Reached as `/win-clean claude`, or by asking.

## How a low-disk machine is steered to it

1. `hooks/winclean-notify.ps1` (SessionStart) prints one line when free space is low.
2. When the app's data folder exists, that line also says: run `/win-clean claude`.
3. `/win-clean` (no argument) runs the Windows scan; `/win-clean claude` runs this workflow.

Detection is `Get-WinCleanClaudeDataDir` in `tools/lib/Status.ps1`: a few `Test-Path`
calls, nothing measured, so the hook stays effectively free.

## What each part does

| Target | How | Notes |
|---|---|---|
| Worktrees of inactive sessions | `clean_up_worktrees` (30/60/90 days) | App shows an approval card; sessions, conversations and branches stay |
| Archived sessions that kept uncommitted work | `discard_kept_worktree`, one session at a time | Changes are unrecoverable; only when the user names the session |
| Spare worktrees kept ready for new sessions | nothing | The app's reuse pool; it reaps them itself |
| App caches and logs | reported, then **Settings › This computer › Storage › Clear cache** | No cleanup tool is exposed and they sit inside the data folder |
| Conversation history, Claude Code versions | reported only | Never deleted from here |

## Drive caveat

Worktrees live in each repository's `.claude\worktrees`, often on a different drive from
the one holding the app's data. Cleaning them only frees the drive they sit on. The
workflow checks this before promising relief on a tight system drive. The hook still only
probes the system drive.

## Status

- [x] Detection helper and `ClaudeAppFound` in the status JSON
- [x] Hook message mentions `/win-clean claude` when the app is present
- [x] `claude-storage.md` workflow, `SKILL.md` section, `/win-clean claude` argument
- [x] Tests: 11 new (193 total), all passing
- [x] README section
- [x] Installed locally (skill, `/win-clean` command, SessionStart hook)
- [x] PR [#2](https://github.com/totpero/ai-win-clean/pull/2) open from `feat/claude-storage-cleanup`
- [ ] Merge to `main`, then delete the branch (local and remote)

## Open points

- The hook probes only the system drive. A full secondary drive (where worktrees usually
  are) raises no notice. A `-Drive` list for the probe would close that.
- If the app ever exposes a cache-clearing action, step 4 of the workflow can use it
  instead of pointing at the Settings button.
