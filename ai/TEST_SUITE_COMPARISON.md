# Test Suite Comparison: OLD vs NEW E2E Suites

## Summary: Scenarios MISSING from New Suites

Below are functional test scenarios present in the OLD suites (test1–test5) that do **not** have equivalent coverage in the NEW E2E suites (suite-*).

---

## 1. From test1 (basic-sync-test-and-save-load-test)

| Scenario | OLD test1 | NEW coverage |
|----------|-----------|--------------|
| **Mirror reset clears run_once** | `aba --dir mirror reset --force`; verify `mirror:reg:install` run_once cleared; verify binary removed; re-extract | **MISSING** – suite-create-bundle-to-disk tests `aba --dir mirror clean` and re-extract, but NOT `aba reset` and run_once state |
| **Delete cluster then re-install SNO after save/load** | Delete sno → save load → rm sno → re-install sno with same default_target | **MISSING** – mirror-sync does save/load and SNO install, but not the explicit delete-then-reinstall cycle |
| **Save/load then uninstall reg then save/load again** | Uninstall reg → save load (reinstalls) → install sno again | **MISSING** – mirror-sync has save/load, but not the “uninstall → save load (reinstalls)” cycle |

---

## 2. From test2 (airgapped-existing-reg)

| Scenario | OLD test2 | NEW coverage |
|----------|-----------|--------------|
| **Incremental save/load: vote-app only** | Add vote-app to imageset → save → copy → load → deploy vote-app | **COVERED** – suite-airgapped-existing-reg has deploy vote-app |
| **Incremental save/load: ACM operators** | Add ACM+MCH to imageset → save → copy → load → day2 → install ACM subs → MCH | **COVERED** – suite-airgapped-existing-reg |
| **Compact cluster full install** | Compact install with `--step $default_target` (iso or install), then delete | **PARTIAL** – suite-airgapped-existing-reg does compact **bootstrap** only, not full install |
| **VLAN/BOND matrix with NTP verification on node** | test_ssh_ntp.sh – verify chronyc on node0 | **COVERED** – suite-network-advanced verifies NTP with `chronyc sources` |
| **Install to localhost must fail** | `aba -d mirror install` when reg is on remote | **COVERED** – suite-airgapped-existing-reg “Install to localhost … should fail” |

---

## 3. From test3 (using-public-quay-reg)

| Scenario | OLD test3 | NEW coverage |
|----------|-----------|--------------|
| **Direct mode: create ISO** | `aba -d sno iso` for `int_connection=direct` | **MISSING** – suite-connected-public creates cluster.conf and agentconf for direct mode but does NOT create ISO |
| **Direct mode: verify install-config** | grep registry.redhat.io, cloud.openshift.com, sshKey; !proxy, !BEGIN CERTIFICATE, !ImageDigestSources, !mirrors | **COVERED** – suite-connected-public “Direct mode: verify install-config.yaml” |
| **Proxy mode: install from public** | source proxy-set → aba -d sno install | **COVERED** – suite-connected-public |

---

## 4. From test4 (airgapped-bundle-to-disk)

| Scenario | OLD test4 | NEW coverage |
|----------|-----------|--------------|
| **Light bundle** | abatest + web-terminal, yaks, nginx-ingress-operator, flux | **COVERED** – suite-create-bundle-to-disk |
| **Full bundle** | --op-sets --ops | **COVERED** – suite-create-bundle-to-disk |
| **Verify mirror_000001.tar in bundle** | tar tvf \| grep mirror_000001 | **COVERED** – suite-create-bundle-to-disk |

All test4 scenarios are covered.

---

## 5. From test5 (airgapped-install-local-reg)

| Scenario | OLD test5 | NEW coverage |
|----------|-----------|--------------|
| **Quay → uninstall → Docker → load** | Install Quay → uninstall → install Docker reg → load | **COVERED** – suite-airgapped-local-reg |
| **SNO full install + day2** | SNO install, day2, operator checks | **COVERED** |
| **Vote-app direct + IDMS** | Deploy from mirror path; deploy via IDMS (quay.io source) | **COVERED** |
| **Standard cluster full install** | build_and_test_cluster(standard): full install, mon, wait workers, shutdown/startup, vote-app | **MISSING** – suite-airgapped-local-reg only bootstraps standard (macs.conf), does not run full install |
| **Compact cluster full install** | build_and_test_cluster(compact): full install | **MISSING** – not in airgapped-local-reg; airgapped-existing-reg only bootstraps compact |
| **Worker restart on install failure** | If mon fails → restart worker nodes → re-run mon | **MISSING** |
| **Service mesh demo deploy** | deploy-mesh.sh (OLD comment: “THIS STOPPED WORKING”) | **MISSING** (and was broken in OLD) |
| **Cluster upgrade flow** | day2-osus, oc adm upgrade --to-latest, wait for Completed | **COVERED** – suite-airgapped-local-reg |
| **Graceful shutdown/startup cycle** | shutdown --wait, verify poweredOff, startup --wait | **COVERED** – suite-airgapped-local-reg |
| **Standard with macs.conf** | macs.conf for bare-metal MACs | **COVERED** – suite-airgapped-local-reg |

