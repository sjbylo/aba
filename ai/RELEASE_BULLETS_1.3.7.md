# ABA 1.3.7 Release Highlights

Major reliability fix for disconnected installs, conditional upgrade warnings, and TUI polish.

- **Fixed `aba load` hang on disconnected hosts** — no more zero-output deadlock; oc-mirror progress animations now visible
- **Conditional upgrade path warnings** — detects known risks in the update graph and warns before proceeding
- **Stale registry directory detection** — catches leftover data from a previous install before Ansible fails
- **New `aba -d mirror status` command** — compact summary of mirror configuration and state
- **Pre-operation summaries** — save, sync, and load show what they'll do before starting
- **Preflight guard** — catches upgrade + excluded-platform conflicts early, not after a long operation
- **~40% less mirror output** — cleaner save/sync/load output; full detail still available via `DEBUG_ABA=1`
- **TUI improvements** — instant ESC key, image preview before adding, context-sensitive menus, clearer labels
