# E2E Test Run Status Report

> Baseline snapshot — 2026-03-14 ~06:00 (after commit 3910973)

## Suite Status Overview

| Suite                  | Last Pool | Result | Notes |
|------------------------|-----------|--------|-------|
| `cluster-ops`          | pool 4    | PASS   | 9/9 tests. Retry on pool 4 succeeded after pool 2 failure. |
| `airgapped-existing-reg` | pool 1  | RUNNING | Re-launched with increased compact cluster resources (12 CPU / 24 GB). |
| `negative-paths`       | pool 1    | FAIL   | Stale e2e-docker-test/neg dirs consuming disk. Fix: added to _E2E_WASTEFUL_DIRS. |
| `negative-paths`       | pool 2    | FAIL   | "Docker install fails on blocked port" unexpectedly succeeded. |

## Issue 1: airgapped-existing-reg — Compact Bootstrap Timeout

**Status:** Fix deployed, awaiting results.

**Root cause:** Compact cluster (3 masters) bootstrap timed out due to insufficient resources. Default 8 CPU / 16 GB (auto-bumped to 20 GB) wasn't enough for reliable convergence.

**Fix (commit pending):** Modified `suite-airgapped-existing-reg.sh` to set `master_cpu_count=12` and `master_mem=24` via `sed` on `cluster.conf` before the bootstrap step.

## Issue 2: cluster-ops — Sync/Day2/Operator Failure Chain (con2)

**Status:** Understood. Framework bug identified. Retry on pool 4 passed 9/9.

### Root Cause Chain (3 layers)

**Layer 1 — Corrupt tarball (infrastructure):**
`mirror-registry-amd64.tar.gz` on con2 was truncated. All 3 sync attempts failed:
```
gzip: stdin: unexpected end of file
tar: Unexpected EOF in archive
tar: Error is not recoverable: exiting now
make: *** [Makefile:173: mirror-registry] Error 2
```
Likely corrupted during `run.sh deploy` (rsync/scp). Transient infrastructure issue.

**Layer 2 — Framework restart bug (CODE BUG):**
When the operator pressed `0` (restart-suite), the framework:
1. Cleaned up clusters/mirrors (correct).
2. `e2e_run` returned 4 (framework.sh:992) to the suite script.
3. Suite script has no `set -e` → return 4 silently swallowed.
4. `test_end` called with no argument → defaults to `result=0` → records **PASS**.
5. runner.sh has proper restart loop (line 590) for `exit 4`, but it **never fires**.

The restart mechanism is dead code. Pressing `0` just marks the failed step as PASS and continues.

**Layer 3 — day2 exits 0 with missing working-dir:**
Since oc-mirror never ran, `working-dir/cluster-resources/` was never created. `aba day2` warned:
```
[ABA] Warning: Missing oc-mirror working directory
[ABA] IMPORANT: No cluster resource files found (CatalogSource, idms/itms ...)
```
But exited 0. No CatalogSources applied → operator verification timed out ("No resources found").

### Cascade Diagram
```
Corrupt tarball
  → sync fails 3x
    → user presses '0' (restart)
      → framework bug: return 4 swallowed
        → test_end records PASS
          → suite continues
            → day2 warns but exits 0
              → no CatalogSources applied
                → operator verification times out
```

### Fix
Change `return 4` to `exit 4` at framework.sh line 992. Since suites run as child `bash` processes, `exit 4` terminates the child immediately. The runner catches it and does a proper clean restart.

## Issue 3: negative-paths — Two Distinct Failures

### 3a: Stale E2E Mirror Directories Consuming Disk (con1)

**Status:** Root cause identified.

`/home` is at 10 GB after running `airgapped-existing-reg`. The disk check `[ $used_gb -lt 10 ]` fails because stale mirror directories (`~/aba/e2e-docker-test/`, `~/aba/e2e-docker-neg/`) created by `negative-paths` are not cleaned up if the suite fails before its explicit `rm -rf` step. `e2e_cleanup_mirrors` uninstalls the registry but doesn't remove the mirror directory itself.

**Fix:** Add `~/aba/e2e-docker-test` and `~/aba/e2e-docker-neg` to `_E2E_WASTEFUL_DIRS` in `test/e2e/runner.sh` so they are forcefully removed before each suite run.

### 3b: "Docker install fails on blocked port" Succeeds (con2)

**Status:** Code gap identified.

The `$SUDO` fix for data directory removal (reg-uninstall.sh:141) IS working — "Data directory removed" passes in both recent runs.

The actual failure: `e2e_run_must_fail "Docker install fails on blocked port"` unexpectedly succeeded. The test blocks port 5002 on dis2 with iptables INPUT rule, then installs Docker on dis2 via SSH. But `reg-install-remote.sh` does NOT verify the registry is reachable after starting the container — it only uses SSH (port 22). The iptables rule is irrelevant to the install.

By contrast, the local `reg-install-docker.sh` (lines 109–132) has a post-install curl verification that would catch this.

**Fix:** Add a post-install connectivity check (curl to `https://$reg_host:$reg_port/v2/`) in `reg-install-remote.sh`'s Docker case, matching the local install pattern. Save credentials first (so user can recover), then abort if unreachable.

## Previously Fixed (commit 3910973)

- **Dispatcher unreachable-pool bug:** `_find_free_pool()` now probes SSH reachability (5s timeout) before marking a pool as free.
- **$SUDO in fallback uninstall:** `reg-uninstall.sh:141` now uses `$SUDO rm -rf` for local Docker data directory removal.
- **grep -q removed:** All 5 instances of `grep -q` in `suite-negative-paths.sh` replaced with `grep` for output visibility.
- **Docker tests moved to disN:** Tests A/B/C in `suite-negative-paths.sh` refactored to install on disN via `-H $DIS_HOST -k ~/.ssh/id_rsa`.

## Open Backlog

- **`aba register` should clean stale working-dir:** `reg-register.sh` does not remove `save/working-dir` or `sync/working-dir`. If a user re-registers a different mirror without resetting, stale CatalogSources/IDMS/ITMS from the old registry persist and `aba day2` would apply them. Fix: add `rm -rf save/working-dir sync/working-dir` to `reg-register.sh`.
- ~~Tarball integrity check~~ — superseded by plan item: add `run_once -w` + gzip check to `mirror-registry` target (same fix as CLI tarballs, prevents race condition).
- `aba day2` exit code: consider returning non-zero when working-dir is completely missing (currently warns only).
- `cluster-ops` sync on pre-populated registry: the Makefile `mirror-registry` target re-extracts even if already present — check idempotency.
- **Tarball download error messages:** `cli/Makefile` and `templates/Makefile.mirror` produce cryptic Make errors when tarball downloads fail. Add proper user-facing error messages (e.g. "Download failed — check network/URL") instead of raw Make dependency errors.
- **Optimize `download-registries`:** On the connected `sync` path, only download the tarball for the configured `reg_vendor` (quay or docker). Keep downloading both for the `save`/`bundle` path since the disconnected user's vendor choice is unknown.
