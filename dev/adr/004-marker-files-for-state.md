# ADR-004: Marker files for state tracking

## Status
Accepted

## Context
ABA needs to track lifecycle state: is the mirror initialized? Is the registry
installed? Has the cluster been bootstrapped? Options: database, env vars,
or simple filesystem sentinels.

## Decision
Empty (or near-empty) marker files track lifecycle state. Makefiles create and
remove them as part of target recipes. Scripts read them (test -f) but never
create or remove them.

Key markers: .init (dir initialized), .available (registry up),
.unavailable (registry explicitly absent), .install-complete,
.bootstrap-complete, .preflight-done, .bundle (extracted bundle tree).

## Consequences
- Visible: `ls -la mirror/` shows current state at a glance
- Debuggable: `touch .available` or `rm .init` can manually fix stuck state
- Fragile: `make clean` or `rm -rf` can wipe markers and desync state
- Make's dependency graph uses marker mtimes to decide what to rebuild
