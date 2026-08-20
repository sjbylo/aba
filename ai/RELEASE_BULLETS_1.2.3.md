# Release Highlights — 1.2.3

- `image_source` consolidates two `cluster.conf` fields (`int_connection`, `mirror_name`) into one — simpler config, full backward compat (ADR-012)
- Upgrade path preview shows intermediate versions before `aba save`/`sync` so you know what `oc-mirror` will fetch
- Cluster operator stability waits after `day2`/`day2-ntp`/`day2-osus` and before `upgrade` — reduces "not ready" upgrade failures
- Consecutive sudo calls batched into single invocations — fewer password prompts for non-root users
- `cluster-upgrade` retries once on transient `oc adm upgrade` rejection instead of aborting immediately
- Install script no longer prompts for sudo password before it's actually needed
