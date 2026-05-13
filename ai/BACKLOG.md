# ABA Backlog

## Refactor: Unify CLUSTER_NAME (uppercase) to cluster_name (lowercase) across all scripts

**Priority:** Medium
**Scope:** ~25 scripts in `scripts/` (vmw-*.sh, kvm-*.sh, monitor-*.sh, generate-image.sh, cluster-config.sh, check-macs.sh, cluster-rescue.sh, cluster-graceful-shutdown.sh)

### Problem

Two parallel variable conventions coexist:
- `cluster-config.sh` outputs uppercase: `CLUSTER_NAME`, `BASE_DOMAIN`, `CP_NAMES`, `WORKER_NAMES`, `CP_REPLICAS`, `WORKER_REPLICAS`
- `normalize-cluster-conf` outputs lowercase: `cluster_name`, `base_domain`, `num_masters`, `num_workers`

~80+ references to `$CLUSTER_NAME` across ~25 scripts. The newer `externalize_cluster_state()` and `auto_finalize_cluster()` use lowercase only. This split adds cognitive overhead and forces bridging logic when the two conventions meet.

### Proposed approach

1. Update `cluster-config.sh` to output lowercase vars (or make `normalize-cluster-conf` the single source)
2. Update all ~25 scripts to use lowercase `$cluster_name`, `$base_domain`, etc.
3. Remove or deprecate `cluster-config.sh` if `normalize-cluster-conf` can fully replace it
4. Run full E2E suite (vmw + kvm lifecycle) to validate

### Risk

High — touches the entire VM lifecycle layer. Must be done as a focused effort with full E2E coverage.

## Feature: Store oc-mirror metadata in the registry as an OCI image

**Priority:** High
**Scope:** Core ABA (`mirror/Makefile`, `scripts/reg-sync.sh`, `scripts/reg-load.sh`, `scripts/day2-apply.sh`)

### Problem

After `mirror sync` or `mirror load`, oc-mirror produces YAML files (IDMS, ITMS, CatalogSources) that must be applied to the cluster via `aba day2`. In DISCO environments, ABA often runs on a **different host** (the internal bastion) than the one that loaded the images. Currently the user must manually copy these YAML files across the air gap — error-prone and annoying.

### Proposed solution

After every `sync` or `load`, automatically:
1. Package the oc-mirror output YAMLs into a lightweight OCI image (using `podman build` or `oras push`)
2. Push to the mirror registry under a well-known tag, e.g. `<reg_host>:<reg_port>/aba/mirror-metadata:latest`
3. On the disconnected side, `aba day2` pulls that image from the registry, extracts the YAMLs, and applies them

### Why it works

- The mirror registry is already the shared resource accessible from both sides of the air gap
- The metadata image is tiny (a few KB of YAML)
- No manual file transfer needed — the registry IS the transport
- Idempotent: each sync/load overwrites `:latest` with the current state

### Implementation ideas

1. **Push side** (after sync/load completes):
   ```bash
   # Build a minimal image containing the YAML output
   tar -cf - -C results-dir/ . | podman import - localhost/aba-metadata
   podman tag localhost/aba-metadata <reg>/aba/mirror-metadata:latest
   podman push <reg>/aba/mirror-metadata:latest
   ```
   Or use `oras push` for a cleaner OCI artifact (no Dockerfile needed):
   ```bash
   oras push <reg>/aba/mirror-metadata:latest ./results-dir/:application/yaml
   ```

2. **Pull side** (`aba day2` on disconnected bastion):
   ```bash
   # Pull and extract
   podman pull <reg>/aba/mirror-metadata:latest
   podman create --name aba-meta <reg>/aba/mirror-metadata:latest
   podman cp aba-meta:/. ./mirror-metadata/
   podman rm aba-meta
   # Apply YAMLs to cluster
   oc apply -f ./mirror-metadata/
   ```

3. **Versioning** (optional): tag with OCP version or timestamp for rollback:
   `<reg>/aba/mirror-metadata:4.16-20260510`

### Open questions

- `oras` vs `podman import` — oras is cleaner but adds a dependency. Podman is already available.
- Should we version-tag (keep history) or just use `:latest` (simpler)?
- Should `aba day2` auto-detect "am I on a different host?" or always try to pull from registry first?
- Fallback: if the image doesn't exist in the registry (first install, or pre-feature), fall back to local files.

---

## Security: Prevent sensitive data in log/trace files

**Priority:** High
**Scope:** Core ABA (`scripts/include_all.sh`, trace/debug infrastructure)

### Problem

Credentials (e.g. `reg_pw`, pull-secret tokens) can leak into:
- ABA trace files (`$ABA_TRACE_FILE`)
- Debug output (`DEBUG_ABA=1`)
- State override messages (now debug-level but still logged)
- Any `aba_debug`/`aba_info`/`aba_warning` call that prints config values

Example: `aba_debug "State: mirror.conf reg_pw=p4ssw0rd differs from..."` writes the password to the trace file.

### Approach ideas

1. **Redaction in logging functions**: `aba_debug`/`aba_warning`/`aba_info` could pipe through a redaction filter before writing. Pattern: replace values of known sensitive fields (`reg_pw`, `password`, `token`, `secret`, `pull-secret`) with `***`.
2. **Redaction at source**: Callers mask sensitive fields before logging (e.g. `_sval_display="${_sval:0:1}***"` for known password fields).
3. **Sensitive field list**: Maintain a list of field names that should never be logged in cleartext (e.g. `_SENSITIVE_FIELDS="reg_pw pull_secret token password"`).
4. **Trace file permissions**: Ensure trace files are created with `600` permissions (owner-only read).
5. **Audit**: grep the codebase for any place credentials are echoed/logged.

### Open questions

- Which approach is most robust? (Centralized redaction in the logging function is safest — one place to maintain.)
- Should redaction apply to all output or only trace/file output? (Probably all — even stderr in debug mode.)
- Are there cases where the full credential MUST be logged for troubleshooting? (Probably not — first/last char + `***` is enough.)

---

## TUI v2: "Remember my selection" — persistent user preferences

**Priority:** Medium
**Scope:** TUI v2 only

### Summary

Add a "remember my choice" mechanism so the TUI saves user preferences (e.g. execution mode: TUI vs Terminal) and skips the prompt next time.

### Design ideas

1. **Persistence file**: `~/.aba/tui-preferences.conf` — simple `key=value` format (e.g. `exec_mode=terminal`, `confirm_before_exec=false`).
2. **Remember checkbox**: On dialogs like execution mode, add a "Remember" checkbox or prompt. When checked, the selection is saved and the dialog is skipped on next invocation.
3. **Global Settings menu**: Add a "Settings" item to the main TUI menu (all modes) that shows current preferences and allows toggling each one:
   - Execution mode: TUI / Terminal / Always ask (default)
   - Confirm before execute: yes (default) / no
   - (future) Editor preference: nano / vi / dialog
4. **Implementation approach**:
   - `tui_pref_get <key> [default]` — reads from preferences file
   - `tui_pref_set <key> <value>` — writes to preferences file
   - At each preference-gated dialog, check `tui_pref_get` first; if set, skip dialog and use saved value
   - Settings menu uses `--checklist` or `--menu` to toggle each preference
5. **Reset**: Settings menu has "Reset all to defaults" option; also `aba reset` clears the file.

### Open questions

- Should "remember" be per-dialog (a checkbox on the dialog itself) or only configurable from the global Settings menu?
- Should preferences survive `aba reset --force`? (Probably yes — they're user preferences, not project state.)

---

## TUI v2: "Advanced" sub-menu

**Priority:** Low → **DONE**
**Scope:** TUI v2 only

### Summary

Implemented as `tui_advanced_menu()` in `tui-cluster.sh`. Available from all three mode menus (CONNO, DISCO, DIRECT) under the "Advanced" section.

Current items:
- **Reset ABA** (`aba reset --force`) — double-confirm, cleans everything
- **Reconfigure Platform** — select vmw/kvm/none, runs `aba -p <plat> <plat>`

---

## Known issue: DNS on different subnet unreachable during CoreOS early boot

**Priority:** Low (environmental / documentation)
**Scope:** Cluster installation (all modes)

### Observation

When installing a cluster on the `10.0.x.x/16` network (e.g., "VM Network" port group), using a DNS server on a different subnet (`192.168.2.8` on "Private Network") causes "Cannot access Rendezvous Host" failures. The VM boots CoreOS but cannot resolve its own hostname during early agent startup because the cross-subnet DNS is unreachable at that stage.

### Workaround

Use a DNS server on the **same subnet** as the cluster nodes (e.g., `10.0.1.8` instead of `192.168.2.8`). NTP can remain cross-subnet since it's less time-critical.

### Root cause hypothesis

During CoreOS early boot (initramfs/dracut stage), networking may not yet have a full routing table. The default gateway is configured but cross-subnet traffic may be blocked by the port group's VLAN configuration or by ESXi's virtual switch settings. Once the OS fully boots, routing works normally — but the agent fails before that point.

### Action items

- Consider adding a TUI warning when DNS is on a different subnet from `machine_network`
- Document in README/troubleshooting section

---

## Simplify port naming — auto-generate labels, only ask for port count

**Priority:** Medium
**Scope:** ABA core + TUI + CLI

### Background

Port names in the OpenShift Agent-Based Installer are **relational labels only** — they are
placeholder strings that act as foreign keys linking MAC addresses to nmstate YAML config blocks.
The installer's Go code uses regex to resolve these labels to actual hardware interface names at
boot time. The port names do NOT need to match real hardware names (e.g. `ens192`, `eno1`).

Only MAC addresses must match the physical hardware.

### What this means for ABA

- ABA does NOT need to ask users for actual port names
- ABA can auto-generate placeholder names like `port0`, `port1`, etc.
- The only question needed is: **how many ports?** (for bonding/multi-NIC scenarios)
- Single port = default (`port0`), no question needed
- Multiple ports = ask count (for bonds/VLANs), auto-name them `port0`, `port1`, ...

### Changes needed

1. **ABA core** (`scripts/create-cluster-conf.sh`, templates): Replace `ports=ens160` with
   auto-generated `port0` (or `port0,port1` for bonds). Remove platform-aware port name
   defaults (they become irrelevant).
2. **TUI**: Replace the "Ports" text input field with a port count selector (default 1).
   Only show for multi-NIC/bond scenarios.
3. **CLI**: `--ports` flag could accept a count instead of names (backward-compat: still
   accept explicit names for advanced users).
4. **Agent YAML templates**: Use auto-generated port labels in `install-config.yaml` /
   `agent-config.yaml` generation.

### IMPORTANT: Test first!

Before making this change, validate the assumption with a real deployment:
- Create a cluster using made-up port names (e.g. `port0`) instead of real HW names
- Verify the agent-based installer resolves them correctly via MAC→interface mapping
- Test on at least one platform (VMware or bare-metal)

### Notes

- Existing clusters with manually-entered port names should continue to work (backward compat)
- This supersedes the "platform-aware default port names" backlog item below
- Simplifies UX significantly: one fewer thing for users to get wrong

---

## Consolidate `int_connection` + `mirror_name` into `mirror_conn`

**Priority:** Medium
**Added:** 2026-05-08

### Problem

`cluster.conf` currently has two related variables:
- `int_connection` — how the cluster reaches the internet (proxy / direct / empty=use-mirror)
- `mirror_name` — which mirror directory the cluster uses (default: "mirror")

These are semantically linked and partially redundant. When `int_connection` is empty, the cluster uses the mirror named by `mirror_name`. The two fields cause confusion (e.g. `--int-connection mirror` is invalid today, but users expect it to work).

### Proposed change

Merge both into a single variable `mirror_conn`:
- `mirror_conn=proxy` — cluster uses cluster-wide proxy for internet
- `mirror_conn=direct` — cluster uses NAT/direct internet
- `mirror_conn=mirror` (default) — cluster uses the default mirror directory
- `mirror_conn=mirror2` — cluster uses a mirror named "mirror2"
- Empty — same as "mirror" (backwards compat)

Values "proxy" and "direct" are reserved — mirror directories MUST NOT be named "proxy" or "direct".

### Scope

1. Rename `int_connection` to `mirror_conn` in `cluster.conf` template
2. Add backwards-compat shim in `normalize_cluster_conf()`: read old `int_connection=` and map to new name
3. Update `aba.sh` CLI flag: rename `--int-connection` to `--mirror-conn` (keep `--int-connection` as deprecated alias)
4. Remove `mirror_name` from template; derive path from `mirror_conn` value (if not proxy/direct, it's the mirror name)
5. Update all scripts that use `$mirror_name` to derive it from `$mirror_conn`
6. Update validation in `include_all.sh`
7. Update TUI toggle and display
8. Update docs/comments

### Why

- Single source of truth for "how does this cluster connect"
- Eliminates the confusing empty-means-mirror semantics
- Users can specify mirror name and connection mode in one place
- Simpler mental model

---

## Make `aba delete` idempotent (no-op when nothing to delete)

**Priority:** Urgent
**Added:** 2026-05-07

### Problem

`aba --dir <cluster> delete` fails with "Not in a cluster directory" when the directory exists but has no `cluster.conf` (e.g. leftover scaffold from an interrupted `aba cluster` or from `aba reset`). The guard in `scripts/aba.sh` line 970 requires `cluster.conf` and aborts before the actual delete script runs, even though `vmw-delete.sh`/`kvm-delete.sh` already handle missing configs gracefully (exit 0 with "nothing to delete").

This caused a real E2E failure on pool4: `cluster-ops` left behind an `e2e-compact4` skeleton (symlinks only, no `cluster.conf`), and the subsequent `airgapped-existing-reg` suite failed trying to clean it up.

### Proposed fix

Make `aba delete` idempotent, following the same convention as `aba shutdown` (already off → exit 0), `aba startup` (already running → exit 0), and `aba upgrade` (already at version → exit 0):

1. Remove `delete` from the `cluster.conf` guard in `aba.sh` line 969
2. In the `delete)` handler, if `cluster.conf` is missing, print "nothing to delete" and exit 0
3. With `--force`, also remove the directory itself (the empty scaffold)
4. `vmw-delete.sh`/`kvm-delete.sh` already have the right no-op logic -- the guard is the only blocker

### Why this is safe

- No VMs can exist without `cluster.conf` (config is required before VM creation)
- `vmw-delete.sh` already checks for VMs and exits 0 if none found
- `--force` already does `rm -rf` of the directory after delete -- adding the no-config case is natural
- Aligns with user expectation: "delete this cluster" when there's nothing → success

### Related

- "Externalize installed-cluster state" backlog item (Urgent) — would make this even more robust by allowing delete to find VMs even without `cluster.conf`

---

## Verify httpd serves ISO/ignition for bare-metal installs

**Priority:** Medium
**Added:** 2026-05-06

### Description

Verify that the `httpd` RPM (in `rpms-internal.txt`) is actually being used by ABA to serve ISO/ignition files for bare-metal installs. If it's not needed (e.g. agent-based installer doesn't use httpd), remove it from the list. If it IS needed, ensure there's a test covering this path.

---

## Add comments to RPM list files (`templates/rpms-*.txt`)

**Priority:** Low
**Added:** 2026-05-06

### Description

Add `#` comments to `templates/rpms-external.txt` and `templates/rpms-internal.txt` explaining WHY each package is needed — specifically showing the actual ABA commands/scripts that use them (not generic descriptions).

Example format:
```
coreos-installer      # Used by: scripts/create-iso.sh (coreos-installer iso customize ...)
nmstate               # Used by: agent-config.yaml generation (networkConfig)
bind-utils            # Used by: scripts/verify-dns.sh (dig api.$cluster ...)
net-tools             # Used by: scripts/check-nic.sh (route -n, netstat)
```

Requires filtering comments when reading: `sed 's/#.*//' FILE | tr -s '[:space:]' ' '`
~10 files consume these lists and need the filter added.

---

## Rename `aba_warning()` to `aba_warn()`

**Priority:** Low
**Added:** 2026-05-06

### Description

Rename `aba_warning()` to `aba_warn()` across all scripts. Shorter, more consistent with `aba_abort`, `aba_info`, `aba_debug`. Update the pre-commit lint in `build/pre-commit-checks.sh` accordingly.

---

## Preflight checks: run but don't block when no issues detected

**Priority:** Medium
**Added:** 2026-05-05

### Description

When there are no preflight check failures, the checks should still run (to provide visibility) but should NOT block the user or require interaction. Currently preflight checks may pause even when everything passes. The ideal UX: checks run, output results, and if all pass, continue automatically without stopping.

---

## Support UPI (User Provisioned Infrastructure) installation method

**Priority:** Medium
**Added:** 2026-05-04

### Description

Add support for UPI (User Provisioned Infrastructure) as an installation method alongside the existing ABI (Agent-Based Installer) flow. UPI is the traditional OpenShift installation method where the user provisions their own infrastructure (VMs, bare metal, cloud instances) and provides ignition configs to each node.

### Why

- Some environments cannot use ABI (e.g. restricted platforms, specific hardware requirements, cloud providers without ABI support)
- UPI is the most widely documented and understood installation method
- Expands ABA's reach to more deployment scenarios

### Scope (TBD)

- Generate ignition configs via `openshift-install create ignition-configs`
- Provide helper scripts for common UPI platforms (bare metal PXE, VMware, cloud)
- Integrate with existing mirror/registry workflow (airgapped UPI)
- Consider `aba cluster -t sno --method upi` or similar CLI flag

---

## URGENT: Test golden VM recreation from templates

**Priority:** Urgent
**Added:** 2026-05-03

### Problem

The rhel9 golden VM was never rebuilt (`"Golden VM exists with 'golden-ready' snapshot -- reusing"`). Its snapshot had `/var/lib/expand-root.done` baked in, causing all cloned VMs to skip partition expansion (95GB partition on a 300GB vDisk). The `pool-ops.sh` golden creation path (lines 169-170) correctly removes the marker before snapshotting, but we have never validated this end-to-end since switching to rhel9.

### Action required

1. Run `setup-infra.sh --recreate-golden --pools 1` (or `run.sh run --recreate-golden ...`) to force a full golden rebuild from the RHEL9 template.
2. Verify the resulting golden snapshot does NOT contain `/var/lib/expand-root.done`.
3. Clone a VM from the rebuilt golden, expand its vDisk, boot it, and confirm `expand-root.service` runs and grows the partition to full size.
4. If successful, rebuild all pools from the new golden (`--recreate-vms`).

### Mitigation already applied

- `setup-infra.sh` Phase 3 now removes the marker before pool-ready snapshot (commit pending).
- Manual expansion was done on all 8 VMs (con1-4, dis1-4) to unblock current E2E run.

---

## Config precedence: comment out cluster.conf values copied from aba.conf

**Priority:** Medium
**Added:** 2026-04-26

### Problem

When `cluster.conf` is created, values like `ntp_servers` are copied from `aba.conf`. At runtime, `cluster.conf` has precedence (sourced last). This means `aba --ntp new-server` (changes `aba.conf`) followed by `aba day2-ntp` silently does nothing because `cluster.conf` still has the old value. The user must know to use `aba -d <cluster> --ntp` instead.

### Proposed fix (Option 4)

When generating `cluster.conf` from `aba.conf`, write "inherited" values as comments (prefixed with `#`). This way:
- `aba.conf` value takes effect by default (commented line doesn't override)
- `cluster.conf` documents what was used at install time
- User can uncomment to pin a per-cluster value (cluster.conf then wins)
- `aba -d <cluster> --ntp <value>` uncomments and sets the value

Applies to: `ntp_servers`, potentially `dns_servers`, `next_hop_address`, and other values that are global defaults but might need per-cluster overrides.

### Alternative considered

Remove `ntp_servers` from `cluster.conf` entirely (keep only in `aba.conf`). Rejected because it breaks the principle that `cluster.conf` is self-contained.

---

## E2E: Investigate SSH PATH behavior for --user root

**Priority**: Low
**Context**: `e2e_run` sources `.bash_profile` before every remote command, simulating console login. This means `~/bin` is always in PATH and `aba install` always installs to `~/bin/aba`. However, a real user doing `ssh root@host "cd ~/aba && ./install"` (non-interactive) would NOT have `~/bin` in PATH -- `aba install` would correctly fall through to `/usr/local/bin/aba`. Both paths work, but tests only exercise the console-login path. Consider whether `--user root` runs should test both login methods, or whether the `.bash_profile` sourcing in `e2e_run` should be optional/configurable.

---

## IMPORTANT (post code-freeze): Audit and fix exit code handling in ABA scripts

**Plan**: `~/.cursor/plans/audit-exit-codes.plan.md`
**Priority**: Important -- do NOT change during code freeze

37 scripts end with `exit 0`, silently swallowing errors. Confirmed bug: `vmw-create.sh` govc failure returns exit 0 because `create_node()` errors don't trigger the ERR trap (no `set -E`) and `exit 0` forces success regardless.

**Phase 1** (minimal, targeted):

- Add `set -E` to `include_all.sh` (one-line fix, makes ERR trap work in ALL functions)
- Remove `exit 0` from `vmw-create.sh` and `kvm-create.sh` (the confirmed bugs)

**Phase 2** (systematic):

- Audit all 37 scripts, remove unnecessary `exit 0`, add explicit error handling
- Consider `set -o pipefail` for pipeline failures

---

## IMPORTANT (post code-freeze): Remove ABA-internal function calls from E2E suites

**Plan**: `~/.cursor/plans/remove-internal-calls-from-suites.plan.md`
**Priority**: Important -- do NOT change during code freeze
**Status**: Phase 1 complete (replaced `normalize-aba-conf` calls in 2 suites)

Suites should never call ABA-internal functions directly. Three suites still `source include_all.sh` to call `verify-*-conf` functions for validation testing.

**Phase 2**: Create `aba verify` CLI command so validation suites use the CLI instead of sourcing internals.

---

## IMPORTANT (post code-freeze): Refactor normalize-*-conf() with `set -a/+a`

**Plan**: `~/.cursor/plans/normalize_conf_set_a_refactor.plan.md`
**Priority**: Important -- do NOT change during code freeze

5 normalize functions share duplicate sed pipelines and use an awkward `source <(func)` pattern. Also, `cluster-config.sh` has 4 different eval syntax variants across 25 callers.

**Phase 1** (internal cleanup, same caller interface): Extract `_parse_conf()` helper, rewrite function internals.
**Phase 2** (caller migration): Switch to `set -a/+a`, update ~75 callers, refactor `cluster-config.sh` into `load-cluster-config()` function.

---

## ~~Enhancement: Warn when changing mirror registry identity after install~~ SUPERSEDED

**Superseded by**: Unified State Management plan (`~/.cursor/plans/unified_state_management.plan.md`)

The "override + warn via normalize" approach replaces the original `ask()` proposal. Normalize functions now source `state.sh`, override immutable fields, and emit a warning on stderr if config drifts from installed state.

## Enhancement: TUI early catalog prefetch after pull secret

Start downloading operator catalog indexes immediately after the user provides a pull secret (before channel/version selection), so catalogs are already cached when the operators screen loads.

### Problem

Currently, catalog downloads don't start until version confirmation. For fresh users, this means a multi-minute wait at the operators screen while 3 large catalog images download from registry.redhat.io.

### Proposed implementation

In `tui/abatui.sh`, after `select_pull_secret` returns `"next"`, trigger:

```bash
if [[ -f ~/.pull-secret.json ]]; then
    run_once -S -i "tui:prefetch:catalogs" -- "$ABA_ROOT/scripts/prefetch-catalogs.sh"
fi
```

### Challenges discovered

1. **Version mismatch**: At pull-secret time, no version is selected yet. `prefetch-catalogs.sh` falls back to `stable:latest`, but if the user selects `fast` channel, catalogs are downloaded for the wrong version -- pure overhead, no cache benefit.
2. **I/O contention**: With `CATALOG_MAX_PARALLEL=3` (default), the prefetch runs 3 concurrent `podman` pulls for the wrong version. When the correct-version catalog downloads start at version confirmation, the system has 6 concurrent podman pulls, saturating network and disk I/O. This causes the operators screen to take >240s to load (normally <120s).
3. **TUI test failures**: The I/O contention caused 3 of 4 TUI tests to time out, even with 2x timeout scaling.

### Possible approaches

- **A) Cap prefetch parallelism**: Run `prefetch-catalogs.sh` with `CATALOG_MAX_PARALLEL=1` to reduce contention. Still downloads wrong version if user picks a different channel.
- **B) Defer prefetch to after version selection**: Start prefetch right after version confirmation instead of after pull secret. The version is known, so catalogs match. Less aggressive but correct.
- **C) Prefetch all likely versions**: Download catalogs for both `stable:latest` and `fast:latest` minor versions (4 total minors). More aggressive, higher bandwidth.
- **D) Increase test timeouts**: Add `TUI_TIMEOUT_SCALE` multiplier in `tui-test-lib.sh` `wait_for()` and set `CATALOG_MAX_PARALLEL=1` via `start_tui()` tmux command. Infrastructure for this was prototyped but 2x wasn't sufficient.

