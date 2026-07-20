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
**Status:** Done (v1.1.4: ocp_version removed from state override; mirror_ocp_version added as mirror fact)
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

## TUI Day-2: add "Cluster login" shell item

**Severity:** LOW — UX convenience
**Status:** Planned
**Added:** 2026-07-13

**Problem:** When troubleshooting or inspecting a cluster from the TUI, the
user must exit the TUI, find the kubeconfig, export it, and run `oc` commands
manually. This breaks flow, especially for less experienced users.

**Proposed fix:** Add a "Cluster login" (or "Shell") menu item to the Day-2 /
Cluster Management menu. When selected, it drops the user into an interactive
bash shell with `KUBECONFIG` already exported and `oc` on the PATH. The user
can run any `oc` commands, then `exit` to return to the TUI.

**Implementation idea:**
```bash
# In the Day-2 menu handler:
_kc=$(cluster_kubeconfig 2>/dev/null)
export KUBECONFIG="$_kc"
clear
echo "[ABA] Logged into cluster: $(oc whoami --show-server 2>/dev/null)"
echo "[ABA] Type 'exit' to return to the TUI."
bash --login
```

**Considerations:**
- Use `bash --login` (not `exec bash`) so the TUI resumes on `exit`
- Show cluster name/API URL in the shell prompt or banner
- `aba shell` CLI command already exists — reuse the same logic
- Consider adding a custom `PS1` prompt (e.g. `[aba:clustername] $`) to
  remind the user they're inside a TUI subshell

**Files to change:**
- `tui/v2/tui-cluster.sh`: add menu item to Day-2 menu and handler

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
**Status:** Planned
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

## Automated infrastructure services (`infra=auto`)

**Severity:** MEDIUM — major UX improvement for new users
**Status:** Planned
**Added:** 2026-07-16

**Problem:** Users new to OpenShift must manually install and configure DNS
(dnsmasq), NTP (chronyd), and firewall rules before ABA can install a cluster.
This is the #1 barrier to entry for beginners.

**Proposed fix:** New `aba.conf` setting `infra=auto` (default: `manual`) that
makes ABA automatically install and configure these services on the bastion.
Per-cluster DNS records are added at install time and removed on delete.

**Design doc:** `ai/DESIGN-infra-auto.md`

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
