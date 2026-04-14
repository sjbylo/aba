# ABA Backlog

## URGENT: Shutdown power-off timeout and failure handling (hotfix on `main`)

Increase the shutdown VM power-off timeout from 5 min to 40 min and ensure `aba_abort` on timeout (not just a warning). Fix already exists on `dev` (commits `6550923`, `2b81278`). Cherry-pick to `main`.

## Enhancement: Warn when changing mirror registry identity after install

When a mirror registry is installed and the user changes an "identity" field in `mirror.conf` (`reg_host`, `reg_port`, `reg_vendor`), display a warning via `ask()`:

```
Warning: Registry is installed at old-host:8443 but you're changing reg_host to X ... continue anyway (Y/n):
```

Default is **yes** so automation (`ask=false`) passes through without blocking. Non-identity fields (`reg_path`, `reg_user`, `reg_password`, operator sets, channels) remain freely editable.

**Implementation:** When processing `--reg-host`, `--reg-port`, or `--reg-vendor` flags in `aba.sh` (or the underlying normalize/config scripts), compare the new value against the installed state in `~/.aba/mirror/<dir>/state.sh`. If `state.sh` exists and the value differs, fire the `ask()` warning.

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

| Flag | Variable | aba.sh line |
|------|----------|-------------|
| `--api-vip` | `api_vip` | 542 |
| `--ingress-vip` | `ingress_vip` | 569 |
| `--master-cpu` / `--mcpu` | `master_cpu` | 681 |
| `--master-memory` / `--mmem` | `master_mem` | 693 |
| `--worker-cpu` / `--wcpu` | `worker_cpu` | 705 |
| `--worker-memory` / `--wmem` | `worker_mem` | 717 |
| `--starting-ip` / `-i` | `starting_ip` | 729 |
| `--data-disk` / `--data-disk-gb` | `data_disk` | 741 |
| `--int-connection` / `-I` | `int_connection` | 771 |
| `--num-workers` / `-W` | `num_workers` | 833 |
| `--num-masters` | `num_masters` | 844 |
| `--vlan` | `vlan` | 859 |
| `--ssh-key` | `ssh_key_file` | 871 |
| `--proxy` | `http_proxy` / `https_proxy` | 883 |
| `--no-proxy` | `no_proxy` | 896 |

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

## Investigate: Stale VolumeAttachments after ungraceful cluster shutdown

**Added**: 2026-04-13

After ungraceful VM power-off (e.g. `aba shutdown`, ESXi power-off), the vSphere CSI driver doesn't get to cleanly detach volumes. On next startup, stale VolumeAttachment objects are stuck with `deletionTimestamp` set and a finalizer that the CSI driver can't clear. This blocks rook-ceph-osd pods from re-attaching PVs.

**Current workaround** (manual each time):
```bash
oc get volumeattachment -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}'
oc patch volumeattachment <name> -p '{"metadata":{"finalizers":null}}' --type=merge
oc delete pod <stuck-pod>
```

**Possible solutions to investigate:**
1. Add cleanup to `cluster-startup.sh` (auto-clear stale VAs after uncordon)
2. Improve `cluster-graceful-shutdown.sh` to give CSI driver more time to detach before power-off
3. Investigate if OCP has a built-in recovery mechanism that could be enabled
4. Consider if this is a vSphere CSI bug worth reporting upstream