### Test infrastructure ready

The following changes were prototyped and can be re-applied:

- `tui-test-lib.sh`: `TUI_TIMEOUT_SCALE` config var + multiplier in `wait_for()`
- `tui-test-lib.sh`: `TUI_CATALOG_PARALLEL` injected into tmux `start_tui()` command
- Both default to non-intrusive values (scale=1, parallel=3)

## Enhancement: Replace dot-waiting loops with `aba_wait_show`

Several scripts use hand-rolled `echo -n .` + `sleep` loops for progress indication. These should be migrated to `aba_wait_show()` which provides a proper elapsed-time display (e.g. `5s 10s 15s ...`).

**Known locations:**

- `scripts/day2-config-osus.sh` line 112: CSV subscription wait (`echo -n .` + `sleep 10`, up to 60 retries)
- `scripts/day2-config-osus.sh` line 124: CSV phase=Succeeded wait (same pattern)
- `scripts/day2-config-osus.sh` line 276: OSUS policy engine graph URI curl check (inline `while true` with `echo -n .`)
- Any other `echo -n .` or `printf .` patterns in `scripts/`

**Also fix:** `scripts/cluster-startup.sh` curl checks were dumping raw HTTP 503 headers to stdout (fixed with `>/dev/null` -- verify this is committed).

**Approach:** Extract the condition into a function, then call `aba_wait_show "description" interval timeout condition_fn`. This gives consistent UX across all wait points.

## Investigate: is the oauth-proxy imagestream deletion still needed?

After `aba day2` (IDMS/ITMS/CatalogSource apply), ABA patches `image.config.openshift.io/cluster` with `additionalTrustedCA` and then scans imagestreams for "Unknown authority" errors, deleting affected imagestreams (e.g. `oauth-proxy` in `openshift` namespace) so they get re-imported with the trusted CA. The deletion retries up to 15 times with increasing backoff.

**Question:** Is this still necessary on modern OCP versions (4.14+)? The `additionalTrustedCA` patch should propagate to all nodes and the image registry operator should reconcile imagestreams automatically. If so, the retry loop is wasted time and noise in logs.

**Action:**

1. Understand why "Unknown authority" appears in `oauth-proxy` imagestream after mirrored install
2. Test on a fresh 4.16+ mirrored install -- apply `additionalTrustedCA` but skip the imagestream deletion
3. Monitor: does the imagestream fix itself once the CA propagates? How long does it take?
4. If it self-heals within a reasonable time, remove the deletion + retry logic

**References:**

- The log output showing the retry loop (15 attempts with backoff)
- `scripts/day2.sh` or wherever the imagestream scanning/deletion is implemented

## Bug: bare `sudo` in SSH commands should use `$SUDO` or detect availability

**Discovered:** While fixing the mirror-sync E2E BM delete regression (Mar 31).

### Problem

`reg-uninstall.sh` line 127 uses bare `sudo` inside an SSH command:

```bash
$_ssh "podman rm -f registry; sudo rm -rf $reg_root" || true
```

The remote host may not have `sudo` installed (e.g. inside a container or minimal image). ABA already defines `$SUDO` in `include_all.sh` (set to `sudo` if available, empty otherwise), but this doesn't help for SSH commands since `$SUDO` is expanded locally.

`reg-uninstall-remote.sh` line 81-82 has the same issue -- `$SUDO` is expanded locally before being sent over SSH.

### Proposed fix

Detect `sudo` availability on the remote host before using it in SSH commands. For example:

```bash
_remote_sudo=$($_ssh "which sudo 2>/dev/null && echo sudo")
$_ssh "podman rm -f registry; $_remote_sudo rm -rf $reg_root" || true
```

### References

- `scripts/include_all.sh` lines 13-15: local `$SUDO` detection
- `scripts/reg-uninstall.sh` line 127: bare `sudo` in SSH
- `scripts/reg-uninstall-remote.sh` line 81-82: `$SUDO` expanded locally before SSH

## Audit: VM lifecycle scripts that bypass Make init (similar to delete fix)

**Discovered:** While fixing `aba delete` silent failure after `aba clean` removes symlinks (Apr 2).

### Problem fixed

`aba.sh` calls VM lifecycle scripts (`vmw-delete.sh`, `vmw-start.sh`, etc.) directly, bypassing Make's dependency chain. These scripts use `source scripts/include_all.sh` with a relative path, which requires the `scripts/` symlink to exist in the cluster directory. After `aba clean`, the symlink is removed and the scripts fail with "No such file or directory".

**Fix applied:** Added `make -s init` before every VM lifecycle call in `aba.sh` (ls, start, stop, kill, delete, refresh, upload). Also removed `|| exit 0` from `delete)` so errors propagate.

### Additional symptoms found (2026-04-16)

1. `**aba clean refresh` -- chaining a Make target with an externalized target fails:**
  `clean` is not in the externalized target list (`case $cur_target` line 918), so it gets appended to `BUILD_COMMAND`. `refresh` IS externalized, so it becomes `cur_target`. The `refresh)` handler (line 1068) runs `eval $BUILD_COMMAND` which tries to execute `clean` as a bare shell command: `line 1069: clean: command not found`. The same bug affects any combination of a Make target + externalized target (e.g. `aba clean delete`, `aba clean start`).
2. `**aba clean` then any Make-passthrough target -- symlink breakage:**
  `aba clean` removes the `scripts` and `templates` symlinks. Any subsequent command that goes through Make (e.g. `mon`, `install`, `day2`) fails with `scripts/include_all.sh: No such file or directory`. The externalized targets (`delete`, `start`, `stop`, etc.) already have `make -s init` guards, but Make-passthrough targets don't. Fix: either add `make -s init` before `eval make -s $BUILD_COMMAND` in `aba.sh`, or add `.init` as a dependency of the relevant Makefile targets.

### Remaining audit

1. **Check all `source scripts/include_all.sh` callers** -- are there other scripts that assume the symlink exists? Search for `source scripts/include_all.sh` and `source ./scripts/include_all.sh` across the codebase.
2. **Check all `source templates/` callers** -- same issue with the `templates/` symlink.
3. **Review `|| exit 0` on `start)` and `kill|poweroff)`** -- currently kept because VMs might already be running/off, but these mask real errors too. Consider replacing with more targeted error handling (e.g. check if VMs exist first, then start/kill without masking).
4. **Review `|| echo "No vm(s)."` on `ls)`** -- is this the right fallback? Should it check whether VMs are expected first?

### References

- `aba.sh` lines 1031-1080: all VM lifecycle cases with `make -s init`
- `templates/Makefile.cluster` clean target: removes `.init`, `scripts`, `templates` symlinks
- `scripts/vmw-delete.sh` line 4: `source scripts/include_all.sh`

## Architecture: Review symlink dependency and consider `/opt/aba` for static files

### Current design

Cluster directories (e.g. `sno/`, `compact/`, `e2e-sno1/`) use symlinks to reference shared code:

- `scripts -> ../scripts`
- `templates -> ../templates`
- `Makefile -> ../templates/Makefile.cluster`
- `aba.conf -> ../aba.conf`
- `mirror -> ../mirror`

This design means scripts can use relative paths (`source scripts/include_all.sh`) and everything "just works" -- until a symlink is removed (e.g. by `aba clean`, manual deletion, or tar/rsync without `-L`).

### Problems with symlinks

1. **Fragile**: `aba clean` removes `scripts/` and `templates/` symlinks, breaking all VM lifecycle commands until `make init` recreates them. Fixed with `make -s init` guard, but it's a band-aid.
2. **Relative paths**: Symlinks use `../scripts` which only works when the cluster dir is one level below ABA root. Nested or relocated directories break.
3. **Bundle/tar portability**: Archives that don't follow symlinks (`tar` without `-h`, `rsync` without `-L`) create broken links.
4. **Confusion**: New contributors don't expect `scripts/` inside a cluster dir to be a symlink.

### Proposed alternative: Install static files to `/opt/aba`

Place immutable/shared files in a fixed location:

```
/opt/aba/
  scripts/       # all scripts
  templates/     # Makefile.cluster, cluster.conf template, etc.
  cli/           # aba CLI wrapper
```

Cluster directories would then reference scripts via `$ABA_SCRIPTS` or `/opt/aba/scripts/` instead of relying on symlinks. The `scripts/` and `templates/` symlinks in cluster dirs would no longer be needed.

### Considerations

- **Backward compatibility**: `make -C sno install` must still work. Makefiles would use `$ABA_SCRIPTS` or `/opt/aba/scripts/` instead of relative `scripts/`.
- **Multi-version**: If two ABA versions are installed, `/opt/aba` would need versioning or the user must choose.
- **Dev workflow**: Developers editing `scripts/` need changes to be picked up immediately -- a symlink from `/opt/aba/scripts -> ~/aba/scripts` during dev would preserve this.
- **Permissions**: `/opt/aba` owned by root or the installing user?
- **Install step**: `./install` would need to copy/link files to `/opt/aba`.
- **Bundle builds**: The bundle host clones from git -- would it install to `/opt/aba` or keep using the repo directly?

### Decision needed

Is this worth the migration effort? The `make -s init` guard fixes the immediate problem. The `/opt/aba` approach is cleaner long-term but touches nearly every Makefile and script.

## Bug: `aba_wait_show` timer freezes while the polled command runs

The `aba_wait_show` function displays elapsed time (e.g. `[ABA] Waiting for OpenShift console  |  9s`) but the counter only advances between poll iterations. If the polled command (e.g. `curl --connect-timeout 10`) takes 5-10 seconds to complete, the displayed time freezes during that period, making it look stuck.

**Expected:** The timer should show wall-clock time that updates continuously (or at least reflects total elapsed seconds accurately when it does update).

**Proposed fix:** Run the polled command in the background and keep updating the timer every second while it runs:

```bash
$cmd_func &
cmd_pid=$!
while kill -0 $cmd_pid 2>/dev/null; do
    elapsed=$(( $(date +%s) - start ))
    printf "\r[ABA] %s  |  %ds" "$desc" "$elapsed"
    sleep 1
done
wait $cmd_pid; rc=$?
```

This gives a smooth, continuously updating timer (e.g. `5s 6s 7s 8s ...`) even when `curl --connect-timeout 10` blocks for 10 seconds. Falls back gracefully -- if backgrounding isn't possible, use wall-clock `$(( $(date +%s) - start ))` instead of incrementing by the sleep interval so the jump is at least accurate.

**Location:** `aba_wait_show()` in `scripts/include_all.sh`

## Enhancement: Clean up `aba startup` output (reduce redundancy)

`aba startup` currently shows the `oc get nodes` output **4 times**: before uncordon (SchedulingDisabled), the uncordon messages, after uncordon (Ready), and a final listing. It also displays the full vCenter VM path (e.g. `/Datacenter/vm/abatesting/demo1/demo1-master1`) instead of just the VM name.

**Proposed changes:**

1. **VM listing**: Show only the VM name (e.g. `demo1-master1`), not the full vCenter/ESXi path. Strip the path prefix before display.
2. **Node status**: Show nodes **once** with `SchedulingDisabled`, then show uncordon results, then show nodes **once** as Ready. Remove the redundant intermediate/final listings.
3. **Target output** -- concise and clear:
  ```
   [ABA] Starting cluster demo1.example.com:6443 ...
   demo1-master1
   demo1-master2
   demo1-master3
   [ABA] Start the above virtual machine(s)? (Y/n): [default: -y]
   Powering on VirtualMachine ... OK (x3)
   [ABA] Waiting for cluster API  |  45s
   [ABA] Cluster endpoint accessible at https://api.demo1.example.com:6443/
   [ABA] Making all nodes schedulable (uncordon) ...
   [ABA] All nodes are ready!
   NAME      STATUS   ROLES                         AGE    VERSION
   master1   Ready    control-plane,master,worker   244d   v1.33.8
   master2   Ready    control-plane,master,worker   244d   v1.33.8
   master3   Ready    control-plane,master,worker   244d   v1.33.8
   [ABA] Certificate expiration: 2027-04-13T01:18:17Z
   [ABA] Waiting for OpenShift console  |  30s
   [ABA] Waiting for all cluster operators  |  1m4s
  ```

**Location:** `scripts/cluster-startup.sh` (or `scripts/vmw-start.sh` depending on where the output logic lives)

**Also:** Apply the same cleanup to `aba shutdown` output if it has similar redundancy.

## Bug: CLI flags silently ignored via `aba cluster` when cluster.conf exists

**Discovered:** While investigating the `connected-public` E2E regression (commit `9b3ca98`, Mar 29). The E2E test was fixed by restoring `rm -rf` for mid-suite cleanups, but the underlying ABA core bug remains.

### Root cause analysis

`aba.sh` processes arguments in two passes:

1. **First pass** (lines 58-104): extracts `--dir`/`-d` and `--debug`/`-D`. If `-d` is present, it does `cd "$target_dir"` immediately.
2. **Second pass** (lines ~530-900): processes all other flags (`-I`, `-i`, `--api-vip`, etc.). Each flag handler uses the same pattern:
  ```
   if [ -f cluster.conf ]; then
       replace-value-conf -n <key> -v <value> -f cluster.conf
   else
       BUILD_COMMAND="$BUILD_COMMAND <key>=<value>"
   fi
  ```

