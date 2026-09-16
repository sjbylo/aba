# ABA 1.3.3 Release Highlights

More reliable version handling, improved TUI usability, and community-contributed registry and day2 fixes.

- **Version fetch no longer caches errors** — If the internet is down when fetching OCP versions, the next online run re-fetches cleanly instead of showing stale error text.
- **TUI version wizard fix** — The version selection dialog no longer shows "Script error..." for candidate channel versions.
- **Additional images toggle** — Additional images can now be included or excluded from the ISC via a TUI toggle, like platform images.
- **Monitor Installation in main menu** — Moved from Advanced to the Cluster menu. Automatically highlighted when a cluster is installing.
- **ISO Created dialog** — Shows correct node count for SNO and offers "Monitor Installation" and "Back to Menu" buttons.
- **Empty `reg_user` no longer breaks registry install** — A blank `reg_user` in `mirror.conf` now defaults to `init`. (Contributed by [@mateuszslugocki](https://github.com/mateuszslugocki))
- **`day2` applies all manifest waves** — Fixed a bug where only the first batch of custom manifests was applied. (Contributed by [@mateuszslugocki](https://github.com/mateuszslugocki))
