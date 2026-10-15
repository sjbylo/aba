# ABA 1.4.1 Release Highlights

Mirror lifecycle reliability, stale state detection, and UX improvements.

- **Docker registry resume** — re-running install after a failure now recovers instead of aborting
- **Stale registry detection** — install detects leftover state from a previous unclean uninstall and tells you how to fix it
- **Registry start shows progress** — `aba start` now shows a live countdown instead of sitting silently (Quay can take up to 10 minutes)
- **Uninstall cleans up fully** — state files and symlinks are removed, no empty leftover directories
- **TUI progress shows title bar** — progress dialogs now display the standard header with host, mode, and version info
- **`aba setup dns` crash fixed** — no longer crashes on systems with no existing DNS configuration
- **`aba setup ntp` wrong network** — firewall rule now applied to the correct interface
- **Single-label domains accepted** — domains like `lab` or `local` now work in CLI, TUI, and config
- **oc-mirror for EC builds** — engineering candidate builds fall back to stable channel when `oc-mirror` is not published
- **Ctrl-C no longer fakes success** — interrupted operations correctly report failure
- **Proxy bootstrap failures fixed** — agent IPs and cluster networks now included in `no_proxy`
- **Network cross-validation** — catches gateway-outside-CIDR, IP collisions, and VIP overlap before install
- **Security hardening** — eval injection guard, temp directory permissions, password masking in logs
