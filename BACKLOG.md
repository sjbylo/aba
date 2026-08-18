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

## Validate SSH key files (private vs public)

**Severity:** LOW
**Status:** Planned
**Added:** 2026-07-20

**Problem:** Users can accidentally pass a public key (`.pub`) where a private
key is expected (e.g. `reg_ssh_key` in mirror.conf, `ssh_key_file` in
cluster.conf). SSH fails with a cryptic "error in libcrypto" message.

**Proposed fix:** Add a validation helper that:
1. Warns if file ends in `.pub` ("looks like a public key")
2. Checks file contents: private keys contain `-----BEGIN ... PRIVATE KEY-----`
3. Apply to `reg_ssh_key` (mirror.conf) and `ssh_key_file` (cluster.conf)
   in their respective `verify-*-conf()` functions.

**Workaround:** Use the correct key path (e.g. `~/.ssh/id_rsa` not `~/.ssh/id_rsa.pub`).

---

## ISC upgrade mode broken by state.sh ocp_version override

**Severity:** HIGH — produces wrong ISC, upgrade sync downloads wrong images
**Status:** Mostly Done (v1.1.4: ocp_version removed from state override; mirror_ocp_version added as mirror fact; mirror_ocp_upgrade_from tracked in state.sh). ISC template not yet updated to use mirror_ocp_upgrade_from.
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
**Status:** Done (day2-config-osus.sh now derives channel from cluster's actual version)
**Added:** 2026-07-10
**Closed:** 2026-07-10
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

## day2-osus: auto-run day2 if CatalogSources not yet applied

**Severity:** LOW — UX improvement, reduces manual steps
**Status:** Planned
**Added:** 2026-07-13

**Problem:** When the user runs `aba day2-osus` on a cluster where `aba day2`
has not yet been run, it fails with "cincinnati-operator not available in
OperatorHub" because the mirrored CatalogSources haven't been applied yet.
The user has to manually run `aba day2` first, then re-run `aba day2-osus`.

**Current behavior:** `day2-config-osus.sh` checks for the `cincinnati-operator`
package manifest and aborts if not found, telling the user to run `aba day2`.

**Proposed fix:** Before aborting, detect whether `aba day2` has been run on
this cluster (e.g. check if mirrored CatalogSources exist, or check for a
day2 marker). If not, offer to run it automatically:
```
[ABA] CatalogSources not yet applied to this cluster.
[ABA] Running 'aba day2' first...
```
Then continue with the OSUS installation. In `--yes`/non-interactive mode,
run `day2` automatically without prompting.

**Considerations:**
- `day2` includes more than just CatalogSources (IDMS, signatures, NTP) —
  running it as a prerequisite is safe and idempotent
- Need to wait for CatalogSource sync after `day2` before retrying the
  `cincinnati-operator` package manifest check
- Should NOT auto-run `day2` if it was already run but the operator is
  genuinely missing (different failure mode)

**Files to change:**
- `scripts/day2-config-osus.sh`: add day2 prerequisite check before the
  `cincinnati-operator` availability check

---

## TUI Day-2: "Open Cluster Login Terminal" in all Day-2 menus

**Severity:** LOW — UX convenience
**Status:** Done (v1.1.6: "L" menu item in Day-2 menu)
**Added:** 2026-07-13
**Updated:** 2026-07-25
**Closed:** 2026-07-25

**Problem:** When troubleshooting or inspecting a cluster from the TUI, the
user must exit the TUI, find the kubeconfig, export it, and run `oc` commands
manually. This breaks flow, especially for less experienced users.

**Proposed fix:** Add an "Open Cluster Login Terminal" (or similar) menu item
to ALL Day-2 menu items. When selected, it opens a full terminal (do not ask
which terminal to run it in) and runs:

```bash
. <(aba -d mycluster login) || . <(aba shell)
```

**Key requirements:**
- Present in ALL Day-2 menu items (not just one cluster menu)
- Opens a proper full terminal directly — no dialog asking which terminal
- Uses `aba login` (sources kubeconfig) with fallback to `aba shell`

**Files to change:**
- `tui/v2/tui-cluster.sh`: add menu item to all Day-2 menus and handler

---

## day2-ntp: apply NTP config without node reboot where possible

**Severity:** MEDIUM — reduces downtime during NTP configuration
**Status:** Planned
**Added:** 2026-07-13

**Problem:** `aba day2-ntp` applies NTP configuration via MachineConfig, which
triggers the MCO to drain, reboot, and reconcile every node. On a 3-node
compact cluster this means ~15-30 minutes of rolling reboots just to change
`chrony.conf`. On SNO, the entire cluster goes offline during the reboot.

**Current implementation:** `day2-config-ntp.sh` generates Butane specs for
master/worker MachineConfigs, applies them with `oc apply`, then waits for
MCO to process (Phase 1a/1b), chrony.conf to appear (Phase 2), NTP sync
(Phase 3), and API recovery (Phase 4).

**Proposed improvement:** Where possible, apply NTP configuration directly
without requiring a reboot:

1. **Direct chrony reconfiguration via SSH:** After applying the MachineConfig
   (for persistence across future reboots), also SSH to each node and:
   ```bash
   # Write chrony.conf directly
   sudo cp /tmp/chrony.conf /etc/chrony.conf
   # Reload chrony without reboot
   sudo systemctl restart chronyd
   ```
   This gives immediate NTP sync without waiting for MCO reboot.

2. **MCO rebootless updates (OCP 4.14+):** OpenShift 4.14+ supports
   `In-place updates` for certain MachineConfig changes (files under
   `/etc/` that don't require a kernel or kubelet restart). Chrony config
   changes may qualify. Investigate whether the MCO can apply chrony.conf
   changes without draining/rebooting nodes.

3. **`chronyc` live reconfiguration:** Use `chronyc` commands to add/remove
   NTP sources at runtime without touching `chrony.conf`:
   ```bash
   chronyc add server <ntp-host> iburst
   chronyc delete <old-source>
   ```
   Combined with MachineConfig for persistence, this gives instant sync
   with zero disruption.

4. **NodeDisruptionPolicy (OCP 4.16+):** Apply a `MachineConfiguration`
   object with a `nodeDisruptionPolicy` that tells the MCO to restart
   `chronyd.service` instead of rebooting when `/etc/chrony.conf` changes:
   ```yaml
   spec:
     nodeDisruptionPolicy:
       files:
       - actions:
         - restart:
             serviceName: chronyd.service
           type: Restart
         path: /etc/chrony.conf
   ```
   Apply this BEFORE the chrony MachineConfigs. The MCO will restart chronyd
   instead of draining/rebooting. Only applies to OCP >= 4.16; on older
   clusters, fall back to current behaviour. Phase 1a wait and Phase 4
   (API recovery post-reboot) can be skipped when the policy is active.
   Ref: https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/machine_configuration/machine-config-node-disruption_machine-configs-configure

**Approach:** On OCP 4.16+, use NodeDisruptionPolicy (approach 4) as the
primary method -- cleanest, fully supported by the MCO. On older clusters
(4.12-4.15), fall back to direct SSH + restart chronyd (approach 1). Keep
the MachineConfig apply in all cases for persistence.

**Compatibility:** Check which approach works on OCP 4.12+ (minimum supported).
`chronyc` commands and `systemctl restart chronyd` should work on all versions.
MCO rebootless updates are 4.14+. NodeDisruptionPolicy is 4.16+.

**Files to change:**
- `scripts/day2-config-ntp.sh`: add direct SSH chrony reconfiguration before
  or after MachineConfig apply; conditionally skip MCO reboot wait

---

## Catalog prefetch: download next minor in background

**Severity:** LOW — UX improvement, reduces wait time
**Status:** Mostly Done (prefetch now downloads upgrade-target minors from Cincinnati graph, which includes the next minor when available). Previous minor is still fetched too — could be dropped.
**Added:** 2026-07-13

**Problem:** When a user selects OCP 4.21, the operator catalog for 4.22 is not
downloaded until the user explicitly sets an upgrade target. This means the user
has to wait for the 4.22 catalog download when they later initiate an upgrade.
Catalogs are large (~200-500MB per catalog type) and take minutes to pull.

**Current behavior:** `aba_prefetch_catalogs()` downloads the current minor
(e.g. 4.22) and then the **previous** minor (e.g. 4.21). The previous minor
download is rarely useful — if you're on 4.22, you don't need 4.21 catalogs.

**Proposed change:** Replace the previous-minor prefetch with a **next-minor**
prefetch. After downloading the current version's catalogs, speculatively
download the next minor line in the background:

1. Download **current** minor catalogs (e.g. 4.22) — blocking, needed now
2. Download **next** minor catalogs (e.g. 4.23) — background, sequential,
   silent on failure (version may not exist yet)

**Priorities within each version:**
- Download the **redhat-operator** catalog first (most used, contains the
  operators users care about: ACM, ODF, Virt, etc.)
- Then certified-operator, then community-operator
- This ensures the highest-value catalog is ready fastest

**Constraints:**
- Sequential downloads only (one catalog at a time) — minimize bandwidth
  and disk disruption to active operations
- Silent failure — if the next minor doesn't exist yet, exit quietly
- No cross-major speculation (don't try 5.0 when on 4.x) — different
  catalog image naming, too speculative
- Respect existing TTL caching (`CATALOG_CACHE_TTL`) — don't re-download
  catalogs that are already cached

**Files to change:**
- `scripts/include_all.sh` (`aba_prefetch_catalogs()`): replace previous-minor
  logic with next-minor logic; reorder catalog downloads within
  `download_all_catalogs()` to prioritize redhat-operator
- `scripts/include_all.sh` (`download_all_catalogs()`): consider adding a
  `priority_order` parameter or reordering the internal catalog list
- `scripts/prefetch-catalogs.sh`: no change needed (thin wrapper)

---

## Automated infrastructure services (`aba setup dns/ntp`)

**Severity:** MEDIUM — major UX improvement for new users
**Status:** Done (v1.1.5: `aba setup dns`, `aba setup ntp`, `aba remove dns`, `aba remove ntp`; per-cluster DNS hooks in Makefile)
**Added:** 2026-07-16
**Closed:** 2026-07-24

**Problem:** Users new to OpenShift must manually install and configure DNS
(dnsmasq), NTP (chronyd), and firewall rules before ABA can install a cluster.
This is the #1 barrier to entry for beginners.

**Implemented:** `aba setup dns` / `aba setup ntp` configure services on the
bastion. Per-cluster DNS records are added at install time (`.infra-dns` marker
in Makefile) and removed on delete. VIP auto-allocation when ABA manages DNS.

**Design doc:** `ai/DESIGN-infra-auto.md`

---

## quay-ng: transition to GA (mirror-registry v3.0)

**Severity:** LOW — tracking item, no action until upstream ships GA
**Status:** Waiting on upstream
**Added:** 2026-07-21

**Context:** The Go-based mirror-registry rewrite (currently `quay-ng` in ABA)
will ship as "mirror-registry v3.0". ABA already supports it as a BETA vendor.

**When GA ships, ABA needs:**
- Switch `_QUAY_NG_IMAGE` from `quay.io/sjbylo/quay-mirror:dev` to official image
- Evaluate offline install mode (binary + tar — may eliminate container/Quadlet)
- Re-test `-init-password-stdin` flag (merged upstream, not in current image)
- Re-test `-port` flag (PR merged: https://github.com/quay/quay/pull/6543)
- Rename vendor display from "quay-ng [BETA]" to GA (internal name can stay)
- Update bundle workflow for official offline delivery format

**Design doc:** `ai/DESIGN-quay-ng-vendor.md`

---

## Refactors

- **ARCH variable normalization**: `include_all.sh` normalizes ARCH to the Go/OCI convention (`amd64`), but ISO filenames and Makefiles use `uname -m` (`x86_64`). Scripts like `vmw-upload.sh`, `kvm-upload.sh`, and `cluster-write-usb.sh` must override ARCH after sourcing `include_all.sh`. Provide both `ARCH` (Go: `amd64`) and `ARCH_UNAME` (kernel: `x86_64`) from `include_all.sh` so scripts don't need per-file overrides.

---

## Feature: Merge int_connection and mirror_name into a single config value

**Status:** Done (v1.2.3)
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

---

## Multi-version operator catalogs: day2 applies wrong catalog after upgrade sync

**Severity:** HIGH — can break operators on existing clusters
**Status:** Planned
**Added:** 2026-07-11
**Related:** ISC upgrade mode / state.sh override (above), day2-osus channel bug (above)

**Problem:** When a mirror is upgraded (e.g. 4.21 → 4.23), `oc-mirror` generates
CatalogSource files in `working-dir/cluster-resources/` that reference the
**target** version's catalog (`redhat-operator-index:v4.23`). Running `aba day2`
on an existing 4.21 cluster after the upgrade sync applies v4.23 CatalogSources
to a 4.21 cluster, breaking operator resolution.

**Details:**
1. Each `oc-mirror` sync creates a filtered catalog image tagged by OCP
   major.minor (e.g. `:v4.21`, `:v4.23`). These are independent images
   containing operators compatible with **that** OCP version only.
2. `oc-mirror` is additive — old catalog images (v4.21) remain in the registry
   after a v4.23 sync. The images are fine.
3. However, `working-dir/cluster-resources/cs-*.yaml` is **overwritten** on each
   sync. After a v4.23 sync, these files point to v4.23 catalogs only.
4. `day2.sh` blindly applies whatever CS files exist — no version awareness.
5. The v4.23 catalog contains operators designed for 4.23 APIs. Installing them
   on a 4.21 cluster can break because the operators may use APIs or channels
   that don't exist in 4.21.

**Impact scenarios:**

| Scenario | Result |
|----------|--------|
| 4.21 cluster, `day2` already run before upgrade sync | Safe — existing CatalogSources still point to v4.21 |
| 4.21 cluster, `aba day2` run AFTER v4.23 sync | **BREAKS** — v4.23 CatalogSources applied to 4.21 cluster |
| New cluster at 4.21 from same mirror | **Risky** — `day2` applies v4.23 CatalogSources |
| Stale v4.21 catalog (frozen from original sync) | No security patches for 4.21 operators unless re-synced |

**Proposed fix (two parts):**

### Part 1: Version-guard in day2.sh

Before applying CatalogSources, query the cluster's actual version and compare
it to the catalog version referenced in the CS file. Warn/abort if they don't
match:
```bash
_cluster_ver=$(oc get clusterversion version \
  -o jsonpath='{.status.desired.version}' 2>/dev/null) || _cluster_ver=""
_cluster_major=$(echo "${_cluster_ver:-$ocp_version}" | cut -d. -f1-2)
# Extract catalog version from CS image reference (e.g. v4.23)
_cs_ver=$(grep -oP 'operator-index:v\K[0-9]+\.[0-9]+' "$f" | head -1)
if [ "$_cs_ver" ] && [ "$_cluster_major" != "$_cs_ver" ]; then
    aba_warning "CatalogSource references v$_cs_ver but cluster is at $_cluster_major — skipping"
    continue
fi
```

### Part 2: Multi-version operator catalogs in ISC

When generating the ISC for an upgrade, include operator catalog entries for
**both** the source and target versions. This ensures `oc-mirror` syncs operator
images for all versions in use into the mirror:
```yaml
operators:
- catalog: registry.redhat.io/redhat/redhat-operator-index:v4.21
  packages:
  - name: web-terminal
- catalog: registry.redhat.io/redhat/redhat-operator-index:v4.23
  packages:
  - name: web-terminal
```

**Complication with Part 2:** `oc-mirror` generates one CS file per catalog name
(not per version tag), so v4.21 and v4.23 entries collide in `cs-redhat-operator-
index.yaml`. The images are synced correctly, but only one CS file survives.
This is acceptable if `day2.sh` is version-aware (Part 1) — it can construct
the correct CatalogSource image reference using the cluster's version rather
than relying on the oc-mirror-generated CS file.

**Alternative to Part 2:** Document that mixed-version environments require
separate sync cycles. Users who upgrade the mirror but still have old clusters
must run a separate sync for the old version to refresh its operator catalog.

**Files to change:**
- `scripts/day2.sh`: add version-guard before CS application loop (~line 284)
- `scripts/reg-create-imageset-config.sh`: optionally emit dual catalog entries
- `scripts/add-operators-to-imageset.sh`: handle dual catalog version logic
- `templates/imageset-config.yaml.j2`: support dual operator catalog blocks

---

## E2E: operator set installation smoke tests

**Severity:** MEDIUM — missing operator dependencies silently break bundle builds
**Status:** Planned
**Added:** 2026-07-12

**Problem:** Operator sets (`templates/operator-set-*`) list packages and their
dependencies, but there is no automated test that verifies these sets actually
install correctly. When upstream adds new dependencies (e.g. `ocs-tls-profiles`
in ODF 4.22), the sets become stale and bundle builds fail with cryptic
`ResolutionFailed` errors. This was caught manually; it should be caught by CI.

**Proposed fix:** Add E2E tests that mirror and install the most important
operator sets end-to-end, verifying that all expected CSVs reach `Succeeded`:

- `operator-set-acm` (Advanced Cluster Management)
- `operator-set-ai` (Assisted Installer / Infrastructure Operator)
- `operator-set-odf` (OpenShift Data Foundation)
- `operator-set-odfdr` (ODF Disaster Recovery)
- `operator-set-quay` (Quay)
- `operator-set-sec` (ACS / Compliance / File Integrity)
- `operator-set-virt` (OpenShift Virtualization)

Each test would:
1. Configure `mirror.conf` with the operator set
2. Sync/save + load the operator catalog and images
3. Install the operator(s) on a test cluster
4. Wait for all expected CSVs to reach `Succeeded`
5. Report any `ResolutionFailed` subscriptions (missing dependencies)

**Trigger:** Run at least once per minor OCP version bump (e.g. 4.21 → 4.22)
to catch new dependencies early. Could also run on any change to
`templates/operator-set-*` files.

**Files:**
- New suite(s) under `test/e2e/suites/`
- `templates/operator-set-*` (validated, not changed)

---

## Bundle additional CLI tools (virtctl, etc.)

**Severity:** LOW — UX convenience for air-gapped users
**Status:** Done
**Added:** 2026-07-25
**Done:** 2026-07-26

**Solution:** Optional `download-extra-clis` / `install-extra-clis` in `cli/Makefile`
(virtctl, kn, tkn, helm, opm, argocd, roxctl). Auto-downloaded on `aba bundle` and
`aba save` via `cli_download_extra_clis` (warn-and-continue). Not part of everyday
`download-all`. Disco installs extras when artifacts already exist under `cli/`.

**Follow-ups (optional):** operator-set-conditioned inclusion to shrink download size.

---

## Upgrade: Upgradeable=False pre-flight check in CLI

**Severity:** MEDIUM — CLI silently hits confusing OpenShift errors
**Status:** Planned
**Added:** 2026-08-01

**Problem:** The TUI checks `Upgradeable=False` before triggering an upgrade
(`_upgrade_preflight_check` in `tui-cluster.sh`), but the CLI path (`aba upgrade`)
does not. When an admin acknowledgment gate is active (e.g. cross-minor upgrade
4.14→4.15 requiring API removal acknowledgment), the CLI upgrade fails with a
confusing OpenShift error instead of a clear ABA message.

**Proposed fix:** Add an `Upgradeable=False` check to `cluster-upgrade.sh` before
executing the upgrade command. If detected:
1. Show the `Upgradeable=False` reason and message
2. For admin ack gates: offer to auto-acknowledge with `oc adm upgrade ack`
3. For other blockers: abort with a clear message

The check already exists in `tui-cluster.sh` (`_upgrade_preflight_check`) — the
logic should be extracted to a shared function in `include_all.sh` or moved
into `cluster-upgrade.sh` itself so both TUI and CLI benefit.

**Files to change:**
- `scripts/cluster-upgrade.sh`: add `Upgradeable=False` check before upgrade
- `tui/v2/tui-cluster.sh`: refactor `_upgrade_preflight_check` to share logic
- `scripts/include_all.sh`: optional shared helper

---

## Feature: Per-node / per-role cluster configuration

**Severity:** MEDIUM — blocks some bare-metal use cases without `--primed` workaround
**Status:** Planned
**Added:** 2026-08-01

**Problem:** `cluster.conf` provides a single set of config values applied uniformly
to all nodes of a given role. Some bare-metal deployments need:

- **Per-role NIC names** (`ports_master=ens1f0`, `ports_worker=ens2f1`) — masters
  boot from one interface, workers from another.
- **Per-node `rootDeviceHints`** — each physical server has a unique disk identifier
  (e.g. `/dev/disk/by-path/...` or serial number).

**Current workaround:** Use `aba bundle --primed` to supply a hand-crafted
`agent-config.yaml` that ABA bundles as-is (the `.primed` marker skips regeneration).

**Proposed approach:**
- Extend `cluster.conf` syntax to accept per-role and optionally per-node overrides
- Per-role: `ports_master=`, `ports_worker=` (already partially supported)
- Per-node: new config file or extended `macs.conf` format with per-node fields
- Must remain backward compatible with existing single-value `ports=` syntax

**Files likely affected:**
- `scripts/include_all.sh` (`normalize-cluster-conf`): parse new per-role keys
- `templates/agent-config.yaml.j2`: conditional per-node rootDeviceHints
- `scripts/create-cluster-conf.sh`: new prompts/validation
- `devel/01-SPEC.md`: document the extended config model

---

## TUI upgrade dialog: show conditional versions inline instead of toggle

**Severity:** LOW
**Status:** Planned
**Added:** 2026-08-03

**Problem:** The upgrade dialog uses a "W" toggle to show/hide conditional
(not-recommended) versions. This hides available options behind a toggle the
user may not discover, adding unnecessary complexity.

**Proposed fix:**
- Remove the "Include conditional versions" (W) toggle entirely
- Always show all versions in the list, annotating conditional ones
  (e.g. `4.21.26 (conditional)`)
- When the user selects a conditional version, show a confirmation dialog
  with the specific reason/risk from the OSUS graph before proceeding
- Automatically pass `--allow-not-recommended` to `aba upgrade` for
  conditional versions (already implemented)
- Keep the Force (F) toggle as-is — it serves a different purpose

**Benefit:** Simpler dialog, all options visible at once, user makes an
informed choice without needing to know about the toggle.

## TUI upgrade dialog: warn when versions cannot be validated without OSUS

**Severity:** MEDIUM
**Status:** Planned
**Added:** 2026-08-03

**Problem:** When OSUS is not installed, the TUI upgrade dialog shows all
mirrored versions as "recommended" because there is no graph to classify
them. The user discovers a version is conditional only AFTER day2 runs and
OSUS is installed mid-upgrade — wasting several minutes. Internet access
cannot be assumed (the cluster being upgraded is disconnected).

**Proposed fix:**
- In the TUI upgrade dialog header (where `[no OSUS]` is shown), add a
  clear warning: "Upgrade recommendations cannot be validated without OSUS.
  Some versions may have known issues."
- In `aba upgrade` CLI output (non-TUI), show a similar warning before
  listing available versions when OSUS is not installed.
- The existing "Tip: Install OSUS..." message should be more prominent
  when showing unvalidated versions.
- Do NOT attempt to query public Cincinnati graph — internet connectivity
  cannot be assumed on a disconnected cluster's bastion.

**Benefit:** User is informed up-front that version classification is
best-effort without OSUS, and is encouraged to install OSUS before
choosing an upgrade target.

---

## TUI "Test Connection" should validate vSphere/KVM resources, not just connectivity

**Severity:** MEDIUM — user discovers misconfigured resources only at install time
**Status:** Planned
**Added:** 2026-08-08

**Problem:** The TUI's "Test Connection" button in VMware/ESXi Configuration
(`_test_vmw_connection` in `tui-cluster.sh`) only runs `govc about`, which
validates TCP/TLS/auth to vCenter. It does NOT check whether the configured
Datastore, Cluster, Network, Datacenter, or VM Folder actually exist. A user
can enter "Datastore4-S4x" (a typo), see "Connection Successful", and only
discover the error much later during `aba install` when the preflight check
runs.

The comprehensive validation already exists in `scripts/preflight-check-vsphere.sh`
(Layer 3: resource existence checks for datastore, cluster, network, datacenter,
folder, resource pool). The same gap exists for KVM (`_test_kvm_connection`
only runs `virsh version`).

**Proposed fix:**
1. Create an ABA core command `aba preflight-conn` (or a `--light` flag on
   the existing `preflight-check.sh`) that runs only the connectivity and
   resource-existence checks (Layers 1-3), skipping the slower privilege
   validation (Layer 4). Silent on success, shows only errors.
2. TUI's "Test Connection" calls this command via `run_once` in the background.
   Shows an infobox while running, then displays results: either "all OK" or
   a list of resources that don't exist.
3. Extend to KVM: validate that the storage pool, network bridge, and
   libvirt URI target are reachable.
4. Keep the code DRY: the TUI is a dumb consumer — it calls the ABA core
   command, displays the output. No resource validation logic in TUI code.
5. Design for future platforms (e.g. OpenShift Virtualization): the core
   command dispatches to platform-specific checks, TUI doesn't need to know.

**Files to change:**
- `scripts/preflight-check.sh`: add `--light` / `--conn-only` mode
- `scripts/preflight-check-vsphere.sh`: expose Layers 1-3 as a callable subset
- `scripts/aba.sh`: add `preflight-conn` subcommand (or route `--light` flag)
- `tui/v2/tui-cluster.sh`: replace `_test_vmw_connection` / `_test_kvm_connection`
  with calls to the core command
- `tui/v2/tui-lib.sh`: optional shared helper for run_once + display pattern

**Ref:** Discussed in [TUI preflight and DRY refactoring](f52568ba-a878-4dfb-aa3d-dfcd6b0ac759) chat.

---

## Upgrade: detect stale OSUS graph when cluster version not in graph

**Severity:** MEDIUM — user gets confusing "not an available upgrade" error
**Status:** Planned
**Added:** 2026-08-09

**Problem:** When a cluster is upgraded via a connected path (e.g. z-stream
4.21.27 → 4.21.28) but the mirror's ISC still has `minVersion: 4.21.27` with
`shortestPath: true`, re-syncing the mirror does NOT add 4.21.28 to the OSUS
graph. The shortest path from 4.21.27 → 4.22.8 is direct, skipping 4.21.28
entirely. A subsequent `aba upgrade --to 4.22.8` fails with:

```
[ABA] Error: Version 4.22.8 is not an available upgrade from 4.21.28.
```

The user has no indication that the problem is a stale `minVersion` in the ISC.

**Root cause:** The OSUS graph only contains versions that were mirrored.
With `shortestPath: true`, intermediate z-stream versions (4.21.28) are
excluded from the graph unless `minVersion` matches or includes them.

**Proposed fix (upgrade pre-flight):** In `cluster-upgrade.sh`, when the
upgrade fails because the target version is not in the graph, check whether
the cluster's current version exists as a node in the OSUS graph. If it
doesn't, show an actionable message:

```
[ABA] Error: Your cluster is on 4.21.28 but the local update graph has no
[ABA]        upgrade path from that version (only from 4.21.27).
[ABA]        Update minVersion in your imageset config to 4.21.28 and re-sync:
[ABA]          aba -d mirror sync
```

This tells the user exactly what to fix instead of the generic "not an
available upgrade" message.

**Partially implemented — gap is edge validation:**
`verify_upgrade_path_exists()` in `include_all.sh` already checks that the
source version exists as a **node** in the target channel's Cincinnati graph.
It's already called in `reg-sync.sh`, `reg-save.sh`, and
`reg-create-imageset-config.sh` as a pre-flight before oc-mirror.

However, it only checks **node presence**, not **edge existence**. In the
reproducer scenario, `4.21.28` IS a node in the `candidate-4.22` graph (so
the check passes), but the only edge from `4.21.28` goes to `4.22.9`, not
`4.22.8`. The function doesn't catch that.

**Fix: extend `verify_upgrade_path_exists()` to check edges:**
After confirming the source version is in the graph, also verify that a path
(direct edge or transitive via shortest-path) exists from `current_ver` to
the specific `target_ver`. If no path exists, return failure with a
diagnostic that includes the nearest valid target:

```bash
# Pseudo-logic addition to verify_upgrade_path_exists():
# 1. Fetch graph JSON (already done)
# 2. Check current_ver is a node (already done)
# 3. NEW: Check target_ver is a node
# 4. NEW: Check an edge exists from current_ver → target_ver
#    (walk edges, or at minimum check direct adjacency)
# 5. NEW: If no edge, find the nearest valid target from current_ver
#    and include it in the diagnostic output
```

**Additionally — expose as `aba` subcommand with `--shell` flag:**
Wrap the function as `aba validate-upgrade-path` (or similar) with a
`--shell` flag so the TUI can call it and parse the result to show its own
warning dialog:

```bash
# CLI usage (human-readable output)
aba validate-upgrade-path --from 4.21.28 --to 4.22.8 --channel candidate-4.22

# Shell mode (machine-parseable for TUI consumption)
aba validate-upgrade-path --from 4.21.28 --to 4.22.8 --channel candidate-4.22 --shell
# Output: VALID=0  NEAREST=4.22.9  (exit code 1 if no path)
```

The TUI calls this with `--shell` when the user selects or enters an upgrade
target in the "Prepare Upgrade" dialog, displaying a warning if no path
exists.

**Files to change:**
- `scripts/include_all.sh`: extend `verify_upgrade_path_exists()` to check edges
- `scripts/cluster-upgrade.sh`: add graph-node check when upgrade path not found
- `scripts/aba.sh`: expose as `aba validate-upgrade-path` subcommand with `--shell`
- `tui/v2/tui-mirror.sh`: call validator with `--shell` in upgrade dialog

**Reproducer:**
1. Install cluster at 4.21.27, mirror synced with `minVersion: 4.21.27`
2. Upgrade cluster to 4.21.28 via connected path
3. Re-sync mirror with same ISC (`minVersion: 4.21.27, shortestPath: true`)
4. Run `aba upgrade --to 4.22.8` → fails with "not an available upgrade"
5. Expected: clear message about stale minVersion

**Additional issue — TUI offers stale upgrade target:** The TUI "Prepare
Upgrade" dialog shows "Current target (4.22.8)" because that value is stored
in `mirror.conf` from a previous configuration. The TUI does not validate
whether that target is reachable from the cluster's actual current version.
If the cluster has moved (e.g. z-stream 4.21.27 → 4.21.28), the "current
target" may no longer be a valid upgrade path even though the TUI presents
it as option 1. The user selects it, syncs, and only discovers the problem
at upgrade time.

**Proposed TUI fix:** Validate the upgrade target against the Cincinnati
graph before proceeding with the sync. This applies to both the "Current
target" option and manual entry:

1. **Graph validation:** After the user selects or enters a target version,
   query the upstream Cincinnati graph (bastion is in connected mode, so
   internet is available) to check if a path exists from the cluster's
   actual version to the target. If no path exists, warn (not block):
   ```
   Warning: No upgrade path from 4.21.28 to 4.22.8 found in the
   candidate-4.22 channel. The nearest target is 4.22.9.
   Continue anyway? (y/n)
   ```
   Warn only — the user may have a legitimate reason to mirror specific
   versions even without a direct upgrade path.

2. **"Current target" annotation:** When showing the "Current target" option,
   check if it's still reachable from the cluster's actual version. If not,
   annotate it (e.g. "Current target (4.22.8) — no path from 4.21.28") or
   remove it from the list entirely.

3. **Cluster version discovery:** To determine the cluster's current version,
   use this priority:
   - If only one cluster directory exists, use that cluster
   - If the user last selected a cluster (TUI focus), use that one
   - If the cluster is accessible (kubeconfig works), query `oc get
     clusterversion` for the live version
   - If the cluster is not accessible, fall back to the version recorded
     in the cluster's state (install-time version or last-known version)
   - If no cluster exists yet, skip the validation (fresh install scenario)

**Files to change (TUI):**
- `tui/v2/tui-mirror.sh`: validate target against graph, annotate stale targets
- `tui/v2/tui-cluster.sh` (or shared helper): cluster version discovery logic

**Workaround:** Manually select "Next minor" or "Manual entry" instead of
"Current target" when the cluster has been z-stream upgraded since the last
mirror sync.

---

## Upgrade: auto-restart OSUS pod when graph-image content changes

**Severity:** MEDIUM — user gets "not an available upgrade" after a successful sync
**Status:** Planned (was prototyped and verified on testy@conno, then stashed for v1.2.3)
**Added:** 2026-08-16

**Problem:** After `aba sync` (or `aba load`) mirrors a new OCP version, the
`graph-image:latest` in the registry is updated with the new version's graph
data. However, the running OSUS pod does not pick up the change because:
- The OSUS operator only redeploys pods when the `graphDataImage` field in the
  `UpdateService` CR changes (different image reference), not when the content
  behind a `:latest` tag changes.
- The OSUS init container has `imagePullPolicy: Always`, but this only takes
  effect when the pod restarts — not while it's already running.

The user runs `aba upgrade --to 4.22.10` and gets "Version 4.22.10 is not an
available upgrade" even though the version was just synced successfully.

**Root cause:** Stale graph data in the running OSUS pod. The init container
cached the old `graph-image:latest` at pod creation time.

**Verified fix (tested on testy@conno 2026-08-16):**
In `cluster-upgrade.sh`, after the initial OSUS graph check fails to find the
target version:
1. Restart the OSUS pod: `oc delete pod -n openshift-update-service -l app=osus`
2. Wait for the new pod to be ready (init container re-pulls `graph-image:latest`)
3. Wait for the target version to appear in the graph
4. If still not found after restart, abort with the existing error message

The pod restart takes ~30-60 seconds (init container pull + graph load).
Graph data is available immediately after the pod reaches Ready state.

**Detection logic:** The graph is "stale" when:
- OSUS is installed and configured (`osus_upstream` is set)
- `oc adm upgrade --include-not-recommended` does not list the target version
- But we know the version was just synced (it's in the mirror registry)

**Implementation notes:**
```bash
# In cluster-upgrade.sh, after initial graph check fails:
if [ -z "$_graph_ok" ] && [ "$osus_upstream" ]; then
    aba_info "Target version not yet in OSUS graph — restarting OSUS pod ..."
    oc delete pod -n openshift-update-service -l app=osus 2>/dev/null || true
    # Wait for new pod Ready, then wait for target in graph
    aba_wait_show "Waiting for OSUS pod" 5 180 _osus_pod_ready || true
    aba_wait_show "Waiting for $target_ver in graph" 5 120 _osus_graph_has_target || true
    _osus_graph_has_target && _graph_ok=1
fi
```

**Design consideration:** Could also be triggered proactively after `aba day2`
(which applies updated CatalogSources/IDMS), since that's the natural point
where the cluster learns about new mirror content. But `cluster-upgrade.sh` is
the place where the failure actually manifests, so reactive restart there is
the minimum viable fix.

**Future enhancement:** Trigger OSUS pod restart from `aba day2` as a
background `run_once` task, so the graph is already fresh by the time the
user runs `aba upgrade`. See "Cluster-mirror auto-actions" below.

**Files to change:**
- `scripts/cluster-upgrade.sh`: add OSUS pod restart logic after graph check
- Also remove the early `aba_abort` that fires before the pod restart logic
  can be reached (the early check short-circuits on "some graph data but no
  target version")

**Workaround:** Manually restart the OSUS pod:
```bash
oc delete pod -n openshift-update-service -l app=osus
# Wait ~60s, then retry:
aba upgrade --to <version>
```

---

## Feature: Cluster-mirror auto-actions after sync/load

**Severity:** MEDIUM — reduces manual steps, prevents user confusion
**Status:** Planned
**Added:** 2026-08-16

**Problem:** After `aba sync` or `aba load` updates the mirror registry, the
user must manually determine which clusters need updating and run commands on
each one. The CLI just prints generic `aba -d <cluster> day2` hints. The TUI
has `_offer_day2_after_mirror_update()` which discovers clusters, but only
offers day2 — not other post-mirror actions. Several post-mirror actions are
needed depending on context.

**Core missing piece:** A shared `clusters_using_mirror()` function in
`include_all.sh` (not TUI code) that both CLI and TUI can call. The TUI
already has `list_installed_clusters()` + `int_connection` filtering in
`tui-lib.sh` — this logic should move to ABA core.

**Use cases requiring cluster discovery + action:**

| # | Trigger | Action on cluster(s) | Priority |
|---|---------|---------------------|----------|
| 1 | `sync`/`load` completes | Run `aba day2` (IDMS, CatalogSources, signatures) | HIGH — already prompted in TUI, but CLI is manual |
| 2 | `sync`/`load` adds new OCP version to graph-image | Restart OSUS pod to refresh graph data | MEDIUM — see "auto-restart OSUS pod" above |
| 3 | Cross-minor upgrade sync | Update OSUS channel on cluster to match target minor | MEDIUM — currently manual, can break `aba upgrade` |
| 4 | Mirror reinstall (new CA cert) | Warn that old clusters can't reach new mirror | MEDIUM — already in backlog (cert mismatch) |
| 5 | `aba day2` after upgrade sync | Skip CatalogSources whose version doesn't match cluster | HIGH — already in backlog (multi-version catalogs) |
| 6 | `aba upgrade` pre-flight | Query cluster's actual version, not aba.conf | MEDIUM — partially done, needs strengthening |

**Proposed design:**

### Phase 1: Core discovery function (prerequisite for everything else)

```bash
# include_all.sh
clusters_using_mirror() {
    # Returns list of installed cluster dirs that use the mirror
    # (int_connection is empty or unset = mirror mode)
    local _dir
    for _dir in ../*/.install-complete; do
        [ -f "$_dir" ] || continue
        _dir=$(dirname "$_dir")
        _dir=$(basename "$_dir")
        local _int_conn
        _int_conn=$(cd "$_dir" && source <(normalize-cluster-conf) 2>/dev/null && echo "${int_connection:-}") || true
        [ -z "$_int_conn" ] && echo "$_dir"
    done
}
```

Refactor `_offer_day2_after_mirror_update()` in `tui-lib.sh` to call this
function instead of duplicating the discovery logic.

### Phase 2: Post-mirror hook system

After `aba sync` or `aba load`, call a hook that iterates
`clusters_using_mirror()` and performs context-aware actions:

- **Always:** Print which clusters need `aba day2` (current behavior, improved)
- **If OSUS installed:** Restart OSUS pod (via `run_once` background task)
- **If upgrade sync:** Print upgrade command for each cluster
- **Future:** Auto-run day2 on single-cluster setups (with `--yes`)

### Phase 3: CLI `aba mirror clusters` subcommand

Expose cluster discovery as a user-facing command:
```bash
aba -d mirror clusters          # List clusters using this mirror
aba -d mirror clusters --json   # Machine-readable for scripting
```

**Files to change (Phase 1):**
- `scripts/include_all.sh`: add `clusters_using_mirror()` function
- `tui/v2/tui-lib.sh`: refactor `_offer_day2_after_mirror_update()` to use it
- `scripts/reg-sync.sh`: use discovery for smarter post-sync messages
- `scripts/reg-load.sh`: same

**Files to change (Phase 2):**
- `scripts/reg-sync.sh`: add post-sync hook calling discovery + actions
- `scripts/reg-load.sh`: same
- `scripts/cluster-upgrade.sh`: OSUS pod restart (separate backlog item)

**Dependency:** The OSUS pod restart item (above) can be implemented
independently as a reactive fix in `cluster-upgrade.sh`. The full auto-action
framework is additive — it makes the OSUS restart proactive rather than
reactive.

---

## Feature: Auto-update base version when all clusters have upgraded

**Severity:** MEDIUM — prevents stale base version causing wrong sync behavior
**Status:** Planned
**Added:** 2026-08-18
**Depends on:** Cluster-mirror auto-actions (clusters_using_mirror)

**Problem:** After upgrading all clusters from 4.21.28 to 4.22.9, the base
`ocp_version` in `aba.conf` still says `4.21.28`. Future `aba sync` operations
use this stale base version, and new cluster installs default to 4.21.28. The
user must manually update `aba.conf` on both the disconnected and connected
bastions.

**Proposed behavior:**

1. Query all clusters using this mirror (`clusters_using_mirror()`)
2. Get each cluster's running version (from externalized state in
   `~/.aba/clusters/` or live via `oc get clusterversion`)
3. Find the **lowest** running version across all clusters
4. If lowest > `ocp_version` in `aba.conf`:
   - Auto-update `ocp_version` in `aba.conf` on the local (disco) side
   - Tell the user to do the same on the connected bastion:
     ```
     [ABA] All clusters using this mirror are at 4.22.9 or higher.
     [ABA] Updated ocp_version in aba.conf: 4.21.28 → 4.22.9
     [ABA] Remember to update ocp_version on the connected bastion as well.
     ```

**When to trigger:** After `aba sync`, `aba load`, `aba day2`, or as part of
the post-mirror hook system (Phase 2 of Cluster-mirror auto-actions).

**Considerations:**
- Only update when ALL clusters are confirmed above the old version
- Use lowest version, not highest — safety net for mixed-version environments
- The connected-side update must be manual (ABA can't reach it from disco)
- Could also trigger after a successful `aba upgrade` completes

**Architecture:** All discovery, version comparison, and config update logic
lives in ABA core (`scripts/include_all.sh`, dedicated scripts). The TUI is a
dumb consumer — it calls core functions and displays results. No version
comparison or `aba.conf` mutation logic in TUI code.

**Files likely affected:**
- `scripts/include_all.sh`: version comparison logic across clusters
- `scripts/reg-sync.sh` / `scripts/reg-load.sh`: trigger point
- `scripts/aba.sh`: `ocp_version` update in `aba.conf`

---

## Feature: Purge unused images from mirror after all clusters upgrade

**Severity:** LOW — UX improvement, reclaims storage on constrained hosts
**Status:** Planned
**Added:** 2026-08-18
**Depends on:** Auto-update base version (above), clusters_using_mirror

**Problem:** After upgrading all clusters from 4.21 to 4.22, the old 4.21
release images and operator catalogs remain in the mirror registry, consuming
10-15GB+ of storage. In disconnected environments where mirror hosts have
limited disk, this waste adds up across multiple upgrade cycles.

**Proposed behavior:**

After confirming all clusters are at a higher version (see auto-update base
version item above), offer to purge unused images:

```
[ABA] Old release images for 4.21.x are no longer used by any cluster.
[ABA] Purge old images to reclaim disk space? (y/n) [n]:
```

**Critical safety warnings (must show before purge):**
- Purging is **destructive and irreversible** in a disconnected environment —
  there is no way to re-download the images without connectivity
- Old images are needed not just for installing new clusters at that version,
  but also for **running** existing clusters — if any cluster still references
  those images (e.g. for pod restarts, node reboots, operator reconciliation),
  pulling will fail
- Only safe when ALL clusters have fully completed the upgrade AND the old
  version's images are no longer referenced by any running workload

**Implementation approach:**
- Default to "no" — opt-in only
- Could use `oc-mirror` pruning or direct registry garbage collection
- Could expose as `aba -d mirror prune` command
- In `--yes`/non-interactive mode: **never auto-purge** — always require
  explicit interactive confirmation for destructive operations

---

## Feature: Manage additional images in ISC

**Severity:** MEDIUM — reduces manual YAML editing and ISC regeneration issues
**Status:** Planned
**Added:** 2026-08-18

**Problem:** The `additionalImages` section in the imageset-config.yaml (ISC)
is currently just commented-out examples. Users must manually edit the YAML to
add images like `ose-cli`, `support-tools`, or OpenShift Virtualization
container disks. Manual edits are error-prone and get overwritten when the ISC
is regenerated (e.g. after operator changes or upgrade prep).

**Proposed behavior:**

### ABA Core (CLI commands)

- `aba image add <image:tag>` — adds to a tracked list
- `aba image remove <image:tag>` — removes from tracked list
- `aba image list` — shows configured additional images
- The tracked list is stored persistently (e.g. `templates/additional-images`
  or a key in `mirror.conf`) and rendered into the ISC `additionalImages:`
  section automatically during ISC generation, just like operator sets.
- Images persist across ISC regeneration.

### Auto-add images based on operator sets

When the user selects an operator set, ABA should automatically add commonly
needed companion images. Examples:

| Operator set | Auto-added images |
|---|---|
| `operator-set-virt` | `quay.io/containerdisks/centos-stream:10`, `centos-stream:9`, `fedora:latest` |
| (all) | `registry.redhat.io/openshift4/ose-cli:latest`, `registry.redhat.io/rhel9/support-tools:latest` |
| (testing) | `quay.io/openshifttest/hello-openshift:1.2.0` |

Auto-added images should be presented to the user for confirmation (not
silently injected). The user can remove any they don't want.

### TUI (dumb consumer)

- Menu item under Mirror configuration to add/remove/view additional images
- Calls core commands, displays results
- No ISC editing or image list management logic in TUI code

**Architecture:** All image list management, operator-set association, and ISC
rendering lives in ABA core (`scripts/include_all.sh`, ISC template). The TUI
only calls core commands and displays results.

### Remove commented-out image examples from ISC template

Once `aba image add` is implemented, the commented-out `additionalImages`
block in `imageset-config.yaml.j2` (lines 26-35) should be removed. These
comments are currently used as **anchors** by the bundle build scripts
(`bundles/v2/scripts/02-configure-aba-and-imageset.sh` and
`bundles/bundle-create-test.sh`) via `uncomment_line`. Removing them before
migrating the bundle scripts to `aba image add` would **break the bundle
build pipeline**.

**Migration order:**
1. Implement `aba image add/remove/list` in ABA core
2. Migrate bundle scripts from `uncomment_line` to `aba image add`
3. Remove commented-out examples from the ISC template
4. Users who manually uncommented lines in generated ISCs will automatically
   get the clean format on next ISC regeneration

**Files likely affected:**
- `templates/imageset-config.yaml.j2`: render tracked image list, then remove
  commented-out examples (step 3)
- `scripts/reg-create-imageset-config.sh`: export image list for Jinja
- `scripts/aba.sh`: `image add/remove/list` subcommands
- `scripts/include_all.sh`: image list management functions
- `templates/additional-images` (new): persistent image list file
- `bundles/v2/scripts/02-configure-aba-and-imageset.sh`: migrate from
  `uncomment_line` to `aba image add` (step 2)
- `bundles/bundle-create-test.sh`: same migration (step 2)
- `tui/v2/tui-mirror.sh`: UI for image management (calls core)

---

**Architecture:** All cluster discovery, version checking, and pruning logic
lives in ABA core. The TUI only calls core commands and displays the result —
no pruning decisions, safety checks, or registry operations in TUI code.

**Files likely affected:**
- `scripts/include_all.sh`: cluster version discovery (shared with auto-update)
- New script `scripts/reg-prune.sh` or addition to existing reg-*.sh
- `scripts/aba.sh`: `prune` subcommand
- `tui/v2/tui-mirror.sh`: optional TUI integration (calls core, displays result)
