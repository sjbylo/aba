# ADR-012: Merge int_connection and mirror_name into image_source

## Status
Accepted

## Context
`cluster.conf` used two separate fields to control where a cluster pulls images:

- `int_connection` — `direct`, `proxy`, or empty (meaning "use mirror")
- `mirror_name` — the mirror directory name (default `mirror`)

This split caused confusion: `int_connection=` (empty) was the signal for "use a
mirror", but was non-obvious and error-prone. The two fields encoded a single
concept (image source) across two variables with interdependent semantics.
ADR-009 already noted the `int_connection=none` backward-compat quirk.

## Decision
Replace both fields with a single `image_source` in `cluster.conf`:

- `image_source=direct` — nodes pull from the Internet directly
- `image_source=proxy` — nodes pull via HTTP proxy
- `image_source=<name>` — nodes pull from the named mirror directory (default: `mirror`)

Implementation details:

- `normalize-cluster-conf()` has a migration shim that derives `image_source`
  from legacy `int_connection` + `mirror_name` when only old keys are present
- The same function emits backward-compat `int_connection` and `mirror_name`
  variables derived from `image_source`, so unmigrated code keeps working
- CLI flag `--image-source` replaces `--int-connection` and `--mirror-name`;
  old flags remain as deprecated aliases
- Helper functions `image_source_is_mirror()` and `image_source_mirror_name()`
  provide clean boolean/value access without hardcoding the direct/proxy checks
- `setup-mirror.sh` blocks `direct` and `proxy` as mirror directory names
- Externalized cluster state persists `image_source` instead of `mirror_name`

## Consequences
- Single field to understand ("where do images come from?")
- Legacy cluster.conf files migrate transparently on next normalize
- Backward-compat shim can be removed once all consumers are migrated
- `--int-connection` and `--mirror-name` flags remain functional but deprecated
- Mirror directory names `direct` and `proxy` are now reserved
