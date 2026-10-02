# ABA 1.3.7 Release Highlights

Cleaner mirror operations output, new mirror status command, and improved reliability.

- **New `aba -d mirror status` command** — Shows a compact summary of your mirror configuration: OCP version, registry, operators, and exclusions. Available in human-readable, shell-parseable, and preflight-check modes.
- **Pre-operation summaries** — Save, sync, and load now show what they're about to do (version, operator count, image breakdown) before starting work.
- **Preflight guard catches conflicts early** — Save and sync now check for upgrade + excluded-platform conflicts interactively before work begins, not after a long operation fails.
- **~40% less mirror output** — Duplicate lines, redundant details, and double blank lines are cleaned up. All detail is still available via `DEBUG_ABA=1`.
- **Config backup on load** — Loading images now backs up your existing configuration before unpacking the transfer archive.
- **TUI upgrade guard dialog** — When an upgrade needs release images but they're excluded, the TUI now offers a clear Yes/No choice with a warning about the consequences.
- **Image preview before adding** — Recommended image sets now show the full list of images for review before committing. No more guessing what "5 images" means.
- **Context-sensitive Additional Images menu** — Menu items that don't apply when no images are configured are hidden, reducing clutter.
- **ESC key is now instant** — ESC in the TUI now responds in ~200ms instead of the old ~1 second delay, making navigation feel much snappier.
- **Reliable operator parsing** — ISC operator parsing replaced with a robust yaml-to-json approach, fixing potential misparsing issues across save, sync, load, and bundle operations.
- **Auto-DNS messages explain themselves** — DNS add/remove messages now mention "ABA auto-DNS via dnsmasq" and the config file path, so users know where the records come from.
