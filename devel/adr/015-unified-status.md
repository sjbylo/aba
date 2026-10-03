# ADR-015: Unified Status Command

## Status
Accepted

## Context

ABA state detection is scattered across multiple places:

- **TUI**: `_detect_mode()`, `_validate_payload()`, `tui_cluster_menu_flags()`,
  `mirror_available()`, `_mirror_has_release_image()` — all in tui-lib.sh and
  abatui2.sh, reimplemented from marker files, run_once tasks, and config files.
- **mirror-status.sh** (ADR-014): Exists for the mirror domain only.
- **Cluster state**: No status script. TUI walks cluster dirs inline.
- **Repo state**: No status script. TUI checks aba.conf, CLI tools, bundle flag,
  and registry installer files inline.

There is no single command that tells the user "here is where you are, here is
what to do next." The TUI derives this from scattered checks; CLI users have
nothing equivalent.

## Decision

### Three domain scripts + one aggregator

Extends the ADR-014 pattern (one status script per domain):

| Domain | Script | CWD | Exists |
|--------|--------|-----|--------|
| Repo | `scripts/repo-status.sh` | `$ABA_ROOT` | **new** |
| Mirror | `scripts/mirror-status.sh` | `mirror/` | **exists** |
| Cluster | `scripts/cluster-status.sh` | `$ABA_ROOT` | **new** |
| Top-level | `scripts/aba-status.sh` | `$ABA_ROOT` | **new** (future) |

Each script supports two modes:
1. **Default** — human-readable `[ABA]` output
2. **`--shell`** — sourceable key=value pairs for TUI and scripts

### CLI surface

```
aba status              # top-level repo summary (fast, repo-status only)
aba status --all        # repo + mirror + all clusters + live health
aba status --shell      # machine-readable (repo only)
aba status --all --shell # machine-readable (everything)
aba -d mirror status    # mirror-only (already works, ADR-014)
aba -d <cluster> status # cluster-only (future)
```

### repo-status.sh — state gathered

| Key | Source | Description |
|-----|--------|-------------|
| `aba_installed` | `~/bin/aba` exists | ABA installed in PATH |
| `aba_version` | VERSION file | Current version |
| `aba_conf_exists` | `aba.conf` | Setup wizard completed |
| `ocp_version` | aba.conf | Baseline OCP version |
| `ocp_channel` | aba.conf | Update channel |
| `pull_secret` | aba.conf `pull_secret_file` | Pull secret file exists |
| `internet` | cached connectivity | Online/offline |
| `mode` | `.bundle` + internet | CONNO / DISCO / DIRECT |
| `infra_platform` | `vmware.conf` / `kvm.conf` | vmware / kvm / bm / none |
| `cli_oc` | `~/bin/oc` | oc installed |
| `cli_oc_mirror` | `~/bin/oc-mirror` | oc-mirror installed |
| `cli_openshift_install` | `~/bin/openshift-install` | openshift-install installed |
| `reg_installer_quay` | `mirror/mirror-registry*.tar.gz` | Quay installer available |
| `reg_installer_docker` | `mirror/docker-reg-image.tgz` | Docker installer available |
| `saved_archives` | `mirror/data/mirror_*.tar` | Saved image archives exist |
| `bundle_flag` | `.bundle` | Bundle marker present |
| `cluster_count` | dirs with `cluster.conf` | Total cluster directories |

### cluster-status.sh — state gathered

| Key | Source | Description |
|-----|--------|-------------|
| `cluster_count` | dirs with `cluster.conf` | Total cluster dirs |
| `cluster_installed_count` | `.install-complete` marker | Fully installed |
| `cluster_installing_count` | no marker | In progress |
| Per-cluster | kubeconfig + `oc get clusterversion` | name, type, status, health, version |

Cluster health queries run in parallel (backgrounded subshells). Each takes
~1-2s. Reports: `Available`, `Progressing`, `Degraded`, `Unreachable`, or
`unknown` (no kubeconfig).

### mirror-status.sh — already exists

Provides: `mirror_installed`, `mirror_has_release`, `reg_host`, `reg_port`,
`reg_vendor`, `operator_count`, `ocp_version`, `ocp_channel`, `ocp_upgrade_to`
(from mirror.conf), `excl_*` flags, upgrade path info, ISC state.

Note: `ocp_upgrade_to` lives in **mirror.conf** (per-mirror), not aba.conf.

### Next-steps engine (future, in aba-status.sh)

Priority-ordered recommendations. First matching condition is the primary
recommendation; others shown as secondary.

| Condition | Recommendation |
|-----------|---------------|
| No `aba.conf` | Run `aba` to configure |
| No pull secret | Add pull secret to `aba.conf` |
| No mirror directory | Run `aba mirror` |
| No registry installers (DISCO) | Transfer bundle with registry files |
| Mirror not installed | Run `aba -d mirror install` |
| Mirror installed, no images | Run `aba -d mirror sync` or `load` |
| Upgrade target set, not synced | Run `aba -d mirror sync` |
| No clusters | Run `aba cluster --name <n> --type sno` |
| Cluster installing | Run `aba -d <name> mon` |
| Cluster installed, no day2 | Run `aba -d <name> day2` |
| Upgrade synced, not applied | Run `aba -d <name> upgrade` |
| Everything current | "All up to date" |

### Additional state (for future enrichment)

- Disk space: mirror data dir size + available space
- Mirror data age: last sync/load timestamp from state.sh
- Signature count: release signatures for upgrade readiness
- ABA update available: `~/bin/aba` version vs repo version

## TUI migration path

Gradual — TUI adopts one domain script at a time:

1. `_detect_mode()` → `repo-status.sh --shell` (mode, internet, payload)
2. `tui_cluster_menu_flags()` → `cluster-status.sh --shell` (counts, install state)
3. `_validate_payload()` → `repo-status.sh --shell` (cli, reg_installer, archives)
4. Mirror menu labels → already uses `mirror-status.sh --shell`

Each migration removes duplicated logic from TUI code. No TUI changes required
in phase 1 — status scripts are purely additive.

## Implementation phases

### Phase 1 (non-disruptive, additive only)
- Create `repo-status.sh` and `cluster-status.sh`
- Wire `aba status` in aba.sh to call repo-status.sh
- No TUI changes, no existing code modified

### Phase 2 (aggregator + next-steps)
- Create `aba-status.sh` as aggregator
- Add `--all` flag support
- Implement next-steps engine

### Phase 3 (TUI migration)
- TUI sources `--shell` output instead of inline checks
- Remove duplicated state logic from tui-lib.sh

## Consequences

- Users get a single `aba status` command showing where they are and what to do.
- ABA core owns all state logic; TUI becomes a pure consumer.
- Pattern extends naturally from ADR-014 (mirror-status) to all domains.
- No existing behavior changes in phase 1 — purely additive.
