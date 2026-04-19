# ABA Backlog

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

### Additional symptoms found (2026-04-16)

5. **`aba clean refresh` -- chaining a Make target with an externalized target fails:**
   `clean` is not in the externalized target list (`case $cur_target` line 918), so it gets appended to `BUILD_COMMAND`. `refresh` IS externalized, so it becomes `cur_target`. The `refresh)` handler (line 1068) runs `eval $BUILD_COMMAND` which tries to execute `clean` as a bare shell command: `line 1069: clean: command not found`. The same bug affects any combination of a Make target + externalized target (e.g. `aba clean delete`, `aba clean start`).

6. **`aba clean` then any Make-passthrough target -- symlink breakage:**
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

| Code | Meaning |
|------|---------|
| 1 | Generic error (pre-batch: config, auth, collection phase) |
| 2 | Release image copy error |
| 4 | Operator image copy error |
| 8 | Additional image copy error |
| 16 | Helm image copy error |

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
5. **Extract shared retry loop first**: The retry loops in `reg-save.sh`, `reg-sync.sh`, and `reg-load.sh` are ~70 lines of near-identical copy-paste (~210 lines total). The only differences are the `oc-mirror` command args and the action name in messages. Before adding bitmask decoding, extract a shared function (e.g. `_run_oc_mirror_with_retry "$action" "$cmd"`) in `include_all.sh` or a dedicated helper. This avoids modifying 3 copies of the same loop and prevents inconsistencies.

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
**Related**: catalog clobber fix (`0281f6d`), `--since` delta behavior

### Root cause

oc-mirror v2 `diskToMirror` (load from archive) ALWAYS attempts to contact the upstream catalog source (`registry.redhat.io`) during the "collecting operator images" phase. The initial full load works because the archive contains complete catalog data. But an incremental (delta) archive -- even with "save A+B" ISC -- doesn't include enough catalog metadata for oc-mirror to resolve operators without reaching upstream.

Evidence from Pool 2 logs:
- Initial load: `Collected catalog registry.redhat.io/...v4.20` succeeds in <1s (found in archive)
- Incremental load: same catalog collection attempts `registry.redhat.io`, gets `no route to host` (exit=4)

This appears to be an **oc-mirror v2 limitation**: delta archives created with `--since` don't embed sufficient catalog index data for standalone `diskToMirror` resolution.

### Possible workarounds

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

## Enhancement: Externalize installed-cluster state for robust `aba delete`

**Added**: 2026-04-15
**Priority**: Medium
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

## TESTING NEEDED: `aba delete` non-fatal config regen (`make -s init agentconf || true`)

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
- `govc` -- VMware operations (`vm.clone`, `vm.power`, `vm.destroy`, `snapshot.*`, etc.)
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
- The test mirrors 9 `quay.io/kiali/demo_travels_*` images, clones the repo, rewrites image
  refs to the mirror registry, then runs `00-install-all-mesh3.sh` on the air-gapped side

