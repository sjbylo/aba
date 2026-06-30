# ADR 009: Network auto-detection at cluster creation time

## Status: Accepted

## Context

Network values (machine_network, dns_servers, next_hop_address, ntp_servers) were
previously auto-detected at `aba.conf` creation time (first `aba` run). On connected
hosts creating bundles for disconnected environments, this produced wrong values.
The TUI duplicated auto-detection in-memory, violating "config as source of truth".

## Decision

- Defer auto-detection to cluster creation time (`create-cluster-conf.sh`)
- Auto-detect block runs ALWAYS (before the existing-cluster early-exit)
- For existing cluster.conf: fill empty network fields from aba.conf
- Remove hardcoded fallbacks from detection functions (fail-fast)
- TUI delegates to core (`aba cluster --step cluster.conf --yes`) + reloads
- NTP `pool.ntp.org` fallback only for `int_connection=direct`

## Consequences

- Users on broken systems get explicit errors instead of silent wrong values
- Bundle workflow no longer leaks connected-network values into bundles
- Existing cluster.conf files with empty fields get auto-populated on next run
- TUI is simpler (no duplicated detection logic)
