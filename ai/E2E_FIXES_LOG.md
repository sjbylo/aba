# E2E Fixes Log

Tracking issues found during E2E test runs, root causes, and fix status.
ABA core fixes are deferred -- only framework/suite fixes applied immediately.

## Issues Found

### 1. suite-create-bundle-to-disk: "aba mirror" does nothing on disconnected bastion
- **Status**: FIXED (committed 3b775e0)
- **Severity**: High -- blocks BM simulation test
- **Root cause**: `aba mirror` on dis1 runs `make -s mirror` from top-level Makefile, which has no `mirror` target. Returns 0 in 1s without installing anything.
- **Additional issue**: Even with correct target, `mirror.conf` has `reg_host=registry.p1.example.com` which doesn't resolve on dis1.
- **Fix**: Changed to `aba -d mirror load -H $DIS_HOST` which:
  1. Uses `-d mirror` to run in mirror/ directory (correct Makefile)
  2. `load` target installs registry + loads saved images
  3. `-H $DIS_HOST` overrides reg_host to the local hostname (dis1.example.com)

### 2. suite-mirror-sync: "--reg-host" is not a valid aba CLI option
- **Status**: FIXED (committed 3b775e0)
- **Severity**: High -- blocks save/load roundtrip test
- **Root cause**: Suite used `--reg-host` and `--reg-ssh-key` which don't exist. Correct flags are `-H` (`--mirror-hostname`) and `-k` (`--reg-ssh-key` short form).
- **Fix**: Changed to `aba -d mirror -H $DIS_HOST -k ~/.ssh/id_rsa --data-dir '~/my-quay-mirror-test1'`

### 3. create-bundle-to-disk exit=1 on pool 1 (Feb 28 ~23:37)
- **Status**: KNOWN -- will pass on next run (fix already deployed)
- **Severity**: N/A (was running old code before fix 1 was deployed)
- **Root cause**: Pool 1 resumed from checkpoint, skipped test 9 (which had "passed" with broken `aba mirror`), hit test 10 BM simulation which needs the registry. Fix #1 above resolves this.

### 4. suite-airgapped-local-reg: IDMS heredoc variables not expanded
- **Status**: FIXED (hot-deployed, pending commit)
- **Severity**: High -- blocks vote-app IDMS test
- **Root cause**: Heredoc used `<<'IDMSEOF'` (single-quoted = no variable expansion). The `source` command loaded `reg_host`/`reg_port`/`reg_path` but the single-quoted heredoc prevented expansion. Combined with `\$` escaping, variables were passed literally as `${reg_host}` to Kubernetes which rejected the invalid mirror URL.
- **Fix**: Changed to unquoted `<<IDMSEOF` so the remote shell expands variables from the sourced mirror.conf.

### 5. network-advanced: "No space left on device" on vSphere datastore
- **Status**: INFRASTRUCTURE -- not a code bug
- **Severity**: Blocks pool 2 network-advanced suite
- **Root cause**: Datastore4-1 has no free space. VM swap file for `standard-vlan2-worker1` cannot be created. Need to clean up old VMs/disks on the datastore.

### 6. airgapped-existing-reg: compact3 bootstrap timeout (VIP conflict)
- **Status**: INVESTIGATION NEEDED
- **Severity**: High -- blocks compact cluster test on pool 3
- **Root cause**: Bootstrap fails with `api vips <10.0.2.33> is already in use` and `ingress vips <10.0.2.34> is already in use`. Likely stale cluster or IP conflict from a previous run that wasn't fully cleaned up. Could also be related to the vCenter folder issue (VMs in wrong folder).

### 7. airgapped-existing-reg: compact1 bootstrap VIP conflict (pool 1, Mar 1)
- **Status**: FIXED (approach revised)
- **Severity**: High -- blocks compact cluster test
- **Root cause**: When `aba cluster ... --step bootstrap` times out (67 min), ABA leaves the VMs running with marker files. Retrying just re-waits on a broken state. ABA is designed to resume, so deleting+recreating is wrong.
- **Original fix (REVERTED)**: `aba delete + rm -rf` before each retry -- this fought against ABA's resume design.
- **Final fix**: Changed all cluster install/bootstrap to `-r 1 1` (single attempt) so failures immediately go to the interactive prompt for user intervention instead of pointlessly retrying long operations.

### 8. suite-airgapped-existing-reg: regcreds restore uses fragile manual reconstruct
- **Status**: FIXED (deployed, pending commit)
- **Severity**: Low -- test passes but brittle
- **Root cause**: After the "load without regcreds" must-fail test, regcreds were reconstructed by manually copying files from `~/.docker/config.json` and `~/quay-install/quay-rootCA/rootCA.pem`. Fragile if paths change.
- **Fix**: Changed to backup/restore pattern: `cp -a ~/.aba/mirror/mirror/ /tmp/e2e-regcreds-backup/` before removing, then restore after the test.

