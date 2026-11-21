# Claude app storage

Reclaiming disk space used by the Claude desktop app itself: the git worktrees it makes for
Code sessions, plus its caches and logs. This is **not** Windows junk and the main scan
never touches it, so it has its own workflow.

Use it when the user says the disk is full and the Claude app is in the picture ("clean
Claude storage", "delete old worktrees", "clear app caches and logs"), when
`/win-clean claude` is typed, or when the low-disk notice from the hook points here.

## Where this runs

The actions below are tools of the Claude desktop app's **Code tab** and only manage
*local* sessions (not SSH or WSL). Outside the app they do not exist. If
`get_storage_usage` is not available, say so and stop; do not fall back to deleting
folders by hand.

The tools may be deferred. Load all three in one call before using them:

```
ToolSearch  select:mcp__ccd_host__get_storage_usage,mcp__ccd_host__clean_up_worktrees,mcp__ccd_host__discard_kept_worktree
```

## Hard rules

- **Never delete, move, rename or edit the app's data folder** (`Claude-Data`, `Claude-3p` or
  `Claude` under `%LOCALAPPDATA%` / `%APPDATA%`), or anything inside it, with
  `Remove-Item` or any script. It holds the user's sessions, settings and sign-in; removing
  parts of it can lose them for good, and after a move the app no longer finds them.
- Conversation history is shown for context and is never deleted from here.
- Every destructive step needs the user's explicit yes for that scope. The app shows its own
  approval card for the two cleanup tools; that card is not a reason to skip asking first.
- Never pass `include_uncommitted` or `delete_sessions` unless the user asked for exactly
  that, having seen what it covers.

## Workflow

Run these in order. Do not skip the report.

### 1. Report

Call `get_storage_usage` with `refresh: true`. It is read-only. Summarise in a few lines:

| Report | Field |
|---|---|
| Free space on the disk holding the app's data | `free_bytes` |
| Worktrees held by sessions | `code.worktrees.held_by_sessions_*` |
| Worktrees kept ready for new sessions | `code.worktrees.kept_ready_*` (the app's reuse pool; it reaps these itself) |
| Archived sessions that kept a worktree because of uncommitted changes | `code.worktrees.kept_after_archive` |
| Conversation history | `code.transcripts_bytes` |
| App caches and logs | `app.web_cache_bytes + browser_panes_bytes + logs_bytes + other_caches_bytes` |

**Say which drive each number can help.** `free_bytes` is for the disk holding the app's
data (usually `C:`). Worktrees live inside their repositories (`<repo>\.claude\worktrees`),
which are often on another drive, and deleting them only frees the drive they sit on. Check
the paths in `kept_after_archive` and the free space of that drive (`-Status` shows the
system drive) before promising relief on a tight `C:`.

### 2. Worktrees of inactive sessions

`clean_up_worktrees` removes the worktrees of sessions with no activity for
`older_than_days` (30, 60 or 90). Sessions, conversations and branches stay, and a resumed
session checks its branch out again. Running, pinned, open and recently used sessions are
never touched.

Start with `older_than_days: 30` (the most inclusive window; 90 frees the least). The app
works out what qualifies, then shows one approval card listing the worktrees and the space
freed; nothing is removed until the user approves it. Report what it removed and freed.

### 3. Archived sessions that kept uncommitted work

An archived session keeps its worktree on disk only when it held uncommitted changes.
Those are in `kept_after_archive` (title, folder, days kept). Do **not** bulk-discard them.
For each one, show the title, folder and age, and suggest the user look first:

```bash
git -C "<worktree folder>" status --short
git -C "<worktree folder>" log --oneline @{u}..
```

Call `discard_kept_worktree` with that `session_id` (and `folder` if the session has
several) only after the user says to discard that session's leftovers. The changes cannot be
recovered; the branches are kept.

### 4. App caches and logs

No cleanup tool is exposed for these, and they are inside the app's data folder, so this
workflow does not delete them. Report the combined size from step 1 and point the user to
the app's own button: **Settings › This computer › Storage › Clear cache**. Logs and
installed Claude Code versions are managed by the app too.

### 5. Confirm

Call `get_storage_usage` with `refresh: true` again. Report the before/after figures for
free space and for worktrees, and be plain about anything that did not move (for example,
worktrees freed on `D:` do not change free space on `C:`).

## What not to do

| Mistake | Do this instead |
|---|---|
| Deleting `.claude\worktrees` folders or app cache folders by hand | Use the app's tools; a hand-deleted worktree leaves git's worktree list pointing at nothing |
| Offering relief for `C:` by cleaning worktrees that live on `D:` | Check the drive first (step 1) |
| Discarding every kept worktree in one go | One session at a time, after the user has seen what it holds |
| Counting spare worktrees (`kept_ready`) as reclaimable | They are the app's reuse pool and are reaped by the app |
| Using `delete_sessions` to "tidy up" | It deletes conversations permanently; only when asked for by name |
