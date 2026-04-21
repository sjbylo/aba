# ADR-001: Config files as single source of truth

## Status
Accepted

## Context
ABA needs a way to pass configuration between the CLI, Make targets, and
scripts. Options considered: environment variables threaded through every call,
CLI flags passed down the chain, or config files read at each layer.

## Decision
Config files (aba.conf, mirror.conf, cluster.conf) are the single source of
truth. CLI flags write TO config files. Scripts read FROM config files.

The `platform=` variable in `aba.conf` is authoritative for which hypervisor
config to load. File presence (e.g. vmware.conf existing) must not be used as
a proxy for "this platform is active."

## Consequences
- Simple: scripts just `source <(normalize-*-conf)` to get current values
- Debuggable: `cat mirror.conf` shows current state at any time
- Requires discipline: every new setting must go through normalize*() -> config
- Risk: stale config if user edits config while a long operation is running
  (mitigated by re-sourcing ~/.aba/config on each retry iteration)