### Two code paths -- only one works

**Path A (WORKS): `aba -d mycluster -I proxy install`**

- `-d mycluster` does `cd mycluster/` in the first pass (line 82)
- CWD is now the cluster directory
- `-I proxy` in the second pass finds `cluster.conf` in CWD
- Calls `replace-value-conf` directly -- value is applied

**Path B (BROKEN): `aba cluster -n mycluster -I proxy`**

- No `-d`, so CWD stays as ABA root during flag parsing
- `-I proxy` checks `[ -f cluster.conf ]` -- fails (not in ABA root)
- Falls to `BUILD_COMMAND="$BUILD_COMMAND int_connection=proxy"`
- `BUILD_COMMAND` flows: `make cluster int_connection=proxy` -> Makefile (line 115) -> `setup-cluster.sh`
- `setup-cluster.sh` does `cd mycluster` (lines 21-38), then calls `create-cluster-conf.sh`
- `create-cluster-conf.sh` line 21: `[ -s cluster.conf ] && exit 0` -- **exits immediately, ignoring all values**
- The CLI-passed value is silently lost

### ALL flags affected in Path B (not just int_connection)


| Flag                             | Variable                     | aba.sh line |
| -------------------------------- | ---------------------------- | ----------- |
| `--api-vip`                      | `api_vip`                    | 542         |
| `--ingress-vip`                  | `ingress_vip`                | 569         |
| `--master-cpu` / `--mcpu`        | `master_cpu`                 | 681         |
| `--master-memory` / `--mmem`     | `master_mem`                 | 693         |
| `--worker-cpu` / `--wcpu`        | `worker_cpu`                 | 705         |
| `--worker-memory` / `--wmem`     | `worker_mem`                 | 717         |
| `--starting-ip` / `-i`           | `starting_ip`                | 729         |
| `--data-disk` / `--data-disk-gb` | `data_disk`                  | 741         |
| `--int-connection` / `-I`        | `int_connection`             | 771         |
| `--num-workers` / `-W`           | `num_workers`                | 833         |
| `--num-masters`                  | `num_masters`                | 844         |
| `--vlan`                         | `vlan`                       | 859         |
| `--ssh-key`                      | `ssh_key_file`               | 871         |
| `--proxy`                        | `http_proxy` / `https_proxy` | 883         |
| `--no-proxy`                     | `no_proxy`                   | 896         |


### Design: should `aba cluster` overwrite existing cluster.conf?

Three approaches considered:

- **A) Full overwrite** -- always regenerate `cluster.conf` from scratch. Already rejected (commented-out code at `setup-cluster.sh` lines 28-29: `#rm -f $name/cluster.conf`). Destroys manual edits (worker counts, memory, MAC prefixes, etc.).
- **B) Selective override** -- keep existing `cluster.conf` intact, apply only explicit CLI flags the user passed. Principle of least surprise: if the user explicitly said `-I proxy`, they expect it to take effect. Everything else they hand-tuned is preserved. This is how `aba.conf` and `mirror.conf` already work.
- **C) Warn and skip** -- print a warning like "cluster.conf exists, -I flag ignored". Honest but unhelpful.

**Recommendation: B (selective override)** for all CLI-passable values.

### Proposed fix options

- **Option 1**: In `setup-cluster.sh`, after `$create_cluster_cmd` (line 51), apply all non-empty CLI-passed values to existing `cluster.conf` via `replace-value-conf`. Requires forwarding all values through `create_cluster_cmd` or as separate variables.
- **Option 2**: Rework `create-cluster-conf.sh` to not exit early on existing `cluster.conf`. Instead, merge CLI values into the existing file. Bigger change but fixes it at the source.
- **Option 3**: In `aba.sh`, when the target is `cluster` and `--name` is given, detect if `<name>/cluster.conf` exists and `cd` into the cluster dir before the second pass. This way the existing `if [ -f cluster.conf ]` / `replace-value-conf` logic in each flag handler works for both paths. Most elegant but requires careful ordering.

### References

- `aba.sh` lines 58-104: first pass does `cd` for `-d` before flag parsing
- `aba.sh` lines ~530-900: all flag handlers with `if [ -f cluster.conf ]` dual-path pattern
- `Makefile` line 115: passes all values to `setup-cluster.sh`
- `setup-cluster.sh` line 47: `create_cluster_cmd` omits several values
- `setup-cluster.sh` lines 28-30: commented-out code showing prior rejection of full overwrite
- `create-cluster-conf.sh` line 21: `[ -s cluster.conf ] && exit 0` (early exit on existing file)

---

## Enhancement: E2E tests MUST support ESXi-direct API (no vCenter)

**Added**: 2026-04-14
**Priority**: High

All current E2E suites hardcode `--platform vmw` which defaults to vCenter (`VC=1`). We have no E2E coverage for ESXi-direct installs (`VC=` empty), which is a supported ABA deployment mode.

The old (pre-v2) E2E tests supported this simply by using a different `vmware.conf` that pointed directly at an ESXi host instead of vCenter. The same approach should work in the new framework.

**Proposed approach:**

- Add a `VMWARE_CONF` per-pool override in `pools.conf` (already possible) pointing to an ESXi-only `vmware.conf`
- Or add a pool-level `VC=` override that suites can pick up
- At minimum: one pool should run with ESXi-direct to catch regressions in the `VC=` empty code path
- The `vmware.conf` for ESXi-direct uses `GOVC_URL=https://esxiN.lan/sdk` (host, not vCenter)

**Key risk:** Without this, bugs in ESXi-direct installs (e.g. the doubled `resourcePool` path bug we already found) go undetected until a user reports them.

---

## Enhancement: Add backoff/retry delay when mirroring images with oc-mirror

**Added**: 2026-04-18
**Priority**: Medium

### Problem

When oc-mirror encounters transient failures (network blips, registry throttling, CDN rate-limits), it retries immediately. Rapid-fire retries against a throttling registry make the problem worse and can exhaust all attempts before the rate-limit window resets.

### Proposed change

Add an exponential backoff between oc-mirror retry attempts in `reg-save.sh`, `reg-sync.sh`, and `reg-load.sh`. Currently these scripts retry in a tight loop (`while` with immediate re-invocation). Add a configurable delay that increases with each attempt:

```bash
# Example: 30s, 60s, 120s, 240s between attempts
_delay=30
for (( attempt=1; attempt<=max_retries; attempt++ )); do
    oc-mirror ... && break
    echo "[ABA] oc-mirror attempt $attempt/$max_retries failed. Retrying in ${_delay}s ..."
    sleep $_delay
    _delay=$(( _delay * 2 ))
    [ $_delay -gt 600 ] && _delay=600  # cap at 10 minutes
done
```

Consider making the initial delay and max delay configurable via `~/.aba/config` (e.g. `OC_MIRROR_RETRY_DELAY=30`, `OC_MIRROR_RETRY_MAX_DELAY=600`).

### Related

- Bitmask exit codes backlog item (below) -- backoff logic pairs well with decoded exit codes for smarter retry decisions
- CDN resilience improvements already in E2E framework (`stagger`, `sub-manager refresh`)

---

## Enhancement: Use oc-mirror v2 bitmask exit codes for smarter error handling