### 9. All suites: `-r 1` missing backoff parameter eats command string
- **Status**: FIXED (deployed to con1/2/3)
- **Severity**: Critical -- silently skips cluster install, causes cascading failures
- **Root cause**: `e2e_run -r` expects TWO args (count, backoff): `-r 1 1`. But we passed `-r 1` (one arg), so `shift 3` consumed the `-r`, the count, AND the description string. The actual command became the description, and the real command was empty. An empty command returns exit=0 immediately, so the "install" appeared to succeed in 0 seconds, but no cluster was created.
- **Affected**: All 6 cluster install/bootstrap commands across 4 suites (suite-airgapped-existing-reg, suite-airgapped-local-reg, suite-mirror-sync, suite-cluster-ops)
- **Fix**: Changed all `-r 1` to `-r 1 1` (1 attempt, backoff multiplier 1)

### 10. suite-airgapped-existing-reg: regcreds restore `cp -a` puts files in wrong subdirectory
- **Status**: FIXED (deployed to con1/2/3)
- **Severity**: High -- breaks all subsequent tests that need registry access
- **Root cause**: `cp -a /tmp/e2e-regcreds-backup/ ~/.aba/mirror/mirror/` when `~/.aba/mirror/mirror/` doesn't exist creates `~/.aba/mirror/mirror/e2e-regcreds-backup/` instead of copying files directly into `mirror/`. The trailing-slash `cp` behavior varies when the target's parent doesn't exist.
- **Fix**: Changed restore to `rm -rf ~/.aba/mirror/mirror && cp -a /tmp/e2e-regcreds-backup ~/.aba/mirror/mirror` (no trailing slashes, copies the directory AS the target)

### 11. notify.sh: hangs indefinitely due to stdin blocking and slow URL encoding
- **Status**: FIXED (deployed to con1/2/3 and bastion)
- **Severity**: High -- notifications never sent, suites can hang waiting for notify
- **Root cause**: Three problems: (1) `cat` without timeout blocks when stdin is not a tty but has no data (common in non-interactive shells), (2) manual bash `urlencode()` loops character-by-character which is extremely slow for long messages, (3) no `--max-time` on curl allows indefinite hangs.
- **Fix**: Replaced manual URL encoding with curl's `--data-urlencode`, added `timeout 2 cat` for stdin, added `--max-time 30 --connect-timeout 10`

### 12. create-bundle-to-disk: oc-mirror port 55000 already in use
- **Status**: FIXED (deployed to con1/2/3)
- **Severity**: High -- blocks bundle creation on pool 3
- **Root cause**: oc-mirror v2 starts a local registry on port 55000 during mirrorToDisk. The `cluster-ops` suite ran `setup-pool-registry.sh` which uses oc-mirror to sync images. When that suite was skipped/killed, the oc-mirror process was left holding port 55000. The next suite (`create-bundle-to-disk`) on the same pool tried its own oc-mirror `save` and every attempt (8 internal ABA retries x 3 framework retries = 24 attempts) panicked on the port conflict.
- **Fix**: Added `pkill -f 'oc-mirror'` to `_pre_suite_cleanup()` in `runner.sh` so stale oc-mirror processes are killed before each new suite starts.

### 13. Notification messages need improvement
- **Status**: FIXED (deployed, pending commit)
- **Severity**: Medium -- notifications work but are hard to read/act on
- **Requested improvements** (6 items -- all implemented):
  1. **No duplicate info**: Removed redundant test name from notification body when already in subject.
  2. **Include pool number**: All notifications prefixed with `[e2e] pool${POOL_NUM}/${hostname}`.
  3. **Include test name**: `_E2E_CURRENT_TEST` included in FIRST FAIL and EXHAUSTED bodies.
  4. **Include last ~20 lines of suite log**: Both suite log (`E2E_LOG_FILE`) and command output shown in failure notifications, giving context from preceding commands.
  5. **Replace "localhost" with actual hostname**: `${host:-$(hostname -s)}` used everywhere, never "localhost".
  6. **Prefix with `[e2e]`**: `_e2e_notify_prefix()` adds `[e2e] pool${N}/${host}` to every message.
- **Fix**: Refactored `_e2e_notify_prefix()`, `_e2e_notify()`, `_e2e_notify_stdin()`, and all 3 call sites in `framework.sh`.

## ABA Core Issues (deferred to tomorrow)

### A. Cluster VMs created in wrong vCenter folder
- **Severity**: Low (cosmetic / organizational)
- **Observed**: compact3 cluster VMs (compact3-master1/2/3) land in a shared `abatesting` folder instead of their pool-specific folder (e.g. `pool3/`). Each pool's VMs should be in their respective pool folder for clean organization and to avoid confusion.
- **Likely cause**: The vCenter folder path used during cluster creation doesn't incorporate the pool number. Probably set in vmware.conf or cluster.conf.
