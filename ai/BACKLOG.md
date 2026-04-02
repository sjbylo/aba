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
