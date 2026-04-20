# ADR-006: aba day2 required after mirror load/sync

## Status
Accepted

## Context
When oc-mirror loads or syncs images to a registry, it generates YAML manifests
(IDMS/ITMS/CatalogSources) that tell the cluster where to find the mirrored
content. Without applying these, the cluster cannot pull operator images from
the mirror.

## Decision
After every `mirror load` or `mirror sync` on an already-installed cluster,
the user must run `aba day2`. This applies the oc-mirror-generated manifests
to the cluster.

day2 is NOT part of the initial cluster install flow. Fresh installs are
configured correctly at install time via install-config.yaml.

## Consequences
- Two-step workflow for mirror updates: load/sync, then day2
- Forgetting day2 causes silent image pull failures (hard to diagnose)
- aba could potentially auto-run day2 after load/sync in the future, but
  currently it requires explicit invocation
- day2 also handles trust CA patching and imagestream recreation
