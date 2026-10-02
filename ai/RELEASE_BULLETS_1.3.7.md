# ABA 1.3.7 Release Highlights

Major reliability fix for disconnected installs, conditional upgrade warnings, and TUI improvements.

- **Fixed `aba load` hang on disconnected hosts** — A buffering deadlock caused `aba load` to hang with zero output on disconnected and bundle hosts. The fix also restores oc-mirror's live progress animations (spinners, progress bars) that were previously hidden.
- **New `aba -d mirror status` command** — Shows a compact summary of your mirror configuration: OCP version, registry, operators, and exclusions. Available in human-readable, shell-parseable, and preflight-check modes.
- **Conditional upgrade path warnings** — Upgrade validation now detects known risks in the Cincinnati update graph and shows risk names. The TUI presents a confirmation dialog; the CLI prints warnings.
- **Stale registry directory detection** — Registry install now catches leftover data directories from a previous install (wrong file ownership) and tells you exactly how to fix it, instead of failing deep inside Ansible.
- **Pre-operation summaries** — Save, sync, and load now show what they're about to do (version, operator count, image breakdown) before starting work.
- **Preflight guard catches conflicts early** — Save and sync now check for upgrade + excluded-platform conflicts interactively before work begins, not after a long operation fails.
- **~40% less mirror output** — Duplicate lines, redundant details, and double blank lines are cleaned up. All detail is still available via `DEBUG_ABA=1`.
- **Config backup on load** — Loading images now backs up your existing configuration before unpacking the transfer archive.
- **TUI upgrade guard dialog** — When an upgrade needs release images but they're excluded, the TUI offers a clear Yes/No choice with a warning about the consequences.
- **Image preview before adding** — Recommended image sets now show the full list of images for review before committing.
- **Context-sensitive menus** — Additional Images menu items that don't apply when no images are configured are hidden, reducing clutter. Clearer menu labels throughout.
- **ESC key is now instant** — ESC in the TUI responds in ~200ms instead of ~1 second.
- **Reliable operator parsing** — ISC operator parsing replaced with a robust yaml-to-json approach, fixing misparsing across save, sync, load, and bundle operations.
