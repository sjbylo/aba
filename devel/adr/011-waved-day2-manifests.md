# ADR 011: Waved day2-custom-manifests

## Status: Accepted

## Context

Users need ordered manifest application with readiness gates between stages.
Example: a CRD must be applied and its controller must be running before CRs
that use it can be created. The existing flat `day2-custom-manifests/` directory
applies all files in alphabetical order with no ability to wait.

This feature is independent of the "primed" workflow — it benefits any cluster
that uses custom day-2 manifests.

## Decision

The `apply_custom_manifests()` function in `scripts/day2.sh` supports two modes,
auto-detected based on directory structure:

### Waved mode (numbered subdirs present)

```
day2-custom-manifests/
  10-namespaces/
    ns.yaml
  20-operators/
    sub.yaml
    .wait             # gate: wait for operator readiness before wave 30
  30-app/
    deployment.yaml
```

- Numbered subdirs (`[0-9]*`) are waves, applied in `sort -V` order.
- Top-level flat files are applied BEFORE any waves.
- Optional `.wait` file in a wave dir gates the next wave.
- Each non-comment line in `.wait` is passed as args to `oc wait`.
- Failed `oc wait` is non-fatal (warning + continue to next wave).

### Flat mode (no numbered subdirs — legacy behavior preserved)

All `.yaml/.yml` files found recursively, applied in alphabetical order.
Backward compatible with existing deployments.

### .wait file format

```
# Wait for the operator deployment to be ready
--for=condition=available deployment/my-operator -n my-namespace --timeout=120s
```

One `oc wait` invocation per line. Comments (#) and blank lines are ignored.

## Consequences

- Backward compatible: no numbered subdirs = flat mode (no behavior change)
- `sort -V` for numeric ordering (handles 1, 2, 10, 20 correctly)
- `.wait` failures are non-fatal — deployment continues
- Inner helper `_apply_manifest_list()` extracted for DRY
- No new configuration needed — structure-as-convention