---

## Structured List: MISSING Scenarios (Priority Order)

### High priority (clear functional gaps)

1. **Mirror reset and run_once** (test1)  
   - `aba --dir mirror reset --force`  
   - Verify `~/.aba/runner/mirror:reg:install` cleared  
   - Verify mirror-registry binary removed  
   - Re-extract binary  
   - **Suggestion**: Add to suite-mirror-sync or suite-create-bundle-to-disk

2. **Direct mode ISO creation** (test3)  
   - Create SNO config with `-I direct`  
   - Run `aba -d sno iso`  
   - **Suggestion**: Add to suite-connected-public

3. **Standard cluster full install (airgapped)** (test5)  
   - Full install (not just bootstrap)  
   - Monitor/bootstrap, wait for workers  
   - Shutdown/startup  
   - Vote-app deployment  
   - **Suggestion**: Add to suite-airgapped-local-reg (optional/long-running)

4. **Compact cluster full install** (test2/test5)  
   - Compact full install, not just bootstrap  
   - **Suggestion**: Add to suite-airgapped-existing-reg or suite-airgapped-local-reg

### Medium priority (edge cases)

5. **Save/load reinstalls registry** (test1)  
   - Uninstall registry → save load (reinstalls) → install SNO  
   - **Suggestion**: Extend suite-mirror-sync

6. **Delete SNO and reinstall after save/load** (test1)  
   - Delete SNO → save load → rm sno → re-install SNO  
   - **Suggestion**: Extend suite-mirror-sync

7. **Worker restart on install failure** (test5)  
   - If `aba mon` fails → restart workers → re-run mon  
   - **Suggestion**: Add to suite-cluster-ops or a dedicated resilience suite

### Low priority / deferred

8. **Service mesh demo deployment** (test5)  
   - OLD suite noted “THIS STOPPED WORKING”  
   - **Suggestion**: Revisit only if deploy-mesh.sh is fixed

---

## Mapping: OLD → NEW Suites

| OLD suite | Primary NEW suite(s) |
|-----------|----------------------|
| test1 | suite-mirror-sync, suite-cluster-ops, suite-create-bundle-to-disk |
| test2 | suite-airgapped-existing-reg, suite-network-advanced |
| test3 | suite-connected-public |
| test4 | suite-create-bundle-to-disk |
| test5 | suite-airgapped-local-reg |

---

## Coverage Notes

- **VLAN/bonding matrix** – Covered by suite-network-advanced.
- **ABI config diff** – Covered by suite-cluster-ops (yaml_diff).
- **aba auto-update** – Covered by suite-cluster-ops.
- **OC_MIRROR_CACHE** – Covered by suite-mirror-sync.
- **Must-fail install checks** – Covered by suite-airgapped-existing-reg.
- **Bare-metal simulation** – Covered by suite-mirror-sync.

---

## Bugs Found: Old vs New Test Differences (Feb 28, 2026)

### oc-mirror Incremental Load Failure

**Symptom:** `[GetReleaseReferenceImages] no release images found` during UBI/vote-app
incremental loads in `suite-airgapped-local-reg.sh`.

**Root Cause:** New test uncommented lines in the existing `imageset-config-save.yaml`,
leaving the `mirror.platform` section intact. oc-mirror v2 tried to re-resolve release
images from the disk cache and failed.

**Old test approach (correct):** Created a fresh `imageset-config-save.yaml` with ONLY
`additionalImages` -- no `platform` section. oc-mirror only processes what's in the
config, so without `platform:` it skips release image resolution entirely.

**Fix:** Changed new test to create fresh config files for each incremental load step,
matching the old test pattern. See `ai/DECISIONS.md` "oc-mirror v2: Incremental Image
Loads" for the full decision record.

### Vote-App Deploy Failure (Cascade)

**Symptom:** `oc new-app --image dis2:8443/.../flask-vote-app` failed with "unable to
locate any local docker images".

**Root Cause:** Cascade from the oc-mirror failure above. Vote-app images were never
loaded into the mirror registry because the save/load step failed. Fixing the imageset
config resolves both issues.
