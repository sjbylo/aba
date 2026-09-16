# ABA 1.3.3 Release Highlights

- **Version fetch no longer caches errors** — If the internet is down when ABA fetches OCP version info, the failed result is now recorded as a failure (not success). Next run with internet re-fetches cleanly instead of showing stale error text.
- **TUI version wizard fix** — The version selection dialog no longer shows "Script error..." for channels with fewer than three versions (e.g. candidate). The ERR trap is now correctly suppressed at all version fetch call sites.
- **Additional images exclusion toggle** — Additional images can now be excluded from or included in the ISC via a toggle in the TUI, mirroring the existing platform images toggle.
- **Monitor Installation accessible from main menu** — Moved from Advanced to the Cluster menu. Automatically highlighted when a cluster is installing. The ISO Created dialog now offers direct "Monitor Installation" and "Back to Menu" buttons.
- **ISO Created dialog shows correct node count** — SNO clusters now show "Boot your server" instead of "Boot all 5 server(s)".
- **CLI downloads skip when version is unknown** — Running ABA offline before setting a version no longer creates broken download tasks.
- **`aba image remove` returns non-zero when image not found** — Callers can now reliably detect when a removal had no effect.
- **`aba save` next-steps clarity** — After `aba save`, the suggested next step is now `aba tar` (the correct two-step flow) instead of `aba bundle`.
- **Empty `reg_user` defaults to `init`** — A blank `reg_user` in `mirror.conf` no longer causes registry auth failures. (Contributed by [@mateuszslugocki](https://github.com/mateuszslugocki))
- **`day2` applies all manifest waves** — A clean manifest batch no longer aborts subsequent waves under `set -e`. (Contributed by [@mateuszslugocki](https://github.com/mateuszslugocki))
