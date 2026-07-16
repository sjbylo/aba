# Release Bullets for v1.2.0

Primed bundles, TUI upgrade picker, catalog prefetch, RHEL 10 support, and improved UX.

## New Features

- **`aba bundle --primed`** — Bundle pre-configured cluster directories alongside mirror data. On the disconnected side, primed clusters skip config regeneration while cluster.conf-only directories generate normally.
- **TUI upgrade path picker** — Upgrade menu queries available versions from the mirror registry and validates them against the Cincinnati upgrade graph.
- **Catalog prefetch for next minor** — Background pre-download of operator catalogs for the next OCP minor version.
- **`aba transfer-info`** — Show transfer tar contents, metadata, and cluster directory summary.
- **Suggest `aba unstick` on install failure** — Error message now suggests `aba unstick` when cluster install fails with stuck pods.

## Improvements

- **RHEL 10 support** — RHEL 10 and CentOS Stream 10 added as supported platforms.
- **Clarified sudo requirements** — ABA runs as a normal user with `sudo` for system operations; root is optional.
- **Context-aware next steps** — `aba load`, `aba save`, and `aba sync` show condensed, context-appropriate hints with consistent coloring.
- **TUI: smart DISCO menu focus** — Menu cursor moves to the logical next step after state-changing actions.
- **Agent wait timeout increased to 5 min** — Accommodates slower VM boot times across all platforms.
- **Skip agent wait on install retry** — Agent detection is not repeated when `aba install` is retried.

## Bug Fixes

- **Fix ODF operator set missing `ocs-tls-profiles`** — Fixes ODF installation failures on recent OCP versions.
- **Fix catalog extraction retry** — Transient Podman container errors now trigger automatic retry.
- **Fix `--primed` bundle symlink restoration** — EXIT trap restores exact original symlink targets.
- **Fix `aba save` color output** — Removed stale `PLAIN_OUTPUT=1` export that suppressed color.
