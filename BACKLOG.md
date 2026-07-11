# ABA Backlog

Known issues, planned improvements, and ideas. Contributions welcome via
Issues or Pull Requests.

## Rules for this file

- NEVER include passwords, tokens, certificates, real hostnames, IP
  addresses, or other credentials.
- Use example.com domains and placeholder values in reproducers.

## Entry format

<!-- Example entry (copy this as a template):

## Title of the issue or improvement

**Severity:** HIGH | MEDIUM | LOW
**Status:** Planned | In Progress | Done
**Added:** YYYY-MM-DD

**Problem:** 2-3 sentences describing what the user experiences.

**Root cause:** Technical explanation of why this happens.

**Proposed fix:** Description of the planned approach (code snippets OK).

**Workaround:** How to avoid the issue until it's fixed (if any).

**Reproducer:** (optional) Steps to reproduce.

-->

---

## ISC upgrade mode broken by state.sh ocp_version override

**Severity:** HIGH — produces wrong ISC, upgrade sync downloads wrong images
**Status:** Planned
**Added:** 2026-07-09

**Problem:** When `_state_override_mirror()` overrides `ocp_version` from
`state.sh`, and `ocp_upgrade_to` equals the overridden value, the ISC Jinja
template sees `ocp_version == ocp_upgrade_to` and generates a non-upgrade ISC
(single version, no `shortestPath`). The upgrade path is lost.

**Root cause chain:**
1. User has `ocp_version=4.21.22` in `aba.conf`, sets `ocp_upgrade_to=4.22.2`
2. Prepare Upgrade correctly generates ISC: `minVersion=4.21.22, maxVersion=4.22.2`
3. Sync runs successfully using that ISC
4. `reg-sync.sh` line 142-143 writes `ocp_version=4.22.2` to `state.sh`
5. Any subsequent ISC regeneration (viewing ISC, operator change, etc.) calls
   `reg-create-imageset-config.sh`, which sources `normalize-mirror-conf()`
6. `_state_override_mirror()` (include_all.sh:944) overrides `ocp_version` to
   `4.22.2` (from state.sh), making `ocp_version == ocp_upgrade_to`
7. Jinja template takes the ELSE branch → generates `minVersion=4.22.2,
   maxVersion=4.22.2` (non-upgrade)

