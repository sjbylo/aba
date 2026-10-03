# ABA 1.3.7 Release Highlights

Unified status command, critical error-handling fix, and disconnected workflow improvements.

- **New `aba status` command** — shows where you are and what to do next in one glance
- **Fixed `aba load` hang on disconnected hosts** — no more zero-output deadlock
- **Fixed install/upgrade continuing after errors** — 27 scripts now properly stop on sub-script failures
- **Missing release image warning** — `aba -d mirror status` flags when expected images aren't in the registry
- **Conditional upgrade path warnings** — detects known risks in the update graph before proceeding
- **Stale registry directory detection** — catches leftover data from a previous install before Ansible fails
- **TUI: DISCO mode visual indicator** — cyan background distinguishes disconnected from connected mode
- **~40% less mirror output** — cleaner save/sync/load; full detail still available via `DEBUG_ABA=1`
- **TUI improvements** — instant ESC key, image preview, context-sensitive menus, clearer labels
