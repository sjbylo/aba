# ABA 1.3.6 Release Highlights

Disconnected mode reliability, CLI usability, and Day-2 improvements.

- **Disconnected (DISCO) mode no longer hangs** — The TUI in Fully Disconnected mode no longer attempts internet-dependent operations (catalog downloads, ISC generation) that caused the UI to freeze.
- **Interactive prompts no longer invisible** — CLI prompts that required user input were hidden by buffered output, showing only a blank cursor. Now displays correctly.
- **Quay mirror installs reliably on air-gapped hosts** — The installer auto-creates the network route needed for Quay's hairpin connections when no default route exists.
- **OSUS no longer undoes upgrade channel changes** — The update channel is now derived from a single shared source of truth, preventing Day-2 and upgrade commands from conflicting.
- **Day-2 Virtualization Boot Sources in TUI** — New menu item for configuring OCP Virtualization boot sources directly from the TUI.
- **Bundle creation warns when release images excluded** — Creating an install bundle with `excl_platform=true` now shows a clear warning and asks for confirmation.
- **Day-2 and lifecycle success messages** — `aba day2`, `aba shutdown`, and `aba startup` now print clear success messages on completion.
