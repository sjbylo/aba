# ABA 1.4.0 Release Highlights

Curated image sets for common workloads, a reorganized mirror payload menu, and improved operator selection controls.

- **Recommended Images** — New TUI menu to add curated container image sets for AI (RHOAI), OpenShift Virtualization, and OCP utilities in one click. Automatically detects the latest RHOAI version. After adding operator sets, the TUI offers related companion images.
- **Mirror Payload menu** — All mirror content controls (version, operators, images, toggles, advanced options) are now in a single organized sub-menu instead of scattered across the main menu.
- **OCP version change without full wizard** — Change the target OpenShift version and channel directly from the Mirror Payload menu.
- **Operator exclusion toggle** — Operator images can now be excluded from or included in the mirror payload via a toggle, matching the existing platform and additional images toggles.
- **Improved text throughout** — Replaced technical jargon ("ISC") with plain language in all TUI dialogs. Consistent "ABA" branding across all user-facing text.
- **Toggle cursor stays put** — Toggling inclusion switches in the Mirror Payload menu no longer jumps the cursor away.
- **Stricter operator set validation** — Pre-commit checks now validate operators against all catalog versions, catching both typos and deprecated operators.
