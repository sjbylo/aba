# ADR-008: Cached state pattern (core produces, TUI reads)

## Status
Proposed

## Context
The TUI needs to display state on every menu redraw (mirror status, cluster
health, config values). Querying live state is expensive: `check_release_image`
curls the registry (~0.5s), `mirror-status.sh --shell` parses ISC + operators
(~2s), `normalize-aba-conf` spawns a subshell (~0.15s per call, ~30 calls per
menu cycle).

The TUI also makes state-based decisions (show/hide menu items, auto-focus)
which should live in ABA core, not the TUI (ADR "core is the brains, TUI is
a dumb UI" — see `dry-and-core-logic.mdc`).

## Decision
State queries follow a three-layer pattern:

### 1. Core script produces state (the brains)
A core script (e.g. `mirror-status.sh --reg-state`) reads marker files,
config files, and (when needed) probes the network. It outputs key=value
fields including **derived state** (e.g. `reg_state=ready`). All
interpretation logic lives here.

### 2. run_once caches the output
`run_once -i "aba:mirror:reg-state"` runs the core script in the
background. The output is cached in `~/.aba/runner/`. Callers read the
cached output with `run_once -O`.

Lifecycle:
- **Start:** after TUI mode detection (initial probe)
- **Refresh:** after state-changing operations (`_invalidate_mirror_cache`)
- **Wait:** before menu draw, if refresh was triggered
- **Read:** non-blocking, returns cached key=value lines

### 3. TUI reads cached state (dumb display)
The TUI evals the cached output and maps values to display labels (color
codes, menu item visibility). Zero probes, zero business logic.

### Speed optimization: marker files + state.sh inference
To minimize curl/network calls, the core script uses a tiered approach:

1. **Marker files** (instant, ~0ms): `.available` (installed), `.up` (running)
2. **state.sh inference**: `mirror_ocp_version == ocp_version` + `last_action`
   lets us infer `release_image_available=true` without curling
3. **Live probe** (only when ambiguous): `check_release_image()` with its
   optimized parallel curl pattern

Self-healing: if `.up` exists but curl returns connection refused, remove
`.up` and report `reg_state=stopped`.

### Config freshness: mtime-based caching
For frequently-read config files (`aba.conf`, `mirror.conf`), check the
file mtime before re-sourcing. Cache the parsed values in shell variables.
Re-source only when mtime changes:

```bash
_aba_conf_mtime=0
_ensure_aba_conf_fresh() {
    local _mt
    _mt=$(stat -c %Y "$ABA_ROOT/aba.conf" 2>/dev/null) || return
    [[ "$_mt" == "$_aba_conf_mtime" ]] && return
    source <(normalize-aba-conf)
    _aba_conf_mtime="$_mt"
}
```

## Areas of application

| Area | Core script | Cache task ID | Status |
|------|-------------|---------------|--------|
| Mirror reg-state | `mirror-status.sh --reg-state` | `aba:mirror:reg-state` | Planned |
| Pre-op summary | `mirror-status.sh --shell` | `aba:mirror:full-status` | Future |
| Cluster state | `cluster-status.sh --state` (new) | `aba:cluster:<name>:state` | Future |
| Config (aba.conf) | mtime-based in-process cache | n/a (no run_once) | Future |
| Config (mirror.conf) | mtime-based in-process cache | n/a (no run_once) | Future |
| Internet/podman | already uses run_once pattern | `aba:check:internet`, `aba:preflight:podman` | Done |

## Consequences
- TUI rendering is decoupled from probe latency
- State interpretation is testable in core (unit tests, not TUI screenshots)
- New state fields are added once in core and automatically available to
  both TUI and CLI (`aba -d mirror status --reg-state`)
- Marker files provide instant local state; live probes catch external changes
- mtime caching eliminates redundant subshell spawns for config reads
