# Bug Report: E2E Failures Discovered 2026-03-28

Three distinct bugs surfaced during E2E testing of the sigstore Option B changes
(commit `beef621`). None are caused by the sigstore changes themselves.

---

## Bug 1: IP Conflict False Positive on Existing Clusters

**Severity:** High -- blocks ISO generation for any cluster whose nodes are already running.

**Observed in:** Pool 2 (`vmw-lifecycle`), also reported in the bundle maker.

**Symptom:**
```
[ABA] Checking IP conflicts using arping
[ABA] Warning: IP conflict: 10.0.2.23 is already in use!
[ABA] Warning: IP conflict: 10.0.2.25 is already in use!
...
[ABA] Error: Pre-flight failed: 4 error(s), 0 warning(s)
make: *** [Makefile:119: .preflight-done] Error 1
```

**Root cause:** `preflight_check_ip_conflicts()` in `scripts/preflight-check.sh`
has no concept of "this cluster already exists and owns these IPs." It treats every
responding IP as a conflict. When regenerating an ISO for an existing cluster (e.g.
day-2 reconfiguration, version upgrade, or the bundle maker's test-install step),
the nodes are already running and respond to arping, causing a hard failure.

**Current workaround:** User can run `aba --verify conf` to skip all network
checks, but this also skips DNS and NTP validation.

**Proposed fix:** Before flagging an IP as a conflict, check whether the cluster
already exists (e.g. `.installed` marker, or VMs with matching names on vSphere).
If the cluster is already deployed with those IPs, skip or downgrade to a warning:

- Option A: If `.installed` or `.cluster-up` marker exists in the cluster dir,
  skip IP conflict checks entirely (cluster owns those IPs).
- Option B: Query the cluster API (if reachable) to verify ownership.
- Option C: Check if the responding MAC matches the expected `mac_prefix` from
  `cluster.conf` -- if so, these are our own nodes, not conflicts.

**Files:**
- `scripts/preflight-check.sh` (lines 96-191)
- `templates/Makefile.cluster` (line 142 -- `.preflight-done` dependency on ISO)

---

## Bug 2: "Verify Registry Removed" Test Fails Due to Quay Infra Pod

**Severity:** Low -- E2E test-only, does not affect users.

**Observed in:** Pool 1 (`mirror-sync`), step "Verify registry removed".

**Symptom:**
```
podman ps | grep -v -e quay -e CONTAINER | wc -l | grep ^0$
Attempt (5/5) FAILED (exit=1): Verify registry removed
```

**Root cause:** The test on `suite-mirror-sync.sh` line 166-167 runs `podman ps`
on the remote host (dis1) and filters out lines containing "quay" or "CONTAINER".
However, the Quay mirror registry runs an infra container whose name is a hash
(e.g. `66b889d3339e-infra`) -- it does NOT contain "quay", so it is not excluded.

Actual containers on dis1 after docker registry uninstall:
```
66b889d3339e-infra  registry.access.redhat.com/ubi8/pause:8.10-5  Up 3 hours
quay-redis          registry.redhat.io/rhel8/redis-6:1-...        Up 3 hours
quay-app            registry.redhat.io/quay/quay-rhel8:v3.12.14   Up 3 hours
```

The test intended to verify the Docker (non-Quay) registry was removed, but the
infra pod's name doesn't match the exclusion pattern.

**Proposed fix:** Also exclude the Quay infra pod. Options:
- Grep for the Quay pod's infra container: `grep -v -e quay -e CONTAINER -e infra`
- Or better: only check for a specific container name like `registry` (the Docker
  registry container name) instead of a blanket "zero non-quay containers".
- Or: `podman ps --filter name=registry --format '{{.Names}}' | grep -c .`
  to count only the specific Docker registry container.

**File:** `test/e2e/suites/suite-mirror-sync.sh` line 166-167

---

## Bug 3: Dispatcher Can Override Manual Suite Assignments

**Severity:** Low -- operational nuisance, not a code bug.

**Observed in:** Pool 2 was manually restarted with `config-validation`, but the
dispatcher reassigned it to `vmw-lifecycle` from its queue.

**Root cause:** When `run.sh restart --suite X --pool N` is used while the
dispatcher is running, the restart bypasses the dispatcher's internal state.
The dispatcher may then re-assign the pool to a different suite from its queue
once the restart completes or the pool becomes "available" again.

**Proposed fix:** Consider:
- Having `restart --suite X --pool N` register the assignment with the dispatcher
  so it doesn't override it.
- Or: document that manual `restart` commands should only be used after stopping
  the dispatcher (`run.sh stop` first).

**File:** `test/e2e/run.sh` (dispatcher logic)

---

## Bug 4: E2E Cleanup Bypasses ABA Uninstall with Brute-Force rm -rf

**Severity:** Medium -- hides real ABA uninstall bugs, causes cascading failures.

**Observed in:** Pool 1 (`mirror-sync`), step "Save and load (should reinstall
registry)" -- failed 3/3 attempts.

**Symptom:**
```
PermissionError: [Errno 1] Operation not permitted:
  b'/home/steve/my-quay-mirror-test1/quay-install/sqlite-storage/quay_sqlite.db'
```
Quay's Ansible playbook fails to set permissions on the SQLite DB from a
previous install because it has immutable-like attributes that survive even
`sudo rm -rf`.

**Root cause:** `_cleanup_dis_aba()` in `test/e2e/runner.sh` (line 383)
uses `sudo rm -rf ~/quay-install $_E2E_WASTEFUL_DIRS` to brute-force
remove registry data on disN. This has two problems:

1. It bypasses ABA's own `aba uninstall` code path, hiding bugs in the
   product's cleanup logic. The E2E tests should eat their own dog food.
2. It doesn't actually work -- the Quay SQLite DB has special attributes
   that prevent removal even with `sudo rm -rf`, so stale data persists
   and blocks the next install.

The `_cleanup_con_quay()` function (line 140) correctly calls
`aba -y -d mirror uninstall` first. But `_cleanup_dis_aba()` skips this
for the remote host and goes straight to brute-force file deletion.

**Proposed fix:** Remove the brute-force `sudo rm -rf` of registry data
directories. Instead:

1. Rely on `aba --dir mirror uninstall` to clean up properly (this calls
   `mirror-registry uninstall` which knows how to handle the SQLite DB
   attributes).
2. If `aba uninstall` itself fails to clean up, that's a bug in ABA core
   that should be fixed there -- not masked in the test framework.
3. The `_E2E_WASTEFUL_DIRS` variable can remain for non-registry dirs
   (e.g. `~/mymirror-data`, `~/docker-reg`) that are simple data dirs
   without special attributes.

**Files:**
- `test/e2e/runner.sh` lines 379-383 (`_cleanup_dis_aba`)
- `test/e2e/runner.sh` line 102 (`_E2E_WASTEFUL_DIRS`)

---

## Summary

| # | Bug | Severity | Scope | Blocking? |
|---|-----|----------|-------|-----------|
| 1 | IP conflict false positive on existing clusters | High | Core ABA | Yes (bundle maker, day-2 ISO regen) |
| 2 | Quay infra pod not excluded in registry-removed test | Low | E2E only | No (skip works) |
| 3 | Dispatcher overrides manual suite assignment | Low | E2E only | No (operational) |
| 4 | E2E cleanup bypasses ABA uninstall with rm -rf | Medium | E2E + ABA | Yes (blocks mirror-sync suite) |
