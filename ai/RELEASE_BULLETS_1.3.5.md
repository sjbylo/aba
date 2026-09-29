# ABA 1.3.5 Release Highlights

Curated image sets, Day-2 OCP Virtualization boot source support, reorganized mirror payload menu, and improved operator controls.

- **Recommended Images** — New TUI menu to add curated container image sets for AI (RHOAI), OpenShift Virtualization, and OCP utilities in one click. Automatically detects the latest RHOAI version. After adding operator sets, the TUI offers related companion images.
- **OCP Virtualization boot sources** — New `aba day2-virt` command configures VM boot source images (RHEL, CentOS Stream, Fedora) to make it very easy to launch RHEL VMs in disconnected environments. The Virtualization image set now includes RHEL 9 and RHEL 10 guest images.
- **Mirror Payload menu** — All mirror content controls (version, operators, images, toggles, advanced options) are now in a single organized sub-menu instead of scattered across the main menu.
- **OCP version change without full wizard** — Change the target OpenShift version and channel directly from the Mirror Payload menu.
- **Operator exclusion toggle** — Operator images can now be excluded from or included in the mirror payload via a toggle, matching the existing platform and additional images toggles.
- **Improved text throughout** — Replaced technical jargon ("ISC") with plain language in all TUI dialogs. Consistent "ABA" branding across all user-facing text.
- **Improved oc-mirror error handling** — `aba save`/`load`/`sync` now propagate real oc-mirror exit codes instead of a generic failure, making it easier to diagnose mirroring issues.
