# Session State

## Current goal
Re-apply lost uncommitted changes (Cursor fileWatcher deletion); then continue with README updates plan.

## Done this session
- Diagnosed 91 deleted files from Cursor fileWatcher race condition (known issue)
- User ran `git restore .` to recover working tree
- Re-applied E2E pool usage rule to rules-of-engagement.mdc
- Re-applied _essh and 57GB backlog items to BACKLOG.md
- Re-applying run.sh fixes (pool flag, dash idle, notifications)

## Next steps
- Complete run.sh re-application (pool flag, dash idle, notifications)
- Commit and push re-applied changes
- Execute README updates plan (Docker first-class, named mirrors, TUI, FAQ, backlog)
- Resume gotest on pools 1 and 2

## Decisions / notes
- Cursor fileWatcher fix (exclude .git/) may have been lost -- user should verify User Settings
- Backup rule was not followed in previous session -- must back up before editing going forward
- Version bump NOT needed in README -- release.sh handles it
- Do NOT change existing README headings (permalinks from blog articles)
