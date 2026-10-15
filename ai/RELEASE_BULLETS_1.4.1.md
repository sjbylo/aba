# ABA 1.4.1 Release Highlights

Improved reliability for registry operations, better input validation, and fixes for edge-case crashes.

- Registry stop/start is now reliable — stop waits for the port to close, start waits long enough for Quay to fully initialize, eliminating the recurring restart race condition
- Interrupted registry installs can be safely resumed from any point — each step is idempotent
- `aba setup dns` no longer crashes silently on systems with no existing DNS configuration
- `aba setup ntp` configures the firewall on the correct network when `--bastion-ip` is specified
- Single-label base domains (e.g. `lab`, `local`) are now accepted in CLI, TUI, and config validation
- Network configuration is cross-validated: gateway-in-CIDR, node IP collisions, and VIP overlap are caught before install
- `aba import` rejects unsafe cluster names and validates the kubeconfig path before proceeding
- Day-2 custom manifest `.wait` files are parsed safely (removed `eval`)
- oc-mirror download now works for engineering candidate (EC) builds by falling back to a stable channel
- OMR install is more robust — no redundant image load, automatic recovery from corrupt cached binaries
- DNS warnings replaced with a single actionable message suggesting `aba setup dns` or how to configure `/etc/resolv.conf`
- Image references are validated before writing to configuration, preventing later mirror failures
- Ctrl-C during TUI progress dialogs no longer falsely reports success
- Version matching uses exact comparison (4.2 no longer matches 4.22)