**Why `ocp_version` was added to state override:**
Without the override, the Prepare Upgrade dialog shows "4.22.3 → 4.22.3"
instead of "4.22.2 → 4.22.3" when the user changes aba.conf to the target
version. The state.sh value (what's actually in the mirror) is needed for
correct display. Removing the override would re-open this display bug.

**Why neither ocp_version source works for ISC:**

| Source | What it tracks | Fails when |
|--------|---------------|------------|
| `aba.conf` | What user configured | User changed it independently; cluster was upgraded without updating aba.conf; produces too-broad upgrade path |
| `state.sh` | What mirror last synced | After upgrade sync, holds TARGET version → ocp_version == ocp_upgrade_to → non-upgrade ISC |
| Cluster | What cluster runs | Mostly available, but not always (connected host prepping images for air-gapped transfer) |

**Proposed fix: add `ocp_upgrade_from` to state.sh**

`state.sh` tracks what's actually in the mirror registry — it's the right
place for the upgrade source version, since that's a fact about mirror content,
not a user config wish. When `reg-sync.sh` runs the upgrade sync, it already
writes the target version to `state.sh`. At the same moment it should capture
the source:
```bash
# reg-sync.sh, at upgrade sync time (before writing ocp_version=$target):
replace-value-conf -q -n ocp_upgrade_from -v "$ocp_version" -f "$state_file"
replace-value-conf -q -n ocp_version -v "$ocp_upgrade_to" -f "$state_file"
```

The ISC template uses `ocp_upgrade_from` (not `ocp_version`) for upgrade
`minVersion`. Benefits:
- Source version captured at sync time as a fact about mirror content
- Lives in state.sh alongside ocp_version — complete picture of what's in the registry
- Independent of aba.conf changes
- `_state_override_mirror()` can export it alongside ocp_version
- Persists across ISC regenerations
- Clearing the upgrade clears both fields
- Could be populated from `oc get clusterversion` for maximum accuracy

**Files to change:**
- `scripts/reg-sync.sh`: write `ocp_upgrade_from` to state.sh before updating ocp_version
- `templates/imageset-config.yaml.j2`: use `ocp_upgrade_from` for `minVersion`
  in upgrade branch (currently uses `ocp_version`)
- `scripts/reg-create-imageset-config.sh`: export `ocp_upgrade_from` for Jinja
- `scripts/include_all.sh` (`_state_override_mirror`): export `ocp_upgrade_from`
  from state.sh alongside existing overrides
- `tui/v2/tui-mirror.sh` (`mirror_prep_upgrade`): write `ocp_upgrade_from` to
  state.sh when initiating upgrade
- `scripts/aba.sh` (`--upgrade-to` handler): same as above
- `scripts/reg-save.sh` / `scripts/reg-load.sh`: ensure `ocp_upgrade_from` is
  persisted in state.sh during save/load workflows (air-gapped mode)

**MUST verify both workflows:**
- **Connected (sync):** `reg-sync.sh` writes `ocp_upgrade_from` to state.sh
  before overwriting `ocp_version` with target — ISC regeneration picks it up
- **Disconnected (save/load):** `reg-save.sh` captures `ocp_upgrade_from` into
  the tarball's state; `reg-load.sh` restores it on the disconnected side.
  The ISC is generated on the connected bastion (save) AND may be regenerated
  on the disconnected bastion (load) — both must have access to `ocp_upgrade_from`

**Reproducer:**
1. Configure ABA with `ocp_version=4.21.22`, sync mirror
2. Prepare Upgrade → select 4.22.2 → Sync to registry
3. After sync completes, go to View ISC (V)
4. ISC shows `minVersion: 4.22.2, maxVersion: 4.22.2` (WRONG)
5. Expected: `minVersion: 4.21.22, maxVersion: 4.22.2, shortestPath: true`

**Workaround:** Ensure `aba.conf` holds the correct source version before
running Prepare Upgrade. Don't change `ocp_version` in aba.conf independently.

**Future consideration: retire mirror.conf after mirror install.**
Once the mirror is installed and loaded, `state.sh` is the single source of
truth for what's in the registry. `mirror.conf` is only needed during initial
setup (registry hostname, port, credentials, etc.). After install, all
runtime state (ocp_version, ocp_channel, operators, ocp_upgrade_from, etc.)
lives in `state.sh`. Long-term, `mirror.conf` could be consumed only at
install time and then absorbed into `state.sh`, eliminating the dual-source
confusion that caused this bug.

---

## Mirror reinstall: stale cluster association and cert mismatch

**Severity:** MEDIUM
**Status:** Planned
**Added:** 2026-07-08

**Problem:** When a mirror is freshly installed and loaded, the "Configure
OperatorHub" dialog lists clusters previously installed using an older mirror
at the same hostname and suggests running `aba day2`. This is wrong because
the cluster was built against the old mirror's cert and can't access the new one.

**Root cause:** ABA tracks cluster-to-mirror associations but doesn't
invalidate them on mirror reinstall (new cert = new identity).

**Possible fix:** Compare CA cert fingerprints before listing a cluster in
the post-load dialog. ~5 line change in the dialog logic.

**Reproducer:**
1. Install mirror, load images, install a cluster
2. Uninstall the mirror (`aba uninstall`)
3. Install a new mirror, load images
4. Dialog incorrectly lists old cluster and suggests `aba day2`

---

## TUI: "Upgrade Images Ready" should offer to run Day-2 inline

**Severity:** LOW
**Status:** Planned
**Added:** 2026-07-09

**Problem:** After Prepare Upgrade (U) syncs upgrade images, the TUI shows a
static msgbox. Should offer yesno to run Day-2 Configure OperatorHub inline,
following the established TUI chaining pattern.

**Complication:** No selected cluster at this point in the flow. Need cluster
selection first, or run on all installed clusters using this mirror.

**Files:** `tui/v2/tui-mirror.sh` lines 709-714 (sync path only, not save)

---

## day2-osus: channel set fails after cross-minor upgrade

**Severity:** HIGH — `aba day2-osus` errors out on upgraded clusters
**Status:** Planned
**Added:** 2026-07-10
**Related:** ISC upgrade mode / state.sh override (above) — same root theme: scripts derive version/channel from config files instead of the live cluster

**Problem:** `day2-config-osus.sh` builds the expected channel from `aba.conf`
(`ocp_channel` + `ocp_version` major.minor), e.g. `fast-4.20`. After a
cross-minor upgrade (4.20 → 4.21), the cluster only accepts 4.21+ channels
(`candidate-4.21, fast-4.21, ...`). The script runs:
```
oc adm upgrade channel "fast-4.20"
```
and gets:
```
error: the requested channel "fast-4.20" is not one of the available channels
(candidate-4.21, candidate-4.22, fast-4.21, fast-4.22),
you must pass --allow-explicit-channel to continue
```

**Root cause:** Line 290-291 of `scripts/day2-config-osus.sh`:
```bash
_ocp_ver_major=$(echo "$ocp_version" | cut -d. -f1-2)
_expected_channel="${ocp_channel}-${_ocp_ver_major}"
```
`$ocp_version` comes from `aba.conf` (the base install version), NOT the
cluster's actual running version. After upgrade, the cluster is on 4.21 but
the script still tries to set `fast-4.20`.

**Impact:**
- `aba day2-osus` fails on any cluster that has been upgraded cross-minor
- `aba day2` (which calls day2-osus) also fails

**Proposed fix:** Use the cluster's actual version to determine the channel:
```bash
# Get the cluster's running version (what it's AT, not what aba.conf says)
_cluster_ver=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null) || _cluster_ver=""
_ocp_ver_major=$(echo "${_cluster_ver:-$ocp_version}" | cut -d. -f1-2)
_expected_channel="${ocp_channel}-${_ocp_ver_major}"
```
Falls back to `$ocp_version` if the cluster is unreachable (pre-install).

**Files to change:**
- `scripts/day2-config-osus.sh` (line 290-291): derive channel from cluster version
- Consider same pattern anywhere else `ocp_version` from aba.conf is used to
  derive cluster-specific state (channel, graph URI, etc.)

**Broader theme:** Multiple scripts assume `aba.conf`'s `ocp_version` matches
the cluster's running version. After upgrade, this is no longer true. The
backlog item above (ISC upgrade mode / state.sh override) is the same class
of bug. A systematic audit of all `ocp_version` usage in cluster-facing
scripts would catch any remaining instances.

**Reproducer:**
1. Install cluster with `ocp_version=4.20.28`
2. Upgrade cluster to 4.21.23 via `aba upgrade --to 4.21.23 --force`
3. Run `aba day2-osus` → fails with channel error
4. Run `aba day2` → same failure

---

## Upgrade: review --force flag granularity

**Severity:** LOW — UX design question, not a functional bug
**Status:** Planned
**Added:** 2026-07-10

**Problem:** The `--force` flag on `aba upgrade` currently does two unrelated
things: (1) bypasses admin acknowledgment gates for cross-minor upgrades, and
(2) adds `--allow-upgrade-with-warnings` to tolerate transiently degraded
operators. These are distinct concerns — a user might want one without the other.

**Current implementation:** `--allow-upgrade-with-warnings` is added whenever
`--force` is specified (commit 7b9569ea). This works but conflates two intents.

**Proposed review:**
- Should `--force` be split into separate flags? E.g.:
  - `--force` = bypass admin ack gates only
  - `--force-warnings` or `--ignore-warnings` = tolerate degraded operators
  - `--force` with both behaviors as a convenience shortcut
- Or is the current single `--force` sufficient for the target audience?
- Also audit `--noask` behavior: currently auto-confirms `--allow-explicit-upgrade`
  prompts. Is this correct or should `--force` be required?

---

## Upgrade UX: pre-flight and monitoring improvements

**Severity:** MEDIUM — UX gaps that cause confusion during upgrades
**Status:** Planned
**Added:** 2026-07-10

**Current state:** `cluster-upgrade.sh` pre-flight checks ClusterVersion-level
conditions (`Failing`, `Upgradeable`) and warns the user. It also warns when
no OSUS graph is detected and prompts before adding `--allow-explicit-upgrade`.
After triggering the upgrade, ABA waits briefly for it to start, prints one
status snapshot from `oc adm upgrade status`, then exits telling the user to
monitor manually. This is inconsistent with the install workflow where `aba mon`
provides continuous monitoring.

**Suggested improvements:**

### A. Interactive `--allow-upgrade-with-warnings` prompt

Before triggering the upgrade, check for degraded/unavailable operators. If
unhealthy operators are found, show them and ask whether to proceed:
```
[ABA] Warning: 2 cluster operators are not fully healthy:
[ABA]   authentication  Available=False  (since 3m ago)
[ABA]   etcd            Degraded=True    (NodeInstallerProgressing)

[ABA] Proceed with --allow-upgrade-with-warnings? (y/n) [n]:
```
- If yes → add `--allow-upgrade-with-warnings` to the `oc adm upgrade` command
- If no → abort, let user fix operators first
- `--force` skips the prompt and adds the flag automatically (existing behavior)

This gives the user informed consent in interactive mode rather than a blind
rejection from OpenShift or a silent `--force` override.

### B. Per-operator pre-flight breakdown

Show which specific cluster operators are not healthy, not just the aggregate
ClusterVersion condition. Example:
```
[ABA] 3 of 35 cluster operators are degraded:
[ABA]   authentication   Available=False  (since 2m ago)
[ABA]   etcd             Progressing=True (NodeInstallerProgressing)
[ABA]   monitoring       Degraded=True    (PrometheusOperatorDown)
```

### C. Continuous upgrade monitoring (like `aba mon` for installs)

Currently after triggering the upgrade, ABA prints one snapshot and exits:
```
[ABA] Upgrade 4.21.23 → 4.22.4 is in progress!
= Control Plane =
Completion: 3% (1 operators updated, 0 updating, 33 waiting)
Duration:   46s (Est. Time Remaining: 1h14m)
...
[ABA] To monitor the upgrade, run:
[ABA]   oc adm upgrade status
```

For installs, `aba mon` provides continuous monitoring until completion. Upgrades
should have the same UX — either:
- `aba upgrade` continues monitoring by default (Ctrl-C to detach), OR
- `aba upgrade-mon` / `aba upgrade --monitor` for explicit re-attach

The monitoring loop would poll `oc adm upgrade status` periodically and exit
when ClusterVersion reports completion (or timeout/failure).

### D. Post-upgrade channel sanity

After a successful cross-minor upgrade, warn if the cluster channel doesn't
match what's expected for the new version. This would catch the `day2-osus`
channel bug earlier.

**Files:** `scripts/cluster-upgrade.sh` (pre-flight and monitoring sections)

---

## Cluster stability: wait after install and before day2

**Severity:** MEDIUM
**Status:** Planned
**Added:** 2026-07-10

**Problem:** Running `aba day2` immediately after install while the cluster is
still reconciling causes the marketplace-operator to overwrite mirrored
CatalogSources back to upstream defaults, also resetting
`OperatorHub.spec.disableAllDefaultSources`.

**Root cause:** Race condition — day2 patches OperatorHub and applies mirrored
CatalogSources, but the marketplace-operator is still restarting and reconciles
everything back to defaults after day2 finishes.

**Proposed fix (two parts):**

1. **Post-install stability gate:** After `aba install` completes (cluster
   reports installed), ABA should verify full cluster stability before declaring
   success. Poll `cluster_is_ready()` (all COs available, not progressing, not
   degraded) with a message like "Waiting for full cluster stability... hit
   Ctrl-C to skip". This protects users who immediately run `aba day2` after
   install — the install step itself guarantees the cluster is truly ready.

2. **Pre-day2 blocking wait:** In `day2.sh`, after the existing
   `warn_if_cluster_unstable` call (line 63), add a blocking wait for cluster
   stability before proceeding. Use the same logic as `cluster_is_ready()`.
   Fail or prompt the user if the cluster doesn't stabilize within a
   reasonable timeout (e.g. 15 minutes).

**Also audit other scripts for the same vulnerability:** any ABA command that
modifies cluster state (`day2-ntp`, `day2-osus`, `upgrade`, `shutdown`,
`startup`) should consider whether it needs a stability pre-check. A shared
helper (e.g. `require_cluster_stable`) could be extracted for reuse.

**Files likely affected:**
- `scripts/monitor-install.sh`: add post-install stability poll
- `scripts/day2.sh`: add blocking wait
- `scripts/include_all.sh`: extract `require_cluster_stable` helper
- `scripts/day2-config-ntp.sh`: consider adding stability check
- `scripts/day2-config-osus.sh`: consider adding stability check
- `scripts/cluster-upgrade.sh`: already has pre-flight checks, verify coverage

---

## `oc-mirror`: check port 55000 before invoking

**Severity:** LOW
**Status:** Planned
**Added:** 2026-07-10

**Problem:** `oc-mirror` v2 starts an ephemeral local registry on port 55000
during `mirrorToDisk` and `diskToMirror` operations. If a previous `oc-mirror`
process didn't release the port cleanly (crash, kill, slow shutdown),
`oc-mirror` panics with `listen tcp :55000: bind: address already in use`
instead of retrying gracefully. ABA's `--retry` loop recovers, but wastes a
full retry cycle (minutes of re-discovery) for what is typically a 1-2 second
port release delay.

**Proposed fix:** Before invoking `oc-mirror`, check if port 55000 is in use.
If so, wait up to ~30 seconds for it to be released. If still held, warn the
user and identify the process. Implement in `scripts/reg-save.sh` and
`scripts/reg-sync.sh` (or wherever `oc-mirror` is invoked).

```bash
# Example
for i in $(seq 1 30); do
    ss -tlnp | grep -q ':55000 ' || break
    sleep 1
done
```

**Files likely affected:**
- `scripts/reg-save.sh`
- `scripts/reg-sync.sh`
- `scripts/reg-load.sh` (if oc-mirror also uses port 55000 for diskToMirror)

---

## Refactors

- **ARCH variable normalization**: `include_all.sh` normalizes ARCH to the Go/OCI convention (`amd64`), but ISO filenames and Makefiles use `uname -m` (`x86_64`). Scripts like `vmw-upload.sh`, `kvm-upload.sh`, and `cluster-write-usb.sh` must override ARCH after sourcing `include_all.sh`. Provide both `ARCH` (Go: `amd64`) and `ARCH_UNAME` (kernel: `x86_64`) from `include_all.sh` so scripts don't need per-file overrides.

---

## Feature: Merge int_connection and mirror_name into a single config value

**Status:** Planned
**Added:** 2026-07-10

**Problem:** `cluster.conf` has two fields (`int_connection` and `mirror_name`)
that encode one mutually exclusive decision: where does the cluster pull images
from? The empty value meaning "use mirror" is easy to misread.

**Proposed change:** Replace both with a single key (e.g. `image_source`) that
accepts: `direct`, `proxy`, or `<mirror-dir-name>` (default: `mirror`).

**Migration notes:**
- Accept old keys (`int_connection`, `mirror_name`) for at least one release
  cycle so existing `cluster.conf` files and already-built `--primed` bundles
  keep working.
- `proxy` and `direct` become reserved mirror directory names — document this.
- The key name `int_connection` carrying a mirror name reads oddly; `image_source`
  is a cleaner name (community suggestion).

**Files likely affected:**
- `scripts/include_all.sh` (`normalize-cluster-conf`): emit new key, map old keys
- `scripts/create-install-config.sh`: read new key
- `scripts/create-agent-config.sh`: read new key
- `templates/Makefile.cluster`: dependency logic referencing int_connection
- `tui/v2/tui-cluster.sh`: "Image source" toggle on Interfaces page
- `cli/cluster-flags.sh` (or wherever `--int-connection` is parsed)
- `others/help-cluster.txt`: update flag documentation
- Migration shim in `normalize-cluster-conf` to read old keys and emit new key

**Community feedback (Mateusz):** "One value with direct/proxy/<mirror name>,
defaulting to mirror, is cleaner. Accept old keys for a release or two. proxy
and direct become reserved dir names. The key name itself might deserve a rename
— something like image_source."
