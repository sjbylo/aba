# ADR-014: Status / Preflight Script Pattern

## Status
Accepted

## Context

Mirror status and preflight logic was scattered across multiple files:

- `reg-save.sh` — inline upgrade+excl_platform guard
- `reg-sync.sh` — none (missing checks)
- `include_all.sh` — `_print_operation_summary()` for pre-operation display
- TUI — `mirror_available`, `_mirror_has_release_image`, etc. reimplemented
  from marker files and run_once tasks

Each consumer reimplemented its own subset of checks. Adding a new consistency
check (e.g. "upgrade target set but release images excluded") required touching
multiple files and risked drift between CLI and TUI behavior.

The TUI was accumulating business logic that belonged in ABA core.

## Decision

### One status script per domain

Each domain (mirror, cluster, repo) gets a single status script that is the
source of truth for all state queries and preflight checks:

| Domain | Script | Makefile target |
|--------|--------|-----------------|
| Mirror | `scripts/mirror-status.sh` | `status`, `status-preflight` |
| Cluster | (future) `scripts/cluster-status.sh` | (future) |
| Repo | (future) | (future) |

### Three modes per script

1. **Default (human-readable)**: Nicely formatted `[ABA]` output for CLI users.
2. **`--shell`**: Sourceable key=value pairs for programmatic consumers (TUI,
   other scripts). Follows the `transfer-info.sh` pattern.
3. **`--preflight`**: Runs the same analysis as `--shell`, then acts on blocking
   issues using `ask()`. Wired as a Makefile dependency of mutating targets
   (save/sync) so checks run automatically before operations.

### Preflight as Makefile dependency

`status-preflight` is a dependency of `save` and `sync`, placed before
`data/imageset-config.yaml` so preflight can fix config before ISC generation:

```makefile
save: .init .rpmsext status-preflight data/imageset-config.yaml
```

The TUI's background ISC generation targets `data/imageset-config.yaml`
directly and is unaffected — no preflight hangs.

### TUI workflow

Because `ask()` respects `aba -y` (ASK_OVERRIDE) and `ask=false` in aba.conf:

1. TUI calls `mirror-status.sh --shell` to detect issues
2. TUI presents issues in dialog form, user decides
3. TUI fixes config if needed
4. TUI calls `aba -y -d mirror save` — preflight auto-accepts, no duplicate prompts

## Consequences

- One place to add new preflight checks — no multi-file scatter.
- TUI becomes a dumb consumer of `--shell` output — business logic stays in core.
- Pattern extends naturally to cluster-status and repo-level status.
- `transfer-info.sh` is unaffected (separate concern: transfer tar inspection).
- Shared ISC-parsing helpers (`_isc_operator_list`, `_isc_operator_count`) in
  `include_all.sh` avoid duplicating the awk across yet another script.