**Added**: 2026-04-15
**Priority**: Medium
**Upstream PR**: [openshift/oc-mirror#1062](https://github.com/openshift/oc-mirror/pull/1062) (merged Apr 4, 2025, cherry-picked to 4.18)

Since oc-mirror v2 (OCP 4.18+/4.19+), `oc-mirror` returns bitmask exit codes that identify which category of images failed:


| Code | Meaning                                                   |
| ---- | --------------------------------------------------------- |
| 1    | Generic error (pre-batch: config, auth, collection phase) |
| 2    | Release image copy error                                  |
| 4    | Operator image copy error                                 |
| 8    | Additional image copy error                               |
| 16   | Helm image copy error                                     |


Codes 2/4/8/16 are combined via bitwise OR (e.g. exit 12 = operator + additional image errors). Code 1 (generic) is returned for errors *outside* the batch worker (config parse, auth handshake, collector phase). The `BatchError.ExitCode()` method in `v2/internal/pkg/batch/common.go` computes the bitmask. `main.go`'s `exitCodeFromError()` returns `GenericErr` (1) for any error that doesn't implement `CodeExiter`.

**IMPORTANT -- bitmask tells you WHAT failed, not WHY**: The exit code identifies the *category* of image that failed (release, operator, etc.), but does NOT distinguish between transient network errors and permanent problems (bad auth, missing image). A release image that fails due to a 2-second network blip returns exit 2 -- identical to a permanent auth failure. Verified in source: `concurrent_chan_worker.go` computes `releaseCountDiff` as `expected - copied` with no cause inspection. Similarly, exit 1 (generic) can be a transient collector-phase timeout or a permanent config error.

**Affected ABA files**: `scripts/reg-save.sh`, `scripts/reg-sync.sh`, `scripts/reg-load.sh`

**Current behavior**: All three scripts capture `ret=$?` after `oc-mirror` and treat any non-zero as a generic failure. They also check for `mirroring_errors_*.txt` files (which can indicate failure even when `ret=0` in older v2 builds). Since we control the oc-mirror version (4.18+/4.19+), the error file detection is now redundant -- the bitmask exit code is the single source of truth.

**Proposed improvements**:

1. **Remove error file detection**: Drop the `mirroring_errors_*.txt` existence checks and the stale-file cleanup logic. The bitmask exit code is sufficient and more reliable. This simplifies all three scripts significantly.
2. **Decode the bitmask** in the retry loop to give the user actionable feedback:
  - Exit 1 (generic): pre-batch failure (config, auth, collection). Log: "oc-mirror failed before image copying started"
  - Exit 2 (release): release image copy failed. Log: "release image(s) failed to mirror"
  - Exit 4 (operator): warn which catalog/package failed, suggest `--retry` or removing the operator
  - Exit 8 (additional): warn about specific additional images
  - Exit 16 (helm): warn about helm chart failures
  - Combined codes (e.g. 12): report each category separately
3. **Retry ALL non-zero exit codes** (up to the configured retry limit): Since any exit code -- including release (2) and generic (1) -- can be caused by transient network issues, all codes are retryable.
4. **Log decoded exit code + running history** each attempt so the user can see whether retries are making progress or stuck on the same error. Example output:
  ```
   oc-mirror attempt 1/5 failed (exit 6: release + operator)
   oc-mirror attempt 2/5 failed (exit 4: operator) -- history: [6, 4]
   oc-mirror attempt 3/5 failed (exit 4: operator) -- history: [6, 4, 4]
  ```
   A narrowing code (6 → 4) means progress; a repeating code (4 → 4 → 4) suggests a permanent issue. Keep it simple -- just log the trail, no automated heuristics.
5. **Extract shared retry loop first**: The retry loops in `reg-save.sh`, `reg-sync.sh`, and `reg-load.sh` are ~~70 lines of near-identical copy-paste (~~210 lines total). The only differences are the `oc-mirror` command args and the action name in messages. Before adding bitmask decoding, extract a shared function (e.g. `_run_oc_mirror_with_retry "$action" "$cmd"`) in `include_all.sh` or a dedicated helper. This avoids modifying 3 copies of the same loop and prevents inconsistencies.

**Source code references** (commit `be3d7693`):

- Error code constants: `v2/internal/pkg/errcode/code.go`
- Bitmask computation: `v2/internal/pkg/batch/common.go` (`BatchError.ExitCode()`)
- Release fail-fast + cancel: `v2/internal/pkg/batch/concurrent_chan_worker.go` (line: `if res.imgType.IsRelease() { cancel(); break }`)
- Process exit code: `v2/cmd/oc-mirror/main.go` (`exitCodeFromError()` -- returns `GenericErr` for non-`CodeExiter` errors)

---

## Enhancement: Make oc-mirror `--since` configurable (move out of reg-save.sh)

**Added**: 2026-04-15
**Priority**: Medium
**Affected file**: `scripts/reg-save.sh`

`reg-save.sh` currently hardcodes `--since 2025-01-01` in the oc-mirror command. This should be a user-configurable variable in `~/.aba/config`, OFF by default.

### Why `--since` matters for disconnected environments

oc-mirror keeps a history of previously archived blobs in `working-dir/.history/`. On subsequent `save` runs:

- **Without `--since`**: oc-mirror creates a **differential** (incremental) archive containing only blobs not in any previous run. The archive is smaller, but it only works if the disconnected registry already has all images from every previous `load`. If the registry was rebuilt, or a transfer was skipped, the differential archive is **incomplete** -- `load` will fail because blobs it references aren't in the archive or the registry.
- **With `--since <far-back-date>`**: oc-mirror ignores history newer than that date. If no history predates the date (typical), the archive includes **all blobs** -- a complete, self-contained tarball that works on a fresh registry every time. Larger, but safe.

For ABA's air-gapped workflow, a complete archive is the safe default -- users can't always guarantee every previous archive was loaded in order.

### The imageset-config must always be complete (not additive)

Verified in source (`v2/internal/pkg/operator/local_stored_collector.go` and `v2/internal/pkg/cli/executor.go`):

During `load` (disk-to-mirror), oc-mirror reads the `imageset-config.yaml` passed via `--config` on the command line. Both `save` and `load` in ABA use the same file (`--config imageset-config.yaml` in `data/`).

The operator collector iterates over `o.Config.Mirror.Operators` from **that** config and for each catalog:

1. Reads the catalog from the extracted archive/cache
2. Filters to only the selected packages
3. **Rebuilds** the catalog index with those packages
4. Pushes the rebuilt index to the disconnected registry, **overwriting** any previous version

This means the imageset-config is **the complete truth for each round -- not additive**. Consequences:

- If you remove an operator from imageset-config between rounds, it **disappears from OperatorHub** (the rebuilt catalog no longer references it, even though its blobs may still sit in the registry).
- If you add a new operator, its blobs get collected during `save` regardless of `--since` (the history tracks blobs, not config entries -- new operator blobs aren't in history, so they're always archived).
- **To keep OperatorHub complete, the imageset-config must always list ALL operators you want** -- not just the ones added since the last round.

For ABA users this means: never trim the imageset-config between save/load cycles unless you intentionally want to remove operators from OperatorHub.

### Bug found: E2E suites were silently clobbering operator catalogs

**Fixed**: 2026-04-15

The E2E suites `suite-airgapped-local-reg.sh` (mesh step) and `suite-airgapped-existing-reg.sh` (ACM step) were creating incremental operator configs listing ONLY the new operators. During `load`, oc-mirror rebuilt the catalog index with only those operators, silently dropping the initially loaded `kiali-ossm` from OperatorHub.

The tests passed because no assertion checked that previously loaded operators survived. The catalog was restored later (in suite 1 by the upgrade step's full config regeneration; in suite 2 because the suite ends without checking).

**Fix applied**: Both suites now include `kiali-ossm` in every incremental operator config, and assert `kiali-ossm` is still in OperatorHub after each incremental load. This catches catalog clobber regressions.

**IMPORTANT regression (2026-04-15):** The initial fix (`df21642`) used a "save-B, load-A+B" pattern (save only new operators, load with all operators via a separate `imageset-config-load.yaml`). This broke airgapped (disconnected) workflows: oc-mirror v2 `diskToMirror` resolves catalog data from the archive -- operators not in the archive cause oc-mirror to reach upstream `registry.redhat.io`, which fails on disconnected hosts. Fixed by changing to "save A+B, load A+B" -- the same ISC (with ALL operators) is used for both save and load, making the archive self-contained.

**MUST RE-TEST:** The save-A+B / load-A+B pattern needs end-to-end verification:

1. Save with full operator list (A + B) -- verify archive contains catalog data for all operators
2. Load on disconnected host -- verify no upstream registry access attempted
3. Verify ALL operators (both old and new) appear in OperatorHub after load
4. Verify incremental save overhead is negligible (oc-mirror delta logic should skip already-archived blobs)

**Broader concern for ABA users**: ABA should warn users (or prevent them) from running `aba load` with a partial imageset-config. A possible future enhancement: `reg-load.sh` could compare the config's operator list against what's currently in the registry catalog and warn if operators would be dropped.

### Proposed change

1. Add `OC_MIRROR_SINCE` to `~/.aba/config` template, commented out (OFF by default):
  ```bash
   # oc-mirror --since date for mirror-to-disk (save) only (format: yyyy-MM-dd).
   # When set, oc-mirror includes all content since this date -- use a far-back date
   # (e.g. 2020-01-01) to force a complete archive every time.
   # When unset (default), oc-mirror creates differential archives (only new blobs
   # since the last save). Differential archives are smaller but require that every
   # previous archive was loaded into the disconnected registry in order.
   # OC_MIRROR_SINCE=
  ```
2. In `reg-save.sh`, replace the hardcoded `--since 2025-01-01` with:
  ```bash
   ${OC_MIRROR_SINCE:+--since $OC_MIRROR_SINCE}
  ```
   This expands to `--since <date>` when set, or nothing when empty/unset.
3. Remove the stale comment about `--since`.

---

## BUG: KVM `virsh desc` fails with "metadata title can't contain newlines"

**Found**: 2026-04-16 (Pool 3, kvm-lifecycle suite)
**Severity**: High -- blocks ALL KVM cluster creation
**Introduced by**: commit `96b0df3` (_vm_annotation() helper)

### Root cause

In `kvm-create.sh`, the `virsh desc` command is called as:

```bash
virsh desc "$vm_name" --title "ABA: ${CLUSTER_NAME}.${base_domain}" --new-desc "$annotation"
```

But `--title` is a **flag** (not an option taking a value). When `--title` is present, `--new-desc` sets the **title**, not the description. So the multi-line `$annotation` is assigned to the title, causing `error: metadata title can't contain newlines`.

### Fix

Split into two separate `virsh desc` calls:

```bash
virsh desc "$vm_name" --title --new-desc "ABA: ${CLUSTER_NAME}.${base_domain}"
virsh desc "$vm_name" --new-desc "$annotation"
```

The second attempt also fails because `virsh undefine` removed the ISO volume, so re-create couldn't find `agent-*.iso`. This is a cascading failure from the first error.

---

## BUG: oc-mirror v2 diskToMirror always tries upstream catalog on incremental loads

**Found**: 2026-04-16 (Pool 2, airgapped-local-reg suite, "Incremental: mesh operators")
**Severity**: High -- blocks incremental operator loads on disconnected hosts
**Upstream bug**: [OCPBUGS-81712](https://issues.redhat.com/browse/OCPBUGS-81712) -- oc-mirror v2 attempts to retrieve images from registry.redhat.io in disk2mirror mode
**Upstream PR**: [openshift/oc-mirror#1390](https://github.com/openshift/oc-mirror/pull/1390)
**Related**: catalog clobber fix (`0281f6d`), `--since` delta behavior

### Root cause

oc-mirror v2 `diskToMirror` (load from archive) ALWAYS attempts to contact the upstream catalog source (`registry.redhat.io`) during the "collecting operator images" phase. The initial full load works because the archive contains complete catalog data. But an incremental (delta) archive -- even with "save A+B" ISC -- doesn't include enough catalog metadata for oc-mirror to resolve operators without reaching upstream.

Evidence from Pool 2 logs:

- Initial load: `Collected catalog registry.redhat.io/...v4.20` succeeds in <1s (found in archive)
- Incremental load: same catalog collection attempts `registry.redhat.io`, gets `no route to host` (exit=4)

This appears to be an **oc-mirror v2 limitation**: delta archives created with `--since` don't embed sufficient catalog index data for standalone `diskToMirror` resolution.

### Workaround IMPLEMENTED: catalog digest pinning (2026-04-24)

ABA now pins operator catalog references by **digest** (`@sha256:...`) instead of tag (`:vX.Y`) at
oc-mirror invocation time. When oc-mirror sees a digest it skips upstream tag resolution entirely.

**How it works:**
- `download-catalog-index.sh`: captures digest via `podman image inspect` after pulling the catalog image
- Digest saved to `.index/.{catalog}-index-v{ver}.digest`
- `_run_oc_mirror_with_retry()`: before invoking oc-mirror, calls `_oc_mirror_pin_catalogs_by_digest()`
  which does a single-pass `sed` to produce `data/imageset-config-digest.yaml` with tags replaced by digests
- User's `imageset-config.yaml` is **never modified** -- the digest file sits alongside for debugging

**To disable** (once oc-mirror fixes upstream tag resolution):
- Set `OC_MIRROR_PIN_CATALOGS=0` in `~/.aba/config` or environment
- Or remove the pinning code entirely (grep for `OC_MIRROR_PIN_CATALOGS` and `_oc_mirror_pin_catalogs_by_digest`)

### Other workarounds (still available)

1. **Force full save**: Use `--since 2020-01-01` for incremental saves to force a complete archive (large but self-contained). Already available via `OC_MIRROR_SINCE` config.
2. **Clear oc-mirror state before save**: Remove `.oc-mirror/` working dir before the incremental save so oc-mirror treats it as a fresh save (downloads everything).
3. **File upstream bug**: oc-mirror v2 `diskToMirror` should not require network access when the archive is self-contained.

### Impact on E2E tests

The suite's "save A+B, load A+B" approach is necessary but not sufficient for incremental airgapped loads. Need to investigate whether clearing oc-mirror state before save produces a complete archive.

---

## ~~Enhancement: Improve VM notes/descriptions for VMware and KVM~~ DONE (but KVM broken -- see BUG above)

**Implemented**: 2026-04-15 (commit `96b0df3`)

Added `_vm_annotation()` helper in `include_all.sh`. VMware: rich multiline govc annotation. KVM: `virsh desc` with title + full description. Includes ABA version, cluster type, OCP version, console/API URLs, and management examples.

---

## ~~Enhancement: Externalize installed-cluster state for robust `aba delete`~~ SUPERSEDED

**Superseded by**: Unified State Management plan (`~/.cursor/plans/unified_state_management.plan.md`) — Phase 1 + Phase 2.

**Added**: 2026-04-15
**Priority**: Urgent
**Related**: reliable VM delete fix (`e5c310b`)

### Problem

`aba delete` currently requires `cluster.conf` (and now regenerates `agent-config.yaml`/`install-config.yaml` via `make agentconf`) to determine which VMs to delete. If the entire cluster directory is wiped (e.g. by a killed suite or accidental `rm -rf`), `aba delete` has no way to know what VMs existed.

### Proposed approach

Externalize "installed cluster" metadata to `~/.aba/clusters/<cluster-name>/state.sh` (similar to how mirror state lives in `~/.aba/mirror/<dir>/state.sh`). This file would be written at VM creation time and contain:

```bash
cluster_name=sno2
base_domain=example.com
cluster_type=sno
platform=vmw
cp_names="sno2"
worker_names=""
vc_folder="/Datacenter/vm/aba-e2e/pool1"
installed_from="/home/steve/aba/sno2"
installed_on="2026-04-15T23:00:00"
```

`aba delete` could then fall back to this state file when the cluster directory or its configs are missing, enabling cleanup even after a total directory loss.

### Considerations

- Must not conflict with the existing config-as-truth model -- state file is a fallback, not primary
- Write at VM creation, update at delete (remove state file after successful delete)
- Should `aba clean` remove the state file? Probably not -- it's external state
- May make the `make -s init agentconf` fallback in `aba.sh delete)` unnecessary

---

## ~~TESTING NEEDED: `aba delete` non-fatal config regen (`make -s init agentconf || true`)~~ OBSOLETE

**Obsoleted by**: Unified State Management plan (`~/.cursor/plans/unified_state_management.plan.md`) — Phase 2 eliminates the need to regenerate config for delete; state.sh provides VM names directly.

**Added**: 2026-04-16
**Priority**: High
**Affected file**: `scripts/aba.sh` `delete)` case

### Change

The `delete)` case now runs `make -s init agentconf 2>/dev/null || true` instead of `make -s init agentconf`. This allows `aba delete` to proceed even when config regeneration fails (e.g. missing pull secret on a disconnected host after registry deregistration).

### Risk

The `2>/dev/null || true` suppresses ALL errors from `make -s init agentconf`, not just "missing pull secret". If `agentconf` silently produces a corrupt/partial `agent-config.yaml`, the subsequent `${HV}-delete.sh` may:

- Delete the wrong VMs (if VM names were generated from corrupt config)
- Miss VMs (if config is incomplete and lists fewer nodes than actually exist)
- Fail in a confusing way (if the delete script assumes valid config)

### Test scenarios needed

1. **Happy path**: `aba delete` after normal install -- should work identically to before
2. **Missing pull secret**: `aba delete` on disconnected host after `aba unregister` -- should succeed, exit 0
3. **Missing mirror creds**: `aba delete` when mirror registry is down or creds expired -- should succeed
4. **Corrupt cluster.conf**: `aba delete` with a malformed `cluster.conf` -- should it exit 0 or error?
5. **No cluster.conf at all**: `aba delete` in a fresh directory -- should exit 0 (no VMs)
6. **Partial agentconf**: What if `make agentconf` creates `agent-config.yaml` but not `install-config.yaml`? Does `${HV}-delete.sh` handle that?
7. **Wrong VM count**: What if `agent-config.yaml` lists 1 master but 3 VMs actually exist? Only 1 gets deleted?

### Long-term fix

The "Externalize installed-cluster state" backlog item would eliminate this risk entirely -- `aba delete` would read VM names from `~/.aba/clusters/<name>/state.sh` instead of regenerating config.

---

## BUG: `ensure_govc` fails when called from outside ABA root (relative path)

**Found**: 2026-04-16
**Severity**: Medium -- blocks `run.sh` and other callers after `~/bin/govc` is removed
**Triggered by**: TUI test `aba reset` removing `~/bin/govc`, then `run.sh` calling `_ensure_govc()`

### Root cause

`ensure_govc()` in `scripts/include_all.sh` calls `make -sC cli govc`. The `cli` path is **relative** to CWD. When sourced from `test/e2e/run.sh` (whose CWD is `~/aba/test/e2e`), the relative path resolves to `~/aba/test/e2e/cli/` which doesn't exist:

```
make: *** cli: No such file or directory.  Stop.
ERROR: govc installation failed.
```

### Reproduction

```bash
cd ~/aba && aba reset -f        # removes ~/bin/govc and cli/.init
cd ~/aba/test/e2e && ./run.sh run --all --pools 4
# ERROR: govc installation failed.
```

### Proposed fix

Use `$ABA_ROOT` or compute the absolute path in `ensure_govc()`:

```bash
ensure_govc() {
    run_once -q -w -i "cli:download:govc" -- make -sC "$ABA_ROOT/cli" download-govc
    run_once -w -m "Installing govc to ~/bin" -i "$TASK_GOVC" -- make -sC "$ABA_ROOT/cli" govc
}
```

Or the same pattern used by other `ensure_*()` functions. Check if `ensure_oc`, `ensure_oc_mirror`, etc. have the same relative-path bug.

### References

- `scripts/include_all.sh` line 2654: `ensure_govc()` with `make -sC cli`
- `test/e2e/run.sh` line 269: `_ensure_govc()` sources `include_all.sh` and calls `ensure_govc`

---

## Cleanup: Promote bundles/v2/ to bundles/ and remove v1

**Added**: 2026-04-17
**Priority**: Low (post-1.0.0)
**Prerequisite**: v2 bundle pipeline fully proven in production

Once `bundles/v2/` is the confirmed production pipeline, promote its contents up to `bundles/` and delete the old v1 code (`bundles/go.sh`, `bundles/bundle-create-test.sh`, `bundles/templates/`).

**Changes needed when promoting:**

- `git mv` all v2 contents up one level
- Update `common.sh` `REPO_ROOT` path (one fewer `../`)
- Update `.gitignore` (`bundles/v2/build.log` -> `bundles/build.log`)
- Update path references in `CHANGELOG.md` and `ai/` docs

---

## Refactor: Replace `$regcreds_dir` with `regcreds/` symlink across all scripts

**Added**: 2026-04-17
**Priority**: Low (cleanup)

### Problem

21 scripts in `scripts/` manually compute `regcreds_dir=$HOME/.aba/mirror/$(basename "$PWD")` (mirror-side) or `regcreds_dir=$HOME/.aba/mirror/$mirror_name` (cluster-side). This is redundant because both `Makefile.mirror` and `Makefile.cluster` already create a `regcreds` symlink during `make init`:

- Mirror dir: `ln -sfn ~/.aba/mirror/$(basename $PWD) regcreds` (Makefile.mirror line 71)
- Cluster dir: `ln -sfn ~/.aba/mirror/$mirror_name regcreds` (Makefile.cluster line 72)

Every script could just use `regcreds/` (relative path) instead of computing `$regcreds_dir`.

### Affected scripts (21)

Mirror-side (13): `reg-load.sh`, `reg-sync.sh`, `reg-install.sh`, `reg-verify.sh`, `reg-register.sh`, `reg-uninstall.sh`, `reg-uninstall-quay.sh`, `reg-uninstall-docker.sh`, `reg-uninstall-remote.sh`, `reg-unregister.sh`, `reg-existing-create-pull-secret.sh`, `reg-common.sh`, `add-operators-to-imageset.sh`

Cluster-side (8): `day2.sh`, `day2-config-osus.sh`, `verify-config.sh`, `verify-release-image.sh`, `create-install-config.sh`, `create-agent-config.sh`, `generate-image.sh`, `cluster-info.sh`

### Change

For each script: remove `export regcreds_dir=...` line, replace all `$regcreds_dir` references with `regcreds`. The `regcreds` symlink is guaranteed to exist because every script runs after `make init`.

Also update `create-containers-auth.sh` which reads `$regcreds_dir` from the caller's environment -- change it to use `regcreds/` directly.

### Risk

Low -- the symlink is already created and used by Makefiles. The only risk is if a script is called from a directory where `regcreds` symlink doesn't exist (but all scripts are called via Make targets which ensure `.init` ran first).

---

## Enhancement: Add `aba_debug` before every important CLI invocation

**Added**: 2026-04-17
**Priority**: Medium (improves debuggability)

### Problem

When debugging ABA failures, it's often unclear exactly which CLI command was executed and with what arguments. Some scripts already have `aba_debug "Running: $cmd"` (e.g. `vmw-create.sh`), but coverage is inconsistent. Many critical CLI calls have no debug logging at all.

### Proposed change

Add `aba_debug` lines before every invocation of the following CLIs, logging the exact command with all arguments:

**High priority (`~/bin/` -- ABA-managed, critical path):**

- `oc-mirror` -- long-running, error-prone, complex args (save/load/sync)
- `oc` -- cluster operations, day2, monitoring (`oc apply`, `oc get`, `oc adm`, etc.)
- `govc` -- VMware operations (`vm.clone`, `vm.power`, `vm.destroy`, `snapshot.`*, etc.)
- `openshift-install` -- agent-based install (`create`, `wait-for bootstrap-complete/install-complete`)
- `opm` -- operator catalog operations
- `kubectl` -- cluster access (where used instead of `oc`)
- `yq` -- YAML processing (where non-trivial transformations occur)

**Medium priority (system CLIs, important for diagnostics):**

- `podman` -- registry container lifecycle, image operations
- `virsh` -- KVM VM operations (create, start, stop, destroy, desc)
- `nmcli` -- network configuration during VM setup
- `curl` -- registry connectivity checks, downloads (where not already logged)

**Format:** Use consistent pattern:

```bash
aba_debug "Running: oc-mirror --v2 --config imageset-config.yaml file://. --since 2020-01-01"
```

For commands built dynamically in variables:

```bash
aba_debug "Running: $cmd"
```

### Scope

Audit all `scripts/*.sh` files. Some already have debug logging (e.g. `vmw-create.sh` has `aba_debug Running: $cmd` for govc calls). Fill in the gaps -- don't duplicate existing debug lines.

### Notes

- `aba_debug` output is only visible when `ABA_DEBUG=1` or `--debug` is passed, so this adds zero noise in normal operation
- Particularly valuable for `oc-mirror` failures where the exact flags matter (e.g. `--since`, `--config`, `--from`)
- Also valuable for `govc` where the resource path, datastore, and folder args are often the source of bugs

---

## Plan: Restore `run.sh live` and `run.sh dash` dashboard features

**Added**: 2026-04-19
**Priority**: Medium (post-1.0.0)
**Related commits**: `5995c2a` (original enhancement), `0d301fb` (revert to fix flapping)

### Background

Commit `5995c2a` added rich dashboard features to `run.sh live` and `run.sh dash`:

- Pane titles showing user, OS, vmware.conf basename (e.g. `live | Pool 2 | root | rhel9 | esxi.conf`)
- Completion banners with PASSED/FAILED status, metadata, and timestamp
- Scrollback preservation (no `clear` after suite completion -- banner + output stay visible)
- Dead-pane detection via `tmux list-panes -F '#{pane_dead}'` for smooth suite transitions
- Suite user detection (`/tmp/e2e-suite-user`) for multi-user awareness

Commit `0d301fb` reverted `_dash_pane_cmd()` and `_live_create_script()` to simpler versions because the richer logic caused "flapping" (rapid re-attach/disconnect cycling). The revert fixed flapping but lost all the above features.

### What was lost (current state)

`**run.sh live`** pane titles show only: `live | Pool N (conN) | suite-name`

- Missing: user, OS, vmware.conf
- No completion banner -- when a suite finishes, the pane just shows "No e2e session. Waiting..."
- `clear` on every loop iteration wipes scrollback

`**run.sh dash**` pane titles show only: `dashboard | Pool N (conN) | suite-name`

- Missing: user, OS, vmware.conf
- No smart reconnect when suite changes -- kills and restarts `tail -F`

### Root cause of flapping

The flapping was likely caused by the live pane script doing `ssh -t ... tmux attach -d` (detach-others) on every loop iteration, combined with aggressive reconnect logic. When the SSH session drops (normal), the outer loop immediately reconnects, which detaches the previous session, causing a rapid attach/detach cycle.

### Proposed fix: use `live-pane.sh` as an external script

`test/e2e/scripts/live-pane.sh` already contains the full richer logic and is deployed to `~/.e2e-harness/scripts/` on conN hosts. The key insight is to make the generated `poolN.sh` wrapper call `live-pane.sh` in a loop instead of inlining all the logic. This allows:

1. **Hot-reload**: Changes to `live-pane.sh` take effect on the next loop iteration (~5s) without restarting `run.sh live`
2. **Cleaner wrapper**: The generated script just sets env vars and loops, calling `source live-pane.sh`
3. **Anti-flap**: Add a post-attach delay (e.g. `sleep 2`) after `ssh -t ... tmux attach` returns, so the loop doesn't immediately re-enter. The `live-pane.sh` script already has careful state tracking (dead pane detection, gone-count threshold) that prevents premature reconnection.

### Implementation plan

#### Phase 1: Fix the anti-flap mechanism

1. In `_live_create_script()`, add a 2-second `sleep` after the `ssh -t ... tmux attach` call returns (the attach exit means SSH dropped or session was killed). This is the minimal fix for flapping.
2. Test: run `run.sh live --pools 4` with suites active on all pools. Verify no flapping for 10+ minutes.

#### Phase 2: Re-integrate `live-pane.sh` into live dashboard

1. Modify `_live_create_script()` to generate a wrapper that:
  - Sets env vars: `_POOL_NUM`, `_DOMAIN`, `_SSH_OPTS`, `_DEFAULT_USER`, `_LIVE_ID`, `_E2E_TMUX_SESSION`
  - Runs `source $HOME/.e2e-harness/scripts/live-pane.sh` in a `while true` loop
  - Falls back to the current simple logic if `live-pane.sh` doesn't exist on the bastion
2. Verify `live-pane.sh` is deployed to the bastion (it's in `test/e2e/scripts/`, which gets deployed via `_make_source_tar`)
3. Test: verify pane titles show user, OS, vmconf; completion banners appear; scrollback preserved

#### Phase 3: Enrich `run.sh dash` pane titles

1. Modify `_dash_pane_cmd()` to also read `/tmp/e2e-suite-user`, `/tmp/e2e-suite-os`, `/tmp/e2e-suite-vmconf` and include them in the pane title
2. The dash pane is simpler (just `tail -F` of log file) so flapping is not a concern
3. Test: verify dash pane titles show enriched metadata

#### Data files on conN (already written by `runner.sh`)


| File                    | Content                    | Written by    |
| ----------------------- | -------------------------- | ------------- |
| `/tmp/e2e-last-suites`  | Suite name                 | `runner.sh`   |
| `/tmp/e2e-suite-user`   | SSH user running the suite | `runner.sh`   |
| `/tmp/e2e-suite-os`     | OS (e.g. `rhel9`)          | `runner.sh`   |
| `/tmp/e2e-suite-vmconf` | vmware.conf path           | `runner.sh`   |
| `/tmp/e2e-live-owner`   | Live session ID            | `run.sh live` |


### Expected pane title formats

**Live**: `live | Pool 2 | root | airgapped-existing-reg | rhel9 | esxi.conf`
**Live (idle)**: `live | Pool 2 | (idle)`
**Live (done)**: `live | Pool 2 | airgapped-existing-reg | PASSED | rhel9`
**Dash**: `dashboard | Pool 2 | root | airgapped-existing-reg | rhel9`

### Completion banner format (live only)

```
================================================================================
  PASSED: airgapped-existing-reg (4 passed, 0 failed, 0 skipped)
  Pool 2 | root | rhel9 | esxi.conf
  Completed: 2026-04-19 15:30:45

  Scroll up to review suite output. Waiting for next suite ...
================================================================================
```

### Risk

- Phase 1 is low-risk (just a sleep)
- Phase 2 depends on `live-pane.sh` being correct -- it needs testing on all 4 pools with different users/OS combos
- Phase 3 is low-risk (dash panes don't have the flapping problem)

---

## Enhancement: Ctrl-C in `run.sh live` should show interactive mini-menu

**Added**: 2026-04-15
**Priority**: Medium (post-1.0.0)

### Problem

When the user presses Ctrl-C in a `run.sh live` window (attached to a running suite via SSH + tmux), the signal kills the SSH session and drops back to the outer loop which immediately reconnects. There's no opportunity for the user to interact with the running suite (e.g. re-run the failed command, skip the current test, pause the suite, or detach gracefully).

### Proposed behavior

When Ctrl-C is detected in a live pane:

1. **Trap SIGINT** in the live pane loop script (the generated `poolN.sh` wrapper or `live-pane.sh`)
2. **Show a mini-menu** to the user:
  ```
   Ctrl-C detected. Choose an action:
     r) Re-run the current/last command
     s) Skip current test and continue
     p) Pause suite (send SIGUSR1 to runner)
     d) Detach (return to shell, suite keeps running)
     q) Quit live view
     c) Continue (re-attach, ignore Ctrl-C)
   >
  ```
3. **Execute the chosen action** and either re-attach or exit the live view

### Considerations

- The live pane connects via `ssh -t conN tmux attach -t e2e-suite`. Ctrl-C inside tmux goes to the running command inside the tmux session. So the trap needs to be at the SSH/wrapper level, not inside the tmux session.
- One approach: use `ssh -t conN tmux attach` but trap SIGINT in the outer wrapper. When SSH exits (due to Ctrl-C killing the ssh process), the wrapper catches it and shows the menu instead of immediately looping.
- The "re-run" action would need to communicate with `runner.sh` on conN (e.g. write a signal file like `/tmp/e2e-rerun` that runner checks between tests).
- The "skip" action could write `/tmp/e2e-skip` for runner to pick up.
- The "pause" action could send `SIGUSR1` to the runner's PID (stored in `/tmp/e2e-runner.pid`).

### Related

- Plan: Restore `run.sh live` and `run.sh dash` dashboard features (above)
- `test/e2e/scripts/live-pane.sh` already has loop logic that could host this menu

---

## E2E: Fix mesh demo test in suite-airgapped-local-reg

**Added**: 2026-04-18
**Priority**: Medium
**Currently**: Disabled (`if false; then ... fi` block in `suite-airgapped-local-reg.sh`)

### Problem

The "Deploy: service mesh demo" test step fails because the upstream demo install script
(`00-install-all-mesh3.sh` from `github.com/sjbylo/openshift-service-mesh-demo`) reports
"No route available" on current OCP versions. This is not an ABA bug -- it's an issue with
the demo repo's Sail/Istio operator installation on OCP 4.20+.

### What needs fixing

1. **Investigate upstream**: Check if `openshift-service-mesh-demo` repo has been updated
  for newer OCP / Sail operator versions. The `00-install-all-mesh3.sh` script may need
   updating for API changes in the Sail operator.
2. **Test manually**: On an air-gapped SNO with mesh operators loaded, run the demo script
  interactively and diagnose exactly where "No route available" comes from.
3. **Fix or replace**: Either update the demo repo script, or replace the test with a simpler
  mesh smoke test (e.g. just verify Sail operator installs and Istio control plane goes Healthy,
   skip the travels app deployment).
4. **Re-enable**: Remove the `if false; then ... fi` wrapper and verify the test passes end-to-end.

### References

- `test/e2e/suites/suite-airgapped-local-reg.sh` lines 437-508: disabled mesh demo block
- `github.com/sjbylo/openshift-service-mesh-demo`: upstream demo repo
- The test mirrors 9 `quay.io/kiali/demo_travels_`* images, clones the repo, rewrites image
refs to the mirror registry, then runs `00-install-all-mesh3.sh` on the air-gapped side

---

## E2E: Increase wait before `oc apply` of MultiClusterHub CR

**Added**: 2026-04-20
**Priority**: Medium
**Affected suite**: `suite-airgapped-existing-reg.sh` (ACM: MultiClusterHub step)

### Problem

After installing the ACM operator (via `aba day2`), the suite immediately attempts `oc apply -f ~/aba/test/acm-mch.yaml` to create the MultiClusterHub CR. The validating webhook (`multiclusterhub-operator-webhook`) is not yet ready:

```
Error from server (InternalError): failed calling webhook
"multiclusterhub.validating-webhook.open-cluster-management.io":
no endpoints available for service "multiclusterhub-operator-webhook"
```

The framework retries (5 attempts, 5s between), and it succeeds on retry 2. But the 5-second retry interval is too short for a webhook that needs operator pods to schedule and start. If the cluster is under load or slow, all 5 retries could fail.

### Proposed fix

Add a wait/poll step before the `oc apply` that checks the webhook endpoint is ready:

```bash
e2e_run "Wait for MCH webhook" \
    "aba --dir e2e-snoN run --cmd 'oc wait --for=condition=Available deployment/multiclusterhub-operator -n open-cluster-management --timeout=120s'"
```

Or alternatively, increase the retry delay for this specific step to 30s (giving the operator ~2.5 minutes total to become ready).

### References

- Error log: Pool 2, `airgapped-existing-reg` suite, "Install MultiClusterHub" step
- The ACM operator webhook pod needs time to start after CatalogSource/Subscription are applied

---

## E2E: Improve ACM CSV readiness check in `suite-airgapped-existing-reg`

**Added**: 2026-04-20
**Priority**: Low
**Affected suite**: `suite-airgapped-existing-reg.sh` (ACM: install operators step)

### Problem

The test waits for the ACM CSV to appear with:

```bash
oc get csv -n open-cluster-management -o name | grep advanced-cluster-management
```

Two issues:

1. `**-o name` is misleading here**: The output is `clusterserviceversion.operators.coreos.com/advanced-cluster-management.v2.16.0` -- still a resource path, not just a name. Without `-o name` the default tabular output includes the `PHASE` column (e.g. `Succeeded`, `Installing`, `Pending`), which is more useful for debugging.
2. **Doesn't check for `Succeeded` phase**: The grep matches as soon as the CSV *exists*, but a CSV can exist in `Pending` or `Installing` phase for a long time before it becomes usable. The test should also verify the CSV has reached `Succeeded` to ensure the operator is actually ready before proceeding to the MultiClusterHub CR apply.

### Proposed fix

Replace:

```bash
oc get csv -n open-cluster-management -o name | grep advanced-cluster-management
```

With:

```bash
oc get csv -n open-cluster-management | grep 'advanced-cluster-management.*Succeeded'
```

This gives better log output (shows the full CSV status line including version and phase) and only proceeds once the operator is fully installed. This would also reduce or eliminate the webhook-not-ready issue in the subsequent MCH apply step (see backlog item above).

### References

- Pool 2 log: CSV appears after ~60s but webhook not ready for another ~30s
- Checking `Succeeded` phase would naturally add the wait time needed for the webhook to come up

---

## Enhancement: Guardrail to prevent direct script execution

**Added**: 2026-04-20
**Priority**: Medium (post-1.0.0)

### Problem

Scripts under `scripts/` must only be called via Make targets or the `aba` CLI -- never directly. Direct execution bypasses Make's dependency tracking, marker management, and CWD setup. Today this is only an honor-system rule (documented in `.cursor/rules/` and `dev/SPEC.md`). There is no runtime enforcement.

### Proposed fix

Add a guardrail near the top of every `scripts/*.sh` file (after the shebang and header contract) that detects direct invocation and aborts with a clear error message. For example:

```bash
# Guardrail: scripts must be called via Make or aba, never directly
if [ -z "${ABA_CALLED_VIA_MAKE:-}" ] && [ -z "${ABA_CALLED_VIA_ABA:-}" ]; then
    echo "[ABA] Error: $(basename "$0") must not be run directly." >&2
    echo "[ABA] Use 'aba <command>' or 'make <target>' instead." >&2
    exit 2
fi
```

The `aba` CLI and Makefiles would `export ABA_CALLED_VIA_MAKE=1` or `ABA_CALLED_VIA_ABA=1` before invoking scripts. This is a simple, zero-overhead guard that catches accidental direct execution.

### Scope

- ~37 scripts in `scripts/`
- `aba.sh` sets `ABA_CALLED_VIA_ABA=1`
- Makefiles set `ABA_CALLED_VIA_MAKE=1`
- `include_all.sh` could check and abort if neither is set (single enforcement point)

### Considerations

- Must not break `test/func/` tests that source `include_all.sh` for utility functions
- E2E tests that call `aba` CLI are fine (they go through the proper path)
- The guard variable name should be documented in `dev/SPEC.md`

---

## Review and simplify `vmw-create-folder.sh`

**Priority:** Low
**Added:** 2026-04-15

### Problem

`scripts/vmw-create-folder.sh` has complex retry/fallback logic for creating vSphere folders (iteratively stripping path components and rebuilding). It's unclear whether this complexity is still needed or whether a simpler approach (e.g. single `govc folder.create` with proper error handling) would suffice.

### Action items

- Review whether vSphere/ESXi actually requires the incremental folder-creation logic
- Determine if `govc folder.create` can handle nested paths in one call (may depend on govc version)
- Simplify if possible, or add comments explaining why the complexity is necessary
- Verify the script is actually called (check Makefiles for the target that invokes it)
- Consider whether ESXi vs vCenter behavior differs here

---

## Bug: Registry probe uses `curl -k` -- wrong host / untrusted cert not detected before oc-mirror

**Priority:** High
**Added:** 2026-04-20

### Problem (user-reported use case)

A user left the **default** `reg_host=registry.example.com` in `mirror.conf` -- a real host on the network, but NOT the correct mirror registry. `reg_ssh_key` was commented out (not set). The user ran `aba -d mirror sync`. ABA ran through all its pre-flight checks without complaint, then `oc-mirror` failed with:

```
[ERROR] checking registry "registry.example.com:8443/ocp4/openshift4" access:
  failed to authenticate: tls: failed to verify certificate: x509: certificate
  signed by unknown authority
```

ABA should have caught this **before** invoking `oc-mirror`, with a clear message like "Registry TLS certificate is not trusted" or "Cannot authenticate with registry".

### Root cause: three gaps in the pre-flight chain

**Gap 1: `probe_host()` uses `curl -k` (skip TLS verification)**

`probe_host()` in `include_all.sh` (line ~2360) runs:

```bash
curl -s $_pf --connect-timeout 5 --max-time 15 --retry 2 -ILk "$url"
```

The `-k` flag means curl accepts any certificate -- even self-signed, expired, or from a completely wrong host. So the probe happily reported "registry reachable" even though the certificate was untrusted. Then `oc-mirror` ran **without** `-k` and immediately failed.

**Gap 2: `sync`/`load` skip authentication when `.available` already exists**

`sync` and `load` depend on `install` which depends on `.available`. When a registry was previously installed, `.available` already exists, so Make skips `reg-install.sh` entirely (which is where TLS trust and credentials are set up). The Makefile comment (line 126) explicitly says: "Auth is verified only when building .available (install); do not depend on verify here." So if the user changes `reg_host` in `mirror.conf` after a previous install, `.available` is stale -- it was created for the OLD host. Make doesn't re-verify, and `reg-sync.sh` only does the lightweight `curl -k` probe. `reg-verify.sh` (which does proper `podman login`) is never called unless the user explicitly runs `make verify` or `.available` is rebuilt.

**Gap 3: `reg_ssh_key` not set = silent local-mode assumption**

When `reg_ssh_key` is commented out, ABA assumes the registry is **local** (on the same host). It never checks whether `reg_host` actually points to localhost. In this case, `reg_host` was a remote host -- but since no SSH key was configured, ABA skipped all remote-host checks. The user had no indication that ABA was treating the configuration as "local registry" when it was actually remote.

### Proposed fixes

**Fix 1 (minimal, high-value): Add TLS-aware probe before oc-mirror**

In `reg-sync.sh` and `reg-load.sh`, after the `probe_host` connectivity check, add a TLS verification step:

```bash
# Verify registry TLS certificate is trusted (without -k)
if ! curl -s --connect-timeout 5 --max-time 10 -I "$reg_url/v2/" >/dev/null 2>&1; then
    aba_abort "Registry at $reg_url is reachable but its TLS certificate is NOT trusted." \
        "This usually means the registry's CA cert has not been added to the system trust store." \
        "Fix: aba -d $(basename "$PWD") register --ca-cert <path-to-ca.pem>" \
        "Or:  trust_root_ca /path/to/rootCA.pem"
fi
```

**Fix 2 (better): Run `podman login` before oc-mirror**

Add a `podman login` pre-check in `reg-sync.sh` and `reg-load.sh` (same check `reg-verify.sh` already does):

```bash
if ! podman login --authfile "$regcreds_dir/pull-secret-mirror.json" "$reg_url" >/dev/null 2>&1; then
    aba_abort "Cannot authenticate with registry at $reg_url" \
        "Check that the registry is running, the CA cert is trusted, and credentials are correct." \
        "Run 'aba -d $(basename "$PWD") verify' for detailed diagnostics."
fi
```

This catches TLS issues AND authentication failures in one step.

**Fix 3 (optional): Warn when `reg_host` is not localhost but `reg_ssh_key` is empty**

In `verify-mirror-conf()` or at the start of `reg-sync.sh`, detect this ambiguous configuration:

```bash
if [ "$reg_host" != "$(hostname -f)" ] && [ "$reg_host" != "localhost" ] && [ -z "$reg_ssh_key" ]; then
    aba_warning "reg_host=$reg_host appears to be a remote host, but reg_ssh_key is not set." \
        "ABA will treat this as a LOCAL registry. If the registry is remote, set reg_ssh_key in mirror.conf."
fi
```

### References

- `scripts/include_all.sh` line ~2360: `probe_host()` with `-k` flag
- `scripts/reg-sync.sh` lines 68-82: lightweight probe, no auth check
- `scripts/reg-load.sh` lines 46-59: same lightweight probe
- `scripts/reg-verify.sh` lines 65-93: proper TLS + `podman login` check (the gold standard)
- `scripts/reg-install-remote.sh` lines 22-47: SSH pre-checks when `reg_ssh_key` is set

---

## Improve `aba refresh` confirmation UX

**Priority:** Low
**Added:** 2026-04-15

### Problem

`aba refresh` (which calls `vmw-refresh.sh` / `kvm-refresh.sh`) has an awkward user experience:

1. It asks **twice** to delete existing VMs (once in refresh, once in the underlying delete script)
2. It asks for confirmation **even when no VMs exist** (nothing to delete)

This makes the command feel clunky and unpolished, especially for new users.

### Action items

- Review the refresh flow: `aba refresh` → `{vmw,kvm}-refresh.sh` → `{vmw,kvm}-delete.sh` + `{vmw,kvm}-create.sh`
- Pass a flag (e.g. `--yes` or `ask=`) from refresh to delete to skip the redundant second prompt
- Check for existing VMs before prompting -- if none exist, skip the delete confirmation entirely
- Ensure the single prompt clearly communicates what will happen (delete + recreate)
- Test with both VMware and KVM paths

---

## Enhancement: day2 NTP output should tell user to hit Ctrl-C

**Priority:** Low
**Added:** 2026-04-15

The `aba day2` NTP verification currently outputs:

```
[ABA] Verifying NTP on all nodes - (hit Ctrl-C to stop)
```

This is good, but the message should also appear during the ongoing check loop (not just once at the start). If the NTP check takes a long time, the user has no reminder that Ctrl-C is an option.

Also: **remove the `[ABA] Ensuring CLI binaries are installed` output** from day2 scripts. This is internal noise that doesn't help the user. CLI binary bootstrapping should be silent (already guarded by `run_once`).

---

## Command injection audit: fix all `bash -c` / `eval` / `/dev/tcp` with unsanitized variables

**Priority:** High (security)
**Added:** 2026-04-22

Full codebase scan for injection patterns similar to CI-01 (PR #25). Input sources: `vmware.conf`, `mirror.conf`, `cluster.conf`, `kvm.conf`, CLI args (`$*`), `aba.conf`. While these are all local config files (not network-supplied), defense-in-depth requires treating them as untrusted.

### Findings

#### HIGH -- Command injection via `bash -c` with interpolated variables

| ID | File | Line | Pattern | Input source | Risk |
|----|------|------|---------|------|------|
| CI-01 | `scripts/preflight-check-vsphere.sh` (PR #25) | TCP probe | `bash -c "echo >/dev/tcp/$host/$port"` | `GOVC_URL` → `vmware.conf` | `;`, `$(...)` in host breaks out of `/dev/tcp` into arbitrary exec |
| CI-02 | `scripts/preflight-check.sh` | 75 | `bash -c "echo >/dev/udp/$host/123"` | NTP server from `cluster.conf` | Same pattern as CI-01, UDP variant |
| CI-03 | `scripts/aba.sh` | 76 | `target_dir=$(eval echo "$target_dir")` | `-d` CLI arg | `eval echo` on user-supplied path: `$(cmd)` or backticks in the path execute arbitrary code. The intent is tilde expansion; safe alternatives: `${target_dir/#\~/$HOME}` |
| CI-04 | `scripts/oc-command.sh` | 22 | `eval oc $cmd` | `aba run --cmd "..."` CLI arg | User controls the entire `$cmd` string passed to `eval`. While the user is local, `eval` allows shell metacharacters to break out of the `oc` invocation. Use `oc $cmd` (without eval) or an array. |
| CI-05 | `scripts/reg-common.sh` | 365 | `eval cp "$ca_source" ...` | `--ca-cert` CLI arg | `eval` on file path for tilde expansion. Same risk as CI-03. |
| CI-06 | `scripts/reg-save.sh` / `reg-load.sh` / `reg-sync.sh` | 97-109 | `eval export TMPDIR=$data_dir/.tmp && eval mkdir -p $TMPDIR` | `data_dir` from `mirror.conf` | `eval` on config-file value; semicolons or `$(...)` in `data_dir` execute. Use `export TMPDIR="$data_dir/.tmp"; mkdir -p "$TMPDIR"`. |
| CI-07 | `scripts/reg-install-quay.sh` | 73 | `eval $cmd --initPassword $reg_pw` | `$reg_pw` from `mirror.conf` | Password with shell metacharacters in it would execute. Use an array or proper quoting. |

#### MEDIUM -- Config-file eval patterns (injection requires local config edit)

| ID | File | Pattern | Input source | Risk |
|----|------|---------|------|------|
| CI-08 | `scripts/include_all.sh` normalize-vmware-conf() | `eval "$vars"` where `$vars` = lines from `vmware.conf` prepended with `export` | `vmware.conf` | A line like `FOO=bar; rm -rf /` in vmware.conf would execute. Mitigated by the sed that strips comments but doesn't validate values. |
| CI-09 | `scripts/include_all.sh` normalize-kvm-conf() | Same `eval "$vars"` pattern | `kvm.conf` | Same risk as CI-08. |
| CI-10 | `scripts/vmw-stop.sh`, `vmw-start.sh`, `kvm-stop.sh`, `kvm-start.sh` | `. <(echo $* | tr " " "\n")` | Make/CLI args | Converts space-separated `key=value` pairs into sourced shell. The `process_args()` regex guard (`^([a-zA-Z_]\w*=?[^ ]*)...`) partially validates but the `.` (source) call AFTER `process_args` bypasses it -- the `.` line sources raw `$*` without the regex check. |
| CI-11 | `scripts/add-operators-to-imageset.sh` | 278 | `list=$(eval echo '${'"$catalog"'[@]}')` | Loop variable from hardcoded array names | Low practical risk (loop variable is hardcoded), but `eval` on constructed variable name is a code smell. |
| CI-12 | `scripts/vmw-create.sh` | 117, 125 | `eval $cmd` where `$cmd` contains govc with `'$sub_mac'` | MAC address from config | Single-quoted MAC in the command string; `eval` is used to handle the quotes. If MAC contained `'; cmd; '` it would break out. Mitigated by MAC format validation elsewhere. |
| CI-13 | `scripts/vmw-upload.sh` | 36, 43 | `eval $cmd` where `$cmd` is govc import command | File paths from config | Paths with metacharacters could inject. |

#### LOW -- `eval make $BUILD_COMMAND` in aba.sh

| ID | File | Lines | Risk |
|----|------|-------|------|
| CI-14 | `scripts/aba.sh` | 1010, 1024, 1042, 1051, 1081, 1137, 1143 | `$BUILD_COMMAND` is assembled from CLI args by `aba.sh` itself (not raw user input). Each flag handler adds specific `key=value` pairs. Risk is theoretical -- a crafted `aba` invocation with shell metacharacters in flag values could inject into `eval make`. Mitigated by the fact that all flag values go through `replace-value-conf` or fixed format strings. |

#### INFO -- `bash -c "$(curl ...)"` install pattern

| ID | Files | Risk |
|----|-------|------|
| CI-15 | `test/basic-test-using-bundle.sh`, `bundles/v2/scripts/01-install-aba-from-git.sh`, `bundles/bundle-create-test.sh`, `test/ex/test-container.sh` | `bash -c "$(curl -fsSL ...install)"` -- standard remote install bootstrap. URL is hardcoded to `github.com/sjbylo/aba`. Risk is supply chain (GitHub account compromise), not code injection. Acceptable for install scripts; not a production codepath. |

### UP-02 (MEDIUM): Fail-open on network-on-cluster check (PR #25)

`_vsphere_probe_resources_network_on_cluster` in PR #25: on `govc` errors, `aba_debug` and `return 0` -- attachment mismatch may be silently skipped (fail-open). Should fail-closed.

### Recommended fixes (priority order)

1. **CI-01, CI-02**: Replace `bash -c "echo >/dev/tcp/$host/$port"` with a validated-host probe: `[[ "$host" =~ ^[a-zA-Z0-9._-]+$ ]] || aba_abort "Invalid host"` before the probe.
2. **CI-03, CI-05**: Replace `eval echo "$target_dir"` with `${target_dir/#\~/$HOME}` for tilde expansion without eval.
3. **CI-06**: Replace `eval export TMPDIR=...` with `export TMPDIR="$data_dir/.tmp"; mkdir -p "$TMPDIR"` (no eval needed).
4. **CI-04**: Replace `eval oc $cmd` with `oc $cmd` (eval not needed for simple args; if pipes/redirects are intended, document the risk).
5. **CI-07**: Use array passing for `mirror-registry` command instead of `eval $cmd --initPassword $reg_pw`.
6. **CI-08, CI-09**: Add value validation to `normalize-vmware-conf()` / `normalize-kvm-conf()` -- reject lines containing `;`, `$(`, backticks.
7. **CI-10**: Remove the `. <(echo $* | tr " " "\n")` line that bypasses the `process_args()` guard.
8. **CI-14**: Consider replacing `eval make $BUILD_COMMAND` with `make` + array args (lower priority -- BUILD_COMMAND is internally assembled).

---

## Documentation: `aba register` / `aba unregister` gaps (code vs docs vs tests)

**Added**: 2026-04-23
**Priority**: Medium
**Affects**: `scripts/aba.sh`, `others/help-mirror.txt`, `others/help-aba.txt`, `README.md`, `scripts/reg-common.sh`, `scripts/setup-mirror.sh`, E2E test suites

### Background

A three-way audit of the `aba register` feature (code, docs/help, tests) revealed 9 gaps where the three sources are inconsistent or incomplete. The `register` command registers an externally-managed mirror registry with ABA by copying the pull secret and CA cert into the regcreds dir, trusting the CA, and writing `state.sh` with `REG_VENDOR=existing`.

### How `aba register` works (from the code)

Two valid invocation forms:

**Form 1 -- Explicit `register` keyword:**
```
aba -d mirror register --pull-secret-mirror /path/to/ps.json --ca-cert /path/to/ca.pem
```

**Form 2 -- Auto-injected (no `register` keyword needed):**
```
aba -d mirror --pull-secret-mirror /path/to/ps.json --ca-cert /path/to/ca.pem
```

When both `--pull-secret-mirror` and `--ca-cert` are passed without an explicit Make target, `aba.sh` auto-injects `register` into `BUILD_COMMAND` (lines 1110-1115).

Both forms support `--reg-host` to set `reg_host` in `mirror.conf`:
```
aba -d mirror register --reg-host registry.example.com --pull-secret-mirror /path/to/ps.json --ca-cert /path/to/ca.pem
```

Implementation chain: `aba.sh` → `make -s register pull_secret_mirror='...' ca_cert='...'` → `Makefile.mirror` register target → `scripts/reg-register.sh` → copies creds, trusts CA, writes `state.sh`, touches `.available`.

`reg-register.sh` requires both `reg_host` and `reg_port` in `mirror.conf` (aborts if missing).

### Gap 1 (HIGH): `aba register -h` shows WRONG help text

**File**: `scripts/aba.sh` lines 262-274

The help routing only matches `mirror|save|load|sync` for `help-mirror.txt`. Since `register` doesn't match any of these, `aba register -h` falls through to the generic `help-aba.txt` which has **zero** information about registration. Same for `aba unregister -h`.

**Fix**: Add `register` and `unregister` to the help routing condition:
```bash
elif [ "$cur_target" = "mirror" -o "$cur_target" = "save" -o "$cur_target" = "load" -o "$cur_target" = "sync" -o "$cur_target" = "register" -o "$cur_target" = "unregister" ]; then
    cat $ABA_ROOT/others/help-mirror.txt
```

### Gap 2 (MEDIUM): `register`/`unregister` missing from "Related commands" in help-mirror.txt

**File**: `others/help-mirror.txt` lines 24-35

The "Related commands" quick-reference lists `sync`, `save`, `load`, `verify`, `password` -- but NOT `register` or `unregister`. They only appear buried in the "Examples" section at the bottom. A user scanning the help won't see them as first-class commands.

**Fix**: Add to "Related commands" section:
```
  aba [-d mirror] register [--reg-host H] --pull-secret-mirror <file> --ca-cert <file>
                                       # Register an existing (external) mirror registry.

  aba [-d mirror] unregister           # Deregister an existing registry (removes creds only).
```

### Gap 3 (MEDIUM): help-mirror.txt register examples omit the `register` keyword

**File**: `others/help-mirror.txt` lines 57-63

The help examples rely on auto-inject (no `register` keyword):
```
aba -d mirror --reg-host registry.example.com --pull-secret-mirror /path/to/pull-secret.json --ca-cert /path/to/rootCA.pem
```

But the README uses the explicit form:
```
aba -d mirror register --reg-host registry.example.com --pull-secret-mirror /path/to/pull-secret.json --ca-cert /path/to/rootCA.pem
```

The explicit form is clearer. Auto-inject is a convenience shortcut, not the canonical invocation.

**Fix**: Add the explicit `register` keyword to help-mirror.txt examples so they match the README.

### Gap 4 (LOW): Error messages in `reg-common.sh` omit `register` keyword

**File**: `scripts/reg-common.sh` lines 112-129

When ABA detects an existing registry and aborts, the error message says:
```
"register it with: aba -d mirror --pull-secret-mirror <file> --ca-cert <file>"
```

This relies on auto-inject and doesn't teach the user the `register` command.

**Fix**: Change to `"register it with: aba -d mirror register --pull-secret-mirror <file> --ca-cert <file>"`.

### Gap 5 (LOW): `setup-mirror.sh` post-creation hint omits `register` keyword

**File**: `scripts/setup-mirror.sh` lines 53-58

After creating a named mirror directory, it prints:
```
Register existing: aba -d $name --pull-secret-mirror <file> --ca-cert <file>
```

**Fix**: Change to `"aba -d $name register --pull-secret-mirror <file> --ca-cert <file>"`.

### Gap 6 (MEDIUM): `--reg-port` not mentioned in any register example

`reg-register.sh` **requires** both `reg_host` and `reg_port` in `mirror.conf`. The default port is 8443, so it works for Quay registries. But if an existing registry runs on a different port, none of the register examples in README, help, or error messages mention `--reg-port`.

**Fix**: Add `--reg-port` to at least one register example in help-mirror.txt and README, e.g.:
```
aba -d mirror register --reg-host registry.example.com --reg-port 5000 --pull-secret-mirror /path/to/ps.json --ca-cert /path/to/ca.pem
```

### Gap 7 (LOW): Tests use two different argument styles

| Suite | Invocation |
|-------|-----------|
| `suite-airgapped-existing-reg.sh` | `aba -d mirror register --pull-secret-mirror <file> --ca-cert <file>` (CLI flags) |
| `suite-cluster-ops.sh` | `aba -d mirror register pull_secret_mirror=<file> ca_cert=<file>` (Make-style args) |

Both work (Make variables pass through), but the Make-style form (`pull_secret_mirror=...`) is an internal implementation detail, not documented for users. Tests should use the documented CLI form.

**Fix**: Change `suite-cluster-ops.sh`, `suite-kvm-lifecycle.sh`, and `suite-vmw-lifecycle.sh` to use `--pull-secret-mirror` / `--ca-cert` CLI flags instead of Make-style args.

### Gap 8 (LOW): CHANGELOG uses bare `aba unregister` (incomplete)

**File**: `CHANGELOG.md` line 147

CHANGELOG 0.9.7 says: "Deregister with `aba unregister`". This only works if CWD is already a mirror directory. The correct portable form is `aba -d mirror unregister`.

**Fix**: Update CHANGELOG to `aba -d mirror unregister`.

### Gap 9 (MEDIUM): `help-aba.txt` has zero mention of register/unregister

**File**: `others/help-aba.txt`

The main `aba --help` output doesn't reference `register` or `unregister` at all. A user who hasn't read the README has no way to discover the feature from the CLI.

**Fix**: Add a brief mention in the mirror section of help-aba.txt, e.g.:
```
  aba -d mirror register ...           # Register an existing mirror registry
  aba -d mirror unregister             # Deregister (removes local creds only)
```

### Summary table

| Gap | Severity | Where | What |
|-----|----------|-------|------|
| 1 | High | `aba.sh` help routing | `aba register -h` shows wrong help |
| 2 | Medium | `help-mirror.txt` | Not in "Related commands" |
| 3 | Medium | `help-mirror.txt` | Examples omit `register` keyword |
| 4 | Low | `reg-common.sh` | Error msgs omit `register` keyword |
| 5 | Low | `setup-mirror.sh` | Post-creation hint omits keyword |
| 6 | Medium | README + help | `--reg-port` undocumented for register |
| 7 | Low | Test suites | Make-style args instead of CLI flags |
| 8 | Low | CHANGELOG | Bare `aba unregister` (no `-d mirror`) |
| 9 | Medium | `help-aba.txt` | No mention of register/unregister |

---

## TUI: `RETRY_COUNT` setting not persisted across TUI restarts

**Priority:** Low
**Added:** 2026-04-26

### Problem

`RETRY_COUNT` is initialized to `"2"` at the top of `tui/abatui.sh` (line 257) and can be toggled via the Settings menu (off → 2 → 8 → off). However, the value is never saved to `aba.conf` or any TUI state file. Every time the TUI restarts, `RETRY_COUNT` resets to `"2"`.

Other settings like `ABA_AUTO_ANSWER` and `ABA_REGISTRY_TYPE` appear to have similar persistence gaps.

### Proposed fix

Persist TUI settings to a state file (e.g. `~/.aba/tui-settings.sh` or into `aba.conf`) on change, and load them on TUI startup. Alternatively, tie `RETRY_COUNT` to the existing `aba.conf` `oc_mirror_retry` variable if one exists.

---

## `_shutdown_all_node_vms_off()` should check `$platform`, not file existence

**Priority:** Medium
**Added:** 2026-04-15

### Problem

`_shutdown_all_node_vms_off()` uses `[ -s vmware.conf ]` and `[ -s kvm.conf ]` to decide
which hypervisor path to take. This violates the ABA architecture rule that **config
variables are the single source of truth** -- file presence must never be used to infer
settings. Only `platform=vmw` or `platform=kvm` (from `aba.conf`) is authoritative.

### Use case

If both `vmware.conf` and `kvm.conf` happen to exist in the cluster directory (e.g. after
switching platforms or copying configs), the function silently picks VMware because it
checks `vmware.conf` first. The user sees incorrect behavior with no error.

### Current code (wrong)

```bash
if [ -s vmware.conf ]; then
    # VMware path ...
fi
if [ -s kvm.conf ]; then
    # KVM path ...
fi
return 1
```

### Fix

```bash
source <(normalize-aba-conf)   # or use $platform if already sourced
case "$platform" in
    vmw)
        ensure_govc
        source <(normalize-vmware-conf)
        # ... VMware power-state checks ...
        ;;
    kvm)
        ensure_virsh
        source <(normalize-kvm-conf)
        # ... KVM domstate checks ...
        ;;
    *)
        return 1
        ;;
esac
```

### Action items

- Audit `_shutdown_all_node_vms_off()` to use `$platform` instead of file-existence checks
- Search for other functions that use `[ -s vmware.conf ]` / `[ -s kvm.conf ]` as branching logic and fix them too
- Ensure `$platform` is available in the calling context (sourced from `aba.conf` or passed as env var)

---

## E2E: Parallelize deploy loops in `run.sh`

**Priority:** Medium
**Added:** 2026-04-26

### Problem

`run.sh` deploys the test harness and source code to conN hosts sequentially:

```
Deploying test harness to con1 ...
Deploying test harness to con2 ...
Deploying test harness to con3 ...
Deploying test harness to con4 ...
```

Same for `--dev` source deploys. With 4+ pools, the sequential loop adds unnecessary startup latency (each deploy involves SSH + scp + tar extract).

### Proposed fix

Run the per-pool deploy operations in parallel (background each, then `wait`):

```bash
for _p in $CLI_POOL_LIST; do
	deploy_pool "$_p" &
done
wait
```

Same treatment for the `--dev` source deploy loop and `sync_dis_aba` calls.

### Considerations

- Output interleaving: redirect each pool's output to a temp file or prefix with `[conN]` to keep logs readable
- Error handling: capture each background job's exit code via `wait $pid; rc=$?` and report failures
- SSH connection limits: unlikely to be an issue with 4-6 pools, but monitor

---

## E2E: Add remote command execution to interactive `!cmd` prompt

**Priority:** Medium
**Added:** 2026-04-28

### Problem

The E2E framework's interactive failure prompt (`[R]etry [s]kip ... [!cmd]`) only runs commands locally on the conN host. Sometimes during debugging, the user needs to run a command on a **different** host (bastion, disN, another conN, etc.) -- for example `!aba --dir e2e-sno3 kill` may need to run on bastion where govc/vCenter credentials are available, not on conN where the VM isn't visible.

### Proposed feature

Add a `!host:cmd` syntax to the interactive prompt:

```
[R]etry [s]kip [S]kip-suite [0]restart-suite [c]leanup [a]bort [p]ause [!cmd] [!host:cmd] (24h timeout):
```

Examples:
- `!bastion:aba --dir e2e-sno3 kill` -- run on bastion via SSH
- `!dis2:ls ~/aba/mirror/` -- run on dis2
- `!aba --dir e2e-sno3 kill` -- existing behavior, run locally on conN

### Implementation sketch

In `lib/framework.sh` (or wherever the interactive prompt is handled), detect the `host:` prefix:

```bash
if [[ "$user_input" == !*:* ]]; then
    _host="${user_input#!}"
    _host="${_host%%:*}"
    _cmd="${user_input#*:}"
    ssh -F ~/.aba/ssh.conf "$_host" "$_cmd"
elif [[ "$user_input" == !* ]]; then
    eval "${user_input#!}"
fi
```

### Considerations

- SSH config (`~/.aba/ssh.conf`) must be available on conN hosts (it is -- deployed by harness)
- The remote host must be reachable from conN (bastion always is; disN may vary)
- Output should be displayed inline so the user can see the result before choosing next action
- Tab-completion of hostnames would be nice but not required

---

## Enhancement: Run preflight checks in the background

**Priority:** Medium
**Added:** 2026-04-28

### Problem

`scripts/preflight-check.sh` runs synchronously before ISO generation (`Makefile.cluster` lines 116/119). It performs DNS reachability, NTP reachability, IP conflict detection, and vSphere resource checks -- all network probes that can take 10-30+ seconds (especially with unreachable servers timing out). This blocks the entire ISO build pipeline while waiting.

### Proposed fix

Run preflight checks in the background while the ISO generation proceeds in parallel:

1. Launch `preflight-check.sh` as a background job, capturing its PID
2. Continue with ISO generation (`openshift-install agent create image ...`)
3. Before the ISO is used (e.g. before VM creation or upload), `wait $pid` and check the exit code
4. If preflight failed, abort before the point of no return (VM creation)

```bash
# In Makefile.cluster or the calling script:
scripts/preflight-check.sh &
_preflight_pid=$!

# ... ISO generation proceeds ...

# Before VM creation:
if ! wait $_preflight_pid; then
    aba_abort "Pre-flight checks failed -- see output above"
fi
```

### Considerations

- Output interleaving: preflight messages will mix with ISO generation output. Options:
  - Redirect preflight output to a temp file, display on failure or at the wait point
  - Use `[PREFLIGHT]` prefix on all preflight messages for clarity
  - Accept interleaving (preflight messages are `[ABA]`-prefixed already)
- The vSphere checks (`preflight-check-vsphere.sh`) are the slowest (govc API calls). These benefit most from parallelization
- If preflight finishes before ISO generation, the user sees results early -- no downside
- `verify_conf=conf` or `verify_conf=off` already skips network checks; background mode would only apply when checks are enabled
- The Makefile target structure may need adjustment since Make doesn't natively support "start A, run B, wait for A"

### References

- `scripts/preflight-check.sh`: all checks (DNS, NTP, IP conflicts, vSphere)
- `templates/Makefile.cluster` lines 116, 119: synchronous invocation before ISO targets
- `scripts/preflight-check-vsphere.sh`: vSphere-specific checks (govc calls)

---

## Enhancement: TUI does not support KVM platform

**Priority:** Medium
**Added:** 2026-04-28

### Problem

The TUI "Platform & Network" screen only offers `vmw` (VMware) as a platform option. There is no way to select `kvm` (libvirt/KVM) through the TUI. Users who want to deploy on KVM must manually edit `aba.conf` to set `platform=kvm` and create `kvm.conf` outside the TUI.

### What's needed

1. **Platform selection**: The TUI platform picker should offer `vmw`, `kvm`, and `bm` (bare-metal) as options
2. **KVM config screen**: When `kvm` is selected, present a `kvm.conf` editor (similar to the `vmware.conf` editor for VMware) with fields for:
   - `KVM_HOST` (libvirt host)
   - `KVM_USER` (SSH user)
   - `KVM_SSH_KEY` (SSH key path)
   - `KVM_STORAGE_POOL` (storage pool name)
   - `KVM_NETWORK` (libvirt network name)
   - Other KVM-specific settings from `templates/kvm.conf`
3. **Bare-metal path**: When `bm` is selected, skip hypervisor config entirely (ISO-only workflow)

### References

- TUI screenshot: Platform & Network screen shows only `vmw`
- `tui/abatui.sh`: platform selection logic
- `templates/kvm.conf`: KVM config template
- `templates/vmware.conf`: VMware config template (model for KVM screen)

---

## UX: Uninstall command not clearly displayed (Quay and Docker)

**Priority:** Low
**Added:** 2026-04-28

### Problem

When running `aba uninstall -d mirror`, the actual command being executed is not prominently displayed before the operation begins. For Quay, the `mirror-registry uninstall` tool prints a massive ASCII art banner and verbose Ansible output that immediately drowns out ABA's `[ABA] Running command: ./mirror-registry uninstall ...` message (line 34 of `reg-uninstall-quay.sh`). The user sees a wall of Ansible logs but can't easily identify what command was run.

The TUI does show `aba uninstall -d mirror` at the top, but the underlying registry-specific command is buried.

### Also check

- `reg-uninstall-docker.sh` -- does it clearly show what's being removed?
- `reg-uninstall-remote.sh` -- same issue for remote uninstalls (SSH + ansible output)
- `reg-install-quay.sh` -- same Quay ASCII art issue during install

### Proposed fix

Add a prominent, visually distinct banner before the registry command runs:

```bash
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
aba_info "Running: $cmd"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
```

Alternatively, suppress the Quay ASCII banner by piping through `grep -v` or redirecting the first N lines of `mirror-registry` output.

### References

- `scripts/reg-uninstall-quay.sh` line 34: `aba_info "Running command: $cmd"`
- `scripts/reg-uninstall-remote.sh` line 75: `aba_info "Running: mirror-registry uninstall on $REG_HOST ..."`
- `scripts/reg-uninstall-docker.sh` lines 28-31: shows stop/remove but no command echo

---

## Enhancement: Configurable GPG signature verification for catalog pulls

**Priority:** Low
**Added:** 2026-04-28

### Background

ABA's `scripts/download-catalog-index.sh` bypasses GPG signature verification when pulling operator catalog images from `registry.redhat.io`, using `--signature-policy` with `insecureAcceptAnything`. This matches oc-mirror's own default behavior (PR [openshift/oc-mirror#852](https://github.com/openshift/oc-mirror/pull/852) -- catalogs mirrored without signature verification by default since OCP 4.16).

The bypass was added because signature infrastructure is fragile -- missing GPG keys (Fedora/minimal systems), broken `lookaside` URLs in `registries.d`, or Red Hat signing changes can all break pulls. Performance impact of signature checking is negligible (<0.3s on a ~500MB image).

### Proposed change

Add a config variable in `~/.aba/config` to control signature verification:

```bash
# Verify GPG signatures when pulling operator catalog images from registry.redhat.io.
# Default: off (matches oc-mirror behavior). Set to 1 to enable verification.
# Requires: /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release and correct registries.d lookaside config.
# VERIFY_CATALOG_SIGNATURES=0
```

In `scripts/download-catalog-index.sh`:

```bash
if [ "${VERIFY_CATALOG_SIGNATURES:-0}" = "1" ]; then
    _pull_err=$(podman pull -q "$catalog_url" 2>&1 >/dev/null) || { ... }
else
    echo '{"default":[{"type":"insecureAcceptAnything"}]}' > "$_sig_policy"
    _pull_err=$(podman pull --signature-policy="$_sig_policy" -q "$catalog_url" 2>&1 >/dev/null) || { ... }
fi
```

### Related fix (already applied)

`templates/aba-sigstore-config.yaml` now includes `lookaside` URLs for `registry.redhat.io` and `registry.access.redhat.com`, preventing ABA's user-level `registries.d` config from overriding the system-level signature lookup URLs. This was required because ABA's `docker: registry.redhat.io:` entry (with only `use-sigstore-attachments`) was shadowing the system-level entry that contained the `lookaside` URL, causing manual `podman pull` to fail with "A signature was required, but no signature exists".

### References

- `scripts/download-catalog-index.sh` lines 128-134: current `insecureAcceptAnything` bypass
- [openshift/oc-mirror#852](https://github.com/openshift/oc-mirror/pull/852): oc-mirror disables catalog sig verification by default
- `templates/aba-sigstore-config.yaml`: ABA's registries.d config (now includes lookaside URLs)

---

---

## Enhancement: TUI option to install mirror without syncing

**Priority:** Medium
**Added:** 2026-04-28

### Problem

The TUI currently combines mirror installation and image syncing into a single workflow. There is no option to just install the mirror registry (Quay or Docker) without immediately syncing images to it. Users may want to:

- Install the registry first, then sync later (e.g. after reviewing the imageset config)
- Install the registry on a remote host and verify connectivity before starting a long sync
- Set up the registry for a bundle-based (save/load) workflow where `sync` is never used
- Register an existing external registry without syncing

### Proposed change

Add a separate menu option in the TUI mirror workflow, e.g.:

```
Mirror Registry
  1. Install & Sync (current behavior)
  2. Install Only (set up registry, skip image sync)
  3. Register Existing (for pre-existing registries)
```

"Install Only" would run `aba -d mirror install` and stop. The user can later run sync from the TUI or CLI.

### References

- `tui/abatui.sh`: mirror workflow screens
- `aba -d mirror install`: installs registry only
- `aba -d mirror sync`: syncs images to installed registry

---

## Enhancement: TUI mirror install screen should allow port configuration

**Priority:** Medium
**Added:** 2026-04-28

### Problem

The "Remote Quay Registry (SSH)" TUI screen shows fields for Remote Host, SSH Username, SSH Key Path, Registry Username, Registry Password, Registry Path, and Data Directory -- but there is no field for **Registry Port**. The port defaults to 8443 (Quay) or 5000 (Docker), but users running registries on non-standard ports have no way to change it from the TUI. They must manually edit `mirror.conf` after the fact.

The same issue applies to the local Quay/Docker install screens.

### Proposed change

Add a "Registry Port" field to all mirror registry TUI screens (local Quay, remote Quay, local Docker, remote Docker), defaulting to 8443 for Quay and 5000 for Docker. The value maps to `reg_port` in `mirror.conf`.

### References

- Screenshot: "Remote Quay Registry (SSH)" screen -- no port field visible
- `mirror.conf`: `reg_port` variable
- `tui/abatui.sh`: mirror configuration screens

---

## E2E: Add thorough remote registry install tests (Docker and Quay)

**Priority:** High
**Added:** 2026-04-28

### Problem

E2E test coverage for remote registry installations is thin. The current suites mostly test local registry installs. Remote installs (via SSH) have different failure modes -- firewall rules, TLS cert trust propagation, connectivity checks from the source host, SSH key handling, and the `reg_ssh_key`/`reg_ssh_user` config flow -- that are not well exercised.

A user hit a post-install connectivity check failure when installing Docker remotely via the TUI (`bastion.example.com:8443 is not reachable from this host`), suggesting the remote install path needs more testing.

### What to test

**Both Docker and Quay, installed remotely via SSH:**

1. **Install**: `aba -d mirror install --vendor docker -H <remote> -k <key>` and same for `--vendor quay`
2. **Post-install connectivity**: verify the registry is reachable from the source host after install
3. **TLS cert trust**: verify the CA cert is fetched and trusted on the source host
4. **Firewall**: verify the port is opened on the remote host
5. **Sync/Load**: verify images can be synced/loaded to the remote registry
6. **Uninstall**: verify remote uninstall cleans up properly (containers, data, certs)
7. **Re-install**: verify a second install on the same remote host works (idempotent)
8. **Wrong SSH key / unreachable host**: verify clean error messages
9. **Port configuration**: non-default port (e.g. 5000 instead of 8443)
10. **Rootless vs root**: test with both `reg_ssh_user=root` and a non-root user

### Where

Add a dedicated suite `suite-remote-registry.sh` or extend `suite-mirror-sync.sh` with a remote-install section. Requires a test host pair where one conN can SSH to another (or to a disN) to install the registry remotely.

### References

- `scripts/reg-install-remote.sh`: remote install logic
- `scripts/reg-uninstall-remote.sh`: remote uninstall logic
- User-reported failure: Docker remote install via TUI, post-install curl check failing

---

## VM Notes: add newlines to vCenter annotation

**Priority:** Low
**Added:** 2026-04-27

### Problem

The `_vm_annotation()` function in `scripts/include_all.sh` (line 287) generates a multi-line heredoc for VM notes, but the result renders as a single paragraph in vCenter (no line breaks). The vCenter Notes field DOES support newlines (confirmed visually in the vCenter UI).

### Current code

```bash
cat <<-EOF
OpenShift ${role_label} Node (${cluster_type}), initial version v${ocp_version}
Installed by ABA v${aba_ver} (github.com/sjbylo/aba) on $(date)
Console: https://console-openshift-console.apps.${CLUSTER_NAME}.${base_domain}
API: https://api.${CLUSTER_NAME}.${base_domain}:6443
Manage from $(hostname):${PWD} — aba -d ${CLUSTER_NAME} [info|startup|shutdown|delete]
EOF
```

### Proposed fix

Investigate whether `govc vm.create -annotation=` strips newlines. If so, try:
1. Using `govc vm.change -annotation=` after creation (may preserve newlines better)
2. Embedding literal `\n` and letting govc interpret them
3. Passing annotation via stdin or a temp file

The annotation is also used by `kvm-create.sh` via `virsh desc --new-desc` -- verify newlines work there too.

### Desired output in vCenter Notes

```
OpenShift Control Node (sno), initial version v4.20.18
Installed by ABA v1.0.1 (github.com/sjbylo/aba) on Mon Apr 27 01:32:47 PM +08 2026

Console: https://console-openshift-console.apps.e2e-sno4.p4.example.com
API: https://api.e2e-sno4.p4.example.com:6443
Manage from con4:/home/steve/aba/e2e-sno4 — aba -d e2e-sno4 [info|startup|shutdown|delete]
```

---

## Bug: Remote Docker install post-install check fails on timing race

**Priority:** Medium
**Added:** 2026-04-28

### Problem

When installing a Docker registry on a remote host via `reg-install-remote.sh`, the post-install curl check (line 231) can fail with a transient 401 "invalid authorization credential" if the Docker registry container hasn't fully loaded the htpasswd volume yet. The check runs immediately after `reg_post_install` returns. Quay doesn't have this issue because its Ansible installer does its own readiness verification.

Additionally, the check has two code quality issues:
1. **`>/dev/null 2>&1` suppresses stderr** -- violates project rules; hides whether the real failure is auth, TLS, or connectivity
2. **Error message says "not reachable"** regardless of failure type -- misleading when the actual problem is a 401 auth error

### Evidence

Registry log from the failure:
- `12:23:02` -- container started
- `12:24:10` -- `GET /v2/ HTTP/2.0` returns 401 "invalid authorization credential" (from bundle host)
- Immediately after: `aba verify` succeeds from the same host with the same credentials

### Proposed fix

1. **Add a retry loop** (e.g. 3 attempts, 3-5 second sleep) to the Docker curl check -- gives the container time to load auth
2. **Remove `2>&1`** from the curl invocation -- let the actual error be visible
3. **Capture and display the curl error** in the `aba_abort` message so the user sees the real reason (auth/connectivity/TLS)

---

## Enhancement: Display actual port numbers in cluster configuration summary

**Priority:** Low
**Added:** 2026-04-28

### Problem

The "Cluster configuration" summary table shows `PORTS_PER_NODE` (e.g. 2) but does not display the actual port numbers (e.g. 6443, 443 or whatever is configured). The user can see how many ports each node has but not which ports they are.

### Proposed fix

Add a row (e.g. `CP_PORTS`, `WKR_PORTS`) showing the actual port values alongside the existing `PORTS_PER_NODE` count, or replace `PORTS_PER_NODE` with the explicit port list if that's more useful.

---

## Bug: "Power down VMs?" prompt shown even when VMs don't exist

**Priority:** Medium
**Added:** 2026-04-28

### Problem

During cluster creation (after ISO build, before VM creation), ABA lists the VM paths and asks "Immediately power down the above virtual machine(s)? (Y/n):" -- but the VMs may not exist yet (all return `govc: vm 'xxx' not found`). The prompt is pointless and confusing when VMs haven't been created, and equally pointless if they're already powered off.

### Proposed fix

Before prompting, check whether any of the listed VMs actually exist AND are powered on. Skip the prompt entirely if:
- None of the VMs exist (first install -- nothing to power down)
- All existing VMs are already powered off

Only prompt when at least one VM exists and is powered on.

---

## Review: Stale debug pod cleanup during cluster startup may be unnecessary

**Priority:** Low
**Added:** 2026-04-28

### Question

`cluster-startup.sh` force-deletes stale `oc debug` pods from the `default` namespace on every startup, citing an "infinite shutdown loop" risk. However, `oc debug --preserve-pod` creates pods with `restartPolicy: Never`, so kubelet should not re-run them after a reboot -- completed pods stay `Succeeded`, interrupted pods go to `Failed`.

### Current code

```bash
for pod in $($OC get pods -n default --no-headers 2>/dev/null | grep "\-debug-" | awk '{print $1}'); do
	aba_info "Removing stale debug pod: $pod"
	_try $OC delete pod -n default "$pod" --grace-period=0 --force || true
done
```

### Proposed investigation

- Verify `restartPolicy: Never` is always set on `oc debug` pods across supported OCP versions.
- Test: shut down a cluster with `--preserve-pod` debug pods present, restart, confirm no re-execution.
- If confirmed safe, either remove the cleanup entirely or downgrade to a simple `$OC delete pod` (no `--force --grace-period=0`).

---

## Enhancement: Fix stderr suppression with TUI compatibility

**Priority:** High
**Added:** 2026-04-28
**Branch:** `feature/try-helper`
**Plan:** `fix_stderr_suppression_8d273729`

### Problem

ABA suppresses stderr (`2>/dev/null`) in many places, hiding actual error messages from users when commands fail. The `_try()` helper and `aba_wait_show()` enhancement were developed to fix this, but the changes are **not TUI-safe**: removing `2>/dev/null` causes raw stderr to leak into the TUI display, corrupting the screen layout.

### What exists (on `feature/try-helper`)

- `_try()` helper: captures stderr into `$_LAST_ERR`, auto-logs "Running:" in debug mode
- Enhanced `aba_wait_show()`: shows "Last output:" on timeout, per-iteration log + full history
- 34 functional tests (all pass)
- One-shot fixes across 7 scripts

### What needs investigation

1. **TUI compatibility**: Scripts called by the TUI must never emit raw stderr. All "unsuppress" changes (`day2.sh`, `aba.sh`, `download-catalog-index.sh`) need to use `_try` + structured output (`aba_warning`/`aba_abort`) instead of just removing `2>/dev/null`.
2. **TUI should adopt `_try()`**: The TUI itself should use `_try` for command execution to capture and display errors cleanly.
3. **Dual-mode scripts**: Scripts called by both CLI and TUI must work in both contexts.

### Remove `aba getco` command

Remove the `getco` verb from `scripts/aba.sh`. It's redundant — `aba run` (which defaults to `--cmd "get co"`) does the same thing. No need for a separate command.

### Key constraints discovered

- `_try` must NOT be used inside `aba_wait_show` polling callbacks (intercepts stderr from `_wait_log`)
- `_try` must NOT be used on stderr-visible commands unless the error is re-displayed via `aba_warning`/`aba_abort`
- `_try curl` must always use `-sS` to avoid progress meter in `_LAST_ERR`
- Probes (`probe_host`) must stay silent -- failures are expected

---

## E2E: Fix --dev flag so uncommitted changes are actually tested

**Priority**: High
**Added:** 2026-04-30

### Problem

The `--dev` flag in `run.sh` is intended to let a developer push their local (uncommitted) working copy to all pool VMs so it gets tested by every suite. Today it pushes a tarball to `~/aba` on conN, but **every suite calls `e2e_install_aba()` as its first step**, which does `rm -rf ~/aba/* && git clone ...` -- wiping the dev tarball and replacing it with the committed code from git. The developer's changes are never actually tested.

### Root cause

`e2e_install_aba()` in `lib/framework.sh` unconditionally does a fresh `git clone`. It has no awareness of dev-mode code already being present.

### Proposed fix

See plan: `fix_--dev_flag_2b507f6b.plan.md`

1. **Keep the dev tarball on conN** at `/tmp/aba-dev-source.tar.gz` (don't delete after extraction).
2. **Modify `e2e_install_aba`** to check for `/tmp/aba-dev-source.tar.gz` -- if present, wipe and re-extract from tarball instead of `git clone`. Each suite still gets a clean `~/aba` but from the dev tarball.
3. **Clean up stale tarball** on non-`--dev` runs so normal runs revert to `git clone`.
4. **Expand `.deploy-manifest`** to include all paths needed for a complete ABA install (currently missing `build/`, full `cli/`, etc.).
5. **Fix `sync_infra_aba`** to use local `scripts/aba.sh` in dev mode instead of `git show` from the committed branch.

### Files involved

- `test/e2e/lib/framework.sh` -- `e2e_install_aba` dev-tarball check
- `test/e2e/lib/deploy.sh` -- `sync_source` keep tarball; `sync_infra_aba` dev-mode path
- `test/e2e/run.sh` -- cleanup stale tarball on non-dev runs
- `test/e2e/.deploy-manifest` -- expand to include all required paths

## Store platform type in installed cluster state

When a cluster is installed, the platform type (`vmw`, `kvm`, `bm`) must be persisted in the cluster directory state (e.g. in `cluster.conf` or a marker). Currently `aba startup` assumes bare-metal and prints "Please power on all bare-metal servers" even for VMware/KVM clusters, where it should auto-start VMs via `govc`/`virsh`.

Example failure: running `aba startup -y` on a VMware-based cluster shows the bare-metal message and waits 5 min for API that will never come up (because VMs were never started).

### Expected behavior

- `aba startup` should check the platform type and:
  - `vmw` → power on VMs via govc
  - `kvm` → start VMs via virsh
  - `bm` → print "power on servers" message and wait
- The platform must be stored at cluster creation time (it's in `aba.conf` globally but needs to be in the cluster dir for portability).

## Test and fix: `scripts/listopdeps.sh`

- Test `scripts/listopdeps.sh` and fix any issues found.
- This script lists operator dependencies (e.g. `scripts/listopdeps.sh 4.18 odf-operator`) and is referenced in the README under "Operator Dependencies".

## Implement `aba status` command

**Priority:** Medium
**Added:** 2026-05-07

### Purpose

Provide a single command to report the full state of the ABA repo, usable by humans and scripts (TUI, CI):

```
aba status            # human-readable text
aba status --json     # machine-parseable JSON
```

### Proposed output fields

- **OCP:** version, channel
- **Mirror:** running (yes/no), verified (yes/no), vendor (quay/docker), remote host (if any), has release image (yes/no)
- **CLI tools:** present (list of `cli/*.tar.gz` files)
- **Config:** `aba.conf` complete (yes/no), `mirror.conf` complete (yes/no)
- **Payload:** equivalent-to-bundle (yes/no) — ISC + archives + CLI all present
- **Clusters:** list of configured/installed cluster dirs with type and status

### Usage in TUI

The TUI currently performs basic file checks (ISC, archives, CLI files, `aba -d mirror verify`)
for CONNO-offline mode detection. Once `aba status --json` exists, the TUI will call it
instead of doing ad-hoc checks, keeping validation logic in one place.

### Notes

- Must work offline (no internet required for status check)
- `aba -d mirror verify` already exists for the registry check — reuse it
- Consider caching the result for ~30s via `run_once` to avoid repeated calls in TUI loops

---

## Suppress "All operator catalogs ready" when no operators defined

### Problem

The message `[ABA] All operator catalogs ready for OCP X.Y` is printed during ISC
generation even when there are NO operators defined in the configuration. This is
misleading — it implies operator catalogs were processed when nothing was actually needed.

### Proposed fix

In the script that prints this message, guard it with a check: only print if there are
actually operators configured (e.g. operator entries in the ISC, or operator-set files
referenced). If no operators are defined, skip the catalog download and suppress the message.

### Scope

- Identify which script prints `All operator catalogs ready` (likely `reg-create-imageset-config.sh` or a catalog download helper)
- Add a condition: if no operators are in the config, skip catalog work entirely
- Low risk, cosmetic improvement

---

## TUI: Add operator selection at the end of the wizard

### Problem

In v1, operator selection was part of the setup wizard (channel → version → operators → action menu).
In v2, operators were moved to a separate action menu item, which means a user can install/save
a mirror without ever being prompted to select operators. This is unintuitive for first-time users.

### Proposed fix

Add an operator selection step at the end of the wizard flow (after version/platform selection),
before entering the action menu. Keep the "Select Operators" item in the action menu as well
so users can change operators later.

### Notes

- The wizard step should be skippable (user can press "Skip" or "Done" to proceed without operators)
- If catalogs haven't downloaded yet, show a brief wait dialog
- This matches v1 behaviour where operators were chosen before any mirror action
- Low risk — additive change, no existing flows broken

---

## TUI: Allow changing channel/version from action menus

### Problem

Once the wizard completes, the channel and version are locked in `aba.conf`. If the user
wants to change them (e.g. upgrade from 4.21 to 4.22, or switch from stable to candidate),
they must exit the TUI and manually edit `aba.conf` or re-run from scratch.

### Proposed fix

Add a "Change Version/Channel" option to the action menu (under an "Advanced" or "Settings"
sub-menu). This would:
1. Present the channel selection dialog (same as wizard)
2. Present the version selection dialog (same as wizard)
3. Save to `aba.conf` via `_direct_save_config()`
4. Trigger ISC background regeneration
5. Optionally warn: "Changing version may require re-saving/re-syncing images"

### Notes

- Advanced use case — should not clutter the main menu (put under "Other" or "Settings" section)
- Must trigger ISC regen (already handled by `_direct_save_config`)
- Should warn about implications (existing mirror data may not match new version)
- Consider: should operator basket be re-validated against new version's catalog? (Yes — stale operators should be flagged/removed)
- Medium complexity — reuses existing wizard dialogs but needs careful UX for the "you already have data" scenario

---

## TUI: Smart bundle creation — reuse existing images or force refresh

### Problem

When creating a bundle, `aba bundle` internally runs `make -C mirror save` which invokes
`oc-mirror`. If images were already downloaded (from a previous `aba save`, `aba sync`, or
an earlier bundle), oc-mirror is incremental and reuses what's on disk. However:

1. The core script (`make-bundle.sh`) shows a confusing warning if `mirror/data/` already
   has files, asking "Continue anyway?" — this is not TUI-friendly
2. The TUI gives no indication that existing data will be reused (saves time!)
3. Users might think they need `--force` when they don't
4. There's no way in the TUI to choose between "reuse" (fast, incremental) vs "clean rebuild"
   (slower, guarantees fresh images)

### Proposed fix

In the TUI's `mirror_create_bundle()`, before running `aba bundle`:
1. Check if `mirror/data/mirror_*.tar` already exists
2. If yes, present a choice dialog:
   - **"Reuse existing images (fast)"** — runs `aba bundle --out $path` (no `--force`,
     oc-mirror is incremental)
   - **"Download fresh (clean rebuild)"** — runs `aba bundle --out $path --force`
   - Help text explains: "Reuse is faster — only changed/new images are downloaded.
     Clean rebuild deletes everything and re-downloads from scratch."
3. If no existing data: skip the dialog, just run without `--force`
4. Pass `-y` so the core script's "Continue anyway?" prompt is auto-answered

### Notes

- oc-mirror v2 is already incremental by design — "reuse" is the correct default
- `--force` should only be needed if the ISC changed significantly (e.g. different OCP version)
  or if previous data is suspected corrupt
- The TUI should default to "Reuse" (pre-selected) since it's the common fast path
- Low-medium complexity — detection is simple (`ls mirror/data/mirror_*.tar`), dialog is standard

---

## ABA core: Platform-aware default port names in create-cluster-conf.sh

### Problem

`scripts/create-cluster-conf.sh` hardcodes `ports=ens160` as the default regardless of platform.
This is only correct for VMware. KVM uses `enp1s0` and bare-metal varies by hardware.

### Proposed fix

In `create-cluster-conf.sh`, replace:
```bash
[ ! "$ports" ] && export ports=ens160
```

With platform-aware logic:
```bash
if [ ! "$ports" ]; then
    case "$platform" in
        vmw) export ports=ens160 ;;
        kvm) export ports=enp1s0 ;;
        *)   export ports=ens1f0 ;;   # bare-metal common default
    esac
fi
```

### Notes

- `$platform` is already available (sourced from aba.conf earlier in the script)
- The bare-metal default (`ens1f0`) is a reasonable guess but ultimately the user must
  verify — the MAC address is what truly identifies the NIC, not the port name
- The TUI already does this (platform-aware defaults in `tui-cluster.sh`) — the core
  script should match
- Low risk, one-line change

## Smart `aba reset` in bundle mode — preserve CLI files

**Priority:** Medium
**Scope:** ABA core (`scripts/aba.sh` or reset logic)

### Problem

`aba reset` is a "distclean" that returns the repo to its unpacked state. However, in
**bundle mode** (`.bundle` flag present — disconnected install from tarball), the CLI
binaries and other downloaded artifacts are irreplaceable without internet access. A
careless `aba reset` wipes them, leaving the user unable to proceed.

### Proposed behaviour

When `.bundle` mode is detected, `aba reset` should:

1. **Skip deletion** of CLI binaries (`~/bin/oc`, `~/bin/oc-mirror`, `~/bin/openshift-install`, etc.)
2. **Skip deletion** of other costly-to-recreate artifacts (e.g. saved mirror images, catalog indexes)
3. Still clean generated configs, cluster dirs, marker files, and `run_once` cache as today
4. Optionally print a notice: "Bundle mode: preserving CLI tools and downloaded images"
5. Provide a `--force` or `--full` flag to override and truly delete everything

### Why

In disconnected environments, re-downloading CLI tools is impossible. Users who want a
fresh config without losing their tools currently have no safe way to reset.

## Smarter ISC "user edited" detection — ignore whitespace-only changes

**Priority:** Low
**Scope:** ABA core (ISC comparison logic)

### Problem

ABA checks whether the user has edited the ImageSet Config (ISC) file by comparing
timestamps (e.g. is `imageset-config.yaml` newer than the `.created` flag). If a user
opens the file, adds or removes only whitespace (blank lines, trailing spaces, indentation
tweaks), and saves — the file is marked as "user-edited" even though the semantic content
is unchanged. This can trigger unnecessary "Reset to auto-generated" prompts or skip
auto-regeneration when it would have been safe.

### Proposed behaviour

When checking if the ISC has been meaningfully edited:

1. First check timestamps (fast path — if ISC is older, skip)
2. If ISC is newer, do a **content comparison with whitespace stripped**:
   - `diff <(sed 's/[[:space:]]//g' "$isc_file") <(sed 's/[[:space:]]//g' "$generated_copy")` or similar
   - If no diff after whitespace removal → treat as NOT edited
   - If there IS a diff → treat as user-edited (current behavior)
3. Keep a shadow copy of the last auto-generated ISC (e.g. `.imageset-config.yaml.generated`)
   to compare against

### Why

Users often open YAML files in editors that auto-format or add trailing newlines. These
cosmetic changes shouldn't trigger "you edited this" logic.

## Smarter operator persistence — eliminate custom set files

**Priority:** Medium
**Scope:** TUI v2 (`tui/v2/tui-mirror.sh`)
**Suggested approach:** B (hybrid)

### Problem

Today `_persist_operator_basket()` always collapses the entire basket into a single
`templates/operator-set-custom-YYYYMMDD-HHMMSS` file and sets `op_sets=custom-...` in
aba.conf. This is opaque (user sees a timestamp, not "ocp,virt"), creates ephemeral files,
and loses track of which named sets the user actually chose.

### Proposed: Hybrid persistence

Track which named sets were toggled (`OP_SET_ADDED`) separately from individual operators
added via search. On persist:

1. **`op_sets=`** gets the list of named sets the user checked (e.g. `ocp,virt`)
2. **`ops=`** gets any individual operators NOT already covered by the checked sets
3. **No custom set file** unless truly needed

If a user removes an operator that belongs to a named set (via basket editor), dissolve
that set: remove it from `OP_SET_ADDED`, move its remaining operators to `ops=`.

### Benefits

- `aba.conf` becomes human-readable: `op_sets=ocp,virt` and `ops=my-extra-op`
- No more timestamped custom files cluttering `templates/`
- User can see exactly what they picked and why
- CLI and TUI stay compatible (both write to same config keys)
- `add-operators-to-imageset.sh` already handles both `op_sets` and `ops` — no change needed

### See also

Full plan: `~/.cursor/plans/operator_selection_improvement_f1a68d98.plan.md`

---

## Corrupt openshift-install tarball — strengthen download and verify

**Priority:** High
**Scope:** ABA core (`cli/Makefile`)
**Discovered:** 2026-05-09

### Problem

If the `openshift-install-linux-*.tar.gz` file is partially downloaded (e.g. interrupted
curl, killed process, network drop), it persists on disk as a corrupt file. Make sees the
file exists and considers the download target "up to date" — it never re-downloads or
re-validates. The `verify-sha256` function only runs inside the download recipe, so if
Make skips the recipe, verification never happens.

Result: `tar` extraction fails with "gzip: stdin: unexpected end of file" every time,
and the user must manually `rm` the file to recover.

### Suggested fixes

1. **Re-validate on extract failure**: In the install target (line 265), when `tar` fails,
   delete the corrupt tarball and re-run the download target:
   ```make
   ~/bin/openshift-install: .init $(openshift_install_file) | ~/bin
       ...
       tar -C ~/bin -xmzf $(openshift_install_file) openshift-install || \
           { echo "[ABA] Corrupt tarball, re-downloading..."; rm -f $(openshift_install_file); $(MAKE) $(openshift_install_file); tar -C ~/bin -xmzf $(openshift_install_file) openshift-install || exit 1; }
   ```

2. **Always verify before extract**: Add a standalone checksum verification step in the
   install recipe, BEFORE extraction — not just during download:
   ```make
       $(call verify-sha256,$(openshift_install_file),$(openshift_install_url)/sha256sum.txt)
       tar -C ~/bin -xmzf $(openshift_install_file) openshift-install || ...
   ```

3. **Use atomic download**: Download to a temp file, verify, then `mv` to final name.
   This prevents partial files from appearing as "complete":
   ```make
   $(openshift_install_file):
       curl -f --retry 8 -o $@.tmp -L $(url)/$@
       $(call verify-sha256,$@.tmp,$(url)/sha256sum.txt)
       mv $@.tmp $@
   ```

4. **Apply same pattern to all CLI tarballs** (oc, oc-mirror, govc, butane).

---

## CRITICAL: ABA doesn't stop when CLI tools are missing/broken

**Priority:** Critical (P0)
**Scope:** ABA core
**Discovered:** 2026-05-09

### Problem

Three related bugs that cause ABA to proceed with installation despite missing CLI binaries:

**Bug A: `-s install` skips CLI prerequisite on existing cluster dirs**

When running `aba cluster -n <name> -s install` on a cluster directory where
`install-config.yaml` already exists, Make skips the recipe that calls
`cli-install-all.sh --wait` (because the file is "up-to-date"). This means
`openshift-install` is never checked/downloaded, and the ISO generation
step fails with `command not found`.

Reproduction:
```bash
rm ~/bin/openshift-install cli/openshift-install-linux-4.*
aba cluster -n sno2 -t sno -i 10.0.1.202 -I proxy -s install
# Proceeds to ISO generation, fails with "command not found"
```

**Bug B: `generate-image.sh` doesn't fail on first `command not found`**

Line 33 of `scripts/generate-image.sh` runs `openshift-install` (for version info)
and gets "command not found" — but the script continues past the error, displays the
full config table, then fails again at line 103. Should exit immediately at line 33.

**Bug C: `cli-install-all.sh` always exits 0**

The script loops through CLI tools (line 45: `run_once ... make -sC cli $item`) but
if any individual install fails, the loop continues and line 48 unconditionally runs
`exit 0`. Errors from individual tools are silently swallowed.

### Expected behavior

1. If `openshift-install` (or any required CLI) is missing, ABA should detect and
   re-download/install it before proceeding — regardless of which `-s` step is used.
2. `generate-image.sh` should check that `openshift-install` is in PATH and fail
   immediately if not (before doing any other work).
3. `cli-install-all.sh` should track failures and return non-zero if any tool fails.

### Suggested fixes

- Add `openshift-install` as an explicit Makefile prerequisite on the ISO target:
  ```
  iso-agent-based/agent.$(arch).iso: ~/bin/openshift-install install-config.yaml ...
  ```
- Add early guard in `generate-image.sh`:
  ```bash
  command -v openshift-install >/dev/null || { echo "[ABA] Error: openshift-install not found"; exit 1; }
  ```
- Fix `cli-install-all.sh` to track and propagate failures:
  ```bash
  rc=0
  for item in ...; do
      run_once ... || rc=1
  done
  exit $rc
  ```

### Impact

Users lose significant time when the error only surfaces deep into the install flow.
The actual error message ("command not found" buried in output) is non-obvious.

---

## TUI v2: Mirror "Reinstall" doesn't uninstall existing registry first

**Priority:** Medium
**Scope:** TUI v2 — `tui-mirror.sh`

### Problem

When clicking "Install Mirror" on an already-installed mirror (shows as "installed"), the TUI asks "Reinstall it?" and the user clicks Yes. But the subsequent `aba -d mirror install` detects `.available` and skips installation — it doesn't uninstall the existing registry first.

### Expected behavior

"Reinstall" should:
1. Run `aba -d mirror uninstall` first
2. Then run `aba -d mirror install` with the new config (e.g. changed vendor from docker→quay)

### Observed during testing (2026-05-10)

- Docker registry was running
- Changed vendor to `quay` in the config page
- Pressed "Reinstall" → Yes
- `aba -d mirror install` returned immediately (Docker still running)
- Result: mirror.conf says `reg_vendor=quay` but Docker is still the actual registry

### Fix

In `_mirror_install_local()` or the reinstall confirmation handler, add an explicit uninstall step when the user confirms reinstall.

---

## TUI v2: Validate input syntax at entry time (e.g. CIDR format)

**Priority:** Medium
**Scope:** TUI v2 — cluster wizard (`tui-cluster.sh`)

### Problem

The TUI accepts invalid input (e.g. machine network "10.0.0.0" without a prefix length) and only fails later when `aba cluster` rejects it at install time. The user has to navigate back through the wizard to fix the value.

### Expected behavior

Validate input immediately after the user enters it in the dialog. For example:
- **Machine network**: Must be valid CIDR (e.g. `10.0.0.0/16`) — reject if missing `/prefix`
- **Starting IP**: Must be a valid IPv4 address
- **DNS/NTP/Gateway**: Must be valid IPv4 addresses (comma-separated list for DNS/NTP)
- **Cluster name**: Must be a DNS label (a-z, 0-9, hyphens, max 63 chars) — already partially validated
- **VLAN**: Must be a number 1–4094 or empty

If validation fails, show an inline error message and re-present the same input dialog (don't advance).

### Observed during testing (2026-05-12)

- Entered "10.0.0.0" as machine network (missing /16 prefix)
- TUI accepted it without complaint
- Install failed later with: `[ABA] Error: invalid CIDR [10.0.0.0]`
- User had to navigate back and re-enter with `/16`

---

## TUI v2: Remove "Finalize Installation" menu item — auto-detect cluster readiness transparently

**Priority:** Medium
**Scope:** TUI v2 — CONNO/DISCO main menus, cluster state detection

### Problem

The "Finalize Installation (wait-for)" menu item exists because if the user triggers an install but doesn't wait for the "ready" state, the TUI needs to detect completion itself. Currently, the user must manually select "Finalize" to re-attach to the monitoring.

The previous approach (`auto_finalize_cluster` probing `oc version` with a 5s timeout per cluster) caused 10-20s TUI hangs and was removed from `list_installed_clusters()`.

### Desired behavior

Remove the "Finalize" menu item entirely. Instead, detect cluster readiness **transparently**:

1. After `aba install` completes (even if the user dismisses early), kick off a **background** readiness check (non-blocking, via `run_once` or similar).
2. On each main menu loop iteration, check if the background probe has completed — if yes, update the `.install-complete` marker silently.
3. The cluster then appears in "installed" lists without the user needing to do anything.
4. If the background probe hasn't finished yet, show a subtle indicator (e.g., "sno2 (installing...)") rather than hiding the cluster entirely.

### Key constraint

Must be 100% non-blocking — never add latency to menu rendering. Use the same pattern as `aba_mirror_verify_wait` (background `run_once` + wait-at-menu-top).

---

## TUI v2: Interfaces page has insufficient vertical space (shows scrollbar at 66%)

**Priority:** Medium
**Scope:** TUI v2 — cluster wizard (`tui-cluster.sh`), Interfaces page

### Problem

The "Cluster – Interfaces" page only has 2 items (Ports, VLAN) but the inner list box is too short, showing a scrollbar indicator (`↓(+) 66%`) even though all items are visible. This wastes vertical space and looks cramped compared to other wizard pages.

### Expected behavior

The inner list box height should be sized to fit the content (or at least not show a scrollbar when all items are visible). Other wizard pages (Basics, Networking, VM Resources) handle this correctly.

### Screenshot

See `assets/image-9a65f471-d459-4e57-bfb7-997120c83c09.png` — the 66% scrollbar is visible at the bottom of the list box despite only 2 items being shown.

