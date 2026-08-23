# Release Highlights — 1.2.3

- `aba import` brings existing OpenShift clusters (UPI, IPI, Assisted) under ABA management — auto-detects topology, network, and image source from the live API
- `image_source` consolidates two `cluster.conf` fields (`int_connection`, `mirror_name`) into one — simpler config, full backward compat (ADR-012)
- CLI binaries (oc, govc, oc-mirror, etc.) self-heal if missing — `ensure_*()` guards verify and reinstall before every use
- Upgrade path preview shows intermediate versions before `aba save`/`sync` so you know what `oc-mirror` will fetch
- Cluster operator stability waits after `day2`/`day2-ntp`/`day2-osus` and before `upgrade` — reduces "not ready" upgrade failures
- TUI no longer shows "load mirror first" when an operators-only archive (no release images) was loaded — now shows "release image missing"
- "Transfer bundle" renamed to "transfer config" in all user-facing output to avoid confusion with install bundles
- Consecutive sudo calls batched into single invocations — fewer password prompts for non-root users
