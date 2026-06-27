# ABA TUI v2 Bug Report — Hackathon
**Date:** 2026-05-14
**Tester:** AI Agent
**Test Host:** registry4 (~/aba, dev branch)
**ABA Version:** 4.21.14 (stable channel)

---

## Re-verification Sweep (2026-06-24)

**Host:** conno (~/aba, dev branch @ b64b16d)
**Method:** Live reproduction via tmux session "tui-debugging" on conno
**Tester:** AI Agent (hackathon)

### REPRODUCED (confirmed still open):
| Bug | Summary | Method |
|-----|---------|--------|
| #23 | ~~FIXED~~ `_operator_menu` marks basket dirty without changes | Code: now uses hash comparison to detect actual changes (lines 976-1003) |
| #27 | ~~NOT A BUG~~ `confirm_quit` ESC (255) treated as "yes, quit" | Intentional: ESC-ESC = quick exit shortcut |
| #35 | Metacharacter `\|` in cluster name causes shell injection | Live: `aba cluster --name "test\|bad"` → `/bin/sh: bad: command not found` |
| #67 | `_cluster_load_conf` strips `#` from values | Live: parser `${val%%#*}` truncates `pool.ntp.org#bad` to `pool.ntp.org` |
| #319 | Cluster name accepts reserved dirs | Live: `aba cluster --name scripts` created files inside `scripts/` |
| #324 | VMware config fields inconsistent quoting | Code: some fields use `'$val'`, others bare `$val` |
| #335 | Day-2 menu available with only configured (not installed) clusters | Live: Day-2 menu fully available with unconfigured `fakecluster` |
| #338/483 | Platform toggle immediately writes aba.conf | Live: selecting VMware in Advanced→Platform wrote `platform=vmw` before confirmation |
| #346 | ~~NOT A BUG~~ ESC in DISCO/DIRECT (from CONNO) exits entire TUI | Correct behavior: ESC at top-level menu → quit confirmation |
| #348 | `ask=yes` does not auto-answer | Live: `ask=yes` in aba.conf, command still prompted (Y/n) |
| #362 | Cluster summary shows "(not set) GB" | Code: `${cl_master_mem:-(not set)} GB` — suffix outside conditional |
| #367 | Kubeadmin password in plaintext | Code: `show-cluster-login.sh` outputs `oc login -p '<PASSWORD>'` |
| #405 | `_tui_reject_squote` only blocks `'` | Code: doesn't reject `` ` ``, `$`, `\` |
| #420 | TUI progressbox auto-answers admin-ack | Code: `ASK_OVERRIDE=1` + `--yes` bypass safety gate in upgrade |
| #447 | `aba --version 4.99` → "local: can only be used in a function" | Live: confirmed error + empty message |
| #467 | `aba --version 4.99.99` accepted without validation | Live: wrote to aba.conf without network check |
| #471 | Typo "reprecated" in verify-mirror-conf | Code: still at include_all.sh:628 |
| #472 | `aba --channel eus` accepted (invalid channel) | Live: wrote `ocp_channel=eus` to aba.conf — verified 2026-06-24 |
| ~~#475~~ | ~~`aba --vmware /nonexistent` silently accepted~~ | ~~FIXED: now returns "file not found or empty" with exit 1 — verified 2026-06-24~~ |
| #477 | `aba cluster --starting-ip 999.999.999.999` accepted | Live: created cluster dir with invalid IP — verified 2026-06-24 |
| #478 | `int_connection` regex accepts substring matches | Live: `directx` matches `direct\|proxy\|mirror` |

### FIXED (confirmed no longer reproducible):
| Bug | Summary | Evidence |
|-----|---------|----------|
| #294 | `_apply_mode_connection` doesn't convert proxy→mirror in DISCO | Code: line 698 now reads `[[ "$cl_connection" != "mirror" ]] && cl_connection="mirror"` — catches both proxy and direct |
| #295 | No Day-2 prompt after sync/load | Code: `_offer_day2_after_mirror_update` IS called after both sync and load |
| #311 | Stale mirror cache after uninstall | Fixed by commit 4bffd928 (post-hook fires unconditionally) |
| #322 | Stale cache after version change via wizard | Fixed by commit 4bffd928 (_invalidate_mirror_cache after wizard) |
| #339 | Install gate trusts stale cache | Live: gate correctly showed "Mirror Not Synced" prompt |
| #340 | Advanced uninstall no cache invalidation | Code: all uninstall paths now have _invalidate_mirror_cache |
| #347 | Base domain rejects uppercase | Live: `_valid_fqdn 'Example.COM'` returned VALID |
| #409 | replace-value-conf regex escaping | Code: now uses `grep -F` first (fixed string) |
| #462 | `aba tui` exits silently (code 0) | Live: now exits with code 1 and error message "TUI requires an interactive terminal" — verified 2026-06-24 |
| #474 | `aba --editor 'nano -w'` truncates at space | Live: now correctly saves `editor='nano -w'` with single quotes — verified 2026-06-24 |
| #476 | `aba --platform bogus` accepted | Live: now returns `Error: invalid platform 'bogus' (use: vmw, kvm, bm)` with exit 1 — verified 2026-06-24 |
| #480 | `aba -d mirror install --help` shows wrong help | Live: now shows mirror-specific help with install options — verified 2026-06-24 |
| #482 | RC→GA upgrade blocked | Code: old numeric comparison removed, uses graph lookup |
| #405 | `_tui_reject_squote` only blocks `'` | Code: now also blocks `` ` ``, `$`, `\\` — verified 2026-06-24 |
| #471 | Typo "reprecated" in verify-mirror-conf | Code: no matches for "reprecated" on dev branch — verified 2026-06-24 |
| #475 | `aba --vmware /nonexistent` silently accepted | Live: now returns "file not found or empty" with exit 1 — verified 2026-06-24 |

### NOT YET VERIFIED (require special infrastructure):
- DISCO-mode bugs (#16, #312, #333, #345, #352) — need disco host with payload
- Cluster-dependent bugs (#288, #289, #314, #317, #368, #465) — need installed cluster
- Mirror sync-dependent bugs (#285, #306, #426) — need synced mirror

## Test Flows Attempted (2026-06-24 Hackathon)

| Flow | Status | Notes |
|------|--------|-------|
| CONNO: wizard (channel/version/platform/operators) | PASS | Completed full wizard: stable/4.20.20/vmw/ocp-set |
| CONNO: install Docker mirror locally | PASS | Docker mirror installed on conno.example.com:8443 |
| CONNO: sync images (OCP 4.20.20 + cincinnati-operator) | PASS | 198 images synced in ~13 minutes |
| CONNO: install SNO cluster (sno.example.com) | PASS | Full install completed (OCP 4.20.20, ~40 min) |
| CONNO: VMware config from scratch (no ~/.vmware.conf) | PASS | TUI prompted for config, form worked |
| CONNO: operator search and basket management | PASS | Search found cincinnati-operator, basket cleared/rebuilt |
| CONNO: main menu status indicators | PASS | Correctly shows mirror ready/installed/synced/no mirror |
| CONNO: Day-2 Configure OperatorHub | PASS | IDMS/ITMS/CatalogSource applied, redhat-operators ready |
| CONNO: Day-2 NTP | PASS | chrony.conf applied, NTP source synced (pool.ntp.org unreachable as expected) |
| CONNO: Day-2 OSUS | PASS | Cincinnati operator installed, graph endpoint available |
| CONNO: Day-2 Cluster Status | PASS | Shows operator status, nodes, pending pods, upgrade status |
| CLI: RC version handling (4.21.0-rc.2) | PASS | Pre-release warning shown, config saved correctly |
| CLI: invalid channel validation | FAIL | Bug #472: `aba --channel eus` accepted |
| CLI: invalid IP validation | FAIL | Bug #477: `aba cluster --starting-ip 999.999.999.999` accepted |
| CLI: invalid platform validation | PASS | Fixed: `aba --platform bogus` now returns error |
| CLI: editor with spaces | PASS | Fixed: `aba --editor 'nano -w'` now preserves spaces |
| CLI: mirror install --help | PASS | Fixed: shows mirror-specific help |
| DISCO: bundle workflow (create on conno, transfer to disco) | PASS | Bundle created (24GB), transferred, mirror installed, images loaded (193/193 + 4/4). **Cache cleanup fixed digest issue** |
| DISCO: mirror load on disco (attempt 1-2, stale cache) | FAIL | oc-mirror exit 6: "Digest did not match" — corrupted blob in stale ~/.oc-mirror cache on conno baked into archive |
| DISCO: mirror load on disco (attempt 3, clean cache) | PASS | After `rm -rf ~/.oc-mirror` on conno, fresh bundle created+transferred — 193/193 release + 4/4 operator images loaded ok |
| DISCO: cluster install (sno.example.com, fully disconnected) | PASS | Full install completed (~50 min). OCP 4.20.20, Docker mirror, all 34 COs Available. Bundle workflow end-to-end success |
| DIRECT: cluster install (Phase 1) | PASS | VM created on "Ext Network", Agent alive, install started. No bugs found in DIRECT mode install path |
| DIRECT: delete installing cluster | PASS | Successfully deleted cluster while install was in progress (VM + state removed) |
| Upgrade: version change + upgrade | PARTIAL | mirror_prep_upgrade tested: Bug #610 confirmed (downgrade not rejected), Bug #609 confirmed (inconsistent channel) |
| Bare-metal flow | PENDING | |
| TUI: wizard Next button navigation | FAIL | Bug #614: Extra/Next button not Tab-navigable in cluster wizard |
| TUI: MAC validation in wizard | FAIL | Bug #613: Invalid MACs kept in memory after warning |
| Day-2: shutdown/startup | PASS | Graceful shutdown (--wait) and startup both work correctly, cluster annotated as "(shut down)" |
| Day-2: upgrade check (dry-run) | PASS | Correctly shows "no versions available" with CONNO hints |
| Day-2: delete cluster | PASS | VM destroyed, state removed, cluster.conf preserved |
| Day-2: delete help text | FAIL | Bug #608: help says "removes cluster directory" but dir is preserved |
| TUI: mode switching CONNO→DISCO→CONNO | PASS | Advanced menu mode switches work |
| TUI: mode switching CONNO→DIRECT→CONNO | FAIL | Bug #616: pressing Exit from DIRECT sub-mode shows "Exit ABA TUI?" instead of returning to CONNO |
| TUI: RC version in title bar | PASS | Correctly shows "candidate 4.21.0-rc.2" in TUI header |
| TUI: RC version ISC regeneration | PASS | ISC correctly generated with candidate-4.21 channel, 4.21.0-rc.2 min/max |
| CLI: RC version set/read | PASS | `aba --channel candidate --version 4.21.0-rc.2` works correctly |
| TUI: DIRECT mode Day-2 label | FAIL | Bug #602: "after mirror load/sync" shown in DIRECT mode |
| CLI: NTP validation | FAIL | Bug #603: accepts any string |
| CLI: IP validation consistency | FAIL | Bug #604: inconsistent octet validation |
| CLI: arg order --version --channel | FAIL | Bug #601: wrong channel used for resolution |
| CONNO: mirror uninstall | PASS | Docker registry removed, firewall closed, status updated to "no mirror" |
| CONNO: mirror reinstall (after uninstall) | PASS | Config preserved, reinstall successful, status shows "installed — not verified" |
| DIRECT: cluster install (Phase 1) | PASS | VM created on "Ext Network", Agent alive, install started. No bugs in DIRECT install path |
| DIRECT: delete installing cluster | PASS | Successfully deleted cluster while install in progress (VM + state removed) |
| TUI: register external registry | FAIL | Bug #624/#898: TUI has no register/unregister menu — forces CLI |
| CONNO: install SNO cluster (sno2.example.com) | PASS | Full install completed (OCP 4.20.20, ~40 min), partially disconnected, Docker mirror |
| CONNO: Day-2 OperatorHub on sno2 | PASS | Trust CA added, imagestream refreshed. No CatalogSource (operators not synced yet) |
| CONNO: Day-2 NTP on sno2 | PASS | chrony.conf applied, NTP synced (pool.ntp.org unreachable as expected) |
| CONNO: Day-2 OSUS on sno2 | FAIL (expected) | Cincinnati operator not in OperatorHub — operators not synced to mirror yet |
| CONNO: Day-2 Cluster Status on sno2 | PASS | All 34 COs Available, node Ready, upgrade status shown (AdminAckRequired) |
| CONNO: Day-2 Shutdown dialog (sno2) | PASS | Dialog clean, cancelled — did not actually shut down |
| CONNO: Day-2 Upgrade dialog (sno2) | PASS | Dialog clean, cluster selector shown correctly |
| Dialog layout: after git pull (dialog spacing commit) | PASS | Main menu, Day-2, Advanced, Settings, Cluster Basics, Networking, Bundle, ISC View/Edit, Operator Basket, Upgrade Transfer, DIRECT mode — all clean and properly spaced |
| Dialog layout: welcome splash screen | PASS | Bug #900 FIXED by commit 62ad4544 — ASCII art banner now renders correctly with matched newline style |
| Dialog layout: help texts (Day-2, Networking) | PASS | Properly formatted bullet points, consistent spacing |
| Dialog layout: exit confirmation | PASS | Clean, properly sized |
| DISCO: Day-2 OperatorHub on sno | PASS | Mirror CA added, IDMS/ITMS created, CatalogSource for redhat-operators added and ready |
| DISCO: Day-2 NTP on sno | PASS | chrony.conf applied, NTP synced (rhel.pool.ntp.org unreachable as expected on disconnected) |
| DISCO: Day-2 OSUS on sno | PASS | OSUS operator installed, update service deployed, graph endpoint available. Full DISCO Day-2 complete |
| DISCO: Delete installed cluster (sno) | PASS | VM destroyed, cluster state removed after full install |
| DISCO: Delete installing cluster (sno) | PASS | Cluster was "installing" (Agent alive, host ready). Delete via TUI successfully destroyed VM and removed state |
| CLI: aba register (named mirror) | PASS | `aba mirror --name test-reg` + `aba -d test-reg register --reg-host ...` + verify + unregister all work correctly. Bug #898 (no TUI equivalent) confirmed |
| TUI: Cluster type toggle (sno→compact→standard→sno) | PASS | Toggle cycles correctly, VIPs appear for compact/standard, worker count for standard, hidden for SNO |
| TUI: Settings registry type toggle | PASS | Docker→Auto→Quay→Docker cycle works correctly |
| TUI: Rerun Wizard dialog | PASS | Shows current config with Continue/Reconfigure options, clean layout |
| TUI: Monitor (no installing clusters) | PASS | Correctly shows "No clusters are currently installing" message |
| TUI: Advanced menu — Help text | PASS | All options documented, clean layout |
| TUI: Advanced menu — Refresh Cluster | PASS | Shows cluster list, cancel works |
| TUI: Advanced menu — Reset ABA warning | PASS | Clear warning with Reset/Cancel buttons |
| TUI: Day-2 — SSH (no installed cluster) | PASS | Shows "No installed clusters found" message |
| TUI: Day-2 — Clean (no installed cluster) | PASS | Shows all cluster dirs correctly |
| TUI: Cluster name validation (invalid chars) | PASS | Rejects "my_cluster" with clear DNS label rules |
| TUI: Prepare Upgrade for Transfer | PASS | Shows version picker (Latest/Previous/Manual), clean dialog |
| TUI: Upgrade manual entry — RC version | PASS | `4.21.0-rc.2` accepted, shows correct upgrade summary |
| TUI: Operator search ("web") | PASS | Shows 5 results from all catalogs, add to basket works |
| TUI: Operator basket add/remove | PASS | Search-add `web-terminal`, basket-remove via uncheck, count updates correctly |
| README: TUI completeness claim | FAIL | Docbug #625: README claims TUI "covers complete workflow" but register is missing |
| README: shutdown/startup docs | FAIL | Docbug #626: No documentation section for shutdown/startup/rescue workflow |
| README: bastion proxy docs | FAIL | Docbug #627: No documentation about bastion-level proxy for ABA operations |
| Code review: aba.sh eval pattern | PASS | Bug #621 already covers eval+single-quote injection (register paths also affected) |
| Code review: upgrade workflow | PASS | TUI upgrade flow properly validates versions, rejects downgrades, checks preflight |
| Code review: KVM config form | PASS | Similar to VMware form, saves to ~/.kvm.conf, uses normalize-kvm-conf |

---

## Bug #6: ~~LOW RISK~~ `_day2_status` hardcodes kubeconfig path
**File:** `tui/v2/tui-cluster.sh`
**Severity:** LOW — Edge case after `aba clean`
**Status:** LOW RISK — Path `iso-agent-based/auth/kubeconfig` is correct for installed clusters. After `aba clean`, there's no kubeconfig to read — that's expected behavior. Not a TUI bug.
**Steps to reproduce:**
1. Install a cluster
2. Run `aba clean` on the cluster directory (removes iso-agent-based/)
3. Go to Day-2 → Cluster Status
4. Status fails because `iso-agent-based/auth/kubeconfig` no longer exists

**Root cause:** Hardcoded path `$ABA_ROOT/$cl_dir/iso-agent-based/auth/kubeconfig`. Should use `aba -d $cl_dir shell` or the externalized kubeconfig path.

**Expected:** Status should work as long as the cluster is running, even after `aba clean`.
**Actual:** Fails with missing kubeconfig after any operation that removes iso-agent-based/.
**Verified:** YES — code analysis confirmed; kubeconfig path is hardcoded.

---

## Bug #12: ~~FEATURE REQUEST~~ No proxy configuration fields in TUI cluster wizard
**Status:** FEATURE REQUEST
**Severity:** ~~MEDIUM~~ — Feature request, not a bug
**Steps to reproduce:**
1. Start TUI → Install Cluster
2. On Interfaces page, set Connection to "proxy"
3. No way to configure proxy URL, no-proxy list, or credentials

**Root cause:** The TUI offers `int_connection=proxy` as a toggle but doesn't provide input fields for `http_proxy`, `https_proxy`, or `no_proxy`. The user must manually edit `cluster.conf` or use env vars.

**Expected:** When "proxy" is selected, offer fields for proxy configuration.
**Actual:** Proxy is selected but no proxy details can be entered.
**Verified:** YES — code analysis confirmed, no proxy fields in tui-cluster.sh

---

## Bug #13: ~~LOW RISK~~ `OP_SET_ADDED` not updated when operators removed from basket
**File:** `tui/v2/tui-mirror.sh`
**Severity:** ~~MEDIUM~~ — LOW RISK (cosmetic)
**Status:** LOW RISK — `OP_SET_ADDED` tracks which sets were selected (for UI checkmarks), not actual basket contents. Cosmetic inconsistency only; does not affect the actual operators written to imageset-config.
**Steps to reproduce:**
1. Select an operator set (e.g., "virt")
2. Go to "View/Edit Basket" and remove all operators from that set
3. Go back to "Select Operator Sets"
4. The set still shows as "on" (checked) even though all its operators were removed

**Root cause:** `_operator_view_basket` removes operators from `OP_BASKET` but does not update `OP_SET_ADDED`. The checkboxes in `_operator_sets` read from `OP_SET_ADDED`, not from the actual basket contents.

**Expected:** Set checkboxes should reflect actual basket contents.
**Actual:** Stale checkboxes mislead the user.
**Verified:** YES — code analysis confirmed

---

## Bug #14: ~~LOW RISK~~ `_mirror_config_review` can proceed with missing/broken mirror.conf
**File:** `tui/v2/tui-mirror.sh`
**Severity:** ~~MEDIUM~~ — LOW RISK
**Status:** LOW RISK — Edge case. mirror.conf is created by `aba` init/make targets before TUI reaches this point. Would require manual deletion mid-session to trigger.
**Steps to reproduce:**
1. Somehow `mirror/mirror.conf` does not exist or its creation fails
2. Enter a flow that calls `_mirror_config_review` (e.g., DISCO Load Images)
3. `make -sC mirror mirror.conf 2>/dev/null || true` fails silently
4. User can press "Continue" (Extra button, rc=3) even though mirror.conf might not exist

**Root cause:** The creation at line 44 uses `|| true`, and the "Continue" button (rc=3 at line 95) breaks out of the loop without validating that mirror.conf actually exists and is valid.

**Expected:** Validate that mirror.conf exists before allowing Continue.
**Actual:** User can proceed with missing or partial config.
**Verified:** YES — code analysis confirmed

---

## Bug #17: Forced `--conno`/`--disco`/`--direct` flags skip sanity checks
**Status:** OPEN
**File:** `tui/v2/abatui2.sh` lines 298-308
**Severity:** LOW — Safety bypass
**Steps to reproduce:**
1. Run `abatui --disco` on a connected host with no bundle
2. TUI enters DISCO mode without validating payload or internet status
3. DISCO operations may fail unexpectedly

**Root cause:** The `--conno`/`--disco`/`--direct` flags set `_TUI_FORCE_MODE` which bypasses the auto-detection logic including sanity checks.

**Expected:** Forced mode should still validate basic prerequisites.
**Actual:** No validation, wrong or confusing mode is possible.
**Verified:** YES — code analysis confirmed

---

## Summary

| # | Bug | Severity | Verified |
|---|-----|----------|----------|
| 1 | cluster_monitor can't select installing clusters | HIGH | YES - TUI |
| 2 | Dead code: _direct_operators never called | LOW | YES - code |
| ~~3~~ | ~~--platform bm not passed, platform mismatch~~ | ~~CRITICAL~~ | FIXED (2026-05-26) |
| 4 | VMware password in plaintext | MEDIUM | YES - TUI |
| 5 | Password single quotes corrupt config | MEDIUM | YES - code |
| 6 | Day-2 status hardcodes kubeconfig path | MEDIUM | YES - code |
| 7 | VMware config always overwrites ~/.vmware.conf | LOW | YES - TUI |
| 8 | Confusing "Switch to Disconnected" label | LOW | YES - TUI |
| 9 | Connection toggle allows "direct" in DISCO/CONNO | MEDIUM | YES - TUI |
| ~~10~~ | ~~Advanced menu ignores Help button~~ | ~~N/A~~ | INVALIDATED |
| 11 | SSH failure masked by \|\| true | LOW | YES - code |
| 12 | No proxy config fields in cluster wizard | MEDIUM | YES - code |
| 13 | Operator set checkboxes stale after basket edit | MEDIUM | YES - code |
| 14 | Mirror config review can proceed without config | MEDIUM | YES - code |
| 15 | Operator persistence uses relative aba.conf path | LOW | YES - code |
| 16 | CONNO→DISCO switch doesn't create .bundle | LOW | YES - code |
| 17 | Forced mode flags skip sanity checks | LOW | YES - code |
| 18 | TUI progressbox frozen during long waits | MEDIUM | YES - TUI |
| 19 | Interfaces help text mentions "mirror" in DIRECT | LOW | YES - TUI |
| 20 | DISCO exit terminates entire TUI from CONNO | HIGH | YES - TUI |
| 21 | disco_reset return code 2 swallowed from CONNO | HIGH | YES - code |
| 22 | Unquoted variables in cluster execute command | MEDIUM | YES - code |
| 23 | Operator basket marked dirty without changes | LOW | YES - code |
| 24 | Wizard overwrites int_connection from cluster.conf | HIGH | YES - code |
| 25 | Cluster rename skips network auto-detect | MEDIUM | YES - code |
| 26 | Stale worker count after cluster type change | MEDIUM | YES - code |
| 27 | ~~NOT A BUG~~ confirm_quit ESC = quick exit (intentional) | N/A | N/A |
| 28 | mirror_save has no "mirror not installed" guard | MEDIUM | YES - code |
| 29 | ISC reset races with background regeneration | MEDIUM | YES - code |
| 30 | DIRECT wizard continues after download failures | HIGH | YES - code |
| 31 | DIRECT wizard doesn't persist pull_secret_file | MEDIUM | YES - code |
| 32 | DIRECT wizard cancel exits entire TUI | MEDIUM | YES - code |
| 33 | Version fallback accepts invalid ocp_version | MEDIUM | YES - code |
| 34 | Review textbox only shows tail, early errors hidden | MEDIUM | YES - code |
| 35 | Metacharacter filter allows single pipe and redirect | LOW | YES - code |
| 36 | select_cluster negative array index → wrong cluster | MEDIUM | YES - code |
| 37 | macs.conf not loaded when re-entering BM wizard | MEDIUM | YES - code |
| 38 | prefix_length before machine_network drops subnet | MEDIUM | YES - code |
| 39 | mirror_install empty choice returns success | LOW | YES - code |
| 406 | ISC editing allows malformed YAML saves without validation | MEDIUM | YES - code |
| 407 | MAC editbox doesn't validate entries against `_valid_mac()` | MEDIUM | YES - code |
| 596 | `verify-cluster-conf` error says "aba.conf" instead of "cluster.conf" | LOW | YES - live |
| 597 | TUI returns to main menu after `aba reset --force` with stale state | MEDIUM | YES - code |
| 598 | `verify-cluster-conf` uses unquoted `$ports` variable | LOW | YES - code |

## Bug #18: TUI progressbox appears frozen during long waits (openshift-install wait-for)
**Status:** LOW RISK
**File:** `tui/v2/tui-lib.sh` lines 615-621 (pipeline to progressbox)
**Severity:** LOW — UX issue (downgraded after re-validation)
**Steps to reproduce:**
1. Start cluster install via TUI using "Run in TUI" (progressbox) mode
2. After VM creation and "Agent alive", the install enters `openshift-install agent wait-for install-complete`
3. The progressbox shows "Waiting up to 40m0s for the cluster to initialize..." and then appears frozen
4. No progress updates for 20-40 minutes while the cluster installs

**Root cause:** `openshift-install` writes progress updates only to the log file at `debug` level (e.g., "Working towards 4.21.14: 824 of 971 done (84% complete)"). These are NOT output to stdout/stderr, so the TUI's progressbox has nothing new to display.

**Re-validation (2026-05-26):** Ctrl+C DOES work in progressbox mode (see Bug #42 re-validation). The user is NOT trapped — they can press Ctrl+C to cancel. Additionally, "Run in Terminal" mode provides full native terminal control.

**Expected:** The TUI should periodically show progress (e.g., tail the log file for debug messages).
**Actual:** Appears frozen for 20-40 minutes in progressbox mode, but Ctrl+C cancels and "Terminal" mode avoids the issue.
**Verified:** YES — frozen appearance confirmed during SNO install, but Ctrl+C interruption confirmed working on registry4 (2026-05-26)

---

## Bug #26: ~~LOW RISK~~ Stale worker count when switching cluster type after loading cluster.conf
**File:** `tui/v2/tui-cluster.sh` line 943
**Severity:** LOW — Minor cosmetic issue
**Status:** LOW RISK — The toggle (line 943) preserves `cl_workers` if non-zero, which is intentional UX (remembers user's previous setting). When creating a NEW cluster, `_cluster_generate_defaults` resets everything properly. Only manifests if user toggles types within the same session — and the "stale" value is their own previous choice. Acceptable behavior.

---

## Bug #30: ~~LOW RISK~~ DIRECT wizard continues after `cli-download-all.sh` / `download_all_catalogs` failure
**File:** `tui/v2/tui-direct.sh` lines 136-142
**Severity:** ~~HIGH~~ LOW — These are early background optimizations, not blocking prerequisites
**Status:** LOW RISK — The downloads at lines 136-142 are early optimizations (pre-fetch catalogs and registry installers). They run AFTER config is saved. If they fail, they will be retried later when actually needed (during operator selection, save, sync). Not truly blocking.
**Steps to reproduce:**
1. Start TUI in DIRECT mode (or start wizard)
2. Select OCP version
3. `cli-download-all.sh` runs to download CLI tools — if it fails (network, disk full)
4. `download_all_catalogs` runs — if it fails
5. Neither exit code is checked — wizard continues to platform selection
6. User can "finish" the wizard with missing/broken CLI tools and catalogs

**Root cause:** After version selection at line 100-105, `cli-download-all.sh` and `download_all_catalogs` run without exit code checks or `|| return` guards. Failures are silently ignored.

**Expected:** Wizard should show error dialog and prevent advancing if critical downloads fail.
**Actual:** Wizard continues silently; install will fail later with opaque errors.
**Verified:** YES — code analysis confirmed

---

## Bug #33: ~~LOW RISK~~ Version fallback accepts invalid `ocp_version` from aba.conf
**File:** `tui/v2/tui-direct.sh`
**Severity:** ~~MEDIUM~~ — LOW RISK
**Status:** LOW RISK — An invalid ocp_version in aba.conf would break the entire system regardless of TUI. The TUI channel selector (via graph API) validates available versions. Manual editing of aba.conf to inject invalid versions is outside TUI's responsibility.
**Steps to reproduce:**
1. Set `ocp_version=broken` in `aba.conf`
2. Start DIRECT wizard
3. Version fetch fails (returns empty `latest`)
4. Fallback logic at line 276-283: since `ocp_version` is set, accepts it without validation
5. `DIALOG_RC=next` — wizard advances with invalid version

**Root cause:** The fallback when `latest` is empty checks only if `ocp_version` is non-empty, not if it's a valid semver `x.y.z` format.

**Expected:** Version should be validated as a proper `x.y.z` format before accepting.
**Actual:** Any non-empty string in `ocp_version` is accepted.
**Verified:** YES — code analysis confirmed

---

## Bug #34: ~~LOW RISK~~ `_exec_in_tui` review textbox only shows tail of output — early errors invisible
**File:** `tui/v2/tui-lib.sh` line 639
**Severity:** LOW — UX enhancement, not functional
**Status:** LOW RISK — The `dialog --textbox` supports scrolling. Current `tail -N` is a UX choice to show most-recent output. For failures, could use full output file. Minor UX enhancement, not a bug.
**Steps to reproduce:**
1. Run any long-running command via TUI (e.g., `aba install` with many steps)
2. Command fails early in the output but produces many subsequent log lines
3. The failure textbox shows only `tail -N` of the output (N = terminal lines - 8)
4. The early error message is not visible in the review

**Root cause:** After command completion, `_exec_in_tui` shows `tail -$(( $(tput lines) - 8 ))` of the output file. For long outputs where the error is at the beginning, the error scrolls off. The user cannot scroll up or see the full log from the review dialog.

**Expected:** Either show the full log with scrolling, or show the first error line prominently.
**Actual:** Only the last N lines are shown; early errors are invisible.
**Verified:** YES — code analysis confirmed

---

## Bug #10 — ~~UPDATED: NOT A BUG~~
**Status:** NOT A BUG
The Advanced menu does NOT have `--help-button` in its dialog call, so exit code 2 cannot occur from dialog's Help button. The `[[ $rc -ne 0 ]] && return 0` catch-all correctly handles all non-zero codes. Downgraded from "bug" to "non-issue".

---

## Bug #36: ~~LOW RISK~~ `select_cluster` — empty/zero menu index selects wrong cluster via negative array index
**File:** `tui/v2/tui-lib.sh` line 1246
**Severity:** ~~MEDIUM~~ — LOW RISK
**Status:** LOW RISK — Theoretical edge case. Dialog menus always return a positive integer tag (1-based). Cancel returns exit code 1 (caught at line 1241). DNS-label regex validation at line 1247 catches any invalid result. Cannot happen in practice.
**Steps to reproduce:**
1. Have multiple clusters available
2. If dialog returns empty or `0` for `selected_idx`
3. `SELECTED_CLUSTER="${_cl_dirs[$(( selected_idx - 1 ))]}"` computes index `-1`
4. In Bash 4.x, `array[-1]` is the LAST element, silently selecting the wrong cluster

**Root cause:** No validation that `selected_idx` is a positive integer before array access. Edge case but could lead to operating on the wrong cluster.

**Expected:** Validate index before array access; return error for invalid selection.
**Actual:** Negative index silently selects the last cluster in the list.
**Verified:** YES — code analysis confirmed

---

## Bug #38: ~~DEFERRED~~ `prefix_length` before `machine_network` in cluster.conf drops subnet prefix
**File:** `tui/v2/tui-cluster.sh` lines 86-120
**Severity:** MEDIUM — Wrong network configuration (theoretical)
**Status:** DEFERRED — Real fix is architectural: merge `prefix_length` into `machine_network` as a single CIDR value (per user). In practice, ABA always generates cluster.conf with `machine_network` before `prefix_length` so the ordering issue doesn't trigger.

---

## Bug #42: Cannot delete a cluster during install via TUI (progressbox blocks all input)
**File:** `tui/v2/tui-lib.sh` line 615
**Severity:** LOW — UX issue (downgraded from HIGH after re-validation)
**Status:** INVALID — Ctrl+C works in progressbox mode; user can choose "Run in Terminal" mode for full control.

**Original claim:** `trap : INT` disables Ctrl+C, trapping the user in the progressbox.

**Re-validation (2026-05-26):** Tested all signal-handling alternatives on registry4 using `dialog --progressbox` with the actual `_exec_in_tui()` function. Findings:
1. **Ctrl+C DOES work** with current `trap : INT` code — the terminal driver delivers SIGINT to all pipeline children (dialog, sed, tee, command), the pipeline closes, TUI shows "FAILED (exit 130)" with OK/Retry buttons, script survives.
2. **Removing `trap : INT` causes a DEADLOCK** — bash defers the global handler until the pipeline finishes, but dialog doesn't exit promptly after stdin closes.
3. The user can choose "Run in Terminal" mode (or "Always Terminal" for the session) via `confirm_and_execute()` — this gives native terminal with full Ctrl+C support.

**Remaining minor issues:**
- Exit code 130/141 shows "FAILED" instead of "Cancelled by user" (UX, not functional)
- `trap - INT` (line 622) resets to SIG_DFL instead of restoring the global handler (minor, EXIT trap still fires)
- The flock still blocks a second TUI instance, but user can `aba delete` from the CLI

**Conclusion:** The core mechanism works. `trap : INT` is the CORRECT approach — it keeps the shell alive while allowing children to be killed. The real UX fix for long-running commands is to use "Run in Terminal" mode, which already exists.

---

## Bug #44: ~~DESIGN LIMITATION~~ `_exec_in_tui` can report "Success" when child process was externally killed
**File:** `tui/v2/tui-lib.sh`
**Severity:** ~~MEDIUM~~ — DESIGN LIMITATION
**Status:** BY DESIGN — This is an inherent limitation of `dialog --progressbox`. The exit code comes from `PIPESTATUS[0]` which reflects the bash pipe, not the external signal. Detecting external kills would require process monitoring beyond what dialog provides.
**Verified:** YES — Observed via TUI (killed `openshift-install` process, TUI showed "Success")
**Steps to reproduce:**
1. Start a long-running command via TUI (e.g., Install Cluster)
2. The command runs inside `_exec_in_tui` via the pipeline: `{ bash -c "$cmd" 2>&1; } | tee | sed | dlg --progressbox`
3. From another terminal, kill the child process (e.g., `kill <openshift-install-pid>`)
4. The wrapper script (`aba cluster`) may still exit 0 because it completed its own logic (the killed subprocess was inside a `|| true` or was caught with a custom handler)
5. `${PIPESTATUS[0]}` reports 0 (from the wrapper, not the killed process)
6. TUI shows green "Success" dialog

**Root cause:** `PIPESTATUS[0]` captures the exit code of the `{ ... }` block, which runs `bash -c "$tui_cmd"`. The inner command (`aba cluster`) wraps `openshift-install` with error handling. If `openshift-install` is killed but `aba cluster` catches the error gracefully (or the kill happens after `openshift-install` exits its foreground), the wrapper returns 0. Additionally, if `dlg --progressbox` exits early (ESC), SIGPIPE can cause the first pipeline stage to get a different exit code than the actual command.

**Expected:** If a critical subprocess is killed, the TUI should report failure.
**Actual:** TUI shows "Success" because it only checks the outermost wrapper's exit code, not the subprocess tree.

---

## Bug #56: ~~FEATURE REQUEST~~ `_mirror_config_review()` lacks local/remote selection and SSH fields
**File:** `tui/v2/tui-mirror.sh`
**Severity:** ~~MEDIUM~~ — Feature request
**Status:** FEATURE REQUEST — Remote mirror installation is an advanced path that currently requires CLI. Local mirror is the primary TUI use case. Not a bug.
**Verified:** Code review only
**Steps to reproduce:**
1. Start TUI in CONNO mode with no mirror installed
2. Select "Install Cluster" from main menu
3. Confirm "Install & Sync" when prompted that no mirror is installed
4. The "Mirror Configuration" form appears — but it only shows local fields (Hostname, Port, Username, Password, Image path, Vendor, Data dir)
5. There is no option to choose "local" vs "remote" installation
6. There are no SSH user/key fields for configuring a remote mirror

**Root cause:** `_mirror_config_review()` (called from CONNO lines 586/615 and DISCO lines 162/174 for the "Install & Sync/Load" shortcut paths) only renders a local-only mirror config form. Compare with `mirror_install()` which correctly offers local/remote selection and routes to `_mirror_install_local()` (7 fields) or `_mirror_install_remote()` (9 fields including SSH user + key). Users going through the shortcut path cannot set up a remote mirror.

**Expected:** `_mirror_config_review()` should either offer local/remote selection (like `mirror_install()`), or include SSH fields with sensible defaults.
**Actual:** Only local mirror fields are shown. SSH user/key fields are absent. If the user needs a remote mirror, they must cancel and use the dedicated "Install Mirror" menu item instead.

---

## Bug #57: ~~LOW RISK~~ "Reset ABA" in Advanced menu returns to main loop with stale state
**File:** `tui/v2/tui-cluster.sh` line 1840
**Severity:** LOW — Edge case. After full reset, user should restart TUI. In-memory state becomes stale but next menu redraw would detect missing configs.
**Status:** DUPLICATE of Bug #77 — Would require `exit 0` after reset (forcing TUI restart).
**Verified:** Code review only
**Steps to reproduce:**
1. Start TUI in CONNO mode with a mirror installed and clusters configured
2. Go to Advanced Options → Reset ABA
3. Confirm the reset; `aba reset --force` runs (removes ALL config, mirror, clusters)
4. After reset completes, TUI returns to `tui_advanced_menu` → returns to `_conno_main` loop
5. The CONNO main menu reappears, but:
   - Mode is still CONNO (should re-detect; after reset, CONNO doesn't make sense)
   - Shell variables from the pre-reset `source <(normalize-aba-conf)` retain stale values (`ocp_version`, `ocp_channel`, `platform`, `domain`, `pull_secret_file`)
   - `mirror_available` and `list_cluster_dirs` dynamically update (showing no mirror/no clusters), so menu labels are partially correct
   - But any action using stale config variables (e.g., cluster wizard defaults, operator basket with pre-reset operators) may produce unexpected results or errors

**Root cause:** Line 1665: `return 0` after `aba reset --force` simply returns to the caller without re-initializing the TUI or forcing a mode re-detection. The caller (`_conno_main`) continues looping with stale sourced variables. The TUI should either:
- Force exit with a "restart TUI to continue" message
- Trigger a full re-detection (`_detect_mode`) and re-source config
- At minimum, re-source `aba.conf` (which no longer exists, so all variables would default)

**Expected:** After "Reset ABA", the TUI should exit cleanly (prompting user to restart) or fully re-initialize, since the entire ABA state was destroyed.
**Actual:** TUI continues in CONNO mode with stale in-memory variables from the destroyed config files.

---

## Bug #79b: ~~FIXED~~ Internet check (aba_inet_check_cached) systematically fails after TTL expiry with `set -o pipefail`
**Status:** FIXED

> **Note:** Numbered #79b to avoid collision with Bug #79 above (copy-paste error in verify-cluster-conf). This is a DIFFERENT bug found in Session 2.

**Severity**: HIGH — blocks core TUI functionality

**Location**: `scripts/include_all.sh` — `aba_inet_check_cached()` function

**Root cause**: After the 30-second TTL expires, `run_once -t $ttl` starts a new background check. Immediately after, `run_once -E` tries to read the exit code file. But the new check hasn't completed yet, so `-E` either reads a stale/empty file or returns non-zero. With `set -o pipefail` active (set in `abatui2.sh` line 26), the pipeline `run_once -E ... | grep -q '^0$'` fails, causing `aba_inet_check_cached` to return 1 (no internet).

**Reproduction**: Launch TUI with proxy, wait >30 seconds, observe `[no internet]` tags appearing on menu items.

**Verified**: YES — via CLI test simulating the `run_once` flow and via TUI observation.

## Bug #94: Mirror config edits saved immediately even if user cancels
**Status:** OPEN

**Severity**: LOW — user expectation issue

**Location**: `tui/v2/tui-mirror.sh` lines 270-324 (local) and 416-483 (remote)

**Root cause**: When configuring the mirror (both local and remote), each field edit immediately calls `replace-value-conf` to write the change to `mirror.conf`. If the user edits a field (e.g., changes hostname) and then presses "Back" to cancel the configuration, the change is already persisted to `mirror.conf`. The user expects "Back" to discard changes, but partial edits remain.

**Verified**: YES — code review confirms `replace-value-conf` is called inside each field's case handler, before the user confirms with "Next".

---

## Bug #99: ~~CORE ABA BUG~~ `--ntp`/`--dns`/`--gateway` flags target wrong `cluster.conf` when used with `--name`

**Severity**: ~~MEDIUM~~ — CORE ABA BUG (not TUI)
**Status:** OPEN — This is in `scripts/aba.sh` (CLI flag handling), not the TUI. Outside scope of TUI fixes.

**Location**: `scripts/aba.sh` lines 630, 642, 654 (and similar flag handlers)

**Description**: When running `aba cluster --name sno --ntp 10.0.1.8 ...`, the `--ntp` flag processing at line 642 runs:
```bash
replace-value-conf -n ntp_servers -v "$ntp_vals" -f $WORK_DIR/cluster.conf $ABA_ROOT/aba.conf
```
`WORK_DIR` is set to `$PWD` (line 55), which is the ABA root directory (`~/aba`). The `--name` flag does NOT change `WORK_DIR` — it only adds `name='sno'` to `BUILD_COMMAND`. So the `replace-value-conf` targets `~/aba/cluster.conf` (doesn't exist) instead of `~/aba/sno/cluster.conf`.

**Result**: `aba.conf` is correctly updated, but the existing `sno/cluster.conf` retains its old value. Since `create-cluster-conf.sh` is skipped when `cluster.conf` already exists (Makefile dependency), the stale value persists. This was observed in testing: `aba.conf` had `ntp_servers=10.0.1.8` but `sno/cluster.conf` still had `ntp_servers=10.0.1.8,2.rhel.pool.ntp.org`.

The same issue affects `--dns` (line 630), `--gateway-ip` (line 654), and any other flag that uses `$WORK_DIR/cluster.conf`.

Note: This is a core ABA bug exposed through the TUI's generated command. The TUI correctly generates `--ntp 10.0.1.8` but the core flag handler doesn't route it to the right cluster.conf.

**Verified**: YES — observed during SNO installation: `aba.conf` updated correctly, `sno/cluster.conf` retained old NTP value.

## Bug #104: ~~FEATURE REQUEST~~ EUS channel missing from TUI channel selection
**Status:** FEATURE REQUEST

**Severity**: ~~MEDIUM~~ — Feature request

**Location**: `tui/v2/tui-direct.sh` lines 203-206 (`_direct_channel`)

**Description**: The `aba.conf` template documents four OpenShift release channels: `stable`, `fast`, `candidate`, and `eus` (Extended Update Support). The TUI's channel selection dialog only offers three options — `eus` is missing:

```bash
--menu "$TUI2_MSG_CHANNEL_PROMPT" 0 0 3 \
    "stable"    "Recommended for production" \
    "fast"      "Latest GA release" \
    "candidate" "Preview/beta" \
```

Users who need EUS (required for certain upgrade paths and longer support cycles) cannot select it through the TUI. They must manually edit `aba.conf` to set `ocp_channel=eus`.

**Fix**: Add `"eus" "Extended Update Support"` to the menu items, and update the menu count from 3 to 4.

**Verified**: YES — code review confirms the channel list has only 3 items; `aba.conf.j2` line 3 documents 4 valid channels including `eus`.

---

## Bug #107: Direct script invocations bypass make dependency tracking
**Status:** OPEN

**Severity**: LOW (architectural — no immediate user impact but breaks invariants)

**File:** `tui/v2/tui-direct.sh` lines 67, 81, 103; `tui/v2/tui-mirror.sh` line 1026

**Root cause:** Multiple TUI files call scripts under `scripts/` directly instead of via `aba` CLI or Makefile targets:

1. `tui-direct.sh:67` — `"$ABA_ROOT/scripts/create-containers-auth.sh"`
2. `tui-direct.sh:81` — `"$ABA_ROOT/scripts/download-catalog-index.sh"`
3. `tui-direct.sh:103` — `"$ABA_ROOT/scripts/cli-download-all.sh"`
4. `tui-mirror.sh:1026` — `scripts/cli-download-all.sh --wait`
5. `tui-direct.sh:466` — `"$ABA_ROOT/scripts/j2"` (template renderer)

This violates the architectural invariant: "Scripts in `scripts/` must NEVER be called directly — only via Makefile targets or `aba` CLI." Direct invocations bypass make's dependency tracking and marker management.

**Expected:** Use `aba` CLI commands or `make` targets instead.
**Actual:** Scripts called directly, bypassing dependency tracking.

**Verified**: YES — code review confirms all 5 direct invocations.

---

# Unified Summary (All Sessions)

**Last updated:** 2026-05-26

## Counts

| Category | Count | IDs |
|----------|-------|-----|
| **Total entries** | 107 | #1–#107 (plus #79b) |
| **Duplicates** | 13 | #82(=#4), #83(=#38), #85(=#42), #86(=#3), #90(=#44), #91(=#69), #92(=#71), #93(=#2), #95(=#46), #100(=#62), #101(=#73), #102(=#59), #105(=#61) |
| **Fixed** | 10 | #3, #45, #47, #59, #60, #79b, #80, #81, #89, #169 |
| **Partially fixed** | 1 | #283 |
| **Invalidated** | 1 | #10 |
| **Unique open bugs** | **82** | (107 − 13 dupes − 10 fixed − 1 partial − 1 invalid) |

## Open bugs by severity

| Severity | Count | Bug IDs |
|----------|-------|---------|
| CRITICAL | 2 | #49, #50 |
| HIGH | 9 | #1, #9, #20, #22, #24, #35, #41, #53, #55, #64 |
| MEDIUM | 39 | #5, #6, #7, #13, #14, #15, #16, #17, #21, #23, #25, #26, #29, #37, #38, #43, #44, #48, #51, #52, #54, #56, #57, #61, #63, #65, #66, #69, #71, #72, #74, #75, #77, #78, #84, #88, #99, #103, #104 |
| LOW | 33 | #2, #4, #8, #11, #12, #18, #19, #27, #28, #30, #31, #32, #33, #34, #36, #39, #42, #46, #58, #62, #67, #68, #70, #73, #76, #79, #87, #94, #96, #97, #98, #106, #107 |

## Re-validation (2026-05-26, registry4, dev branch)

Top 10 DISCO show-stoppers re-validated against current code:

| # | Bug | Result |
|---|-----|--------|
| #169 | DNS warnings as success | **FIXED** — commit 152220b1, uses aba_abort |
| #59 | Shared operator removal | **FIXED** — ref-counting works correctly |
| #3 | --platform bm not passed | **FIXED** — two-step wizard generates cluster.conf first |
| #89 | VM defaults mismatch | **FIXED** — wizard loads real ABA defaults from generated cluster.conf |
| #283 | Uninstall false success | **PARTIALLY FIXED** — fallback detects containers, but vendor mismatch edge case remains |
| #41 | day2.sh proxy=direct | **STILL PRESENT** — `if [ "$int_connection" ]` true for any non-empty value |
| #42/#18 | Progressbox blocks input | **MOSTLY INVALID** — Ctrl+C works; user can also choose "Run in Terminal" mode. UX could show "Cancelled" instead of "FAILED (exit 130)" |
| #280 | Uninstall hidden | **STILL PRESENT** — menu gated on `.available` marker |
| #284 | Stale state.sh override | **STILL PRESENT** — `_state_override_mirror()` forces state over config |
| #293 | Wrong kubeconfig path | **STILL PRESENT** — line 1208 checks `$dir/kubeconfig` not `$dir/iso-agent-based/auth/kubeconfig` |

## New unique bugs from Session 2 (not duplicates)

| # | Bug | Severity |
|---|-----|----------|
| 79b | ~~FIXED~~ Internet check fails with `set -o pipefail` | HIGH |
| 80 | ~~FIXED~~ Internet check failure blocks TUI operations | CRITICAL |
| 81 | ~~FIXED~~ TUI flock FD inherited by Docker container | CRITICAL |
| 84 | VIP auto-detection uses default "ocp" name | MEDIUM |
| 87 | Connection field truncated on Interfaces page | LOW |
| 88 | ESC from VMware config silently continues wizard | MEDIUM |
| ~~89~~ | ~~Wizard VM defaults don't match cluster.conf template~~ | ~~HIGH~~ | FIXED (2026-05-26) |
| 94 | Mirror config edits saved immediately even on cancel | LOW |
| 96 | VMware password placeholder shows "(set)" | LOW |
| 97 | Optional fields (NTP, VIP) cannot be cleared | LOW |
| 98 | Mirror state race — stale label on first render | LOW |
| 99 | --ntp/--dns/--gateway target wrong cluster.conf | MEDIUM |
| 103 | Upgrade version parser captures noise/current ver | MEDIUM |
| 104 | EUS channel missing from TUI selection | MEDIUM |
| 106 | DISCO blocks on mirror verify every menu redraw | LOW |
| 107 | Direct script invocations bypass make | LOW |

## Duplicate cross-reference

| Duplicate | Original | Description |
|-----------|----------|-------------|
| #82 | #4 | VMware password plaintext |
| #83 | #38 | prefix_length/machine_network order |
| #85 | #42 | Ctrl+C blocked in progressbox |
| #86 | #3 | --platform bm not passed |
| #90 | #44 | False "Success" when process killed |
| #91 | #69 | ISC reset doesn't regenerate |
| #92 | #71 | Bundle path with spaces |
| #93 | #2 | Dead code _direct_operators |
| #95 | #46 | KVM quoting inconsistency |
| #100 | #62 | VM values below minimums |
| #101 | #73 | Basket dirty flag unconditional |
| #102 | #59 | Shared operator removal |
| #105 | #61 | DISCO no internet re-check |

---

## Bugs added during DISCO bundle flow testing (2026-05-22)

---

## Bug #164: ~~LOW RISK~~ Cluster monitor availability flag set for ANY existing cluster, not just actively installing ones

**Severity**: ~~MEDIUM~~ — LOW RISK (cosmetic)
**Status:** LOW RISK — The actual Monitor function uses `select_cluster "installing"` which properly filters to only show clusters with kubeconfig but no `.install-complete`. If none exist, user gets an empty list message. Menu visibility is slightly misleading but harmless.
**File:** `tui/v2/tui-lib.sh` lines 761-766
**Description:** `_CLUSTER_MON_AVAIL` is set to `true` if any cluster directory exists, regardless of whether that cluster is actively installing. This means the "Monitor Cluster Installation" menu item is available even when no install is in progress.

**Verified:** YES — code review confirms the logic checks for cluster existence, not active install state.

---

## Bug #165: ~~CORE ABA BEHAVIOR~~ Cluster wizard fails on first run — auto-detects network and exits with error

**Severity**: ~~MEDIUM~~ — CORE ABA BEHAVIOR (not TUI)
**File:** `tui/v2/tui-cluster.sh`
**Status:** NOT A BUG — `aba cluster` auto-detects network settings and exits non-zero on first run to prompt user review. This is core ABA behavior, not a TUI bug. The TUI correctly shows the failure and lets the user retry.

**Verified:** YES — observed during interactive testing.

---

## Bug #166: ~~LOW RISK~~ Platform selection writes to aba.conf immediately, before user can cancel

**Severity**: ~~MEDIUM~~ — LOW RISK
**File:** `tui/v2/tui-cluster.sh`
**Status:** LOW RISK — Minor UX quirk. If user cancels the platform config form after selecting a platform, `aba.conf` retains the new platform value. Harmless: user can re-select the old platform from the same menu. No data loss.

**Verified:** YES — code review confirms `replace-value-conf` runs before form display.

---

## Bug #280: ~~CORE ABA BUG~~ "Uninstall Mirror" option hidden from Advanced menu when `.available` marker is removed
**File:** `tui/v2/tui-cluster.sh` (menu gated by `.available`)
**Severity:** ~~HIGH~~ — CORE ABA BUG (downstream of #283)
**Status:** OPEN — The TUI correctly shows "Uninstall" when `.available` exists. The root cause is Bug #283: `reg-uninstall.sh` falsely reports success, causing Makefile to remove `.available` prematurely. Fix belongs in core ABA uninstall scripts.
**Downstream of:** Bug #283 — `.available` is only removed by Makefile targets AFTER `reg-uninstall.sh` exits 0. This bug can only occur when Bug #283 triggers (uninstall falsely reports success while registry is still running), causing the Makefile to remove `.available` prematurely.
**Steps to reproduce:**
1. Have a running Quay registry on the host
2. Delete `~/.aba/` directory (or it gets corrupted)
3. Run `aba -d mirror uninstall` — it finds "no docker registry" and reports success (checks Docker only)
4. The `.available` marker is removed but Quay is still running
5. Open TUI → Advanced menu → "Uninstall Mirror Registry" option is GONE
6. User has no TUI path to remove the running Quay registry
7. Next attempt to install a local mirror fails: "Existing Quay registry found"

**Root cause:** The Advanced menu conditionally shows "Uninstall Mirror" only when `mirror_available()` returns true (checks `.available` marker). If the marker is removed but the registry is still running, the option disappears. The `.available` marker is managed exclusively by Makefile targets (`templates/Makefile.mirror` lines 244, 319, 332) and is removed only after `reg-uninstall.sh` exits 0. In normal operation it should never be removed while a registry runs — this only happens when Bug #283 causes a false-success exit.

**Expected:** Fixing Bug #283 (ensuring `reg-uninstall.sh` never exits 0 while containers are running) would prevent this bug entirely. Alternatively: always show "Uninstall Mirror" in Advanced, OR probe for running registry containers regardless of `.available`.
**Actual:** Running registry becomes invisible to the TUI once `.available` is removed.
**Verified:** YES — via TUI on registry4 (2026-05-26: Advanced menu had no Uninstall option after `.available` was removed while registry container still running)

---

## Bug #283: ~~CORE ABA BUG~~ TUI uninstall reports "Command completed successfully" when actual registry still running
**File:** `scripts/reg-uninstall.sh`
**Severity:** ~~HIGH~~ — CORE ABA BUG (not TUI)
**Status:** FIXED (commits 193cd237, 0122cf8a, 43fa7131) — Multi-pronged fix: (1) reg_vendor=auto is resolved and written back to mirror.conf at install time (43fa7131), so config always matches state; (2) drift detection escalated to aba_warning (193cd237) so users see if they edit mirror.conf post-install; (3) fallback path (state.sh missing) correctly defaults to quay and probes containers+data dirs. The original scenario (mirror.conf wrong vendor) is now prevented at the source.
**Previously:** PARTIALLY FIXED (2026-05-26) — fallback probes `podman ps -a` and data directory existence.
**Steps to reproduce:**
1. Have a Quay registry running but with missing state (`~/.aba/` deleted)
2. Go to TUI → Advanced → Uninstall Mirror
3. TUI runs `aba --dir mirror uninstall`
4. Script finds no Docker registry state, skips Quay check
5. Command exits 0 ("successfully"), `.available` removed
6. TUI shows "Command completed successfully"
7. Quay containers are still running (podman ps shows quay-app, quay-redis)

**Root cause:** When `state.sh` is missing, the uninstall logic doesn't detect the registry vendor and falls back to Docker-only check. Docker not found = nothing to uninstall = exit 0. But a Quay registry may still be running.

**Expected:** Uninstall should probe for ANY running registry (Quay OR Docker) regardless of state file presence.
**Actual:** Silently reports success with Quay containers still running.
**Verified:** YES — via TUI on registry4 (saw "Command completed successfully" while podman ps showed quay-app, quay-redis running)

---

## Bug #284: ~~DOWNSTREAM OF #283~~ Stale `state.sh` overrides user's `mirror.conf` vendor selection after uninstall
**File:** `scripts/include_all.sh` `_state_override_mirror()`
**Severity:** ~~HIGH~~ — Downstream consequence of Bug #283
**Status:** FIXED (commit 193cd237) — `_state_override_mirror()` now shows a visible `aba_warning` when state.sh and mirror.conf disagree, telling the user to uninstall first. If state.sh survives after uninstall, the user will see the drift warning on next operation. Uninstall scripts DO remove state.sh (`rm -rf "${regcreds_dir:?}/"*`); survival means uninstall didn't complete cleanly.
**Steps to reproduce:**
1. Previously install a Quay registry (state.sh records `reg_vendor=quay`)
2. Uninstall mirror — state.sh survives at `~/.aba/mirror/mirror/state.sh`
3. Edit `mirror.conf` to set `reg_vendor=docker` (via TUI config form)
4. Navigate to sync/install — Mirror Configuration review shows "Vendor: quay" (from stale state.sh)
5. If user proceeds, wrong registry type (Quay) would be installed

**Root cause:** `normalize-mirror-conf` (or similar) reads `~/.aba/mirror/mirror/state.sh` and lets it override the explicit value in `mirror.conf`. After uninstall, `state.sh` should be deleted or `mirror.conf` should take precedence for fresh installs.

**Expected:** After uninstall, `mirror.conf` is the source of truth for new installations.
**Actual:** Stale `state.sh` silently overrides user's explicit `mirror.conf` settings.
**Verified:** YES — observed on registry4 (mirror.conf had docker, TUI review showed quay from state.sh)

---

## Bug #285: ~~LOW RISK~~ Sync status label not invalidated after operator basket change
**File:** `tui/v2/abatui2.sh`
**Severity:** ~~MEDIUM~~ — LOW RISK (UX enhancement)
**Status:** LOW RISK — The "synced" label means "mirror has release images" (basic health). Detecting ISC drift since last sync would require timestamp comparison — a significant enhancement. Current status is functionally correct; users who add operators should know to re-sync.
**Steps to reproduce:**
1. Mirror is synced (OCP images only, no operators)
2. TUI main menu shows "Y  Sync images to mirror (synced)"
3. Go to "O  Select Operators" and add `cincinnati-operator`
4. Return to main menu
5. Menu still shows "Y  Sync images to mirror (synced)"
6. ISC has been updated with the new operator
7. User may think operator is already synced (it's not — needs re-sync)

**Root cause:** The "synced" label is based on whether `_mirror_has_release_image` returns true (checks OCP release image existence in the registry), not whether the ISC has been modified since last sync. Adding operators doesn't change the release image check result.

**Expected:** After ISC modification (operator add/remove), sync label should change to "(needs sync)" or similar to indicate new content is pending.
**Actual:** Label remains "(synced)" even with un-synced operator content in the ISC.
**Verified:** YES — via TUI on registry4 (added cincinnati-operator, ISC updated, menu still shows "synced")

---

## Bug #289: ~~LOW RISK~~ No warning when deleting a cluster that's actively installing

**Severity:** ~~Medium~~ — LOW RISK (UX enhancement)
**Status:** LOW RISK — The delete confirmation already warns "This action cannot be undone." The actual `aba delete` handles mid-install state correctly. Adding an extra "currently installing" warning is a nice-to-have enhancement, not a bug.
**Location:** `tui/v2/tui-cluster.sh` `cluster_delete()` (~line 1724)
**Commit range:** db9d9ace (delete UX)

**Reproduction:**
1. Start a cluster installation via TUI
2. Interrupt the wait (Ctrl+C in the progress dialog) — the VM continues installing
3. Navigate to Day-2 → Delete cluster → select the installing cluster
4. Observe: the confirmation dialog says "Delete cluster 'X'?" with no mention that it's currently installing

**Expected:** The delete confirmation should warn "This cluster appears to be in the middle of installation. Are you sure?" or similar.
**Actual:** The standard generic "This removes all cluster state and resources. This action cannot be undone." message is shown with no indication the cluster is actively installing.

**Root cause:** `cluster_delete()` does not check the cluster's installation state before showing the confirmation. It could check for the presence of `kubeconfig` without `.install-complete` to detect mid-install state.

**Verified:** YES — via TUI on registry4 (2026-05-24): deleted sno cluster that was mid-install, got no warning about active installation.

---

## Bug #306: "Install Mirror" bypasses reinstall confirmation when mirror is installed but not verified — FIXED

**Status:** FIXED (2026-06-24, commit `bd1bc2e5`) — added `mirr_avail=false` in elif branch  
**Severity:** Low (UX confusion — user enters install wizard for already-installed mirror)
**Location:** `tui/v2/abatui2.sh` lines 538-547, 558-567 (status logic) and lines 662-671 (action handler)
**Commit range:** Present since CONNO menu status annotations were added

**Reproduction:**
1. Install a mirror registry (`aba --dir mirror install`)
2. Do NOT sync images yet (mirror is installed but has no release image)
3. Start TUI → CONNO main menu
4. Observe: menu shows "Install Mirror (local or remote) (installed — not verified)"
5. Click "Install Mirror"
6. Expected: "Reinstall?" confirmation dialog (since mirror is already installed)
7. Actual: Goes directly to the install wizard (local/remote choice) without warning

**Root cause:** In both code paths (recheck at line 545 and cached at line 565), when `mirror_available` is true but `_mirror_has_release_image` is false, the code sets the label to "not verified" but does NOT set `mirr_avail=false`. This leaves `mirr_avail=true`, which the action handler at line 662 interprets as "mirror not installed" and skips the reinstall confirmation dialog.

**Fix hint:** Add `mirr_avail=false` in both `elif` branches (lines 545-547 and 565-567):
```bash
elif mirror_available; then
    mirr_avail=false  # ADD THIS — mirror IS installed, just not verified
    mirr_label="$TUI2_LABEL_INSTALL_MIRROR $TUI2_STATUS_NOT_VERIFIED"
fi
```

**Impact:** Low risk. The underlying `make install` target is idempotent (skips if `.available` exists), so no data loss occurs. But it confuses users who see "(installed — not verified)" and then go through the install wizard only for nothing to happen.

**Verified:** YES — code analysis confirmed: `mirr_avail` stays `true` in both "not verified" branches.

---

## Bug #311: Stale "mirror ready"/"synced" status after mirror uninstall + reinstall
**Status:** OPEN

**Severity:** HIGH
**File:** `scripts/include_all.sh` (`aba_mirror_verify_exit` → `run_once -E -i "aba:mirror:check-image"`)
**Affected:** `tui/v2/abatui2.sh` lines 539-544, 559-564 (CONNO menu status rendering)

**Description:** After uninstalling a mirror registry (which had previously been synced/verified) and then reinstalling a fresh empty mirror, the TUI displays "mirror ready" in the status bar and "(synced)" on the Sync menu item. The freshly installed mirror has no images.

**Root cause:** The `run_once` cached exit code for task `aba:mirror:check-image` (stored at `~/.aba/runner/aba:mirror:check-image/exit`) is never invalidated during `aba --dir mirror uninstall`. After reinstall, `aba_mirror_verify_exit()` returns the stale cached "0" (success), and `_mirror_has_release_image()` returns true — making the TUI believe the mirror is verified/synced.

**Steps to reproduce:**
1. Have a working mirror with synced images (exit code 0 cached)
2. Via TUI: Advanced → Uninstall Mirror → confirm
3. Via TUI: Install Mirror (local) → configure → install
4. Observe CONNO menu: status shows "mirror ready" and Sync shows "(synced)"
5. Attempting to install a cluster would likely fail because no images exist

**Expected:** After uninstall, the `run_once` cache for `aba:mirror:check-image` should be cleared/reset. After reinstall with no sync, status should show "mirror installed" and Sync should NOT show "(synced)".

**Actual:** Stale cache causes false "mirror ready" / "(synced)" indicators.

**Verified:** YES — reproduced on registry4. Confirmed `~/.aba/runner/aba:mirror:check-image/exit` contains "0" after fresh reinstall of empty mirror.

---

## Bug #333: "Switch to Connected Mode" from DISCO is impossible when internet is unavailable — user loops back to DISCO — FIXED

**Severity:** MEDIUM
**Status:** FIXED (2026-06-24) — pre-checks internet before allowing the switch, shows clear message if offline
**File:** `tui/v2/tui-disco.sh` (`disco_reset()`)

**Description:** When the TUI auto-detects DISCO mode (internet check fails, payload available), the Advanced menu offers "Switch to Connected Mode" (X). If the user selects it:
1. `disco_reset()` removes `.bundle` and returns 2
2. Main loop catches rc==2 and calls `_detect_mode`
3. `_detect_mode` re-runs the internet check — which fails again
4. Shows misleading "ERROR: Internet access required... Exiting..." dialog
5. DISCO fallback succeeds → user is sent right back to DISCO mode

The switch is impossible and the user wasted time confirming an action that cannot succeed.

**Steps to reproduce:**
1. Start TUI on a host where registry.redhat.io (or other checked sites) is unreachable
2. TUI auto-detects DISCO mode
3. Go to Advanced → X "Switch to Connected Mode"
4. Confirm "Switch" on the confirmation dialog
5. See "ERROR: Internet access required... Exiting..." dialog
6. Press OK → back in DISCO mode (switch failed silently)

**Root cause:** `disco_reset()` unconditionally returns 2 (re-detect mode) without checking if internet is actually available. The main loop re-runs `_detect_mode` which re-runs the full internet check — if it still fails, DISCO fallback kicks in.

**Additional issue:** The confirmation message says "you will be asked to choose between Partially Disconnected and Fully Connected modes" but the user is NEVER asked — `_detect_mode` auto-selects based on internet availability.

**Fix hint:** Either:
1. Check internet availability BEFORE offering the "Switch to Connected Mode" option (grey it out)
2. OR in `disco_reset()`, verify internet is reachable before proceeding
3. OR after `disco_reset()`, if `_detect_mode` returns DISCO again, show a clear message: "Cannot switch — internet still unavailable"

**Verified:** YES — Live-reproduced on registry4 (registry.redhat.io blocked). User selected "Switch to Connected Mode", confirmed, got error, looped back to DISCO.

---

## Bug #337: Operator search / basket edit removal bypasses ref-count decrement

**Severity:** MEDIUM
**Status:** OPEN
**Location:** `tui/v2/tui-mirror.sh` lines 1000-1008 (`_operator_search`), lines 1058-1063 (`_operator_view_basket`)

**Description:** Operator sets use ref-counting in `OP_BASKET` (lines 891-897): adding a set increments counts, removing decrements. However, the search and basket-edit paths use `unset` when removing an operator, bypassing the ref-count entirely. This means unchecking an operator in search results or the basket editor can silently remove it even though another active set still includes it.

**Root cause:**
```bash
# In _operator_search and _operator_view_basket:
elif [[ -n "${OP_BASKET[$op]:-}" ]]; then
    unset 'OP_BASKET[$op]'     # <-- flat unset, ignores ref-count
```

Versus the correct pattern in set removal (lines 891-897):
```bash
local _cnt=${OP_BASKET[$op]:-0}
_cnt=$(( _cnt - 1 ))
(( _cnt <= 0 )) && unset 'OP_BASKET[$op]' || OP_BASKET[$op]=$_cnt
```

**Steps to reproduce:**
1. Select two operator sets that share an operator (e.g. `ocp` + `gpu` both have `cincinnati-operator`)
2. Search for that operator — it shows as checked
3. Uncheck it in search results → Apply
4. Operator disappears from basket entirely
5. But "ocp" and "gpu" sets are still shown as checked in Select Operator Sets
6. ISC misses the operator

**Expected:** Decrement ref-count; only fully remove when count reaches 0

**Actual:** Flat `unset` regardless of ref-count — operator silently lost while set checkboxes remain checked

**Impact:** Silent operator loss in mirror/ISC. Different from Bug #308 (which was about search ADDING/confirming resetting counts) — this is about search/basket REMOVING operators bypassing ref-counting entirely.

**Verified:** YES — code analysis confirms `unset` is used without ref-count logic in both `_operator_search` (line 1005) and `_operator_view_basket` (line 1060).

---

## Bug #339: `tui_install_cluster_gate` trusts stale mirror verify cache — skips sync/load prompt

**Severity:** MEDIUM (downstream of #311 / #326)
**Status:** OPEN
**Location:** `tui/v2/tui-lib.sh` lines 1431-1434

**Description:** The Install Cluster gate returns 0 immediately when `_mirror_has_release_image` returns true. After mirror uninstall/reinstall (#311) or OCP version change (#322), the cached `aba:mirror:check-image` exit code can still be `0` (success from old state). The gate does not perform a version-aware check.

**Root cause:**
```bash
if mirror_available && _mirror_has_release_image; then
    return 0
fi
```
No cache invalidation and no version-aware verification.

**Steps to reproduce:**
1. Sync mirror for 4.21.15 (cache = success)
2. Uninstall mirror; reinstall empty registry (or change version via Rerun Wizard without re-sync)
3. CONNO → Install Cluster → gate returns 0 (no `(sync mirror first)` warning)
4. Wizard → install fails (no release image for current version)

**Expected:** Gate should verify release image for the **current** `ocp_version` or invalidate cache on uninstall/version change

**Actual:** Gate trusts stale cache, allowing install to proceed without sync

**Verified:** YES — code analysis confirms no version-awareness or cache invalidation in the gate check. Related to and exacerbated by Bugs #311, #322, #326.

---

## Bug #341: Advanced CONNO→DIRECT switch runs `direct_main` nested but forces `_TUI_MODE` back to CONNO

**Severity:** MEDIUM (UX / state confusion)
**Status:** OPEN
**Location:** `tui/v2/tui-cluster.sh` lines 1922-1928

**Description:** From CONNO Advanced → "Switch to Fully Connected", the code sets `_TUI_MODE=DIRECT`, runs the full DIRECT action menu as a nested call, then **always** resets `_TUI_MODE=CONNO` when `direct_main` returns. This means the "switch" is not a real mode switch — it's a temporary nested preview.

**Root cause:**
```bash
case "$_TUI_MODE" in
    CONNO)
        _TUI_MODE="DIRECT"
        tui_log "Advanced: switching to DIRECT mode"
        direct_main || true
        _TUI_MODE="CONNO"     # <-- always resets
        ;;
```

Compare with DIRECT→CONNO switch at line 1930 which does `return 0` (permanent mode change).

**Steps to reproduce:**
1. CONNO → Advanced → X (Switch to Fully Connected)
2. Use DIRECT menu for operations
3. Exit DIRECT menu (Back)
4. User is back in CONNO Advanced loop, not in DIRECT mode

**Expected:** Either persist DIRECT mode (like the DISCO switch uses return 2 + re-detect), or clearly label as "Try DIRECT workflow" (temporary preview)

**Actual:** Users think they've switched to fully connected but are still in CONNO semantics

**Impact:** Cluster wizard and mirror operations still use CONNO semantics (mirror requirement, etc.) after the user "switched" to DIRECT

**Verified:** YES — code analysis confirms `_TUI_MODE="CONNO"` is unconditionally set after `direct_main` returns.

---

## Bug #351 — ~~FIXED~~ `_cluster_load_conf` doesn't normalize `int_connection=none` — connection toggle gets stuck

**Status:** FIXED in commit ea58e012 — normalizes legacy `none` to empty on load

**Severity:** LOW
**Component:** `tui/v2/tui-cluster.sh` — `_cluster_load_conf()` line 99, `_apply_mode_connection()` lines 697-703

**Description:** Older versions of ABA used `int_connection=none` in `cluster.conf` to mean "use mirror" (no direct internet). The core `normalize-cluster-conf` function (in `scripts/include_all.sh` line 654) converts `none` to empty. However, the TUI's `_cluster_load_conf` reads the raw `cluster.conf` file directly, so `cl_connection` is set to the literal string "none".

This causes two problems:
1. **Image Source display** — shows "none" (the `*` wildcard case in the `conn_display` switch) instead of "mirror"
2. **Connection toggle stuck** — in CONNO mode, the toggle cycles `mirror→proxy→direct→mirror`. "none" doesn't match any case, so the toggle does nothing. In DISCO mode, `_apply_mode_connection` only converts "direct" to "mirror", so "none" survives.

**Steps to reproduce:**
1. Have a `cluster.conf` from an older ABA version with `int_connection=none`
2. Open TUI → Install Cluster → select the cluster
3. Navigate to Interfaces page (page 3)
4. Observe: Image source shows "none"
5. Try to toggle Image source → nothing changes

**Expected:** `_cluster_load_conf` should normalize `none` to empty (or to "mirror") when loading, consistent with the core normalization logic.

**Fix hint:** Add normalization in `_cluster_load_conf` after loading `int_connection`:
```bash
int_connection)
    cl_connection="$val"
    [[ "$cl_connection" == "none" ]] && cl_connection=""
    ;;
```
Or normalize at the end of the function.

**Verified:** YES — code review confirms: `_cluster_load_conf` reads raw file, `_apply_mode_connection` doesn't handle "none", and the CONNO toggle `case` doesn't match "none"

---

## Bug #352 — DISCO auto-wizard failure or ESC exits TUI without confirmation (no way to reach menu)

**Severity:** HIGH
**Status:** OPEN
**Component:** `tui/v2/tui-disco.sh` — `_disco_bundle_wizard_gate()`, `disco_main()`, `tui/v2/abatui2.sh` main loop (lines 837-844)

**Description:** When the TUI enters DISCO mode with `.bundle` present, `_disco_bundle_wizard_gate()` automatically triggers mirror install and image load. If ANY of these operations fail (non-zero exit from `aba load`) or the user presses ESC at any point during the auto-wizard, the entire TUI exits without confirmation. The user cannot reach the DISCO main menu.

The root cause is a cascade of return-1 propagation:
1. Command failure or ESC in `confirm_and_execute` → returns non-zero
2. `disco_load_images` returns non-zero
3. `_disco_bundle_wizard_gate`: `disco_load_images || return 1` → returns 1
4. `disco_main`: `_disco_bundle_wizard_gate || return 1` → returns 1
5. Main loop (`abatui2.sh` line 839-844): `disco_rc=1`, not 2, so falls through to `break`
6. After the while loop, the TUI shows exit summary and exits (line 863-864)

The TUI log confirms this: "TUI v2 exited" appears without "User attempting to quit" or "User confirmed quit" entries.

This is particularly bad because oc-mirror load failures are common (transient network issues, timeouts, catalog errors). The user must restart the TUI after EVERY failure.

**Steps to reproduce (failure path):**
1. Create `.bundle` marker: `touch ~/aba/.bundle`
2. Have mirror installed but no release image loaded
3. Run `abatui` → select "Fully Disconnected"
4. The auto-wizard triggers image load → oc-mirror fails (e.g., catalog error)
5. Press OK on the failure dialog
6. The TUI exits immediately without confirmation

**Steps to reproduce (ESC path):**
1. Same setup as above
2. When the "Choose execution mode" dialog appears, press ESC
3. The TUI exits immediately without confirmation

**Expected:** After a load failure or ESC, the user should be taken to the DISCO main menu where they can retry the load, change settings, or take other actions. The auto-wizard should not be a one-shot gate that blocks all access to the menu.

**Fix hint:** In `disco_main()`, change the wizard gate handling:
```bash
disco_main() {
    if ! _disco_bundle_wizard_gate; then
        tui_log "DISCO wizard: user cancelled or failed — showing menu anyway"
        # Fall through to the DISCO menu instead of returning 1
    fi
    ...
}
```
Or in `abatui2.sh`, handle non-2 return from `disco_main` by re-prompting instead of breaking.

**Verified:** YES — reproduced interactively on registry4 (both failure and ESC paths). TUI log confirmed no quit confirmation before exit.

---

## ~~Bug #353~~: INVALID — Catalog digest mismatch was caused by flawed testing methodology
**Status:** INVALID
**Severity:** NOT A BUG
**Category:** Testing error, not an ABA defect

**What happened:** During same-host DISCO simulation on registry4, the tester ran `aba save` then `aba load` in the SAME repo directory (with `int_down` to simulate disconnection), bypassing the bundle creation/unpack workflow entirely. The `.index/` digest was updated between save and load by a background catalog re-download, causing `aba load` to look for a catalog digest that wasn't in the tar.

**Why it's not a bug:** The proper DISCO workflow uses `aba bundle` → transfer → unpack → `aba load`. The bundle packages `.index/` alongside the tar, so the digest is self-consistent. On the disconnected host, `download_all_catalogs` fails (no internet), so `.index/` stays as-is from the bundle. The `catalogs-wait` Make target ensures catalogs are fully downloaded before ISC creation. The Make dependency chain (`save: ... data/imageset-config.yaml` → `catalogs-download catalogs-wait`) prevents race conditions.

**The README and test scripts are clear:** `test/basic-test-using-bundle.sh` shows the correct same-host simulation — create bundle, `int_down`, **unpack into a separate directory**, then load from the unpacked bundle. The tester skipped the bundle step entirely.

---

## Bug #357: `aba_wait_show` provides NO real-time progress in TUI progressbox mode

**Severity:** Medium (UX)
**File:** `scripts/include_all.sh` (lines 1328-1331), `tui/v2/tui-lib.sh` (line 626)
**Found:** 2026-06-03 (hackathon, Day-2 operations testing)
**Status:** OPEN

**Description:**
When a command runs inside the TUI's progressbox (`_exec_in_tui`), it sets `PLAIN_OUTPUT=1` which disables the TTY spinner in `aba_wait_show`. The non-TTY fallback uses `printf` without newlines to accumulate progress ticks on a single line (e.g., `[ABA] Waiting for X (max 6m) ... 0s 11s 21s ...`). The final newline is only emitted when the wait completes.

Since `dialog --progressbox` only renders content when it receives a newline, the user sees ZERO visual feedback during waits that can last up to 15 minutes (e.g., oauth-proxy imagestream recreation, NTP chrony.conf rollout, OSUS operator provisioning).

**Observed behavior:**
- Day-2 command runs, shows messages up to the first `aba_wait_show` call
- Screen shows NO new output for 5-15 minutes
- After the wait completes, the entire progress line suddenly appears (e.g., `0s 11s 21s ... 5m7s`)

**Expected behavior:**
Real-time feedback during waits — at minimum, one line every ~30 seconds so the user knows the operation is progressing.

**Root cause:**
`scripts/include_all.sh` line 1329:
```
printf '[ABA] %s (max %s) ... ' "$msg" "$max_fmt"  # No newline
```
Line 1330:
```
printf '%s ' "$(_aba_format_elapsed "$elapsed")"  # No newline
```
Neither produces a `\n`, so `dialog --progressbox` (which is line-buffered) accumulates text without displaying it.

**Suggested fix:**
In non-TTY mode (`use_tty=0`), emit a newline after the header and after every N ticks:
```bash
if [ "$use_tty" -eq 0 ]; then
    [ -z "$hdr_done" ] && { printf '[ABA] %s (max %s) ...\n' "$msg" "$max_fmt"; hdr_done=1; }
    printf '[ABA]   ... %s\n' "$(_aba_format_elapsed "$elapsed")"
fi
```

**Impact:** Users have no indication that long-running operations are progressing inside the TUI. They may think the TUI is frozen and kill it.

**Verified:** Observed during Day-2 testing in tmux session "tui-debugging" on registry4 — the oauth-proxy wait (~5m) and NTP sync wait (~3m) both showed no output until completion.

---

## Bug #367: Kubeadmin password exposed in terminal/log output when `oc login` fails (SECURITY) — FIXED

**Severity:** HIGH (security)
**Component:** `scripts/day2.sh` + `scripts/show-cluster-login.sh` + `scripts/include_all.sh`
**Found by:** Code review + TUI testing (tmux "tui-debugging" session)
**Status:** FIXED (2026-06-24, commit `0f3fa97c`) — `show_error()` masks `-p '...'` patterns to `-p '***'`

**Description:**
When `aba day2` (or any script calling `aba login`) fails to connect to the cluster API, the kubeadmin password is exposed in plaintext in the terminal output and TUI failure dialog.

**Root cause:**
1. `scripts/show-cluster-login.sh` (line 11) outputs: `oc login -u kubeadmin -p '<PASSWORD>' --insecure-skip-tls-verify https://api.CLUSTER:6443`
2. `scripts/day2.sh` (line 46) sources this output via `. <(aba login)` — executing the `oc login` command with the literal password
3. When `oc login` fails (e.g., DNS resolution failure, cluster unreachable), the ERR trap fires
4. `show_error()` in `scripts/include_all.sh` (line 294) prints `$BASH_COMMAND` — which is the full `oc login` command including the plaintext password
5. The password is visible in terminal output, TUI progressbox, and log files

**Verified output (from tmux session):**
```
Script error at Thu Jun  4 02:50:23 AM +08 2026 in directory /home/steve/aba/sno:
Error occurred in command: 'oc login -u kubeadmin -p '5qF8V-PFf33-wM6SV-PCHix' --insecure-skip-tls-verify https://api.sno.example.com:6443'
Error code: 1
```

**Reproduction:**
1. Have an installed cluster whose API is temporarily unreachable (e.g., DNS issue, cluster shut down)
2. Run Day-2 → Cluster Resources (R) → select the cluster → Run in Terminal
3. The kubeadmin password appears in the error output

**Suggested fix:**
Option A: Mask the password in `show_error()`:
```bash
show_error() {
    local exit_code=$?
    local safe_cmd="${BASH_COMMAND//-p */-p '***'}"
    echo_red "Error occurred in command: '$safe_cmd'" >&2
}
```
Option B: Use `--token` instead of `-p` in `show-cluster-login.sh` (get token via `oc whoami -t`)
Option C: Set KUBECONFIG env var instead of running `oc login` (the kubeconfig already has credentials)

**Impact:**
- Password exposed to anyone viewing terminal output, tmux sessions, or log files
- Violates security best practice: secrets should never appear in error messages
- Affects all cluster-dependent Day-2 operations when cluster API is unreachable

## Bug #368: govc: command not found error during cluster install before CLI tools are downloaded

**Severity:** LOW (cosmetic — non-fatal error message)
**Status:** OPEN
**Found:** 2026-06-04 (TUI hackathon — live testing on registry4)

**Description:** During aba cluster --name sno2 --step install, at an early stage (line 1033 of include_all.sh), the script references govc before the CLI download/install step has extracted it. The error message "scripts/include_all.sh: line 1033: govc: command not found" appears in the output but does not stop the install. The install correctly continues and govc is installed later (before it is actually needed for VM operations).

**Reproduction:**
1. Start TUI, Install Cluster on a fresh system where govc has not been extracted yet
2. Observe the error in terminal output during the early validation phase
3. The install continues and govc is extracted later

**Impact:** Confusing error message in the output that may alarm users, even though it is harmless.

**Suggested fix:** Guard the early govc reference with "command -v govc" or move the check after ensure_govc has run.

## Bug #369: Misleading error message when govc/vCenter is unreachable during ISO upload

**Severity:** MEDIUM
**Status:** OPEN
**Found:** 2026-06-04 (TUI hackathon — live testing on registry4)

**Description:** When govc fails during the ISO upload step (.autoupload target) due to DNS resolution failure, vCenter 503, connection timeout, or a panic in govmomi, the error message always says:

  [ABA] Error: ISO file failed to upload!
  [ABA]        The ISO may be attached to a running VM and cannot be overwritten.
  [ABA]        Stop the VM first with 'aba stop' and try again.

This is misleading because:
- DNS failure results in "no such host" (not a VM issue)
- 503 Service Unavailable means vCenter is down (not a VM issue)  
- govmomi panic means govc crash (not a VM issue)

The user is told to stop a VM that may not even exist.

**Reproduction:**
1. Configure cluster for VMware platform
2. Have vCenter unreachable (DNS misconfigured, vCenter down, or network issue)
3. Run Install Cluster — the ISO upload fails with the misleading message

**Impact:** User wastes time trying to stop VMs that dont exist or arent running. The real issue (connectivity to vCenter) is obscured.

**Suggested fix:** Parse the govc exit code and stderr. If the error contains "no such host", "connection refused", "503", "timeout", or "panic", show a connectivity-specific message instead.

## Bug #370: ~~FEATURE REQUEST~~ TUI has no option to change verify_conf setting (feature gap)

**Severity:** LOW (workaround: edit aba.conf manually)
**Status:** FEATURE REQUEST — not a bug
**Found:** 2026-06-04 (TUI hackathon — live testing on registry4)

**Description:** The TUI Settings menu only offers: Auto-answer, Registry Type, and Retry Count. There is no option to change verify_conf (which controls whether DNS/NTP/IP validation is performed during cluster install).

When a users host resolver does not have the cluster DNS records (but the clusters configured DNS does), the install fails with "DNS record api.X does not resolve" and the only way to bypass this is manually editing aba.conf to set verify_conf=conf.

**Impact:** Users who correctly configure cluster DNS in the wizard but whose HOST resolver differs must leave the TUI and manually edit aba.conf. This breaks the "everything through TUI" experience.

**Suggested fix:** Add a verify_conf toggle to the TUI Settings menu (values: all, conf, no), with appropriate help text explaining what each level validates.

---

## Bug #374: `reg-save.sh` instructs user to copy target-version CLIs before download completes

**Status:** OPEN (unverified — code inspection only)

**Severity:** LOW — Only affects manual file-copy workflow; `aba bundle`/`aba tar` correctly wait via `_wait_for_cli_downloads`

**Location:** `scripts/reg-save.sh` lines 51, 128

**Description:** When running `aba save --target-version X.Y.Z`, the script `reg-save.sh`:
1. Starts downloading target-version CLI binaries in background (line 51): `scripts/cli-download-all.sh --target-version $ocp_version_target`
2. Runs oc-mirror save (which takes a long time)
3. At exit, prints instructions telling user to copy `cli/openshift-*-<version>*` files (line 128)

The issue: `reg-save.sh` does NOT wait for the target-version CLI downloads to complete before exiting. If oc-mirror finishes quickly (e.g. incremental save with few new images), the target-version CLIs might not yet be on disk when the user is told to copy them.

**Root cause:** The `cli-download-all.sh --target-version` call is non-blocking (uses `run_once` internally). The script relies on oc-mirror being slow enough for downloads to finish, but this is a race condition.

**Mitigating factors:** Users who use `aba bundle` or `aba tar` (the recommended workflow) are safe — `make-bundle.sh` line 202 calls `_wait_for_cli_downloads` which blocks until all CLI downloads complete. This bug only affects users who manually copy files as instructed by the `reg-save.sh` output message.

**Suggested fix:** Either add `scripts/cli-download-all.sh --wait` before the informational message, or caveat the message with "Note: CLI binaries may still be downloading. Run 'aba cli wait' to ensure they are ready."

---

## Bug #379: TUI Upgrade shows versions from mirror but OSUS graph may not have a direct upgrade path

**Status:** OPEN (verified via TUI on conno - upgrade from 4.20.20 to 4.20.23 failed)

**Severity:** MEDIUM — User follows TUI guidance but upgrade fails

**Location:** tui/v2/tui-cluster.sh _day2_upgrade function (version list from aba upgrade --dry-run)

**Description:** The TUI Upgrade cluster menu shows versions that exist in the mirror (via aba upgrade --dry-run which checks mirror contents). It presented 4.20.23 as "(newest)" available target. However, when the user selects 4.20.23, the actual oc adm upgrade --to 4.20.23 fails with:

  error: the update is not one of the possible targets: 4.20.22. specify --to-image to continue with the update.

The OSUS update graph only has a direct edge from 4.20.20 -> 4.20.22, not 4.20.20 -> 4.20.23. This means the user must upgrade in steps (4.20.20 -> 4.20.22 -> 4.20.23), but the TUI does not communicate this.

**Impact:** User follows TUI prompts, selects the version the TUI shows as available, and gets a confusing failure. The user has no guidance from the TUI about stepping through intermediate versions.

**Root cause:** The version list in _day2_upgrade comes from aba upgrade --dry-run which reports "Versions in mirror (higher than current)". This is based on mirror content, NOT on the OSUS graph edges. The TUI should either consult oc adm upgrade (which shows actual valid targets) or warn that multi-step upgrades may be needed.

**Suggested fix:** Either:
1. Filter the version list by querying oc adm upgrade for actual valid targets from the OSUS graph, OR
2. Add a note in the upgrade menu: "Note: upgrades may require stepping through intermediate versions", OR
3. If the upgrade fails with "not one of the possible targets", suggest the user try the intermediate version shown in the error message.

---

## Bug #380: TUI progress box appears frozen during upgrade wait — no visible progress for up to 10 minutes

**Status:** OPEN (verified via TUI on conno - progress box shows no movement after "Upgrade command accepted")

**Severity:** LOW — Cosmetic/UX, upgrade continues correctly in background

**Location:** scripts/include_all.sh aba_wait_show() lines 1337-1339, interaction with _exec_in_tui (dialog --programbox)

**Description:** After the upgrade command is accepted by the cluster, the TUI progress box shows "[ABA] Upgrade command accepted by cluster" as the last visible line and then appears completely frozen for up to 10 minutes while aba_wait_show polls the cluster for upgrade completion.

The aba_wait_show function detects it is NOT on a TTY (because dialog --programbox captures stdout), so it uses the non-TTY path: it prints elapsed timestamps as space-separated values without newlines (e.g. "0:15 0:30 0:45"). However, dialog --programbox appears to buffer or not display incomplete lines, so the user sees nothing updating.

**Impact:** User sees a frozen progress box and cannot tell if the TUI has hung or is still working. They might kill it or think there is an error.

**Root cause:** aba_wait_show non-TTY path outputs progress without newlines (printf). dialog --programbox does not display partial lines (needs newline to scroll). The progress timestamps accumulate invisibly.

**Suggested fix:** In the non-TTY path of aba_wait_show, output each elapsed tick with a newline so that dialog --programbox shows each poll cycle as a new visible line.

---

## Bug #381: Upgrade to intermediate graph version (4.20.22) fails — signature not included by oc-mirror

**Status:** OPEN (verified via TUI on conno - upgrade from 4.20.20 to 4.20.22 accepted but fails signature verification)

**Severity:** HIGH — Cluster upgrade is blocked, user has no workaround from TUI

**Location:** Interaction between oc-mirror, scripts/day2.sh (signature application), and TUI upgrade menu

**Description:** When upgrading from 4.20.20, the TUI presents both 4.20.22 and 4.20.23 as available targets. However:

1. Direct upgrade to 4.20.23 fails because the OSUS graph only allows 4.20.20 -> 4.20.22 (Bug #379)
2. Upgrade to 4.20.22 is ACCEPTED by the cluster but then fails with:
   "ReleaseAccepted=False, Reason: RetrievePayload, unable to verify sha256:1b8a542f... against keyrings: verifier-public-key-redhat"

The root cause: oc-mirror only saved signatures for the target version (4.20.23, sha256:4a03c010c...) and the current version (4.20.20, sha256:f3d952e9a...). The intermediate version 4.20.22 (sha256:1b8a542fb...) has NO signature in signature-configmap.json.

The cluster cannot verify the 4.20.22 release image without its signature, so the upgrade is stuck.

**Verified:** mirrored-release-signatures configmap only contains 2 entries (4.20.20 and 4.20.23), not 4.20.22.

**Impact:** Complete upgrade path failure. User cannot upgrade at all — neither to 4.20.23 (graph doesn't allow direct) nor to 4.20.22 (signature missing).

**Root cause:** oc-mirror v2 does not include signatures for intermediate versions in the upgrade graph when only the target version is specified in the ISC. This is likely an oc-mirror limitation, but ABA/TUI should handle it.

**Suggested fix options:**
1. (ABA core) After sync/save with a target version, check if the OSUS graph requires intermediate hops and warn the user that those versions also need to be mirrored with their signatures
2. (TUI) When upgrade to intermediate version fails, suggest using --to-image flag to bypass signature verification
3. (ABA core) In cluster-upgrade.sh, if the upgrade fails with signature error for an intermediate version, automatically try with --force flag or suggest --to-image
4. (Documentation) Document that oc-mirror may not include signatures for all graph-reachable versions

---

## Bug #382: cluster-upgrade.sh shows misleading "admin acknowledgment" message when actual failure is signature verification

**Status:** OPEN (verified via TUI on conno - upgrade 4.20.20 -> 4.20.22 shows wrong diagnosis)

**Severity:** MEDIUM — User is misled into thinking AdminAck is the problem when it is actually missing release signatures

**Location:** scripts/cluster-upgrade.sh line 340

**Description:** After the 5-minute "Waiting for upgrade to begin" timeout, cluster-upgrade.sh runs `oc adm upgrade` and checks output for `ReleaseAccepted=False|AdminAckRequired`. If either is found, it displays:
  "[ABA] The cluster may require an admin acknowledgment before upgrading."

In this case, the output contains BOTH conditions:
- AdminAckRequired: warns about Sigstore for 4.21 (informational, not blocking the 4.20 upgrade)
- ReleaseAccepted=False with Reason: RetrievePayload: "unable to verify sha256:... against keyrings" (THE ACTUAL BLOCKER)

The script's diagnostic message points the user toward admin ack, but the real problem is missing release signatures.

**Impact:** User follows the misleading guidance (looking for admin ack procedures) instead of investigating why the signature is missing from the mirror.

**Suggested fix:** Differentiate between the two conditions in the diagnostic:
- If ReleaseAccepted=False with "unable to verify" -> print a specific message about missing release signatures, suggest re-running oc-mirror with the target version to get its signatures
- If only AdminAckRequired -> print the existing admin ack message
- Show both messages if both conditions are present, but prioritize the actual blocker

---

## Bug #383: VMware/KVM config form saves changes immediately — cancelling leaves partial state

**Status:** OPEN (confirmed via code review - same pattern as Bug #94)

**Severity:** LOW — user expectation issue (same class as Bug #94 for mirror config)

**Location:** tui/v2/tui-cluster.sh _configure_vmw_form() lines 360-442, _configure_kvm_form()

**Description:** In the VMware configuration form (_configure_vmw_form), each field edit is immediately written to vmware.conf via replace-value-conf. If the user presses "Back/Cancel" (line 351), the function returns 1 but all field changes made so far are already persisted to the project-level vmware.conf.

Only the copy to ~/.vmware.conf (line 446) is skipped on cancel. This means:
- User opens VMware form
- Changes URL and username
- Realizes they made a mistake and presses Back/Cancel
- vmware.conf already has the changed URL and username (not reverted)
- ~/.vmware.conf still has old values

This is inconsistent: either cancel should revert all changes (expected behavior), or the form should only persist on "Continue" (expected behavior).

Same pattern exists in _configure_kvm_form().

**Impact:** User may not realize their partial changes were saved. Next time they run the form, they see their "cancelled" changes.

**Related:** Bug #94 (same issue for mirror config form)

**Suggested fix:** Save field values to a temp buffer during editing. Only commit all changes to vmware.conf when user presses "Continue". On cancel, discard all temp changes.

---

## Bug #394 — ~~FIXED~~ "Prepare Upgrade" version input: no retry loop on validation failure

**Status:** FIXED (commit 306f8ac6)  
**Severity:** Low  
**Found:** 2026-06-13

### Reproduction

1. TUI CONNO main menu → "U Prepare Upgrade for Transfer"
2. Enter invalid version (e.g., `abc`) → "Invalid version format" error shown
3. Press OK on the error → returns to the main menu instead of re-prompting for the version

### Expected behavior

After dismissing the validation error, the version input dialog should re-appear (loop until valid input or Cancel). This is how the cluster name input works (it loops on invalid names).

### Root cause

`mirror_prep_upgrade()` in `tui/v2/tui-mirror.sh` doesn't loop around the version input — it validates once, shows the error, and then falls through back to the calling function.

### Suggested fix

Wrap the version input + validation in a `while :; do ... done` loop (same pattern as the cluster name input in `_cluster_page_basics`).

---

## Bug #395 — ~~FIXED~~ "Prepare Upgrade" accepts downgrade/same-version without warning

**Status:** FIXED (commit 306f8ac6)  
**Severity:** Low  
**Found:** 2026-06-13

### Reproduction

1. TUI CONNO main menu → "U Prepare Upgrade for Transfer"  
   (Shows "Current installed version: 4.20.20")
2. Enter "4.19.0" (lower than current) → accepted without warning
   Shows: "Download upgrade images (4.20.20 → 4.19.0)"
3. Enter "4.20.20" (same as current) → also accepted
   Shows: "Download upgrade images (4.20.20 → 4.20.20)"

### Expected behavior

The TUI should reject versions that are:
- Lower than the current version (OpenShift doesn't support downgrades)
- Equal to the current version (no-op, waste of time/bandwidth)

Show a clear error: "Target version must be higher than current version (4.20.20)"

### Root cause

`mirror_prep_upgrade()` only validates the version FORMAT (X.Y.Z) but does not compare it against the current installed version.

### Suggested fix

After format validation passes, compare `$target_ver` against the current version. Reject if `target_ver <= current_ver` using version comparison logic (e.g., `sort -V`).

---

## Bug #396 — ~~FIXED~~ `aba verify` hangs indefinitely when pull secret hostname doesn't match mirror.conf

**Status:** FIXED  
**Severity:** HIGH — causes indefinite hang (24h+ observed in E2E tests)  
**Found:** 2026-06-13 (from E2E pool 1 vmw-lifecycle suite)  
**Fixed:** 2026-06-13

**Files changed:**
- `scripts/reg-register.sh` — smart hostname reconciliation (root cause fix)
- `scripts/include_all.sh` — null-check guard in `check_release_image()` (defense-in-depth)
- `test/e2e/suites/suite-vmw-lifecycle.sh` — correct test ordering
- `test/e2e/suites/suite-negative-paths.sh` — coverage for all 6 reconciliation paths

### Reproduction

1. Create a named mirror: `aba mirror --name e2e-vmw-mirror`
2. Register an external registry with a hostname that differs from its pull secret:
   ```bash
   aba -d e2e-vmw-mirror register --reg-host con1.example.com --reg-port 8443 \
       --pull-secret-mirror /tmp/pool-reg-pull-secret.json --ca-cert ...
   ```
   Where the pull secret contains credentials for `registry.p1.example.com:8443` (not `con1.example.com:8443`)
3. Run `aba -d e2e-vmw-mirror verify`
4. **HANGS** after "Verifying mirror registry at https://con1.example.com:8443 ..."

User must press Enter to unblock it. Then it fails with HTTP 401.

### Root cause

In `check_release_image()`:

```bash
_b64auth=$(jq -r ".auths[\"$reg_host:$reg_port\"].auth" "$_authfile" 2>/dev/null)
_userpass=$(echo "$_b64auth" | base64 -d)
```

When `reg_host:reg_port` (e.g., `con1.example.com:8443`) has no matching entry in the pull secret, `jq -r` returns the literal string `"null"`. Then `base64 -d` of `"null"` produces 3 garbage bytes (`0x9e 0xe9 0x65`) — containing **no colon character**.

Later, in the Quay Bearer token exchange path (line 3369):

```bash
_token=$(curl -s $_curl_opts -u "$_userpass" "$_token_url" ...)
```

**`curl -u "string_without_colon"` interprets the argument as a username only and prompts interactively for the password!** The `-s` flag does NOT suppress credential prompts. The process hangs waiting for stdin.

### Suggested fix

**APPLIED — Three-layer fix:**

**Layer 1: Root cause — `scripts/reg-register.sh` (hostname reconciliation)**

The `register` command now validates the pull secret's `.auths` keys against `reg_host:reg_port`:
- Match → proceed (happy path)
- Mismatch + exactly 1 entry → auto-infer hostname from pull secret, update `mirror.conf`
- Mismatch + multiple entries → abort with clear error listing available entries
- No `reg_host` + 1 entry → infer from pull secret
- No `reg_host` + multiple entries → abort (ambiguous)

The pull secret is the source of truth for "which hostname has these credentials."

**Layer 2: Defense-in-depth — `scripts/include_all.sh` (null-check guard)**

```bash
_b64auth=$(jq -r ".auths[\"$reg_host:$reg_port\"].auth" "$_authfile" 2>/dev/null)
if [ -z "$_b64auth" ] || [ "$_b64auth" = "null" ]; then
    _release_http_code="401"
    _release_check_err="no credentials in pull secret for $reg_host:$reg_port"
    return 1
fi
_userpass=$(echo "$_b64auth" | base64 -d)
```

Catches cases where pull secret is corrupted/modified post-register.

**Layer 3: Test fix — `suite-vmw-lifecycle.sh`**

Set `reg_host` in `mirror.conf` BEFORE generating pull secret, so `password` generates credentials
keyed to the correct hostname. The `--reg-host` flag is still exercised.

**Why it surfaced now:** Commit `c282307e` (2026-06-12) added `--reg-host ${CON_HOST}` to the test
to exercise that flag, creating the mismatch. The verify rewrite to pure `curl` (2026-05-13,
`351a2577`) introduced exact hostname matching in pull secret lookup. Before that, `skopeo` handled
auth lookup differently.

---

## Bug #397 — ~~FIXED~~ VMware/KVM config fields: inconsistent quoting (shell metacharacter vulnerability)

**Status:** FIXED — commit `756c40af` now wraps ALL VMware config values in single quotes  
**Severity:** LOW — inconsistency and remaining vulnerability for shell metacharacters  
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`)

### Update

**CORRECTION**: The original report claimed spaces would corrupt values. This is WRONG.
`replace-value-conf` (in `scripts/include_all.sh`, lines 1734-1744) has auto-quoting logic
that wraps values containing spaces or `#` in single quotes automatically. So entering
"My Datacenter" would correctly produce `GOVC_DATACENTER='My Datacenter'` even without
explicit pre-quoting in the TUI code.

The REMAINING concern is:
1. **Inconsistency**: `GOVC_NETWORK` and `GOVC_PASSWORD` are explicitly pre-quoted
   (`replace-value-conf -v "'$value'"`) but other fields are not. This works but creates
   a confusing maintenance pattern.
2. **Shell metacharacters without spaces**: If a VMware resource name contains `$`, `\`,
   or backtick but NO spaces (e.g., a datastore named `store$1`), the auto-quoting would
   NOT trigger (no space, no `#`), and the value would be written unquoted — causing shell
   expansion when `vmware.conf` is sourced. This is unlikely in practice but theoretically
   possible.

### Fields affected (non-pre-quoted)

- `GOVC_DATASTORE` (line 395) — auto-quoted for spaces, unprotected for `$` without spaces
- `GOVC_DATACENTER` (line 411) — same
- `GOVC_CLUSTER` (line 419) — same
- `VC_FOLDER` (line 427) — same
- `KVM_STORAGE_POOL` (line 534) — same
- `KVM_NETWORK` (line 542) — same

### Suggested fix

For consistency and full protection, pre-quote ALL string values (matching the GOVC_NETWORK pattern):

```bash
replace-value-conf -q -n GOVC_DATASTORE -v "'$v_datastore'" -f "$conf_path"
replace-value-conf -q -n GOVC_DATACENTER -v "'$v_datacenter'" -f "$conf_path"
replace-value-conf -q -n GOVC_CLUSTER -v "'$v_cluster'" -f "$conf_path"
replace-value-conf -q -n VC_FOLDER -v "'$v_folder'" -f "$conf_path"
replace-value-conf -q -n KVM_STORAGE_POOL -v "'$k_pool'" -f "$conf_path"
replace-value-conf -q -n KVM_NETWORK -v "'$k_network'" -f "$conf_path"
```

---

## Bug #398 — ~~FIXED~~ Settings help text mentions wrong retry count values

**Status:** FIXED in commit 89fae839 (Bug #485 — updated help text to match actual toggle cycle)

**Severity:** LOW — cosmetic/documentation bug in TUI help
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-lib.sh`, line 1121)

### Description

The help text for "Retry Count" in the Settings menu states:
```
OFF = no retries, 2 or 8 = retry that many times.
```

But the actual toggle cycle (lines 1187-1193) is: 0 → 1 → 2 → 5 → 0

The help text is wrong:
- "8" is not a valid value (should be "5")
- "1" is missing from the list

### Suggested fix

Change line 1121 to:
```
OFF = no retries, 1, 2, or 5 = retry that many times.
```

---

## Bug #399 — ~~FIXED~~ Day-2 Upgrade manual entry does not reject downgrade/same-version

**Status:** FIXED (commit 9e024a64) — TUI now uses is_version_greater() to reject downgrades/same-version with a friendly dialog before passing to core.  
**Severity:** MEDIUM — user could accidentally attempt a downgrade  
**Found:** 2026-06-14 (code review confirmed)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, line 2275)

### Description

The `_day2_upgrade` function's manual version entry (line 2262-2278) validates ONLY the format (X.Y.Z regex) but does NOT check if the entered version is:
- Lower than the current installed version (downgrade — not supported)
- Equal to the current installed version (no-op)

In contrast, `mirror_prep_upgrade()` in `tui-mirror.sh` (lines 529-540) correctly rejects downgrades and same-version entries.

### Root cause

The manual entry path in `_day2_upgrade` at line 2275 only checks format:
```bash
if ! [[ "$target_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
```

It should also compare against the current cluster version before passing to `aba upgrade`.

### Suggested fix

After format validation, fetch the current cluster version and compare:
```bash
local _current_ver
_current_ver=$(aba --dir "$SELECTED_CLUSTER" version 2>/dev/null || echo "")
if [[ "$_current_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    # Same version comparison logic as mirror_prep_upgrade
    ...
fi
```

---

## Bug #400 — ~~FIXED~~ `tui_kick_isconf_regen()` leaks TUI flock FD into background subshell

**Status:** FIXED in commit 31ca4a19 — added `{ABA_TUI_FLOCK_FD}>&-` to close FD before backgrounding

**Severity:** LOW — could prevent new TUI launch until ISC generation completes
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-lib.sh`)

### Description

`tui_kick_isconf_regen()` at line 1430-1433 spawns a background subshell:
```bash
tui_kick_isconf_regen() {
    run_once -r -i "aba:isconf:generate" 2>/dev/null || true
    (cd "$ABA_ROOT" && aba_isconf_generate_start) &
}
```

This subshell inherits ALL file descriptors, including `$ABA_TUI_FLOCK_FD` (the TUI
singleton lock). Other background operations in the TUI properly close this FD:
- `_exec_in_tui` (line 626): `bash -c "$tui_cmd" {ABA_TUI_FLOCK_FD}>&-`
- `_ensure_offline_prereqs` (line 1183): `bash -lc "..." {ABA_TUI_FLOCK_FD}>&-`

But `tui_kick_isconf_regen` does NOT close it. If the ISC generation takes time (e.g.,
calling `make -sC mirror isconf`), and the TUI exits, the background process still holds
the flock. A subsequent TUI launch would see the lock as held and prompt "Another TUI is
already running."

### Suggested fix

Close the flock FD in the subshell:
```bash
tui_kick_isconf_regen() {
    run_once -r -i "aba:isconf:generate" 2>/dev/null || true
    (cd "$ABA_ROOT" && aba_isconf_generate_start) {ABA_TUI_FLOCK_FD}>&- &
}
```

---

## Bug #401 — `cluster_delete` does not warn when deleting an installing cluster

**Status:** OPEN
**Severity:** LOW — UX issue, not a data loss bug (aba delete handles running installs)
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`)

### Description

The `cluster_delete` function (line 1751) uses `select_cluster` which lists ALL clusters.
However, `select_cluster` (line 1209 in `tui-lib.sh`) only annotates clusters with
"(installed)" or "(shut down)" — it does NOT annotate clusters that appear to be
currently installing (have `iso-agent-based/auth/kubeconfig` but no `.install-complete`).

The delete confirmation dialog (line 1761-1778) says "Delete cluster 'X'? This removes
all cluster state and resources. This action cannot be undone." but gives no indication
that the cluster might currently be in the middle of installation.

A user could accidentally delete a cluster that's been installing for 30+ minutes without
realizing it's still running.

### Expected behavior

1. `select_cluster` should annotate installing clusters with "(installing)" status
2. `cluster_delete` should show an extra warning when the selected cluster appears to
   be installing (e.g., "This cluster appears to be installing. Deleting it will abort
   the installation.")

### Notes

The core `aba delete` command likely handles this correctly (stops VMs, cleans up). This
is a TUI UX issue, not a functional bug.

---

## Bug #402 — ~~FIXED~~ Dead constants `TUI2_CONNO_TAG_MONITOR` and `TUI2_DIRECT_TAG_MONITOR`

**Status:** FIXED — removed both dead constants from `tui-strings2.sh` (same fix as Bug #343)

**Severity:** TRIVIAL — dead code, no runtime impact
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-strings2.sh`)

### Description

In `tui-strings2.sh`:
- Line 172: `TUI2_CONNO_TAG_MONITOR="W"`
- Line 188: `TUI2_DIRECT_TAG_MONITOR="W"`

These constants are defined but NEVER referenced anywhere else in the TUI code (confirmed
via grep). The Monitor functionality is accessed from the Advanced submenu using a
hardcoded "F" tag (line 1803 of `tui-cluster.sh`).

Additionally, these constants use the same "W" value as `TUI2_CONNO_TAG_RECONFIGURE` and
`TUI2_DIRECT_TAG_RECONFIGURE`, creating a naming collision. While there's no runtime
conflict (since the Monitor tags are never used in menu items), this dead code could
confuse maintainers.

### Suggested fix

Either remove the unused constants or rename them if they're intended for future use.

---

## Bug #403 — Ctrl-C during command output review silently exits TUI (no confirmation)

**Status:** OPEN
**Severity:** LOW — UX inconsistency, no data loss
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-lib.sh`)

### Description

In `_exec_in_tui()` (line 632), after a command completes and the user is reviewing
the output textbox, the INT trap is set to `exit 0`:

```bash
trap 'exit 0' HUP TERM INT
```

If the user presses Ctrl-C during the review textbox (line 652-665), the INT trap fires
and the TUI exits immediately WITHOUT the normal `confirm_quit` dialog that's shown when
pressing ESC/Exit from the main menu.

This is inconsistent: all other TUI exit points use `confirm_quit` to ask "Really exit?"
before terminating, but Ctrl-C during output review bypasses this confirmation and exits
silently.

### Expected behavior

Ctrl-C during the output review should either:
1. Be ignored (like it is during command execution with `trap : INT`), or
2. Trigger `confirm_quit` before exiting

### Notes

Since the command has already completed when this happens, there's no risk of data loss
or interrupted operations. This is purely a UX consistency issue.

---

## Bug #404 — ~~FIXED~~ Tilde (`~`) in user-entered bundle path is never expanded

**Status:** FIXED in commit ea58e012 — `${bundle_path/#\~/$HOME}` applied immediately after input

**Severity:** MEDIUM — creates wrong directories, command fails silently
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-mirror.sh`, `mirror_create_bundle()`)

### Description

In `mirror_create_bundle()` (line 1262-1271), the user-entered bundle output path
is read from the dialog input but tilde (`~`) is never expanded to the home directory:

```bash
bundle_path=$(<"$_TUI_TMP")     # e.g., "~/my-bundle" (literal tilde)
...
output_dir=$(dirname "$bundle_path")   # returns "~" literally
mkdir -p "$output_dir" 2>/dev/null     # creates a dir literally named "~" in CWD!
```

When the path is later passed to `confirm_and_execute`:
```bash
cmd="aba bundle --out \"$bundle_path\""
```
The tilde is embedded inside double quotes in the `bash -c` string, preventing tilde
expansion. The `aba bundle` command receives `~/my-bundle` literally instead of
`/home/user/my-bundle`.

### Reproduction

1. In CONNO mode, select "Create Install Bundle"
2. Enter `~/my-bundle` as the output path
3. Observe: a literal `~` directory is created in `$ABA_ROOT`
4. The `aba bundle` command fails or writes to a wrong path

### Suggested fix

Expand tilde at input time:
```bash
bundle_path="${bundle_path/#\~/$HOME}"
```

---

## Bug #405 — `_tui_reject_squote` insufficient: allows backtick/dollar/backslash injection in config fields — FIXED

**Status:** FIXED (2026-06-24, commit `0803b0fa`) — now rejects `` ` ``, `$`, `\` in addition to `'`  
**Severity:** MEDIUM — shell injection via config sourcing (requires unusual input values)  
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-lib.sh`, `_tui_reject_squote()` + all callers)

### Description

The `_tui_reject_squote()` function (line 385-390) only rejects single-quote (`'`)
characters in user input:

```bash
_tui_reject_squote() {
    [[ "$1" != *"'"* ]] && return 0
    ...
}
```

This is used as the sole input validation for VMware config fields (URL, username,
datastore, network, datacenter, cluster, folder) and KVM config fields (URI, pool,
network). However, it does NOT reject other shell-dangerous characters:
- Backtick (`` ` ``) — command substitution when sourced
- Dollar sign (`$`) — variable expansion when sourced  
- Double quote (`"`) — could break quoting context
- Backslash (`\`) — escape character

When these values are saved to `vmware.conf` or `kvm.conf` by `replace-value-conf`
WITHOUT explicit single-quoting (they rely on auto-quoting which only triggers for
spaces/`#`), they end up unquoted in the config file. When later sourced by
`source <(normalize-vmware-conf)`, the shell interprets these metacharacters.

### Example attack chain

1. User enters datastore name: `` datastore`id` ``
2. `_tui_reject_squote` passes (no single quote)
3. `replace-value-conf` stores: `GOVC_DATASTORE=datastore\`id\`` (no auto-quote — no spaces)
4. When sourced: bash executes `` `id` `` as command substitution

### Suggested fix

Either:
1. Expand `_tui_reject_squote` to reject `` ` ``, `$`, `"`, `\` (rename to `_tui_reject_metachar`), OR
2. Always single-quote ALL values when saving to config (not just those with spaces)

### Relationship to Bug #397

Bug #397 covers the OUTPUT side (inconsistent quoting). This bug covers the INPUT side
(insufficient validation). Together they form a complete injection path.

---

## Bug #406 — ISC editing in TUI allows malformed YAML saves without validation

**Status:** OPEN
**Severity:** MEDIUM — can corrupt `imageset-config.yaml`, causing opaque `oc-mirror` failures
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-mirror.sh`, `mirror_view_isc()` lines 756-764)

### Description

The "Edit" option for the ImageSet Configuration file uses `dialog --editbox` to let
the user modify `imageset-config.yaml` in-place. When the user presses "Save", the
edited content is copied directly to the ISC file without any YAML validation:

```bash
# tui/v2/tui-mirror.sh line 760
cp "$_TUI_TMP" "$isconf_file"
```

If the user introduces malformed YAML (unclosed brackets, wrong indentation, typos
in field names), the corrupt file is saved. Subsequent `oc-mirror` operations (save,
sync, load) will fail with cryptic YAML parsing errors that don't point back to the
user's edit.

### Steps to reproduce

1. Start TUI in CONNO mode
2. Go to "View/Edit ImageSet Config" → "Edit"
3. Add random garbage text or break the YAML indentation
4. Press "Save"
5. Try to run "Sync images" or "Save images"
6. `oc-mirror` fails with a YAML parse error

### Expected

Before saving, validate the edited content is valid YAML (at minimum, parseable).
Show an error dialog if validation fails, with the option to re-edit or discard.

### Suggested fix

After `dlg --editbox`, before `cp`:
```bash
if ! python3 -c "import yaml; yaml.safe_load(open('$_TUI_TMP'))" 2>/dev/null &&
   ! yq '.' "$_TUI_TMP" >/dev/null 2>&1; then
    dlg --msgbox "Invalid YAML. Please fix and try again." 0 0
    continue
fi
```

---

## Bug #407 — ~~DUPLICATE OF Bug #76~~ MAC address editbox does not validate individual entries against `_valid_mac()` regex

**Status:** DUPLICATE of Bug #76 (same issue; also duplicated by #329, #419). This entry adds detail about `_valid_mac()` function.  
**Severity:** MEDIUM — invalid MACs written to `macs.conf`, causing confusing install failures  
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, `_cluster_page_iface()` lines 1340-1347)

### Description

The MAC address multi-line editbox (tag "M" in the Interfaces page) normalizes user
input (splits by commas/spaces/semicolons, strips whitespace) but does NOT validate
that each resulting entry is a valid MAC address (`XX:XX:XX:XX:XX:XX` format).

The TUI defines `_valid_mac()` at `tui/v2/tui-lib.sh` line 142:
```bash
_valid_mac() {
    [[ "$1" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}
```

But this function is **never called anywhere** — it is dead code. The editbox at
line 1344 merely normalizes:
```bash
cl_macs=$(echo "$raw" | tr ',; ' '\n' | sed '/^$/d' | tr -d ' \t')
```

No format validation is performed. Any text entered (e.g., "hello", "12345",
"aa:bb:cc") will be written to `macs.conf` and passed to the bare-metal
installation process, causing failures deep in the install flow.

### Steps to reproduce

1. Start TUI → Install Cluster wizard (bare-metal platform)
2. Go to Interfaces page → MAC Addresses (M)
3. Enter garbage text: `invalid-mac, not-a-mac, 1234`
4. Press OK → proceed through wizard
5. `macs.conf` is written with invalid entries
6. Installation fails with confusing "invalid MAC" errors from deeper tools

### Expected

Each MAC entry should be validated against `_valid_mac()` after normalization.
Invalid entries should be rejected with a clear error message.

### Suggested fix

After normalization, validate each line:
```bash
local _bad_macs=""
while IFS= read -r _mac; do
    if ! _valid_mac "$_mac"; then
        _bad_macs+="  $_mac\n"
    fi
done <<< "$cl_macs"
if [[ -n "$_bad_macs" ]]; then
    dlg --msgbox "Invalid MAC address(es):\n\n${_bad_macs}\nExpected: XX:XX:XX:XX:XX:XX" 0 0
    continue
fi
```

---

## Bug #408 — ~~FIXED~~ `_operator_sets` uses unescaped operator name as regex in grep

**Status:** FIXED in commit ea58e012 — replaced grep with awk exact-match on `$1`

**Severity:** LOW — Rare false positives for operators with regex metacharacters
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-mirror.sh`, line 1012)

### Description

In `_operator_sets()`, the loop that adds operators from a set file uses:
```bash
if grep -q "^$line[[:space:]]" "$ABA_ROOT"/.index/*-index-v${version_short} 2>/dev/null; then
```

The `$line` variable (operator name from the set file) is interpolated directly as a regex pattern without escaping. Operator names containing regex metacharacters (`.`, `+`, `*`, `?`) would be misinterpreted.

### Steps to reproduce

1. Create a custom operator set file with an operator name containing regex metacharacters
2. Go to TUI → Select Operators → Operator Sets → select the custom set
3. The grep may match wrong operators in the index

### Expected

Use `grep -qF` (fixed string) or escape the pattern.

---

## Bug #409 — ~~FIXED~~ `replace-value-conf` existence check uses unescaped values as regex

**Status:** FIXED — commit `2cda50c0` added `grep -F` (fixed string) check before regex match  
**Severity:** LOW — False positives for values containing regex metacharacters  
**Found:** 2026-06-14 (code review)  
**Component:** Core (`scripts/include_all.sh`, line 1756)

### Description

In `replace-value-conf()`, the "already exists" check at line 1756:
```bash
grep -q "^${name}=${_write_value}[[:space:]]*\(#.*\)\?$" "$f"
```

Both `$name` and `$_write_value` are used directly as regex patterns without escaping. If either contains regex metacharacters (`.`, `+`, `*`, `(`), the check may produce false positives — concluding a value "already exists" when it doesn't literally match.

### Steps to reproduce

1. Set `reg_path=/ocp4/openshift4` in mirror.conf (`.` matches any char in regex)
2. Try to update it to `/ocp4Xopenshift4`
3. The grep check could incorrectly say "already exists"

### Expected

Escape regex metacharacters in the values, or use `grep -F` for the literal comparison.

---

## Bug #410 — ~~DUPLICATE OF Bug #337~~ Operator search/view-basket unchecking bypasses ref-counting

**Status:** DUPLICATE of Bug #337 (same issue; also duplicated by #344)  
**Severity:** MEDIUM — Silently removes shared operators that should remain in basket  
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-mirror.sh`, lines 1094-1101 and 1152-1156)

### Description

The operator basket (`OP_BASKET`) uses reference counting: `_operator_sets()` increments the count when adding from a set, and decrements when removing a set. However, `_operator_search()` (line 1098-1099) and `_operator_view_basket()` (line 1152-1156) both use `unset 'OP_BASKET[$op]'` — completely ignoring the reference count.

If an operator is shared by two operator sets (ref count = 2) and the user unchecks it in Search Results or View Basket, it's entirely removed instead of decremented to 1.

### Steps to reproduce

1. TUI → Select Operators → Operator Sets → check "ocp" and "virt" (share operators)
2. Go to Search → search for a shared operator → uncheck it → it's completely removed
3. Go back to Sets → uncheck "ocp" → removal loop tries to decrement a non-existent key

### Expected

Search/View Basket should decrement ref count instead of unsetting, or only allow removal if ref count ≤ 1.

---

## Bug #411 — ~~DUPLICATE OF Bug #23~~ `_OP_BASKET_DIRTY` set unconditionally after operator submenu visits

**Status:** DUPLICATE of Bug #23 (same issue; also duplicated by #73, #101, #342)  
**Severity:** LOW — Unnecessary ISC regeneration (performance, not correctness)  
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-mirror.sh`, lines 892-903)

### Description

In `_operator_menu()`, `_OP_BASKET_DIRTY=true` and `_persist_operator_basket` are called unconditionally after returning from any operator submenu (Sets, Search, View Basket) — even if the user just viewed and pressed Back without changes. This triggers unnecessary ISC regeneration in the background.

### Expected

`_OP_BASKET_DIRTY` should only be set when the basket actually changes.

---

## Bug #412 — ~~INVALID~~ `_day2_status` "Pending Pods" fallback is actually reachable

**Status:** INVALID — `set -o pipefail` (abatui2.sh line 39) makes the `|| echo` reachable  
**Severity:** N/A  
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`)

### Why invalid

The TUI sets `set -o pipefail` globally (abatui2.sh line 39). With pipefail, the pipeline's exit code reflects the failing `oc` command even though `awk` exits 0. The `|| echo "(Cluster API unreachable)"` fallback DOES fire when `oc` fails. Original analysis incorrectly assumed pipefail was not set.

---

## Bug #413 — Bundle path input not validated (no `_tui_reject_squote`, no path check) — FIXED

**Status:** FIXED (2026-06-24, commit `0e379c40`) — added `_tui_reject_squote` before path use  
**Severity:** MEDIUM — Command quoting breakage via crafted bundle path  
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-mirror.sh`, lines 1262-1266)

### Description

In `mirror_create_bundle()`, the user-entered bundle path has no validation:
- No `_tui_reject_squote` call
- No `_valid_abs_path` check
- Path is embedded in the command with escaped double quotes: `"aba bundle --out \"$bundle_path\""`

A path containing a double quote (e.g., `/tmp/foo"bar`) breaks the `bash -c` quoting. The metacharacter defense doesn't catch `"` characters.

### Steps to reproduce

1. TUI → CONNO menu → Create Install Bundle
2. Enter path: `/tmp/foo"bar`
3. Press Next → command execution fails with bash parsing error

### Expected

Validate the bundle path with `_tui_reject_squote` and `_valid_abs_path` before using it in the command.

---

## Bug #414 — VMware config form shows rejected value in menu display after `_tui_reject_squote`

**Status:** OPEN
**Severity:** LOW — Cosmetic UX confusion, no data corruption
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, lines 360-427 in `_configure_vmw_form`)

### Description

In `_configure_vmw_form()`, when a user enters a value containing a single quote (rejected by `_tui_reject_squote`), the in-memory variable (e.g., `v_url`, `v_network`) is already updated BEFORE the rejection check:

```bash
v_url=$(<"$_TUI_TMP")
_tui_reject_squote "$v_url" || continue
```

After `continue`, the form menu redraws showing the rejected value (from the in-memory variable), even though it was NOT persisted to `vmware.conf`. This confuses the user — the display shows a value that doesn't match the file.

The same pattern exists for all fields in `_configure_vmw_form` (U, N, D, W, C, L, F) and in `_configure_kvm_form`.

### Steps to reproduce

1. TUI → Advanced → Platform Settings → VMware
2. Edit the URL field → enter `test'url` (with single quote)
3. Error dialog appears: "Input cannot contain single-quote..."
4. Menu redraws showing `vCenter/ESXi URL: test'url` in the display

### Expected

After rejection, restore the in-memory variable to its previous value, or defer the assignment until after validation passes.

---

## Bug #415 — `_configure_vmw_form` ignores `~/.vmware.conf` on fresh init (Advanced path)

**Status:** OPEN
**Severity:** LOW — User must reconfigure VMware when using Advanced → Platform Settings after reset
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, lines 310-312)

### Description

In `_configure_vmw_form()` (opened via Advanced → Platform Settings), when `$ABA_ROOT/vmware.conf` doesn't exist:

```bash
if [[ ! -s "$conf_path" ]]; then
    cp "$ABA_ROOT/templates/vmware.conf" "$conf_path"
fi
```

It copies the BLANK template, ignoring `~/.vmware.conf` (which may have cached values from a previous session saved at line 446).

In contrast, the cluster wizard path (`_gate_platform_config` at lines 242-261) DOES check `~/.vmware.conf` and offers to reuse it.

### Steps to reproduce

1. Configure VMware via TUI → values saved to both `$ABA_ROOT/vmware.conf` AND `~/.vmware.conf`
2. Run `aba reset --force` → deletes `$ABA_ROOT/vmware.conf`
3. Start TUI → Advanced → Platform Settings → VMware
4. Form shows blank/template values instead of cached `~/.vmware.conf` values

### Expected

`_configure_vmw_form` should check `~/.vmware.conf` (or `~/.kvm.conf` for KVM) first and offer to reuse it, similar to `_gate_platform_config`.

---

## Bug #383 — ~~DUPLICATE~~ VERIFIED: VMware config changes persisted before user confirms

**Status:** DUPLICATE of Bug #383 above (re-verification entry)  
**Severity:** MEDIUM — Documented as intentional "save-on-edit" in SPEC.md but inconsistent with Back/Cancel UX  
**Found:** Previously reported  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, `_configure_vmw_form`)

### Verification

Live test on conno host confirmed:
1. Opened VMware config form (Advanced → Platform Settings → VMware)
2. Changed Network from "Lab Network" to "VM Network" → pressed OK on input dialog
3. Checked `vmware.conf` BEFORE pressing Continue → value was already persisted
4. Pressed Back to exit the form
5. `vmware.conf` retained the change despite "cancelling"

The SPEC.md (line 245) documents this as intentional "save-on-edit" for mirror config. However, the VMware form's Back button suggests cancellation, creating UX confusion.

---

## Bug #416 — ~~FIXED~~ VERIFIED: No reserved-name check for cluster names (collision with ABA directories)

**Status:** FIXED — `_valid_cluster_name()` now rejects reserved ABA directory names (mirror, scripts, cli, etc.)  
**Severity:** MEDIUM — Can create unmanageable cluster state  
**Found:** 2026-06-14 (code review + live test)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, lines 912-928)

### Description

The cluster name validation at line 923 only checks DNS label format:
```bash
if [[ ${#input} -gt 63 || ! "$input" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]]; then
```

There is NO check against reserved directory names. A user can create a cluster named "mirror", "templates", "scripts", "tui", "build", "test", "ai", etc.

For "mirror" and "templates" specifically, `list_cluster_dirs()` (tui-lib.sh:856) explicitly skips these:
```bash
[[ "$dir" == "mirror" || "$dir" == "templates" ]] && continue
```

So a cluster named "mirror" would:
1. Write `cluster.conf` into the existing `mirror/` directory (conflicting with mirror registry data)
2. Never appear in any cluster selection dialog (invisible to the user)
3. Cannot be deleted, managed, or selected via the TUI

### Live verification

1. TUI → Install Cluster → Edit cluster name → entered "mirror" → accepted without error
2. The wizard page showed "Cluster name: mirror" ready to proceed
3. If the user continues to install, it would write into `~/aba/mirror/cluster.conf`

### Expected

Reject cluster names that collide with existing ABA directories. At minimum: "mirror", "templates", "scripts", "tui", "test", "build", "ai", "catalogs", "cli", "tools", "ocp", "images", "docs", "rpms", "bundles", "devel", "others".

---

## Bug #417 — Pull secret "Use existing" bypasses JSON validation without warning

**Status:** OPEN
**Severity:** LOW-MEDIUM — User proceeds with invalid pull secret, later operations fail
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-direct.sh`, lines 199-218)

### Description

In `_direct_pull_secret()`, the JSON validation at line 199 uses python3 to check the file:
```bash
if [[ -f "$ps_file" ]] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ps_file" >/dev/null 2>&1; then
    return 0  # Valid — skip
fi
```

If validation FAILS (file exists but is not valid JSON, or python3 is unavailable), the user is shown:
```
"Pull secret found at: ~/.pull-secret.json"
  U) Use existing pull secret
  N) Enter a new pull secret
```

Selecting "Use existing" (line 218: `[[ "$choice" == "U" ]] && return 0`) proceeds without any warning that the file failed validation. Subsequent operations (create-containers-auth.sh, oc-mirror) will fail when parsing the invalid JSON.

### Steps to reproduce

1. Create an invalid pull-secret file: `echo "not json" > ~/.pull-secret.json`
2. Start TUI, enter the wizard
3. Dialog shows "Pull secret found at: ~/.pull-secret.json"
4. Select "Use existing pull secret"
5. Wizard proceeds — no warning about invalid JSON
6. First operation requiring pull secret fails with cryptic JSON parse error

### Expected

Either:
- Warn the user that JSON validation failed: "Pull secret file appears invalid. Use anyway?"
- Or re-validate on "Use existing" and block with an error if invalid

---

## Bug #418 — ~~DUPLICATE OF Bug #62~~ VM resource validation does not enforce OpenShift minimums stated in Help text

**Status:** DUPLICATE of Bug #62 (same issue; also duplicated by #100, #444)  
**Severity:** LOW — TUI accepts values that will fail at install time  
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, lines 1401-1408, 1420-1480)

### Description

The Help text for the VM Resources page states:
```
• Master CPUs: vCPU count per control-plane VM (min 4)
• Master Memory: RAM in GB per control-plane VM (min 16)
• Worker CPUs: vCPU count per worker VM (standard only, min 2)
• Worker Memory: RAM in GB per worker VM (standard only, min 8)
```

But the actual validation (lines 1427, 1442, 1457, 1472) only checks `val -lt 1`:
```bash
if [[ -n "$val" ]] && { [[ ! "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]]; }; then
```

This allows entering 1 CPU or 1GB RAM for masters, which would cause cluster install failure.

### Steps to reproduce

1. TUI → Install Cluster → advance to VM Resources page
2. Edit Master CPUs → enter "2" → accepted (should warn: min 4)
3. Edit Master Memory → enter "4" → accepted (should warn: min 16)

### Expected

Validate against documented minimums: masters need ≥4 CPUs and ≥16GB RAM, workers need ≥2 CPUs and ≥8GB RAM. At minimum, show a warning when values are below recommended.

---

## Bug #419 — ~~DUPLICATE OF Bug #76~~ MAC address input (bare-metal) accepts any text without validation

**Status:** DUPLICATE of Bug #76 (same issue; also duplicated by #329, #407)  
**Severity:** LOW — Invalid MACs accepted by TUI, fail later at VM creation  
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, lines 1341-1346)

### Description

The MAC address input (page 3, bare-metal platform) accepts and normalizes any input:
```bash
cl_macs=$(echo "$raw" | tr ',; ' '\n' | sed '/^$/d' | tr -d ' \t')
```

No validation is performed on the MAC format. Invalid entries like "hello", "12:34" (too short), or "ZZ:ZZ:ZZ:ZZ:ZZ:ZZ" (invalid hex) are accepted.

The core script `create-agent-config.sh` (line 139) uses `grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'` to extract valid MACs — so invalid entries would be silently dropped, but the TUI would show "3 entered" when only 1 is actually valid.

### Expected

Validate each MAC entry against `^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$` and warn about invalid entries.

---

## Bug #420 — ~~FIXED~~ HIGH: TUI progressbox mode auto-answers admin-ack safety gate during upgrade

**Status:** FIXED (commit 9e024a64) — TUI now runs _upgrade_preflight_check() before launching upgrade. If Upgradeable=False detected, shows interactive dialog (defaulting to Cancel) before proceeding.  
**Severity:** HIGH — Safety check bypassed, upgrade proceeds without human acknowledgment  
**Found:** 2026-06-14 (code review + live verification)  
**Component:** TUI v2 (`tui/v2/tui-lib.sh` line 610) + Core (`scripts/cluster-upgrade.sh` line 260)

### Description

Commit `072fe0f8` added a safety gate in `cluster-upgrade.sh` for when the cluster reports `Upgradeable=False`:

```bash
ask "Continue with upgrade (only if you have resolved the above)" || exit 1
```

The commit message explicitly states: "ABA must never auto-apply admin-ack patches — the gate varies per version."

However, `_exec_in_tui()` at line 610 ALWAYS appends `--yes` to commands:
```bash
[[ "$tui_cmd" != *" --yes"* ]] && tui_cmd="$tui_cmd --yes"
```

And `--yes` in `aba.sh` (line 807) sets `export ASK_OVERRIDE=1`, which causes `ask()` to auto-answer YES for ALL prompts, including this safety gate.

### Impact

When a user upgrades via TUI → "Run in TUI" mode:
1. The upgrade command runs with `--yes`
2. Cluster reports `Upgradeable=False` (requires admin acknowledgment)
3. The `ask` prompt is silently auto-answered YES
4. Upgrade proceeds without the user reading gate-specific instructions
5. This can break the cluster or leave it in an unsupported state

### Affected flows

- Day-2 → Upgrade → any version selection → "Run in TUI"
- Any upgrade where the cluster has a gate (e.g., 4.20→4.21 sigstore migration)

### NOT affected

- "Run in Terminal" mode (when `ask` is not set to "yes" in aba.conf) — the prompt is interactive

### Suggested fix

Add a `ask_critical()` or `ask_force()` function that ignores `ASK_OVERRIDE` for safety-critical prompts. Alternatively, don't use `ask()` for the admin-ack check — use a direct `read` that cannot be overridden.

---

## Bug #399 — ~~FIXED~~ VERIFIED: TUI upgrade manual entry does not reject downgrades/same-version

**Status:** FIXED (commit 9e024a64) — See primary Bug #399 entry above.  
**Severity:** LOW — CLI catches the error, but user goes through execution mode picker first  
**Found:** Previously reported  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, lines 2301-2318)

### Verification

1. Day-2 → Upgrade → select sno cluster → select "Manual entry"
2. Entered "4.20.19" (lower than installed 4.20.20) → accepted by TUI
3. TUI proceeded to execute `aba --dir sno upgrade --to 4.20.19`
4. CLI correctly rejected it: "Error: Target version 4.20.19 is not higher than current version 4.20.20"
5. User sees "FAILED (exit code: 1)" — but the TUI should have caught this earlier

The `mirror_prep_upgrade()` function (line 529-540) HAS downgrade validation, but `_day2_upgrade()` does NOT.

---

## Bug #414 — ~~NOT A BUG~~ VERIFIED: Kubeadmin password shown in plaintext in TUI status textbox

**Status:** NOT A BUG — showing the password in status output is intentional (same as `aba info` on the CLI)

**Severity:** LOW — Security/UX concern; password visible to shoulder-surfers
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, `_day2_status`)

### Verification

1. Day-2 → Cluster Status → select sno cluster
2. Status textbox shows full `aba info` output including:
   ```
   Login to the console with user: "kubeadmin", and password: "9vJ4y-LnaPP-yBGtL-p2HAV"
   ```
3. Password is in a dialog textbox — persists until user dismisses it
4. Anyone looking at the screen can read the password

### Expected

Either mask the password (show `***`) or omit it from the status display. The user can always run `aba info` from the terminal if they need the password.

---

## Bug #421 — ~~FIXED~~ VERIFIED LIVE: Day-2 Help text inconsistency after "Configure OperatorHub" rename

**Status:** FIXED — help text updated from "Resources" to "Configure OperatorHub"

**Severity:** LOW — Help text says "Resources" but menu says "Configure OperatorHub"
**Found:** 2026-06-14 (live TUI test)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, line 2051)

### Description

Commit `f6784ff3` renamed the Day-2 menu item from "Cluster Resources (OperatorHub, oc-mirror)" to "Configure OperatorHub (after mirror load/sync)". However, the Help text for the Day-2 menu still says:

```
• Resources: applies all Day-2 config (IDMS, CatalogSources, OperatorHub, etc.)
```

Should say:

```
• Configure OperatorHub: applies Day-2 config (IDMS, CatalogSources, OperatorHub, etc.)
```

### Verified

Pressed Help button in Day-2 menu → help displays the old "Resources:" label.

### Suggested fix

Update the help text string at `tui-cluster.sh` line 2051.

---

## Bug #422 — ~~FIXED~~ `_cluster_page_vm` checks global `$ABA_ROOT/macs.conf` instead of per-cluster path

**Status:** FIXED in commit 89fae839 (Bug #315 — same fix as Bug #384)

**Severity:** LOW — Display bug: "(from macs.conf)" hint rarely shows for bare-metal
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, line ~1372)

### Description

In `_cluster_page_vm()`, the `mac_info` display is computed ONCE before the while loop:

```bash
local mac_info=""
[[ -f "$ABA_ROOT/macs.conf" ]] && mac_info=" (from macs.conf)"
```

This checks for a global `$ABA_ROOT/macs.conf`, but the actual per-cluster `macs.conf` lives in `$ABA_ROOT/$cl_name/macs.conf`. Since the global file rarely exists, the "(from macs.conf)" annotation almost never appears even when the cluster directory does have a `macs.conf`.

### Impact

Users on bare-metal platform don't see the helpful hint that MACs will come from `macs.conf`, even when the file exists in the correct location.

### Suggested fix

Check `$ABA_ROOT/$cl_name/macs.conf` instead. Also, update inside the while loop so it reflects the current cluster name if it changes during the wizard.

---

## Bug #423 — ~~DUPLICATE OF Bug #358~~ `_TUI_RETRY_COUNT` inconsistent fallback defaults (1 vs 2)

**Status:** DUPLICATE of Bug #358 (same issue: `_TUI_RETRY_COUNT` uses inconsistent default values 1 vs 2)  
**Severity:** VERY LOW — Cosmetic: dead code with mismatched defaults  
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-lib.sh`, lines 299, 1111, 1154, 1182, 1263)

### Description

`_TUI_RETRY_COUNT` is initialized to `1` at line 299:
```bash
_TUI_RETRY_COUNT="${_TUI_RETRY_COUNT:-1}"
```

But two fallback values use `2` instead of `1`:
- Line 1111 (`_tui_settings_menu_retry`): `local current="${_TUI_RETRY_COUNT:-2}"`
- Line 1182 (`_tui_settings_menu`): `local rc_val="${_TUI_RETRY_COUNT:-2}"`

Since the variable is always initialized to 1, these `:-2` fallbacks are unreachable dead code. But they create confusion for anyone reading/maintaining the code — it looks like the default might be 2 when it's actually 1.

### Impact

None (purely cosmetic — fallbacks never trigger).

### Suggested fix

Change `:-2` to `:-1` at lines 1111 and 1182 for consistency, or remove the fallbacks entirely since the variable is always initialized.

---

## Bug #424 — ~~FIXED~~ CONNO Help text outdated: mentions "Load" (not in menu), omits "Prepare Upgrade"

**Status:** FIXED in commit 7312797d (Bug #469 — help text rewritten to match actual menu)

**Severity:** LOW — Help text misleads users about available menu items
**Found:** 2026-06-14 (live TUI test + code review)  
**Component:** TUI v2 (`tui/v2/abatui2.sh`, lines 620-643)

### Description

The CONNO main menu Help text has three issues:

1. **Mentions "Load" which is NOT a CONNO menu item** (line 631): `"Load — disk-to-mirror (d2m): load saved images into registry"`. The "Load" action only exists in DISCO mode. Users reading this help will look for a "Load" option that doesn't exist.

2. **Omits "Prepare Upgrade for Transfer"** which IS in the CONNO menu (tag `U`). This was a recently-added feature that was not documented in the Help text.

3. **Uses "resources" instead of "Configure OperatorHub"** (line 636): `"Day-2 — post-install config (resources, NTP, update service, etc.)"`. This is the same outdated terminology as Bug #421, but in a different location (CONNO main help vs. Day-2 submenu help).

The same "resources" terminology issue also appears in:
- DISCO help text (`tui/v2/tui-disco.sh`, line 233): `"Day-2 — apply cluster resources, NTP, update service, etc."`
- DIRECT help text (`tui/v2/tui-direct.sh`, line 745): `"Day-2 — post-install config (resources, NTP, update service, etc.)"`

### Steps to reproduce

1. Launch TUI in CONNO mode (partially disconnected)
2. Press Tab twice to reach Help button, then Enter
3. Read the help text — "Load" is listed but doesn't exist in the menu; "Prepare Upgrade" is not listed but exists

### Impact

Users get incorrect information about available menu items, potentially wasting time looking for "Load" and not discovering "Prepare Upgrade for Transfer".

### Suggested fix

1. Remove the "Load" bullet from CONNO help (it's DISCO-only)
2. Add bullet for "Prepare Upgrade for Transfer"
3. Replace "resources" with "Configure OperatorHub" in all three mode help texts

---

## Bug #425 — ~~DUPLICATE OF Bug #338~~ Platform selector immediately persists `platform` change without confirmation

**Status:** DUPLICATE of Bug #338 (same issue; also duplicated by #360, #378, #439)  
**Severity:** MEDIUM — Accidental platform change with no undo  
**Found:** 2026-06-14 (live TUI test + code review)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, lines 1933-1945)

### Description

In the Advanced → Platform Settings submenu, selecting a platform type (V/K/M) immediately writes the new `platform` value to `aba.conf` via `replace-value-conf` — BEFORE showing the configuration form. If the user accidentally selects the wrong platform and then presses "Back" to exit the form, the platform is already changed permanently.

Observed behavior:
1. Started with `platform=vmw`
2. Entered Platform Settings (default was "V - VMware")
3. Pressed Down (moved to K - KVM) and Enter
4. Platform immediately changed to `kvm` in `aba.conf` (confirmed by menu showing "Platform Settings (kvm)")
5. Pressed "Back" to exit KVM form without making any changes
6. Platform is now `kvm` — not restored to `vmw`

Code at lines 1934-1942:
```bash
V)
    replace-value-conf -q -n platform -v vmw -f "$ABA_ROOT/aba.conf"
    platform=vmw
    _configure_platform_file "vmware.conf" "VMware/ESXi"
    ;;
K)
    replace-value-conf -q -n platform -v kvm -f "$ABA_ROOT/aba.conf"
    platform=kvm
    _configure_platform_file "kvm.conf" "KVM/libvirt"
    ;;
```

### Steps to reproduce

1. Start with `platform=vmw` in `aba.conf`
2. TUI → Advanced → Platform Settings
3. Select "K - KVM/libvirt" (or any different platform)
4. Press "Back" in the configuration form
5. Observe the Advanced menu now shows "Platform Settings (kvm)" — platform changed!

### Impact

Users who accidentally select the wrong platform get their `aba.conf` modified immediately. Since this also affects cluster installation (VMs would be created on the wrong hypervisor), this could lead to confusing failures later.

### Suggested fix

Don't persist `platform` to `aba.conf` until the user presses "Continue" (OK) in the platform configuration form. Save the old platform value and restore it if the form is cancelled.

---

## Bug #426 — Mirror config form allows clearing required fields to empty (no validation)

**Status:** OPEN (code review)
**Severity:** LOW — Could cause confusing install failures later
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-mirror.sh`, lines 221-241)

### Description

In the mirror configuration form (`_mirror_config_menu_loop`), field validation only runs for NON-EMPTY values. If a user clears a field (enters empty string and presses OK), validation is skipped and the empty value is persisted to `mirror.conf`.

Code pattern (hostname example, line 222-229):
```bash
m_host=$(<"$_TUI_TMP")
_tui_reject_squote "$m_host" || continue
if [[ -n "$m_host" ]] && ! _valid_fqdn "$m_host" && ! _valid_ip "$m_host"; then
    # ... invalid message ...
    continue
fi
replace-value-conf -q -n reg_host -v "$m_host" -f "$mcf"
```

The `[[ -n "$m_host" ]]` condition means: if hostname is empty, skip validation entirely and write the empty value.

Additionally, for LOCAL installs, the "Next" button (rc=3) does NOT validate that hostname is set (only REMOTE installs validate at line 196). So a local install can proceed with an empty `reg_host`.

Same pattern applies to Port (line 236): empty port bypasses `_valid_port` and gets persisted.

### Impact

If a user accidentally clears the hostname or port field, the empty value is written to `mirror.conf`. Later, when `aba install` runs, it would fail with a confusing error because the registry needs a hostname for certificate generation.

### Suggested fix

Add validation before `replace-value-conf`: reject empty values for required fields (reg_host, reg_port), or at minimum show a warning. Also add a hostname check to the "Next" button for local installs (similar to the existing remote check).

---

## Bug #427 — ~~DUPLICATE OF Bug #296~~ "Exiting..." message displayed before silent fallback to DISCO mode

**Status:** DUPLICATE of Bug #296 (same issue; also duplicated by #334, #376)  
**Severity:** LOW — Confusing UX but no functional impact  
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/abatui2.sh`, lines 448-458)

### Description

When the TUI starts on a host without internet and without the `.bundle` flag, mode detection (`_detect_mode`) shows a large error msgbox saying "Internet Access Required" with the text ending in "Exiting..." (line 450).

However, after the user dismisses this msgbox, the code DOES NOT necessarily exit. Lines 453-455 check `_validate_payload()`, and if the payload is valid (ISC, CLI tools, registry files, and tar archives all exist), the TUI continues in DISCO mode.

The user sees "Exiting..." and then is surprised when the TUI doesn't exit but instead enters DISCO mode.

### Scenario

1. User has previously used `aba save` on this host (creating tar archives in `mirror/data/`)
2. User disconnects from internet
3. User starts the TUI
4. Error dialog shows: "Internet Access Required ... Exiting..."
5. User dismisses the dialog
6. TUI continues in DISCO mode (does NOT exit!)

### Suggested fix

Split the message into two cases:
- If `_validate_payload` will fail: show "Exiting..." and exit
- If `_validate_payload` will succeed: show "Internet unavailable. Switching to Disconnected mode." and continue

Or: move the `_validate_payload` check BEFORE showing the error dialog, so the "Exiting..." message is only shown when the TUI actually will exit.

---

## Bug #428 — ~~DUPLICATE OF Bug #294~~ DISCO mode `_apply_mode_connection` does not reset "proxy" to "mirror"

**Status:** DUPLICATE of Bug #294 (same issue; also duplicated by #327, #375)  
**Severity:** MEDIUM — Could cause cluster install failure in DISCO mode  
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, lines 698-702)

### Description

The `_apply_mode_connection()` function (called at line 704 during `cluster_install_flow`) adjusts the `cl_connection` variable based on the current mode. In DISCO mode (line 700-701):

```bash
elif [[ "$_TUI_MODE" == "DISCO" ]]; then
    [[ "$cl_connection" == "direct" ]] && cl_connection="mirror"
fi
```

This only resets "direct" to "mirror". It does NOT reset "proxy" to "mirror".

### Scenario

1. User is in CONNO mode, starts cluster install wizard
2. On the Interfaces page, toggles connection to "proxy"
3. Goes back to main menu (values are cached in `_cl_connection`)
4. Navigates: Advanced → Switch to Fully Disconnected (DISCO)
5. In DISCO mode, starts Install Cluster again
6. `_apply_mode_connection()` runs: `"proxy" != "direct"` → no reset
7. `cl_connection` remains "proxy" 
8. If user doesn't manually toggle on Interfaces page, "proxy" is persisted to `cluster.conf`
9. Cluster install fails because proxy is unreachable in disconnected environment

### Contrast with Interface page

The toggle logic on the Interfaces page (lines 1315-1321) correctly enforces "mirror" for ALL non-mirror values in DISCO mode. But `_apply_mode_connection()` is called earlier (at wizard entry) and doesn't have the same check.

### Suggested fix

```bash
elif [[ "$_TUI_MODE" == "DISCO" ]]; then
    [[ "$cl_connection" != "mirror" ]] && cl_connection="mirror"
fi
```

---

## Bug #429 — ~~DUPLICATE OF Bug #167 / Bug #298~~ DIRECT mode Help text mentions "Monitor Cluster" as top-level step (hidden under Advanced)

**Status:** DUPLICATE of Bug #167 (same issue; also duplicated by #298)  
**Severity:** LOW — Misleading help text  
**Found:** 2026-06-14 (code review)  
**Component:** TUI v2 (`tui/v2/tui-direct.sh`, lines 738-750)

### Description

The DIRECT mode main menu Help text (shown when pressing Help in the Fully Connected menu) includes:

```
Workflow:
  1. Install Cluster — configure, review, and provision OpenShift
  2. Monitor Cluster — track install progress until completion
  3. Day-2 — post-install config (resources, NTP, update service, etc.)
```

Two issues:

1. **"Monitor Cluster" is NOT a top-level menu item in DIRECT mode.** It's only available under Advanced → "Monitor Cluster Installation (re-attach)" (tag "F"). The help text presents it as step 2 of the main workflow, but a user looking at the menu won't find it at the top level.

2. **Uses outdated "resources" terminology** — should say "Configure OperatorHub" instead of "resources" (same issue as Bug #424).

### Additional instances

The same "resources" terminology issue also exists in:
- DISCO mode Help text (`tui/v2/tui-disco.sh`, lines 226-243)
- CONNO mode Help text (`tui/v2/abatui2.sh`, lines 620-643, also Bug #424)

### Suggested fix

Update the DIRECT Help text to:
```
Workflow:
  1. Install Cluster — configure, review, and provision OpenShift
  2. Day-2 — post-install config (Configure OperatorHub, NTP, update service, etc.)

Monitor Cluster is available under Advanced for re-attaching to in-progress installs.
```

---

## Bug #430 — ~~DUPLICATE OF Bug #177 / Bug #424~~ CONNO Help text mentions "Load" operation which doesn't exist in the CONNO menu

**Status:** DUPLICATE of Bug #177 (same issue; also duplicated by #297). Bug #424 is the comprehensive report covering this + additional CONNO Help text issues.  
**Severity:** LOW — Help text refers to a non-existent menu item  
**Found:** 2026-06-14 (code review of `tui/v2/abatui2.sh` lines 620-643)  
**Component:** TUI v2 (`tui/v2/abatui2.sh`, lines 628-631)

### Description

The CONNO main menu Help text (accessed via Help button) includes:

```
Transfer (uses oc-mirror):
  • Sync — mirror-to-mirror (m2m): push images directly to registry
  • Save — mirror-to-disk (m2d): download images to local archive
  • Load — disk-to-mirror (d2m): load saved images into registry
  • Install Bundle — create a portable bundle (tar) for USB transfer
```

**"Load" does NOT exist in the CONNO menu.** The CONNO menu has:
- Y: Sync images to mirror
- S: Save images to disk
- B: Create Install Bundle
- U: Prepare Upgrade for Transfer

"Load" is a DISCO-only operation (loading image archives into the mirror on a disconnected host). Including it in CONNO help is confusing — a user will look for "Load" and not find it.

Additionally, the Help text omits "Prepare Upgrade for Transfer" (U) which IS in the CONNO menu.

**Note:** This overlaps with Bug #424 but provides additional detail on the "Load" mention.

### Suggested fix

Remove "Load" from the CONNO help text and add "Prepare Upgrade for Transfer":

```
Transfer (uses oc-mirror):
  • Sync — push images directly to registry (m2m)
  • Save — download images to local archive (m2d)
  • Prepare Upgrade — save newer images for disconnected upgrade
  • Install Bundle — create a portable bundle (tar) for USB transfer
```

---

## Bug #431 — ~~DUPLICATE OF Bug #57~~ TUI in-memory state stale after `aba reset --force` from Advanced menu

**Status:** DUPLICATE of Bug #57 (same issue; #57 also references #77). All describe stale TUI state after `aba reset --force`.  
**Severity:** MEDIUM — Confusing post-reset behavior, potential for wrong operations  
**Found:** 2026-06-14 (code review of `tui/v2/tui-cluster.sh` lines 1907-1913)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, lines 1912-1913)

### Description

When the user runs "Reset ABA" from the Advanced menu (`tui_advanced_menu`), the command `aba reset --force` is executed which destroys ALL configuration files (`aba.conf`, `mirror.conf`, cluster directories, etc.). After the reset completes, the function simply `return 0` to the calling menu.

However, the TUI's in-memory state is NOT refreshed:
- `ocp_version`, `ocp_channel`, `platform` — still hold the old (now deleted) values
- `OP_BASKET` — still contains operators from the old config
- `_TUI_REG_VENDOR` — still holds the old mirror vendor setting
- `_TUI_MODE` — unchanged (but the detection criteria have been reset)
- Title bar — still shows old version/channel (e.g., "stable 4.20.20")
- Mirror status cache — still shows "installed" / "synced"

### Impact

1. User runs Reset, TUI returns to main menu still showing "stable 4.20.20" and "mirror ready"
2. User tries "Install Cluster" — the wizard uses stale `platform`, `ocp_version`, etc.
3. `_cluster_generate_defaults` calls `aba cluster --name ... --platform vmw` but vmware.conf no longer exists
4. `_direct_config_complete()` returns true (checks in-memory vars) even though aba.conf is gone

### Steps to reproduce

1. Start TUI in CONNO mode with configured aba.conf (version 4.20.20, platform=vmw)
2. Go to Advanced → "Reset ABA (full clean)"
3. Confirm the reset
4. After reset completes, observe: title bar still shows "stable 4.20.20"
5. Press "Install Cluster" — wizard shows old platform/version

### Suggested fix

After `aba reset --force` succeeds, the TUI should either:
1. Exit with a message: "ABA has been reset. Please restart the TUI."
2. OR: re-source all config, clear OP_BASKET, re-run `_detect_mode`, etc.

Option 1 is simpler and safer:
```bash
confirm_and_execute "aba reset --force" "Reset ABA"
if [[ $? -eq 0 ]]; then
    dlg ... --msgbox "ABA has been reset.\n\nPlease restart the TUI to begin fresh setup." 0 0
    exit 0
fi
```

---

## Bug #432 — Operator basket silently loses operators when catalog index files are missing for current version

**Status:** OPEN (code review)
**Severity:** MEDIUM — Silent data loss, user may not realize operators were dropped
**Found:** 2026-06-14 (code review of `tui/v2/abatui2.sh` lines 221-231)  
**Component:** TUI v2 (`tui/v2/abatui2.sh`, lines 227-228)

### Description

During TUI startup, the operator basket is restored from `aba.conf` (line 221-232). Each operator is validated against the catalog index files for the current OCP version:

```bash
if [[ -n "$_ver_short" ]] && ! grep -q "^${_op}[[:space:]]" "$ABA_ROOT"/.index/*-index-v${_ver_short} 2>/dev/null; then
    continue  # Operator silently dropped!
fi
```

**Problem:** If the catalog index files for `$_ver_short` do NOT exist (e.g., after an `aba reset`, version change, or on a fresh system before indexes are downloaded), the glob `$ABA_ROOT/.index/*-index-v${_ver_short}` doesn't match any files. With default bash behavior (no nullglob), the literal glob string is passed to grep, which tries to open a non-existent file, returns non-zero, and the operator is DROPPED from the basket.

This means ALL operators are silently removed from the basket if the index files haven't been downloaded yet for the current version.

### When this occurs

1. After changing OCP version (e.g., from 4.20 to 4.21) if 4.21 indexes haven't been fetched
2. After `aba reset` which may remove `.index/` contents
3. On first TUI launch before background catalog downloads complete (indexes are fetched asynchronously at line 264-265)
4. On a transferred bundle before indexes are copied

### Impact

- User configures operators (e.g., cincinnati-operator, web-terminal)
- User changes version or restarts TUI before catalogs are ready
- Basket silently becomes empty
- User creates a bundle or syncs without operators, not realizing they were dropped
- No warning or notification is shown

### Suggested fix

Skip validation when index files don't exist (trust the config file):
```bash
local _idx_files=("$ABA_ROOT"/.index/*-index-v${_ver_short})
if [[ -n "$_ver_short" && -f "${_idx_files[0]:-}" ]] && \
   ! grep -q "^${_op}[[:space:]]" "${_idx_files[@]}" 2>/dev/null; then
    continue
fi
```

Or simpler: only validate if at least one index file exists.

---

## Bug #433 — ~~FIXED~~ Cluster wizard platform toggle updates `aba.conf` but not global `$platform`

**Status:** FIXED in commit fe5f8bde — added `platform="$cl_platform"` after the persist call

**Severity:** MEDIUM — Stale platform display in backtitle/settings, potential wrong defaults
**Found:** 2026-06-14 (code review of `tui/v2/tui-cluster.sh` line 994)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, line 994)

### Description

When the user toggles the platform on the Basics page (P key) in the cluster wizard, the code:
1. Updates `cl_platform` (local variable) — correct
2. Updates `aba.conf` via `replace-value-conf` — correct
3. Does NOT update the global `$platform` variable — **BUG**

The global `$platform` (used by `ui_backtitle()`, `_direct_config_complete()`, `_tui_settings_summary()`, and the Reconfigure wizard's "Resume Configuration" dialog) remains stale until the TUI is restarted or `source <(normalize-aba-conf)` is called.

### Impact

1. After toggling platform from vmw→kvm on Basics page, the title bar still shows "vmw"
2. Rerun Wizard shows "Platform: vmw" in the resume dialog
3. Settings summary shows the old platform
4. If the user exits the cluster wizard without installing, the next wizard entry may re-default to vmw-specific ports

### Distinction from Bug #425

Bug #425 is about the Advanced → Platform Settings menu writing immediately without confirmation.
This bug is about the wizard Basics toggle NOT syncing the global `$platform` variable (even though it correctly writes to `aba.conf`).

### Suggested fix

After line 994, add:
```bash
platform="$cl_platform"
```

---

## Bug #434 — ~~NOT A BUG~~ Cluster wizard VM resource fields (CPU, memory) can be cleared to empty

**Severity:** LOW — Allows empty values persisted to cluster.conf
**Found:** 2026-06-14 (code review of `tui/v2/tui-cluster.sh` lines 1427-1492)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, `_cluster_page_vm`)

### Description

The validation for VM resource fields (Master CPUs, Master Memory, Worker CPUs, Worker Memory) only runs when the input value is non-empty. If the user clears the field entirely (e.g., deletes "10" from Master CPUs and presses OK), the empty value is accepted and persisted to `cluster.conf`.

Code pattern:
```bash
local val
val=$(<"$_TUI_TMP")
if [[ -n "$val" ]]; then
    # validation (numeric, minimum check) only runs here
fi
[[ -n "$val" ]] && cl_master_cpu="$val"  # empty never updates — but user might expect reset
```

Actually: empty input does NOT overwrite the variable (the `[[ -n "$val" ]]` guard prevents it). But it also gives NO feedback — user might think they "cleared" the field. The review page would still show the old value.

**Correction:** This is actually NOT a bug — empty input is silently ignored (keeps previous value). The user sees no error but also no reset. This is a UX quirk, not a functional bug.

**Status:** LOW RISK — removed from active bug count.

---

## Bug #435 — Cluster wizard allows empty `ports` field on vmw/kvm platforms

**Status:** OPEN (code review)
**Severity:** LOW — No upfront validation, fails at install time
**Found:** 2026-06-14 (code review of `tui/v2/tui-cluster.sh` lines 1274-1288)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, `_cluster_page_iface`)

### Description

On the Interfaces page, the port name field can be cleared to empty on vmw/kvm platforms. The validation only checks format when the input is non-empty. For bare-metal, empty ports is valid (uses autodetection), but for vmw/kvm, a port name is required for the agent-based installer to configure the correct NIC.

Code at lines 1274-1288:
```bash
local ports_val
ports_val=$(<"$_TUI_TMP")
if [[ -n "$ports_val" ]]; then
    # Validate format (comma-separated alphanumeric with dots/hyphens)
    if ! [[ "$ports_val" =~ ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?(,[a-z0-9]([a-z0-9._-]*[a-z0-9])?)*$ ]]; then
        dlg ... --msgbox "Invalid port format..." || true
        continue
    fi
fi
[[ -n "$ports_val" ]] && cl_ports="$ports_val"
```

If user clears the field, empty is kept (from initial value or default). `_persist_cluster_draft` writes `ports=` (empty) to `cluster.conf`. At install time, `aba cluster` will either use a default or fail with an unclear error.

### Steps to reproduce

1. Install Cluster → platform=vmw → Interfaces page
2. Edit Ports → clear field (Ctrl-U) → OK
3. Continue to install

### Suggested fix

When `cl_platform` is vmw or kvm and `ports_val` is empty, show a warning:
```bash
if [[ -z "$ports_val" && "$cl_platform" != "bm" ]]; then
    dlg ... --msgbox "Port name is required for $cl_platform platform." 0 0
    continue
fi
```

---

## Bug #436 — ~~DUPLICATE OF Bug #421 / Bug #424~~ CONNO Help text uses outdated "resources" terminology for Day-2

**Status:** DUPLICATE of Bug #421 (same terminology issue) and Bug #424 point 3 (CONNO Help text comprehensive). Live verified on conno.  
**Severity:** LOW — Help text inconsistency with actual menu labels  
**Found:** 2026-06-14 (live TUI test on conno)  
**Component:** TUI v2 (`tui/v2/abatui2.sh`, CONNO Help text)

### Description

The CONNO main menu Help text (verified live) states:
```
Day-2 — post-install config (resources, NTP, update service, etc.)
```

But the actual Day-2 menu item "R" is labeled "Configure OperatorHub (after mirror load/sync)". The term "resources" was the old name — it should now say "Configure OperatorHub" or "OperatorHub" to match the current menu label.

This is the same terminology issue as Bug #421 (Day-2 submenu help) and Bug #424 point 3 (CONNO help), but confirmed LIVE with the current code on conno host.

### Live verification

Tested on conno host (dev branch, 2026-06-14):
1. Started TUI → CONNO main menu
2. Pressed Help button (Tab Tab Enter)
3. Help text shows "resources" instead of "Configure OperatorHub"

---

## Bug #437 — ~~DUPLICATE OF Bug #417~~ Pull secret "Use Existing" accepts invalid JSON file without validation

**Status:** DUPLICATE of Bug #417 (same issue: "Use existing" path bypasses JSON validation)  
**Severity:** MEDIUM — Leads to later failures when pull secret is used  
**Found:** 2026-06-14 (code review of `tui/v2/tui-direct.sh` lines 205-218)  
**Component:** TUI v2 (`tui/v2/tui-direct.sh`, `_direct_pull_secret`)

### Description

When the pull secret file exists but is NOT valid JSON, the wizard shows a menu with:
- "U" — Use existing pull secret
- "N" — Enter a new pull secret

If the user chooses "Use existing" (line 218: `[[ "$choice" == "U" ]] && return 0`), the invalid JSON file is accepted without any validation. The wizard proceeds, and downstream operations (`aba sync`, `aba bundle`, etc.) will fail with authentication errors.

### Code flow

```bash
# Line 199: Auto-skip ONLY if valid JSON
if [[ -f "$ps_file" ]] && python3 -c '...' "$ps_file" >/dev/null 2>&1; then
    return 0  # Valid → auto-skip
fi

# Line 205: File exists but is INVALID JSON → show menu
if [[ -f "$ps_file" ]]; then
    dlg ... --menu "..." 0 0 0 \
        "U"  "Use existing pull secret" \
        "N"  "Enter a new pull secret" \
    # User picks "U":
    [[ "$choice" == "U" ]] && return 0  # ACCEPTS INVALID FILE!
fi
```

### Steps to reproduce

1. Create a corrupted pull secret: `echo "not json" > ~/.pull-secret.json`
2. Start TUI → Reconfigure wizard (or fresh start without valid config)
3. Wizard shows "Use existing pull secret" menu
4. Select "Use existing"
5. Wizard proceeds without warning
6. Later: `aba sync` or `aba bundle` fails with auth errors

### Impact

- User who accidentally corrupted their pull secret (e.g., partial download, editor glitch) gets no warning
- Error surfaces much later in the workflow (during oc-mirror or during cluster install)
- User must backtrack to figure out that the pull secret was the problem

### Suggested fix

Validate before accepting "Use existing":
```bash
[[ "$choice" == "U" ]] && {
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ps_file" 2>/dev/null; then
        return 0
    fi
    dlg ... --msgbox "Pull secret file is not valid JSON.\n\nPlease enter a new pull secret or fix the file manually." 0 0
    continue
}
```

---

## Bug #438 — ~~DUPLICATE OF Bug #398~~ Settings Help text says retry values "2 or 8" but actual values are 0, 1, 2, 5

**Status:** DUPLICATE of Bug #398 (same issue: Settings help text lists wrong retry values)  
**Severity:** LOW — Help text inconsistency  
**Found:** 2026-06-14 (live TUI test on conno + code review)  
**Component:** TUI v2 (`tui/v2/tui-lib.sh`, `_tui_settings_menu`, lines 1262-1269)

### Description

The Settings Help text (verified live on conno) states:
```
Retry Count:
  How many times to retry failed oc-mirror operations.
  OFF = no retries, 2 or 8 = retry that many times.
```

But the actual toggle values (from code at lines 1262-1269) cycle: 0 → 1 → 2 → 5 → 0.

Discrepancies:
- Help mentions "8" — does NOT exist in the toggle cycle
- Help omits "1" — which IS a valid toggle value
- Help omits "5" — which IS a valid toggle value

### Live verification

Tested on conno host (dev branch, 2026-06-14):
1. CONNO main menu → C (Configure) → Tab Tab Enter (Help)
2. Help text shows "OFF = no retries, 2 or 8 = retry that many times"
3. Settings menu shows "Retry Count: 1" (current value)
4. Toggle cycle confirmed in code: 0 → 1 → 2 → 5 → 0

**Note:** Related to Bug #423 which reports the inconsistent DEFAULT (1 vs 2), but this is specifically about the HELP TEXT being wrong.

### Suggested fix

Update Help text to:
```
Retry Count:
  How many times to retry failed oc-mirror operations.
  Toggle cycles: OFF → 1 → 2 → 5 → OFF.
```

---

## Bug #439 — ~~DUPLICATE OF Bug #338~~ Platform selection commits to aba.conf BEFORE config form is completed

**Status:** DUPLICATE of Bug #338 (same issue; also duplicated by #360, #378, #425)  
**Severity:** MEDIUM — Silent platform change even when user cancels configuration  
**Found:** 2026-06-14 (live TUI test on conno)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, `tui_advanced_menu`, lines 1933-1949)

### Description

When a user selects a platform (VMware/KVM/Bare Metal) in the Advanced → Platform Settings menu, the code immediately writes the new platform to `aba.conf` and updates the global `$platform` variable BEFORE presenting the configuration form. If the user then presses "Back" (Cancel) in the config form, the platform has already been changed.

### Code flow

```bash
case "$_ptag" in
    V)
        replace-value-conf -q -n platform -v vmw -f "$ABA_ROOT/aba.conf"  # ← Committed!
        platform=vmw                                                       # ← Global changed!
        _configure_platform_file "vmware.conf" "VMware/ESXi"              # ← User may cancel!
        ;;
    K)
        replace-value-conf -q -n platform -v kvm -f "$ABA_ROOT/aba.conf"  # ← Committed!
        platform=kvm                                                       # ← Global changed!
        _configure_platform_file "kvm.conf" "KVM/libvirt"                 # ← User may cancel!
        ;;
```

### Steps to reproduce (verified live on conno)

1. Platform is set to `vmw` (verified: `grep platform aba.conf` → `platform=vmw`)
2. TUI → CONNO → Advanced → Platform Settings
3. Select "K" (KVM/libvirt) → KVM config form appears
4. Press ESC/Back to cancel without configuring
5. Check `aba.conf`: `platform=kvm` ← **CHANGED even though user cancelled!**
6. Advanced menu title shows "Platform Settings (kvm)" confirming the unwanted change

### Impact

- User accidentally changes their platform by just exploring the Platform Settings menu
- Subsequent cluster installs would use the wrong platform (KVM instead of VMware)
- The change is silent — no notification that the platform was permanently changed

### Suggested fix

Only commit the platform change AFTER the config form succeeds:
```bash
case "$_ptag" in
    V)
        if _configure_platform_file "vmware.conf" "VMware/ESXi"; then
            replace-value-conf -q -n platform -v vmw -f "$ABA_ROOT/aba.conf"
            platform=vmw
        fi
        ;;
```

---

## Bug #440 — ~~DUPLICATE OF Bug #421~~ DISCO Help text uses outdated "resources" terminology

**Status:** DUPLICATE of Bug #421 (same "resources" → "Configure OperatorHub" terminology issue, DISCO mode variant; also see #424, #436)  
**Severity:** LOW — Help text inconsistency  
**Found:** 2026-06-14 (code review of `tui/v2/tui-disco.sh` line 233)  
**Component:** TUI v2 (`tui/v2/tui-disco.sh`, `disco_main` Help text)

### Description

The DISCO main menu Help text (line 233) states:
```
4. Day-2 — apply cluster resources, NTP, update service, etc.
```

The term "resources" is the old name for what is now "Configure OperatorHub" in the Day-2 menu. Same pattern as Bugs #421, #429, #436.

### Suggested fix

Change to:
```
4. Day-2 — configure OperatorHub, NTP, update service, etc.
```

---

## Bug #441 — ~~NOT A BUG~~ `verify-mirror-conf` rejects IP addresses for `reg_host` (core code)

**Status:** NOT A BUG (core validation correct) + FIXED TUI side (commit 7707f582 — TUI now also rejects IPs with clear message)  
**Severity:** ~~MEDIUM~~ N/A (core was correct; TUI aligned to match)  
**Found:** 2026-06-14 (code review + CLI verification on conno)  
**Component:** Core (`scripts/include_all.sh`, `verify-mirror-conf()`, line 623)

### Description

The `verify-mirror-conf` function uses a regex that only accepts FQDNs (hostname with at least one dot and a letter-only TLD). It rejects:
- IP addresses (e.g., `10.0.1.5`)
- Bare hostnames (e.g., `localhost`, `registry`)

The TUI's mirror config form (`tui-mirror.sh` line 224) explicitly accepts both FQDNs and IPs via `_valid_fqdn` and `_valid_ip` checks. This creates a TUI-core inconsistency.

### Regex at fault (line 623)

```bash
echo $reg_host | grep -q -E '^[A-Za-z0-9.-]+\.[A-Za-z]{1,}$' || { echo_red "Error: reg_host is invalid..." }
```

This regex requires: `<chars>.<letters>` — forces a dot followed by a letter-only TLD.

### CLI verification on conno

```
steve@conno:~/aba/mirror$ source ../scripts/include_all.sh; reg_host='10.0.1.5'; verify-mirror-conf
Error: reg_host is invalid in mirror.conf [10.0.1.5]
```

Additional test:
```
$ echo '10.0.1.5' | grep -E '^[A-Za-z0-9.-]+\.[A-Za-z]{1,}$'  → NO MATCH
$ echo 'localhost' | grep -E '^[A-Za-z0-9.-]+\.[A-Za-z]{1,}$'  → NO MATCH
$ echo 'conno.example.com' | grep -E ...  → MATCH
```

### Impact

Any user who configures a mirror registry with an IP address (via TUI or manual edit):
- TUI accepts the value ✓
- All subsequent `aba sync`, `aba load`, `aba day2`, `aba uninstall` commands abort with:
  `"Error: reg_host is invalid in mirror.conf [10.0.1.5]"`
- User is stuck and must change to an FQDN

### Suggested fix

Accept FQDNs OR IPv4 addresses:
```bash
echo "$reg_host" | grep -q -E '^([A-Za-z0-9.-]+\.[A-Za-z]{1,}|[0-9]{1,3}(\.[0-9]{1,3}){3})$' || \
    { echo_red "Error: reg_host is invalid in mirror.conf [$reg_host]" >&2; ret=1; }
```

---

## Bug #442 — ~~FIXED~~ Mirror install Help text says "Save or Sync" without mentioning "Load" (misleading in DISCO mode)

**Status:** FIXED in commit fe5f8bde — help text now says "Save, Sync, or Load"

**Severity:** LOW — Help text incomplete for DISCO users
**Found:** 2026-06-14 (code review of `tui/v2/tui-mirror.sh` line 387)  
**Component:** TUI v2 (`tui/v2/tui-mirror.sh`, line 387)

### Description

The `mirror_install()` function's Help text (shown when Help is pressed on the "Install locally/remotely" dialog) says:

```
After installation, use 'Save' or 'Sync' to populate it with images.
```

This is incorrect/misleading in DISCO mode, where:
- **Save** downloads images FROM the internet to disk (unavailable — no internet)
- **Sync** pushes images from internet TO the registry (unavailable — no internet)
- **Load** is the correct operation (loads previously-saved archives into the registry)

Since `mirror_install()` is called from DISCO mode via `disco_install_reg()` (tui-disco.sh line 335), users in DISCO mode will see Help text that mentions two inapplicable operations and omits the one they need.

### Expected

Help text should be mode-aware or mention all three operations:
```
After installation, use 'Load' (disconnected) or 'Sync' (connected) to populate it with images.
```

### Suggested fix

Either make the Help text mode-aware (check `$_TUI_MODE`) or mention all three operations.

---

## Bug #443 — ~~FIXED~~ Dead code: unused `tag` variable in `_day2_upgrade`

**Status:** FIXED in commit 89fae839 (Bug #318 — removed dead `local tag` and its assignment)

**Severity:** COSMETIC — dead code, no functional impact
**Found:** 2026-06-14 (code review of `tui/v2/tui-cluster.sh` line 2256)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, line 2256)

### Description

In `_day2_upgrade()`, the version menu loop computes a `tag` variable:
```bash
local tag
tag=$(echo "${v}" | cut -d. -f1-2)
```

This `tag` variable (containing the `X.Y` portion of the version) is computed for each iteration but NEVER used. The menu display directly uses `v` (the full `X.Y.Z` version) instead:
```bash
items+=("$v" "(newest)")   # uses v, not tag
```

This is leftover code from an earlier implementation where `tag` was used as the menu item key.

### Impact

None — purely dead code. No functional effect.

### Suggested fix

Remove the unused `tag` computation (lines 2255-2256).

---

## Bug #444 — ~~DUPLICATE OF Bug #62~~ VM Resources: Help text states minimum CPU/RAM requirements but TUI does not enforce them

**Status:** DUPLICATE of Bug #62 (same issue; also duplicated by #100, #418). This entry adds live verification.  
**Severity:** LOW — misleading Help text (validation gap)  
**Found:** 2026-06-14 (code review + live TUI verification)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, `_cluster_page_vm()`, lines 1400-1460)

### Description

The VM Resources Help text (line 1402-1405) states minimum requirements:
```
• Master CPUs: vCPU count per control-plane VM (min 4)
• Master Memory: RAM in GB per control-plane VM (min 16)
• Worker CPUs: vCPU count per worker VM (standard only, min 2)
• Worker Memory: RAM in GB per worker VM (standard only, min 8)
```

But the input validation (line 1427) only checks:
```bash
if [[ -n "$val" ]] && { [[ ! "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]]; }; then
```

This means the TUI accepts ANY positive integer (including 1, 2, 3 for Master CPUs), despite the Help text claiming "min 4". The user is misled into thinking the TUI enforces these minimums when it does not.

### Reproduction

1. Navigate to Install Cluster → Cluster wizard → page 4 (VM Resources)
2. Select "Master CPUs" → clear input → enter "1" → press OK
3. The value "1" is accepted without warning
4. But Help text says "(min 4)"

### Impact

User may set CPU/RAM too low, causing OpenShift installation failures (nodes won't meet OCP requirements). The inconsistency between Help text and actual validation is confusing.

### Suggested fix

Either:
1. Add actual minimum validation (reject values below stated minimums with a warning), OR
2. Change Help text to say "recommended: 4" instead of "min 4" if intentionally allowing sub-minimum values for advanced users

---

## Bug #445 — ~~DUPLICATE OF Bug #287~~ Advanced menu Help text mentions "E - Reset Execution Mode" even when option is hidden

**Status:** DUPLICATE of Bug #287 (same issue: Advanced Help text documents "E" when option is conditionally hidden)  
**Severity:** COSMETIC — misleading Help text  
**Found:** 2026-06-14 (live TUI verification)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, `tui_advanced_menu()`, lines 1880-1895)

### Description

The Advanced menu Help text (shown when user presses Help) always includes:
```
E - Reset Execution Mode: Clears your 'Always TUI' or 'Always Terminal'
    preference for this session.
```

But the "E" menu option is conditionally shown (line 1845-1847):
```bash
if [[ -n "$_TUI_EXEC_MODE" ]]; then
    adv_items+=("E" "Reset Execution Mode (currently: $_TUI_EXEC_MODE)")
fi
```

When the user has NOT set an execution mode preference yet, "E" is invisible in the menu — but the Help text still describes it. This confuses users who see "E" in Help but can't find it in the menu.

### Reproduction

1. Start TUI fresh (no "Always TUI/Terminal" selected yet)
2. Navigate to Advanced menu
3. Press Help
4. Help text mentions "E - Reset Execution Mode" but no "E" option exists in the menu

### Impact

Minor UX confusion — user sees a Help entry for an invisible option.

### Suggested fix

Either:
1. Make Help text dynamic (skip E description if `$_TUI_EXEC_MODE` is empty), OR
2. Always show "E" in the menu but grey/disable it when no mode is set, OR
3. Add a note in Help: "E appears only after choosing 'Always TUI' or 'Always Terminal'"

---

# Session 4 — Hackathon Bugs Found (2026-06-17)

---

## Bug #446 — ~~FIXED~~ `mirror_prep_upgrade` rejects valid RC→GA upgrade path (e.g. 5.0.0-ec.3 → 5.0.0)

**Status:** FIXED — `mirror_prep_upgrade()` was rewritten with graph validation (commit `57260cbe`); old numeric comparison code removed  
**Severity:** MEDIUM — Blocks legitimate upgrade workflow  
**Found:** 2026-06-17 (code analysis + TUI live verification)  
**Component:** TUI v2 (`tui/v2/tui-mirror.sh`, `mirror_prep_upgrade()`, lines 529-543)

### Description

The `mirror_prep_upgrade()` function rejects upgrades from a pre-release version to its GA equivalent because the version comparison strips the pre-release suffix before comparing.

**Root cause:** Lines 532-538 strip the `-rc.N` suffix from both versions:
```bash
local _cur_clean="${_current_ver%%-*}"   # 4.21.0-rc.1 → 4.21.0
local _tgt_clean="${_target_ver%%-*}"    # 4.21.0 → 4.21.0
```
Then computes `_tgt_num` and `_cur_num` — both are equal (`4021000`). The check `[[ $_tgt_num -le $_cur_num ]]` evaluates to TRUE, showing: "Target version '4.21.0' must be higher than current version '4.21.0-rc.1'. Downgrades and same-version are not supported."

### Reproduction

```bash
# On conno, in tmux tui-debugging session:
ocp_version="4.21.0-rc.1"; _current_ver="$ocp_version"; _target_ver="4.21.0"
_cur_clean="${_current_ver%%-*}"; _tgt_clean="${_target_ver%%-*}"
# Both are "4.21.0" — comparison fails
```

### Impact

Users running a pre-release (RC) build cannot use the TUI to prepare upgrade images to the GA version. They must use the CLI instead.

### Suggested fix

When stripped versions are equal, additionally check if current has a pre-release suffix and target doesn't — that's always a valid upgrade:
```bash
if [[ $_tgt_num -le $_cur_num ]]; then
    # Allow RC→GA upgrade (same base version but target is GA)
    if [[ "$_current_ver" == *-* && "$_target_ver" != *-* && $_tgt_num -eq $_cur_num ]]; then
        : # Valid: 4.21.0-rc.1 → 4.21.0
    else
        # Show rejection dialog
    fi
fi
```

---

## Bug #447 — ~~FIXED~~ `aba --version 4.99` shows empty error message due to `local` at script top-level

**Status:** FIXED in commit 498cfeb2 — removed `local` keyword (was outside function scope)
**Severity:** MEDIUM — Poor UX (empty error message)  
**Found:** 2026-06-17 (code analysis + CLI verification)  
**Component:** Core ABA (`scripts/aba.sh`, line 500)

### Description

When `aba --version X.Y` is passed with a minor version that has no releases (e.g. `4.99`) and `fetch_latest_z_version` fails, the error handling uses `local` at the script's top level. In bash 5.1, `local` outside a function prints an error and does NOT assign the variable. The resulting `aba_abort ""` shows an empty error message.

### Reproduction

```bash
steve@conno:aba (dev)$ aba --version 4.99
/home/steve/bin/aba: line 500: local: can only be used in a function

[ABA] Error: 

```

### Impact

Users see a useless empty error message instead of "incorrect version format '4.99' — expected X.Y.Z or X.Y.Z-suffix.N". Also prints a confusing "local: can only be used in a function" error to stderr.

### Suggested fix

Replace `local _err_msg=` with just `_err_msg=` (plain variable assignment):
```bash
if [ ! "$ver" ]; then
    _err_msg="incorrect version format '$arg' — expected X.Y.Z or X.Y.Z-suffix.N (e.g. 4.22.0, 5.0.0-ec.2)"
    [ "$tmp_out" ] && _err_msg="failed to look up the ${tmp_out}version for channel [$chan] after option [$opt $arg]"
    aba_abort "$_err_msg"
fi
```

---

## Bug #448 — oc-mirror version display shows empty string (wrong grep pattern for oc-mirror v2)

**Status:** OPEN — live verified on conno — `oc-mirror version 2>&1 | grep 'environment version:'` produces empty output
**Severity:** LOW — Cosmetic (empty version in info message)  
**Found:** 2026-06-17 (CLI verification)  
**Live verified:** 2026-06-18 — confirmed on conno: `oc-mirror version` outputs `GitVersion:"4.21.0-202605260453..."` format. Correct extraction: `grep -oP 'GitVersion:"\K[^"]+'` → `4.21.0-202605260453.p2.g994deeb...`  
**Component:** Core ABA (`scripts/reg-load.sh`, `scripts/reg-save.sh`, `scripts/reg-sync.sh`)  
**Commit:** 2ad8e43f (feat: dynamic oc-mirror URL and show version during mirror ops)

### Description

The recently added `aba_info` line that displays the oc-mirror version uses `grep 'environment version:'` which does NOT match the actual output of `oc-mirror version` (oc-mirror v2). The result is an empty version string.

### Reproduction

```bash
steve@conno:aba$ oc-mirror version 2>&1 | grep 'environment version:'
# (empty — no match)

steve@conno:aba$ echo "Using oc-mirror version $(oc-mirror version 2>&1 | grep 'environment version:' | sed 's/.*environment version: //' | cut -d. -f1-3 | sed 's/\(-[0-9]*\).*/\1/')"
Using oc-mirror version 
```

The actual `oc-mirror version` output uses `GitVersion:"4.21.0-..."` format (Go struct), not "environment version:".

### Impact

During `aba save`, `aba sync`, and `aba load` operations, users see:
```
[ABA] Using oc-mirror version 
```
with an empty version string — confusing but not blocking.

### Suggested fix

Use `oc-mirror version --short 2>&1 | grep 'Client Version:'` or parse `GitVersion` from the full output:
```bash
aba_info "Using oc-mirror version $(oc-mirror version --short 2>&1 | tail -1 | sed 's/Client Version: //' | cut -d- -f1-2)"
```

---

## Bug #449 — `_resolve_minor_to_patch` rejects pre-release versions from `fetch_latest_z_version`

**Status:** OPEN — Code analysis (unverified — requires candidate channel with RC as latest)
**Severity:** MEDIUM — Blocks "x.y" version input on candidate channel  
**Found:** 2026-06-17 (code analysis)  
**Component:** TUI v2 (`tui/v2/tui-lib.sh`, `_resolve_minor_to_patch()`, line 1495)

### Description

When a user enters an `x.y` format version (e.g. "4.22") in the TUI version wizard, `_resolve_minor_to_patch` calls `fetch_latest_z_version`. On the `candidate` channel, this may return a pre-release version like `4.22.0-rc.1`. However, line 1495 validates the result with:
```bash
if [[ -n "$_resolved" && "$_resolved" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
```
This regex does NOT accept pre-release suffixes (`-rc.1`, `-ec.3`). The function returns 1 (failure), and the user sees "Version not found: 4.22" even though a valid version exists.

### Reproduction

1. Set `ocp_channel=candidate` in TUI wizard
2. Enter version "4.22" (x.y format)
3. If `fetch_latest_z_version` returns `4.22.0-rc.1`, the TUI rejects it
4. User sees "Version not found: 4.22 / No releases found for this minor version"

### Impact

Users on the `candidate` channel cannot use the convenient "x.y" shorthand — they must enter the full `x.y.z-rc.N` version manually.

### Suggested fix

Change line 1495 regex to accept pre-release:
```bash
if [[ -n "$_resolved" && "$_resolved" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?$ ]]; then
```

---

## Bug #450 — `fetch_all_versions` returns wrong minor versions (no minor filter, no pre-release)

**Status:** OPEN — live verified on conno — `fetch_all_versions candidate 5.0` returns `4.22.0, 4.22.1` (wrong minor, no pre-release)
**Severity:** HIGH — Silent wrong version resolution  
**Found:** 2026-06-17 (CLI verification)  
**Live verified:** 2026-06-18 — Cincinnati graph for `candidate-5.0` contains `5.0.0-ec.{0..3}` (pre-release only in 5.0.x), but `grep -E '^[0-9]+\.[0-9]+\.[0-9]+$'` filters them all out, leaving only `4.22.0` and `4.22.1` (wrong minor bleed from graph).  
**Component:** Core ABA (`scripts/include_all.sh`, `fetch_all_versions()`, line 1574)

### Description

`fetch_all_versions()` has TWO compounding issues:
1. It does NOT filter returned versions by the requested minor version — the Cincinnati graph for `candidate-5.0` includes nodes from 4.20.x, 4.21.x, 4.22.x, AND 5.0.x
2. The grep `'^[0-9]+\.[0-9]+\.[0-9]+$'` only matches GA versions, so pre-release-only minors (like 5.0 with only EC builds) return zero matching 5.x versions

Combined, `fetch_latest_z_version candidate 5.0` silently returns `4.22.1` (last GA in the graph) instead of `5.0.0-ec.3`.

### Reproduction

```bash
steve@conno:aba$ source scripts/include_all.sh
steve@conno:aba$ fetch_latest_z_version candidate 5.0
4.22.1   # WRONG — should be 5.0.0-ec.3 or error

steve@conno:aba$ aba --channel candidate --version 5.0
[ABA] Added value ocp_version=4.22.1 to file /home/steve/aba/aba.conf
# User asked for 5.0, silently got 4.22.1!
```

### Impact

**HIGH** — Users on the candidate channel requesting pre-release minor versions get a silently wrong version written to their config. No warning, no error. The cluster would install a completely different version than requested.

### Suggested fix

1. Add minor-version filter to `fetch_all_versions`:
```bash
| grep -E "^${minor}\." \
```
2. Also include pre-release versions when the channel is `candidate`:
```bash
| grep -E "^${minor}\.[0-9]+(-[a-z]+\.[0-9]+)?$" \
```
3. In `fetch_latest_z_version`, if `fetch_all_versions` returns empty for the requested minor, return empty (let caller handle the error) rather than falling through to previous minor.

---

## Bug #451 — `aba --version x.y` resolution uses stale graph data (no minor filter applied to results)

**Status:** OPEN — live verified on conno — `fetch_all_versions candidate 5.0` returns `4.22.0, 4.22.1` (wrong minor!)
**Severity:** HIGH — Incorrect version resolution in TUI wizard  
**Found:** 2026-06-17 (code analysis + CLI verification)  
**Live verified:** 2026-06-18 — `_fetch_graph_cached candidate 5.0 | jq .nodes[].version` shows mix of 4.22.x-rc/ec and 5.0.0-ec.0, but after GA-only filter, only `4.22.0` and `4.22.1` survive (no 5.0.x). User asking for `--version 5.0` gets `4.22.1`.  
**Component:** TUI v2 (`tui/v2/tui-lib.sh`, `_resolve_minor_to_patch()`) + Core ABA  
**Linked:** Bug #450 (same underlying `fetch_all_versions` issue)

### Description

The TUI's `_resolve_minor_to_patch` function calls `fetch_latest_z_version` which ultimately calls `fetch_all_versions`. Since `fetch_all_versions` doesn't filter by minor, the TUI can resolve `5.0` to `4.22.1` and present it to the user as "Resolved 5.0 to 4.22.1" — accepting it as valid because `4.22.1` passes the `^[0-9]+\.[0-9]+\.[0-9]+$` regex.

### Reproduction

1. In TUI wizard, select `candidate` channel
2. Enter "5.0" as the version
3. TUI resolves it to "4.22.1" (wrong minor!)
4. User proceeds unaware

### Impact

Same as #450 — user gets wrong version without any warning. The TUI layer has no defense against this because it trusts `fetch_latest_z_version`.

### Suggested fix

In `_resolve_minor_to_patch`, after resolution, verify that the resolved version starts with the requested minor:
```bash
if [[ -n "$_resolved" ]] && [[ "$_resolved" == "${_minor}."* ]]; then
    # Valid — matches requested minor
else
    return 1  # Resolved to wrong minor — treat as failure
fi
```

---

## Bug #452 — Version wizard shows "Latest (4.22.1)" BELOW "Current (5.0.0-ec.3)" on candidate channel

**Status:** OPEN — live verified in TUI on conno
**Severity:** LOW — UX confusion (misleading label)  
**Found:** 2026-06-17 (TUI live verification)  
**Component:** TUI v2 (`tui/v2/tui-direct.sh`, `_direct_version()`, line 352-436)  
**Linked:** Root cause is Bug #450 (`fetch_latest_version` GA-only filtering)

### Description

In the TUI version selection wizard, when the channel is `candidate` and the user is on a pre-release version (e.g. `5.0.0-ec.3`), the menu shows:

```
c  Current   (5.0.0-ec.3)
l  Latest    (4.22.1)
p  Previous  (4.21.20)
o  Older     (4.20.25)
```

This is confusing because:
1. "Latest" (`4.22.1`) appears to be OLDER than "Current" (`5.0.0-ec.3`)
2. The user's current version is newer than the "Latest" — implying their version doesn't exist
3. All three "Latest/Previous/Older" are from older minor versions

### Root cause

`fetch_latest_version(candidate)` → `fetch_latest_minor_version(candidate)` reads the CDN release.txt which shows `5.0.0-ec.3`. Since it's pre-release, the function falls back to previous minor (`4.22`). Then `fetch_all_versions(candidate, 4.22)` returns `4.22.1` as the latest GA version.

### Impact

Users on `candidate` channel with pre-release versions see a confusing menu where their "Current" version is newer than "Latest". This may cause them to inadvertently downgrade by selecting "Latest".

### Suggested fix

On the `candidate` channel, either:
1. Include pre-release versions in "Latest" (since that's the whole point of `candidate`)
2. Label the versions as "Latest GA" to clarify they exclude pre-release
3. Don't show "Latest/Previous/Older" at all when Current is newer than all of them — just show Current + Manual entry

---

## Bug #453 — ~~DUPLICATE OF Bug #104~~ TUI channel wizard missing "EUS" option (silently defaults to stable)

**Status:** DUPLICATE of Bug #104 (same issue: EUS channel missing from TUI wizard)  
**Severity:** LOW — Missing feature / data loss on EUS users  
**Found:** 2026-06-17 (code analysis)  
**Component:** TUI v2 (`tui/v2/tui-direct.sh`, `_direct_channel()`, lines 261-323)

### Description

The TUI channel selection wizard only offers 3 channels: stable, fast, candidate. But `aba --channel eus` is a valid option in the core CLI (`scripts/aba.sh` line 458). If a user has `ocp_channel=eus` in their `aba.conf` (set via CLI), the TUI wizard:

1. Falls through the `case` statement without matching (line 266-270): `_default_tag` stays at `s` (stable)
2. When user presses "Next", the wizard writes `ocp_channel=stable|fast|candidate` — overwriting the EUS channel
3. There's no way to select EUS from within the TUI

```bash
# Code: _direct_channel() line 265-270
local _default_tag=s
case "${ocp_channel:-stable}" in
    stable)    _default_tag=s ;;
    fast)      _default_tag=f ;;
    candidate) _default_tag=c ;;
    # eus is MISSING — falls through, defaults to 's'
esac
```

### Impact

EUS users who use the TUI wizard will have their channel silently changed to stable (or whatever they select from the 3 options). This is silent data loss for their config. The user would need to re-set `aba --channel eus` after using the wizard.

### Suggested fix

Add `"e" "eus       — Extended Update Support"` to the channel menu items and handle in the case statement.

---

## Bug #454 — ~~FIXED~~ Cluster wizard Page 1 "Next" fails on first attempt when network values are empty

**Status:** FIXED (commit 83f287a8 — wraps exit 1 in `if [ "$ask" ]`, --yes bypasses abort)  
**Severity:** MEDIUM — Confusing error on first cluster creation  
**Found:** 2026-06-18 (TUI live testing)  
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, cluster_install_flow) + Core ABA (`scripts/aba.sh`)

### Description

When creating a cluster for the first time (no network values in `aba.conf`), pressing "Next" on the Cluster Wizard Page 1 triggers `aba cluster --name X --type sno --platform vmw --step cluster.conf --yes`. ABA core auto-detects 4 network values (machine_network, dns_servers, next_hop_address, ntp_servers), writes them to `aba.conf`, and then exits with an error:

```
[ABA] Warning: 4 network value(s) were auto-detected and written to aba.conf.
[ABA]          Please review aba.conf and re-run the command.
make: *** [Makefile:124: cluster] Error 1
```

The TUI shows: "Failed to generate cluster configuration (exit code 2)."

Pressing "Next" AGAIN works because the values are now populated in `aba.conf`.

### Reproduction

1. Start with empty network values in `aba.conf` (machine_network=, dns_servers=, etc.)
2. Open TUI → Install Cluster
3. Set name/type/platform on Page 1
4. Press "Next"
5. See error: "Failed to generate cluster configuration (exit code 2)"
6. Press "OK" to dismiss
7. Press "Next" again → works fine this time

### Impact

Users see a confusing error on first cluster creation. The workaround (pressing Next again) works, but the error message "Failed to generate cluster configuration" is alarming and doesn't explain what happened.

### Suggested fix

Option 1: In the TUI, after `aba cluster --step cluster.conf` fails with exit 1 (make error due to auto-detect), automatically retry ONCE (the values are now in aba.conf).

Option 2: In ABA core, don't exit with error when auto-detecting + `--yes` flag is set. Just auto-detect, save, and continue.

Option 3: In the TUI, pre-populate aba.conf network values BEFORE calling the cluster generation command (the TUI already auto-detects these at line 663-674 of `cluster_install_flow`).

---

## Bug #455 — ~~DUPLICATE OF Bug #322~~ Mirror status shows "mirror ready" after changing OCP version via wizard (stale cache)

**Status:** DUPLICATE of Bug #322 (same root cause: stale mirror verify cache after OCP version change via wizard). This entry adds live verification details.  
**Severity:** MEDIUM — Misleading status, can cause user to skip sync  
**Found:** 2026-06-18 (TUI live testing)  
**Component:** TUI v2 (`tui/v2/abatui2.sh`, `tui/v2/tui-direct.sh`)

### Description

After changing the OCP version via "Rerun Wizard" (W), the main menu continues to show "Status: mirror ready" (green) even though the mirror does NOT contain images for the NEW version.

Root cause: At line 718 of `abatui2.sh`, after `direct_wizard` completes, the code reloads `aba.conf` but never calls `_invalidate_mirror_cache()`. The mirror verify check (`run_once -i "aba:mirror:check-image"`) was done for the OLD version and its cached result persists. The TUI uses this stale cached result to display "mirror ready".

### Reproduction

1. Start TUI on CONNO mode with a synced mirror (e.g., OCP 5.0.0-ec.3 synced)
2. Verify "Status: mirror ready" (green) shows in the main menu
3. Press W → Reconfigure → change version to 4.21.0-rc.2
4. Return to main menu → "Status: mirror ready" STILL shows
5. The mirror only has 5.0.0-ec.3 images, not 4.21.0-rc.2

### Impact

Users may attempt to install a cluster without syncing images for the new version, leading to failures. The green "mirror ready" status gives false confidence.

### Suggested fix

After `direct_wizard` returns 0 at line 718 of `abatui2.sh`, add:
```bash
_invalidate_mirror_cache
```

This forces a fresh `check-image` against the newly configured version.

---

## Bug #456 — `aba --channel X --version Y.Z` uses wrong channel for version resolution

**Status:** OPEN — live verified on conno
**Severity:** MEDIUM — Wrong version resolution affects both `--version` and `--target-version`
**Found:** 2026-06-18 (code analysis + live verification)  
**Component:** Core ABA (`scripts/aba.sh`, lines 493 AND 540)

### Description

In `scripts/aba.sh` line 493:
```bash
echo $ver | grep -q -E "^[0-9]+\.[0-9]+$" && ver=$(fetch_latest_z_version "$ocp_channel" "$ver")
```

When the user specifies both `--channel X` and `--version Y.Z` (short format), the version resolution uses `$ocp_channel` (sourced from aba.conf at startup) instead of `$chan` (which reflects the `--channel` flag).

The `--channel` flag correctly writes the new channel to aba.conf (line 464: `replace-value-conf -n ocp_channel -v $chan -f $ABA_ROOT/aba.conf`), but the shell variable `$ocp_channel` still holds the OLD value from the initial `source <(normalize-aba-conf)`.

This is inconsistent with lines 484 and 488 which correctly use `$chan`.

### Reproduction

1. Have `ocp_channel=stable` in aba.conf
2. Run: `aba --channel candidate --version 4.22`
3. Expected: resolves 4.22 using candidate channel
4. Actual: resolves 4.22 using stable channel (stale `$ocp_channel`)

### Live Verification

With `ocp_channel=candidate` in aba.conf:
- `aba --channel stable --version 4.20` → resolves to `4.20.24` (correct: stable channel)
- `aba --version 4.20 --channel stable` → resolves to `4.20.25` (WRONG: uses candidate channel)

The bug triggers when `--version x.y` is specified BEFORE `--channel X`, because at line 479
`chan=$ocp_channel` reads the stale value, and line 493 uses it for resolution.

### Impact

Version resolution uses the wrong channel when `--version x.y` precedes `--channel X`. Produces a version from the wrong channel.

### Suggested fix

Change line 493 from:
```bash
echo $ver | grep -q -E "^[0-9]+\.[0-9]+$" && ver=$(fetch_latest_z_version "$ocp_channel" "$ver")
```
to:
```bash
echo $ver | grep -q -E "^[0-9]+\.[0-9]+$" && ver=$(fetch_latest_z_version "$chan" "$ver")
```

**Same bug also at line 540** (`--target-version` path):
```bash
echo $tgt_ver | grep -q -E "^[0-9]+\.[0-9]+$" && tgt_ver=$(fetch_latest_z_version "$ocp_channel" "$tgt_ver")
```
Should also use `"$chan"` instead of `"$ocp_channel"`.

---

## Bug #458 — TUI wizard manual version entry skips channel validation

**Status:** OPEN — live verified on conno
**Severity:** LOW — Unlikely in practice but can cause downstream failures  
**Found:** 2026-06-18 (live TUI testing)  
**Component:** TUI v2 (`tui/v2/tui-direct.sh`, line 471)

### Description

In the TUI wizard's manual version entry (`_direct_version`), when a user enters a version in `x.y.z` or `x.y.z-suffix.N` format, the TUI accepts it immediately without validating it against the selected channel's Cincinnati graph.

At line 471:
```bash
if [[ "$ocp_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?$ ]]; then
    break  # ← Accepted without validation!
```

This allows entering e.g. `4.21.0-rc.2` on the `stable` channel, creating a channel/version mismatch.

### Live Verification

In the TUI wizard:
1. Selected channel "stable"
2. Chose "Manual entry"
3. Entered `4.21.0-rc.2` (which is on `candidate`, NOT `stable`)
4. TUI accepted it without warning → `aba.conf` set to `ocp_channel=stable ocp_version=4.21.0-rc.2`

### Impact

The mismatch between channel and version can cause:
- `aba sync` to look for the version in the wrong channel
- Misleading error messages during mirror operations
- `fetch_all_versions` to not find the version (since stable 4.21 may not have any RC versions)

The core `aba.sh` interactive version prompt (line 1580) correctly accepts pre-releases without Cincinnati validation, but at least warns. The TUI gives no warning or channel-compatibility check at all.

### Suggested fix

After accepting a manually-entered version, check if it's a pre-release and warn the user. For GA versions, optionally validate against the selected channel's Cincinnati graph (like the x.y resolution path already does).

---

## Bug #457 — ~~FIXED~~ `--retry` without argument: comment says 3, code sets 2, debug says 3

**Status:** OPEN — verified via code analysis
**Severity:** TRIVIAL — Cosmetic inconsistency, actual retry=2 works fine  
**Found:** 2026-06-18 (code analysis)  
**Component:** Core ABA (`scripts/aba.sh`, lines 935-938)

### Description

In `scripts/aba.sh` lines 935-938:
```bash
# In all other cases, use '3'
else
    BUILD_COMMAND="$BUILD_COMMAND retry=2"  # FIXME: Also confusing
    aba_debug Setting $1 to 3
```

Three different values:
- Comment says "use '3'"
- Code actually sets `retry=2`
- Debug message says "Setting ... to 3"

### Impact

Minimal — the actual retry value used is 2, which is fine. But the conflicting documentation/debug could confuse developers.

### Suggested fix

Align all three to the same value (probably 2 based on what the code does).

---

## Bug #459 — ~~FIXED~~ `aba shell` parses `base_domain` with raw grep (includes trailing comments)

**Status:** FIXED — added `sed 's/[[:space:]]*#.*//'` to strip inline comments

**Severity:** MEDIUM — Broken kubeconfig path if cluster.conf has inline comments
**Found:** 2026-06-18 (code analysis)  
**Component:** Core ABA (`scripts/aba.sh`, line 1134, `shell` command)

### Description

The `aba shell` command extracts `base_domain` using raw grep+cut instead of `normalize-cluster-conf`:

```bash
_bd=$(grep '^base_domain=' cluster.conf 2>/dev/null | head -1 | cut -d= -f2 | xargs)
```

If `cluster.conf` contains `base_domain=example.com\t# my domain`, the extracted value includes the comment: `example.com # my domain`. This produces a broken KUBECONFIG path.

### Reproduction

1. Edit cluster.conf to have: `base_domain=example.com	# Default domain`
2. Run `aba shell`
3. Output includes: `export KUBECONFIG=...example.com # Default domain/...`

### Impact

- The exported KUBECONFIG path is wrong (contains `#` comment)
- Sourcing the output (`. <(aba shell)`) silently sets wrong path
- Only affects users whose cluster.conf has inline comments after `base_domain=`

### Suggested Fix

Replace raw grep with `normalize-cluster-conf`:
```bash
_bd=$(source <(normalize-cluster-conf) && echo "$base_domain")
```

Or at minimum, strip comments:
```bash
_bd=$(grep '^base_domain=' cluster.conf | head -1 | cut -d= -f2 | sed 's/[[:space:]]*#.*//' | xargs)
```

---

## Bug #460 — `make-bundle.sh` has multiple unquoted `$bundle_dest_file` references (breaks with spaces in path) — FIXED

**Status:** FIXED (2026-06-24, commit pending) — all `$bundle_dest_file` references properly quoted  
**Severity:** MEDIUM — Bundle creation fails if output path contains spaces  
**Found:** 2026-06-18 (code analysis)  
**Component:** Core ABA (`scripts/make-bundle.sh`, lines 97, 107-108, 132, 135, 214, 249, 293)

### Description

Multiple references to `$bundle_dest_file` throughout `make-bundle.sh` are unquoted:
- Line 97: `if [ -d $bundle_dest_file ]; then`
- Line 107: `! echo write test > $bundle_dest_file.tmp`
- Line 108: `rm -f $bundle_dest_file.tmp`
- Line 132: `if [ -f $bundle_dest_file ]; then`
- Line 135: `rm -f $bundle_dest_file`
- Line 214: `if [ -s $bundle_dest_file ]; then`
- Line 249: `rm -f $bundle_dest_file`
- Line 293: `rm -f $bundle_dest_file`

The TUI's `mirror_create_bundle` properly quotes the path in the command string (line 1332: `local cmd="aba bundle --out \"$bundle_path\""`), but when the script receives and uses it internally, the unquoted variable expansions break if the path contains spaces.

### Reproduction

1. TUI: Create Bundle → Enter path `/tmp/my bundle`
2. The script receives `--out "/tmp/my bundle"` → `bundle_dest_file="/tmp/my bundle"`
3. Line 97: `if [ -d /tmp/my bundle ]` → bash error: too many arguments

### Suggested Fix

Quote all instances of `$bundle_dest_file`:
```bash
if [ -d "$bundle_dest_file" ]; then
```

---

## Bug #461 — ~~FIXED~~ "Prepare Upgrade for Transfer" shows "Current installed version" when no cluster is installed

**Status:** FIXED — changed label from "Current installed" to "Current configured"

**Severity:** LOW — Misleading label (cosmetic, non-blocking)
**Found:** 2026-06-18 (live TUI testing)  
**Component:** TUI v2 (Prepare Upgrade for Transfer dialog)

### Description

The "Prepare Upgrade for Transfer" dialog shows:
```
Current installed version: 4.21.0-rc.2
```

But NO cluster is actually installed. The value comes from `ocp_version` in `aba.conf`, not from an actual cluster's `clusterversion` resource. A user who hasn't installed any cluster yet would be misled into thinking they have an installed cluster at this version.

### Reproduction

1. Configure ABA with `ocp_version=4.21.0-rc.2` (no cluster installed)
2. Start TUI → CONNO main menu → Prepare Upgrade for Transfer (U)
3. Observe: "Current installed version: 4.21.0-rc.2" — misleading

### Impact

Cosmetic confusion only. The upgrade preparation is a mirror operation (saves target version images for transfer), so it doesn't actually require an installed cluster. The label should say "Current configured version" or "Current mirror version" instead.

### Suggested fix

Change the label from "Current installed version" to "Current configured version" or "Current OCP version".

---

## Bug #462 — ~~FIXED~~ `aba tui` exits silently (code 0) instead of launching TUI or showing error

**Status:** FIXED in commit 498cfeb2 — added `tui` subcommand to aba.sh dispatcher
**Severity:** LOW — UX gap, user confusion  
**Found:** 2026-06-18 (live CLI testing)  
**Component:** Core ABA (`scripts/aba.sh`, line 1301)

### Description

Running `aba tui` exits with code 0 and no output. The user expects either:
- The TUI to launch (like `abatui` does), or
- An error message: "Unknown command: tui. Use 'abatui' for the interactive TUI."

Instead, the command silently succeeds with no action because "tui" is not a recognized target, triggering the early exit at line 1301:
```bash
[ "$have_args" -a ! "$BUILD_COMMAND" ] && exit 0
```

### Reproduction

```bash
steve@conno:aba$ aba tui
steve@conno:aba$ echo $?
0
```

No output, no error, no TUI.

### Impact

Users must know to run `abatui` (a symlink). The `aba` help text says "aba — Interactive mode" but doesn't mention `abatui`. A user who tries `aba tui` (a natural guess) gets nothing.

### Suggested fix

Add a case for "tui" in the command parsing that execs `abatui2.sh`:
```bash
tui) exec "$ABA_ROOT/tui/v2/abatui2.sh" "$@" ;;
```

---

## Bug #463 — RC version + stable channel produces confusing "no release images found" error

**Status:** OPEN — live verified on conno
**Severity:** LOW-MEDIUM — Confusing error message
**Found:** 2026-06-18 (live testing)  
**Component:** Core ABA (`scripts/aba.sh` version acceptance + `reg-sync.sh`)

### Description

When `ocp_channel=stable` and `ocp_version=4.21.0-rc.2`, running `aba sync` produces:
```
[ERROR] : [Executor] collection error: [GetReleaseReferenceImages] no release images found
[ABA] Warning: Image sync aborted ...
```

The error is from `oc-mirror` because RC versions are only published on the `candidate` channel, not `stable`. But ABA doesn't validate this mismatch — the `--version` flag accepts any pre-release version regardless of channel, only showing "Warning: Pre-release version — not for production use."

### Reproduction

```bash
aba --channel stable --version 4.21.0-rc.2   # Accepted without channel warning
cd mirror && aba sync                         # FAILS: "no release images found"
```

### Impact

Users get a cryptic oc-mirror error instead of a clear ABA message explaining that RC/EC versions are only available on the `candidate` channel. They may waste time troubleshooting network/auth issues.

### Suggested fix

When accepting a pre-release version (`-rc.N`, `-ec.N`), validate that the channel is `candidate`. If not, warn:
```
[ABA] Warning: Pre-release version '4.21.0-rc.2' is typically only available on the 'candidate' channel (current: stable).
```

---

## Bug #464 — ~~DUPLICATE OF Bug #456~~ `--target-version x.y` uses wrong channel (live verified)

**Status:** DUPLICATE of Bug #456 (live re-verification with --target-version flag)  
**Severity:** MEDIUM — Wrong target version resolved  
**Found:** 2026-06-18 (live testing)  
**Component:** Core ABA (`scripts/aba.sh`, line 540)

### Live Verification

With `ocp_channel=candidate` in aba.conf:
```bash
# Correct order (channel processed first):
aba --channel candidate --target-version 4.20  → 4.20.25 (candidate's latest)

# Bug trigger (target-version processed before channel):
aba --target-version 4.20 --channel stable     → 4.20.25 (WRONG! Should be 4.20.24 from stable)
```

The `--target-version` flag at line 540 uses `$ocp_channel` (from aba.conf, stale value "candidate") instead of `$chan` (which would be updated by the later `--channel stable` flag). Result: 4.20.25 (candidate's latest for 4.20) instead of 4.20.24 (stable's latest for 4.20).

This is the same bug as Bug #456 line 493, but at line 540 (`--target-version` path). See Bug #456 for the full description and suggested fix.

---

## Bug #465 — ~~FIXED~~ `aba delete` leaves orphaned `openshift-install` process running after removing cluster state

**Status:** FIXED (commit 0ae85062 — kill openshift-install via /proc/PID/cwd match before delete)  
**Severity:** HIGH — Orphaned process runs indefinitely, wastes resources, confuses reinstall  
**Found:** 2026-06-19 (live testing)  
**Component:** Core ABA (cluster delete logic)

### Description

When `aba delete` is run while `openshift-install agent wait-for install-complete` (or `aba mon`) is actively monitoring a cluster installation, the delete command:
1. Successfully removes the `iso-agent-based/` directory (containing kubeconfig, auth, logs)
2. Does NOT kill the running `openshift-install` process

The orphaned process continues running indefinitely, looping every 30 seconds with:
```
level=info msg=Waiting for cluster install to initialize. Sleeping for 30 seconds
```

It never terminates on its own because the agent wait-for loop doesn't check if its working directory still exists.

### Reproduction

```bash
# Terminal 1: Start install monitoring
cd ~/aba/sno && aba mon -y

# Terminal 2: Delete the cluster while monitoring is active
cd ~/aba/sno && aba delete -y
# Output: "[ABA] Bare-metal: no VMs to delete. Removing cluster state."

# Check: openshift-install still running with deleted workdir
ps aux | grep openshift-install
# → process still alive, looping every 30s
ls ~/aba/sno/iso-agent-based
# → "No such file or directory" (deleted)
```

### Impact

- **Resource waste**: Process runs forever consuming memory (~140MB) and CPU
- **User confusion**: Terminal is stuck with the orphaned process
- **Reinstall interference**: If user tries to reinstall, there might be a race between old process and new install
- **Data corruption risk**: If `aba install` is re-run before killing the old process, both might try to write to the same directory

### Suggested fix

In the delete logic, before removing `iso-agent-based/`:
```bash
# Kill any running openshift-install processes for this cluster
_oi_pids=$(pgrep -f "openshift-install.*--dir iso-agent-based" 2>/dev/null)
if [ "$_oi_pids" ]; then
    kill $_oi_pids 2>/dev/null
    sleep 1
    kill -9 $_oi_pids 2>/dev/null  # Force kill if still alive
fi
```

Alternatively, add a check at the start of `aba delete` that warns if an install is in progress and asks for confirmation.

---

## Bug #466 — `ocp-versions` display hides pre-release versions from candidate channel

**Status:** OPEN — live verified on conno
**Severity:** LOW — Cosmetic, but candidate channel misrepresented
**Found:** 2026-06-19 (live testing)  
**Component:** Core ABA (`scripts/include_all.sh`, `fetch_all_versions` function)

### Description

Running `aba ocp-versions` shows:
```
Latest candidate:   4.22.1
Previous candidate: 4.21.20
```

These are both GA versions. The `candidate` channel also contains pre-release versions like `4.22.0-rc.1`, `5.0.0-ec.3` etc., but they are ALL filtered out by the `grep -E '^[0-9]+\.[0-9]+\.[0-9]+$'` in `fetch_all_versions()` (Bug #450).

For the `candidate` channel, the "Latest" should arguably show the newest version including pre-releases, since that's the whole point of the candidate channel (early access to pre-release versions).

### Impact

Users looking at `aba ocp-versions` to find RC/EC versions won't see them. They have to know the exact version string or browse the Cincinnati graph manually.

### Related

Manifestation of Bug #450's pre-release filter. Fix Bug #450 and this display issue resolves.

---


## Bug #467 — `aba --version x.y.z` accepts non-existent versions without network validation

**Status:** OPEN — live verified on conno
**Severity:** LOW-MEDIUM — User won't discover the error until sync/save fails
**Found:** 2026-06-19 (live CLI testing)  
**Component:** Core ABA (`scripts/aba.sh`, `--version` flag parsing)

### Description

When a full `x.y.z` format version is given (e.g., `aba --version 99.99.99999`), ABA writes it directly to `aba.conf` without checking if the version actually exists in any channel. The early format validation regex passes because `99.99.99999` matches the allowed pattern.

### Reproduction

```
aba --version 99.99.99999
# Succeeds! Writes ocp_version=99.99.99999 to aba.conf
grep ocp_version aba.conf
# ocp_version=99.99.99999
```

The user won't discover the problem until they try to `sync` or `save` images and `oc-mirror` fails to find release images for this non-existent version.

### Suggested fix

After the format validation passes for a full x.y.z version, optionally probe the Cincinnati graph or the CDN release.txt URL to confirm the version exists. A non-blocking warning is preferable to an abort (the user might know what they're doing with a very new version).

---

## Bug #468 — ~~FIXED~~ `aba cluster --name` lacks character validation (command injection risk via CLI)

**Status:** FIXED — `_valid_cluster_name` called before embedding name in BUILD_COMMAND (plus #319 validates in setup-cluster.sh)

**Severity:** MEDIUM — Shell injection via crafted name, arg-split with spaces, path traversal with slashes
**Found:** 2026-06-19 (live CLI testing)  
**Component:** Core ABA (`scripts/aba.sh`, `--name` flag)

### Description

The `--name` CLI flag for `aba cluster --name <value>` does not validate the cluster name. The TUI has proper DNS label validation (lowercase letters, digits, hyphens; max 63 chars), but the CLI bypasses this entirely.

### Reproduction

```
# Spaces cause argument splitting:
aba cluster --name 'my cluster'
# Creates directory "my/" (only first word used as name)

# Slashes cause path traversal:
aba cluster --name 'test/cluster'
# make[1]: Makefile: No such file or directory

# Backticks cause shell syntax error:
aba cluster --name 'test`id`'
# /bin/sh: -c: line 1: unexpected EOF...
```

### Root cause

In `aba.sh` line 904, the name is embedded in BUILD_COMMAND with single quotes:
```
BUILD_COMMAND="$BUILD_COMMAND name='$2'"
```
No validation regex is applied before embedding. The BUILD_COMMAND is later processed by Make which interprets shell metacharacters.

### Suggested fix

Apply the same validation as the TUI before accepting the name:
```
if ! [[ "$2" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]] || [[ ${#2} -gt 63 ]]; then
    aba_abort "--name must be a valid DNS label: lowercase letters, digits, hyphens; 1-63 chars; start with letter"
fi
```

---

## Bug #469 — ~~FIXED~~ CONNO Help text doesn't match actual menu layout

**Status:** FIXED — help text updated to match actual CONNO menu sections (Mirror, Transfer, Cluster, Advanced)

**Severity:** LOW — Help text misleads users about menu organization
**Found:** 2026-06-19 (code review + live TUI)  
**Component:** TUI v2 (`tui/v2/abatui2.sh`, CONNO mode help, line ~598)

### Description

The CONNO mode Help text has three discrepancies with the actual menu:

1. **"Sync" listed under "Transfer"** — In the actual menu, "Sync" is under the "Mirror" section, not "Transfer"
2. **"Load" mentioned** — "Load" does NOT exist in the CONNO menu (it's a DISCO-mode-only operation). Already noted as Bug #430.
3. **"Prepare Upgrade for Transfer" missing** — This IS in the menu (under Transfer) but is NOT mentioned in the Help text.

### Help text says:
```
Transfer (uses oc-mirror):
  - Sync (m2m)
  - Save (m2d)
  - Load (d2m)       <-- WRONG: not in CONNO menu
  - Install Bundle
```

### Actual menu layout:
```
---- Mirror ----
  View/Edit ISC | Operators | Install Mirror | Sync
---- Transfer ----
  Bundle | Save | Prepare Upgrade for Transfer  <-- not in Help
```

### Suggested fix

Update the Help text to match the actual menu sections and items. Remove "Load", move "Sync" to Mirror section, add "Prepare Upgrade for Transfer".

### Related

Extends Bug #430 (CONNO Help mentions "Load" which doesn't exist).

---

## Bug #470 — ~~FIXED~~ `aba info` (and other commands) shows confusing error after `aba delete`

**Status:** FIXED (commit 0ae85062 — make clean no longer removes scripts/templates symlinks)  
**Severity:** LOW — Confusing error message, not a functional bug  
**Found:** 2026-06-19 (live testing)  
**Component:** Core ABA (cluster command dispatch)

### Description

After running `aba delete` from a cluster directory, `make clean` removes the `scripts/` symlink. Running `aba --dir sno info` produces a confusing raw shell error:

```
/home/steve/aba/scripts/cluster-info.sh: line 4: scripts/include_all.sh: No such file or directory
```

### Root cause

`aba.sh` dispatches to `$ABA_ROOT/scripts/cluster-info.sh` (full path), but the script itself does `source scripts/include_all.sh` (relative path requiring the `scripts/` symlink in the cluster directory). After `make clean`, the symlink is removed.

Only 4 out of 77+ scripts have a proper initialization guard like:
```
[ ! -f scripts/include_all.sh ] && echo "Error: Cluster directory not yet initialized!" && exit 1
```

All other scripts produce raw shell errors when the symlink is missing.

### Suggested fix

Either: (a) run `make -s init` before dispatching to cluster scripts, (b) add the guard to all scripts, or (c) check for `scripts/` symlink in `aba.sh` before dispatch and give a clear error.

---

## Bug #471 — ~~FIXED~~ `verify-mirror-conf` typo: "reprecated" should be "deprecated"

**Status:** FIXED in commit 498cfeb2 — corrected typo
**Severity:** TRIVIAL — Spelling error in error message  
**Found:** 2026-06-19 (code review)  
**Component:** Core ABA (`scripts/include_all.sh`, line 628)

### Description

```
echo_red "Error: 'reg_root' is reprecated. Use 'data_dir' instead in 'mirror/mirror.conf'"
```

"reprecated" should be "deprecated".

### Fix

Change "reprecated" to "deprecated".

---


## Bug #472 — `aba --channel eus` accepted but bare "eus" is not a valid Cincinnati channel

**Status:** NOT A BUG — bare `eus` is a valid short channel name; ABA internally appends `-X.Y` when querying Cincinnati (same as stable/fast/candidate)
**Severity:** LOW-MEDIUM — Silently stores invalid channel, fails on next version lookup
**Found:** 2026-06-19 (live CLI testing)  
**Component:** Core ABA (`scripts/aba.sh`, `--channel` flag, line ~455)

### Description

The `--channel` flag accepts `eus` (or `e`) as a valid channel name. But bare "eus" is NOT a valid OpenShift Cincinnati channel. Valid EUS channels are version-qualified: `eus-4.18`, `eus-4.20`, etc.

### Reproduction

```
aba --channel eus
# Succeeds! Writes ocp_channel=eus to aba.conf

aba --channel eus --version latest
# curl: (22) The requested URL returned error: 404
# Error: failed to look up the latest version for channel [eus]
```

The Cincinnati graph API at `https://api.openshift.com/api/upgrades_info/v1/graph?channel=eus-4.21&arch=amd64` works (note the version-qualified format `eus-4.21`), but `channel=eus` alone returns 404.

### Root cause

The case statement at line ~455 accepts bare `eus`:
```
case "$chan" in
    stable | s) chan=stable ;;
    fast | f)   chan=fast ;;
    eus | e)    chan=eus ;;        <-- should require eus-X.Y format
    candidate | c) chan=candidate ;;
esac
```

### Suggested fix

Either:
1. Remove bare `eus` from the case and require the full format (`eus-4.18`, `eus-4.20`): add a pattern `eus-[0-9].[0-9]*` to the case
2. Or auto-derive: when user passes `eus`, append the major.minor from `ocp_version` to make `eus-4.21`

---

## Bug #473 — ~~FIXED~~ `aba bundle --out filename.tar` produces double-suffixed output path

**Status:** FIXED — strips existing `.tar` suffix before appending `-$ocp_version.tar`

**Severity:** LOW — Confusing filename, user must use base name without .tar
**Found:** 2026-06-19 (live CLI testing)  
**Component:** Core ABA (`scripts/make-bundle.sh`, line 102)

### Description

The bundle creation script ALWAYS appends `-$ocp_version.tar` to the output path. If the user passes a filename ending in `.tar`, the result is double-suffixed:

```
aba bundle --out /tmp/my-bundle.tar
# Creates: /tmp/my-bundle.tar-4.21.19.tar
```

Expected behavior: `/tmp/my-bundle.tar` should be used as-is (or at most version-stamped without doubling the extension).

### Root cause

Line 102 in `make-bundle.sh`:
```
bundle_dest_file="$bundle_dest_file-$ocp_version.tar"
```
This always appends regardless of whether the path already has a `.tar` extension.

### Suggested fix

Check if the filename already ends in `.tar` and only append the version:
```
if [[ "$bundle_dest_file" == *.tar ]]; then
    bundle_dest_file="${bundle_dest_file%.tar}-$ocp_version.tar"
else
    bundle_dest_file="$bundle_dest_file-$ocp_version.tar"
fi
```

---

## Bug #477: `aba cluster --starting-ip 999.999.999.999` accepted (invalid octets, CLI)

**Status:** FIXED — _valid_ipv4() rejects octets > 255 in --starting-ip  
**Severity**: Low (format-only validation, caught downstream but with confusing error)  
**Component**: CLI (`scripts/aba.sh`)  
**Discovered**: 2026-06-19  
**Verified**: Yes (live on conno — accepted by CLI, fails later in verify-cluster-conf)

### Reproduction

```
aba cluster --name test --type sno --starting-ip 999.999.999.999
# CLI accepts it (no IP error), fails downstream with "platform incorrectly set"
```

### Expected behavior

Should reject with: "Invalid IP address: 999.999.999.999 (octets must be 0-255)"

### Root cause

Line 871 in `aba.sh`:
```
if echo "$2" | grep -q -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
```
This regex validates format only (1-3 digits per octet). It does NOT validate that each octet <= 255. The existing `_valid_ip()` function in `include_all.sh` (line 73) does proper validation but isn't used here.

### Suggested fix

Use `_valid_ip` for the check (after sourcing include_all.sh), or add octet range check inline.

---

## Bug #486: TUI mirror verify cache not invalidated when `ocp_version` changes via CLI

**Status:** OPEN  
**Severity**: MEDIUM — Misleading UI status  
**Component**: TUI startup + CLI (`scripts/include_all.sh`, `tui/v2/tui-lib.sh`)  
**Discovered**: 2026-06-23  
**Verified**: Yes (live TUI test on conno, dev branch)

### Reproduction

1. Have a mirror that previously synced images for version X (e.g., 4.22.1)
2. Via CLI: `aba --version 4.20.20` (change to a version NOT in the mirror)
3. Launch TUI: `abatui --conno`
4. Main menu shows "Status: mirror ready" and "Sync images to mirror (synced)"
5. But `aba -d mirror verify` shows "Release image for v4.20.20 is NOT available"

### Root cause

`aba_mirror_verify_start()` calls `run_once -i "aba:mirror:check-image"` which is a no-op if a cached result already exists. The cached exit code (0 = success) was from a PREVIOUS version check. When `ocp_version` changes via CLI (`aba --version`), nothing invalidates the run_once cache.

The TUI wizard path (Bug #322 fix) calls `_invalidate_mirror_cache` after version changes, but the CLI path does not trigger any TUI cache invalidation.

Additionally, there is NO TTL set on the `aba:mirror:check-image` task, so the cached result persists indefinitely.

### Expected

TUI startup should force-refresh the mirror verify when `ocp_version` in aba.conf differs from the version that was last verified.

### Suggested fix

Either:
1. Add a TTL (e.g., `-t 5m`) to `aba_mirror_verify_start` so the check re-runs periodically, OR
2. At TUI startup, compare current `ocp_version` with a stored "last verified version" and invalidate if different, OR
3. Have `aba --version` CLI write a flag that TUI checks on startup to force refresh.

---

## Bug #488: `_upgrade_preflight_check` uses non-existent `./kubeconfig` path (uncommitted code)

**Status:** FIXED (committed in 9e024a6)  
**Severity**: HIGH — Upgrade safety gate is COMPLETELY NON-FUNCTIONAL  
**Component**: TUI (`tui/v2/tui-cluster.sh`, line 2236)  
**Discovered**: 2026-06-23  
**Verified**: Yes (code analysis + live confirmed on conno: wrong kubeconfig path means `oc` fails silently, `|| true` absorbs error, grep for "Upgradeable=False" never matches → gate NEVER triggers)  
**Impact**: The entire upgrade safety gate added in commit 9e024a6 is dead code — it can never detect Upgradeable=False because it reads from a non-existent file. Users will never see the safety warning dialog.

### Reproduction

1. Have an installed cluster (e.g., `sno`)
2. Navigate to Day-2 → Upgrade in TUI
3. Select a version → `_upgrade_preflight_check` runs
4. `oc --kubeconfig ./kubeconfig adm upgrade` fails silently (no file at that path)
5. Gate check never detects "Upgradeable=False" → user proceeds blindly

### Root cause

Line 2236: `_adm_out=$(cd "$ABA_ROOT/$cluster_dir" && oc --kubeconfig ./kubeconfig adm upgrade 2>&1) || true`

The kubeconfig is NOT at `$cluster_dir/kubeconfig`. It's at:
- `~/.aba/clusters/<name>.<domain>/kubeconfig` (externalized state)
- Or `$cluster_dir/iso-agent-based/auth/kubeconfig` (legacy local path)

The function should use `cluster_kubeconfig()` from `include_all.sh` to resolve the correct path.

### Suggested fix

Replace `./kubeconfig` with:
```bash
local _kc
_kc=$(cd "$ABA_ROOT/$cluster_dir" && source <(normalize-cluster-conf) && cluster_kubeconfig "$cluster_name" "$base_domain")
[ -z "$_kc" ] && return 0  # Can't check, skip gate
_adm_out=$(oc --kubeconfig "$_kc" adm upgrade 2>&1) || true
```

---

## Bug #489: `aba --version X.Y.Z-rc.N` does not auto-set channel to `candidate`

**Status:** OPEN  
**Severity**: LOW — Configuration mismatch  
**Component**: CLI (`scripts/aba.sh`, `--version` handler)  
**Discovered**: 2026-06-23  
**Verified**: Yes (live test on conno: `aba --version 4.21.0-rc.2` → `aba.conf` has `ocp_channel=stable`)

### Reproduction

```bash
aba --channel stable --version 4.20.20  # start with stable
aba --version 4.21.0-rc.2              # set RC version
grep ocp_ aba.conf                      # shows: ocp_channel=stable, ocp_version=4.21.0-rc.2
```

### Root cause

The `--version` handler (line ~488) sets the version but does not check if it's a pre-release suffix (`-rc.N` or `-ec.N`). It uses whatever channel is already set (`$ocp_channel`). The README says "Use the `candidate` channel for pre-release versions."

### Expected

When a version with `-rc.N` or `-ec.N` suffix is set, `aba` should either:
1. Auto-set `ocp_channel=candidate`, OR
2. Warn the user that pre-release versions require the candidate channel

### Impact

The mismatch may cause Cincinnati API lookups to fail or return wrong results since the stable channel doesn't contain RC versions.

---

## Bug #490: Sync confirmation shows misleading version range from stale ISC

**Status:** OPEN  
**Severity**: MEDIUM — Misleading UI  
**Component**: TUI (`tui/v2/tui-mirror.sh`, `_mirror_op_confirm()` line ~432)  
**Discovered**: 2026-06-23  
**Verified**: Yes (live TUI test on conno: sync dialog showed "OCP: 4.20.20 → 4.22.1" when ISC was stale)

### Reproduction

1. Have ISC generated for version 4.22.1 (from a previous configuration)
2. Change version via CLI: `aba --version 4.20.20`
3. Launch TUI, select "Sync images to mirror"
4. Confirmation dialog shows: "OCP: 4.20.20 → 4.22.1 (stable)"

### Root cause

Lines 432-436 of `_mirror_op_confirm()`:
```bash
if [[ -z "$_target" && -f "$ABA_ROOT/mirror/data/imageset-config.yaml" ]]; then
    _target=$(grep '^\s*maxVersion:' ... | head -1 | sed 's/.*maxVersion: *//')
fi
if [[ -n "$_target" && "$_target" != "$_ver" ]]; then
    _ver="${_ver} → ${_target}"
fi
```

When there's no explicit `ocp_version_target` set, the code falls back to reading `maxVersion` from the ISC. If the ISC is stale (from a different version/channel), this creates a misleading "upgrade range" display. The user sees "4.20.20 → 4.22.1" and may think they're upgrading, when actually the ISC just hasn't been regenerated.

### Expected

Either:
1. Don't show the ISC maxVersion as an "upgrade target" unless `ocp_version_target` is explicitly set, OR
2. Warn that ISC version doesn't match aba.conf version and offer to regenerate

---

## Bug #491: `aba --type sno cluster --name X` fails due to arg ordering dependency

**Status:** OPEN  
**Severity**: LOW — Confusing error message  
**Component**: CLI (`scripts/aba.sh`, `_set_cluster_conf()` line ~344)  
**Discovered**: 2026-06-23  
**Verified**: Yes (live test on conno: error "Flag --type sets cluster config but no cluster.conf found")

### Reproduction

```bash
aba --type sno cluster --name testbug1
# ERROR: Flag --type sets cluster config but no cluster.conf found.
```

vs (works):
```bash
aba cluster --name testbug1 --type sno  # works
```

### Root cause

The `_set_cluster_conf()` function (uncommitted code, line 344) checks:
1. `[ -f cluster.conf ]` — FALSE (not in cluster dir yet)
2. `[ "$cur_target" = "cluster" ]` — FALSE (`cluster` keyword not yet parsed)

Since `--type` is parsed BEFORE `cluster` in the argument list, `cur_target` hasn't been set yet. The error message suggests using `aba -d <cluster> --type` which is a different use-case.

### Expected

Either accept `--type` before `cluster` target (delay evaluation), OR show a clearer error: "Place --type after 'cluster' target: aba cluster --name X --type sno"

---

## Bug #492: `aba --channel eus` accepted without validation (still open)

**Status:** NOT A BUG — duplicate of #472; bare eus is a valid short channel name  
**Severity**: LOW  
**Component**: CLI (`scripts/aba.sh`)  
**Discovered**: 2026-06-23  
**Verified**: Yes (live test on conno: `aba --channel eus` → accepted, wrote to aba.conf)

### Note

Bug #472 was reported previously. Re-verified on 2026-06-23 that it's still open on the dev branch. The `--channel` handler accepts `eus` (and presumably any string that matches the case statement), but `eus` is later silently converted to `stable` at line 1463 (`[ "$ocp_channel" = "eus" ] && ocp_channel=stable`). This silent conversion is confusing — better to reject at the CLI handler level.

---

## Bug #493: `_day2_status()` uses hardcoded `iso-agent-based/auth/kubeconfig` path (TUI)

**Status:** FIXED (commit pending)  
**Severity**: HIGH — Day-2 Status display is broken for installed clusters  
**Component**: TUI (`tui/v2/tui-cluster.sh`, line ~2164)  
**Discovered**: 2026-06-23  
**Verified**: Yes (code analysis + live check: `ls ~/aba/sno/iso-agent-based/auth/kubeconfig` → No such file)

### Reproduction

1. Have a cluster installed (e.g., `sno`)
2. Navigate to Day-2 → Cluster status
3. Select the installed cluster
4. Output shows "(Cluster API unreachable)" for all sections

### Root cause

Line 2164: `local kc="$ABA_ROOT/$cl_dir/iso-agent-based/auth/kubeconfig"`

This path does NOT exist for clusters that have been externalized to `~/.aba/clusters/<name>.<domain>/`. The kubeconfig is at:
- `~/.aba/clusters/<name>.<domain>/kubeconfig` (preferred, via `cluster_kubeconfig()`)
- `$cluster_dir/clusterstate/kubeconfig` (symlink to the above)

Same root cause as Bug #488 but in the `_day2_status` function.

### Suggested fix

Replace line 2164 with:
```bash
source <(cd "$ABA_ROOT/$cl_dir" && normalize-cluster-conf) 2>/dev/null
local kc
kc=$(cd "$ABA_ROOT/$cl_dir" && cluster_kubeconfig "$cluster_name" "$base_domain" 2>/dev/null)
[ -z "$kc" ] && kc="$ABA_ROOT/$cl_dir/iso-agent-based/auth/kubeconfig"  # fallback
```

---

## Bug #495: Bundle+internet dialog ESC/Help destructively removes .bundle marker

**Status:** OPEN (code analysis confirmed)  
**Severity**: MEDIUM — Data loss (bundle marker), forces unintended mode switch  
**Component**: TUI (`tui/v2/abatui2.sh`, lines 410-426)  
**Discovered**: 2026-06-23  
**Verified**: Code confirmed; not yet reproduced live (requires bundle on conno)

### Description

When `_detect_mode()` finds `.bundle` present AND internet is available, it shows a yesno dialog:
"Use DISCO mode?" (Yes) vs "Switch to Connected?" (No).

The `else` branch (any non-zero return) runs `rm -f "$ABA_ROOT/.bundle"` and sets CONNO mode.
This catches:
- rc=1 (No — intentional) ✓
- rc=255 (ESC — should cancel/go back) ✗
- rc=2 (Help — if help button exists) ✗

### Impact

User pressing ESC (expecting "go back" or "do nothing") permanently loses the `.bundle` marker.
They must re-transfer and re-extract the bundle to get back to DISCO mode.

### Suggested fix

```bash
if [[ $rc -eq 0 ]]; then
    _TUI_MODE="DISCO"
elif [[ $rc -eq 1 ]]; then
    # Only "No" (explicit choice) removes bundle
    rm -f "$ABA_ROOT/.bundle"
    _TUI_MODE="CONNO"
else
    # ESC/Help — treat as cancel, stay in DISCO
    _TUI_MODE="DISCO"
fi
```

---

## Bug #496: DISCO light-bundle first-run exits TUI entirely (no retry)

**Status:** OPEN (code analysis confirmed)  
**Severity**: MEDIUM — Poor UX, forces TUI restart  
**Component**: TUI (`tui/v2/tui-disco.sh`, lines 99-109)  
**Discovered**: 2026-06-23  
**Verified**: Code confirmed

### Description

When `.bundle` exists but `mirror_has_archives()` is false (no `mirror_*.tar` files found),
`_disco_bundle_wizard_gate()` shows a message "No mirror archive files found" and returns 1.

The call chain:
1. `_disco_bundle_wizard_gate` returns 1
2. `disco_main` does `_disco_bundle_wizard_gate || return 1` → returns 1
3. `abatui2.sh` main loop: `disco_main || disco_rc=$?` → disco_rc=1
4. Not equal to 2 (mode re-detect), so `break` → TUI exits

Meanwhile, `disco_load_images()` has a proper "Check again" loop for this exact scenario
(light bundle where archives are copied after TUI start). But users never reach that menu.

### Impact

Light-bundle users who start the TUI before copying archives must quit and restart.
The UX should allow waiting/retrying within the TUI.

### Suggested fix

Instead of `return 1`, enter a wait loop or fall through to the DISCO menu
where the user can use "Load Images" (which has the Check again loop).

---

## Bug #498: ESC on Light/Full bundle dialog proceeds with full bundle instead of canceling

**Status:** OPEN  
**Severity**: MEDIUM — Unintended long-running operation (full bundle with doubled disk usage)  
**Component**: TUI (`tui/v2/tui-mirror.sh`, `mirror_create_bundle()`, lines ~1380-1395)  
**Discovered**: 2026-06-23  
**Verified**: Yes (live reproduction on conno — ESC triggered disk warning then full bundle execution)

### Reproduction

1. TUI CONNO menu → "Create Install Bundle" (B)
2. Accept default path `/tmp/ocp-bundle` → press Next
3. Same-filesystem detected → "Light bundle / Full bundle" dialog appears
4. Press **ESC** (expecting cancel)
5. **Result**: Disk space warning appears (full bundle path)
6. Press Enter on warning → full bundle starts executing

### Root cause

Same pattern as Bug #495. `dialog --yesno` returns 255 for ESC, which fails the `$? -eq 0` check and falls into the `else` branch (full bundle code path). No separate handling for rc=255.

```bash
dlg ... --yesno "$TUI2_MSG_BUNDLE_LIGHT_CONFIRM" 0 0
if [[ $? -eq 0 ]]; then
    light_flag="--light"
else
    # ESC (255) lands here too!
    # Full bundle on same device — warn about disk space
    ...
fi
```

### Suggested fix

```bash
local _rc=$?
if [[ $_rc -eq 0 ]]; then
    light_flag="--light"
elif [[ $_rc -eq 255 ]]; then
    return 1  # ESC = cancel
else
    # Full bundle warning...
fi
```

### Pattern note

This is the THIRD instance of "ESC on yesno treated as No" (see also #495, and the bundle+internet dialog). Systemic fix: all `--yesno` dialogs should handle rc=255 as cancel/back.

---

## Bug #500: DIRECT mode help text mentions "Monitor Cluster" which doesn't exist in menu

**Status:** OPEN (code confirmed)  
**Severity**: LOW — Help text misleading  
**Component**: TUI (`tui/v2/tui-direct.sh`, line 738)  
**Discovered**: 2026-06-23  
**Verified**: Code confirmed

### Description

The DIRECT mode help text (shown when user presses Help in `_direct_action_menu`) lists:
```
Workflow:
  1. Install Cluster — configure, review, and provision OpenShift
  2. Monitor Cluster — track install progress until completion
  3. Day-2 — post-install config (resources, NTP, update service, etc.)
```

But the actual DIRECT action menu only has: Install Cluster, Day-2, Configure, Rerun Wizard, Advanced.
There is no separate "Monitor Cluster" menu item. The install flow handles monitoring internally.

### Suggested fix

Update help text to match actual menu items or remove the "Monitor Cluster" line.

---

## Bug #501: CONNO wizard cancel exits TUI silently (no error dialog)

**Status:** OPEN (code confirmed)  
**Severity**: LOW — Poor UX on first run only  
**Component**: TUI (`tui/v2/abatui2.sh`, `_conno_main()`, line 477)  
**Discovered**: 2026-06-23  
**Verified**: Code confirmed

### Description

When entering CONNO mode for the first time (no `ocp_channel` or `ocp_version` in aba.conf),
`_conno_main()` runs `direct_wizard`. If the user cancels the wizard (presses Back on first step):

1. `direct_wizard` returns non-zero
2. `direct_wizard || return 1` → `_conno_main` returns 1
3. Outer loop: `_conno_main` then `break` → TUI exits without any error/explanation

The user sees: wizard cancelled → TUI disappears. No "Exiting..." dialog, no explanation that
the wizard is required for first-time setup.

### Suggested fix

Either show a message ("Configuration is required for first use. Exit TUI?") or loop back
to offer the wizard again instead of silently exiting.

---

## Bug #502: TUI title bar shows stale version/channel after external aba.conf changes

**Status:** OPEN (live reproduced)  
**Severity**: MEDIUM — Misleading display, wrong version shown in multiple places  
**Component**: TUI (`tui/v2/abatui2.sh`, `tui/v2/tui-lib.sh` `ui_backtitle()`)  
**Discovered**: 2026-06-23  
**Verified**: Live on conno — Changed aba.conf from candidate/4.22.2 to stable/4.20.20 via CLI, TUI continued showing candidate/4.22.2

### Description

The TUI sources `aba.conf` only at startup (line 206) and after Rerun Wizard (line 723). The shell
variables `$ocp_version` and `$ocp_channel` remain stale if `aba.conf` is modified externally (via
CLI `aba --channel stable --version 4.20.20`).

Affected locations:
1. **Title bar** — `ui_backtitle()` reads `$ocp_version`/`$ocp_channel` (line 332-333 tui-lib.sh)
2. **Install wizard "OpenShift X.Y.Z"** — Uses stale `$ocp_version`
3. **Rerun Wizard "Resume" dialog** — Shows stale "Current configuration"
4. **Prepare Upgrade "Current configured"** — Shows stale `$ocp_version`

### Reproduction

1. Start TUI (shows stable 4.20.20)
2. In another terminal: `aba --channel candidate --version 4.22.2`
3. Navigate menus in TUI — title bar still shows stable 4.20.20 (stale)
4. OR: Start TUI with candidate/4.22.2, then `aba --channel stable --version 4.20.20`
   → TUI still shows candidate/4.22.2 everywhere

### Suggested fix

Re-source `aba.conf` at the top of each main menu loop iteration (line ~495 `while :; do`):
```bash
source <(cd "$ABA_ROOT" && normalize-aba-conf) 2>/dev/null || true
```

---

## Bug #503: Wizard version picker shows "Current" from previous channel (may not exist in new channel)

**Status:** OPEN (live reproduced)  
**Severity**: LOW — Misleading option, could lead to sync error if selected  
**Component**: TUI (`tui/v2/tui-direct.sh`, version picker)  
**Discovered**: 2026-06-23  
**Verified**: Live on conno — After switching from candidate to stable channel

### Description

When the wizard's version picker shows options for a newly selected channel, it includes
"Current (X.Y.Z)" which is the previously configured version. This version may not exist in
the new channel.

Example observed:
- Previous: candidate channel, version 4.22.2
- User selects: stable channel
- Version picker shows: Current (4.22.2), Latest (4.22.1), Previous (4.21.19), Older (4.20.24)
- But 4.22.2 does NOT exist in the stable channel! (Latest stable is 4.22.1)

If user selects "Current (4.22.2)" in stable, the ISC would reference stable-4.22/4.22.2 which
may fail during oc-mirror sync.

### Suggested fix

Either: remove "Current" if it doesn't match the selected channel's available versions,
or validate the selected version against the channel's graph before proceeding.

---

## Bug #504: Platform ✓ checkmark only verifies config file existence, not connection

**Status:** OPEN (live reproduced)  
**Severity**: LOW — Misleading UI indicator  
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 807-814)  
**Discovered**: 2026-06-23  
**Verified**: Live on conno — KVM shows ✓ with template/invalid values

### Description

The green ✓ checkmark next to the platform name in the Cluster Basics page only checks
if the configuration FILE exists (via `-s`). It does NOT verify:
- Whether the values are valid (not template defaults)
- Whether the connection works (can reach hypervisor)
- Whether credentials are correct

Observed: Selected KVM platform → showed "kvm (libvirt/KVM) ✓" even though `kvm.conf`
contained only template values (`kvm-user@kvmhost.lan/system` which doesn't exist).

The ✓ misleads users into thinking the platform is verified and ready.

### Code

```bash
[[ "$cl_platform" == "kvm" ]] && [[ -s "$ABA_ROOT/kvm.conf" || -s "$HOME/.kvm.conf" ]] && _conf_ok=true
if $_conf_ok; then
    _plat_status=" \Z2\Zb✓\Zn"   # Shows green checkmark
```

### Suggested fix

Either:
- Change ✓ to a neutral indicator (e.g., "configured") when only file-exists is checked
- Add a quick connectivity test (like the VMware `govc about` test in the Advanced menu)
- Show ✓ only after successful connection test, ⚠ for "file exists but untested"

---

## Bug #499: mirror_has_archives() vs _validate_payload() inconsistent glob+size checks

**Status:** OPEN (code analysis confirmed)  
**Severity**: MEDIUM — Can land user in DISCO mode then immediately exit TUI  
**Component**: TUI (`tui/v2/tui-lib.sh` + `tui/v2/abatui2.sh`)  
**Discovered**: 2026-06-23  
**Verified**: Code confirmed

### Description

Two functions check for image archives with different criteria:

| Function | Location | Glob | Size check |
|----------|----------|------|-----------|
| `_validate_payload()` | `abatui2.sh:375` | `*.tar` | >1MB |
| `mirror_has_archives()` | `tui-lib.sh:938` | `mirror_*.tar` | None |

### Scenario that breaks

1. User has `data.tar` (or any non-`mirror_*` named tar) > 1MB in `mirror/data/`
2. `_validate_payload()` passes → mode detection sets DISCO
3. `_disco_bundle_wizard_gate()` calls `mirror_has_archives()` → fails (no `mirror_*.tar`)
4. Gate returns 1 → TUI exits (Bug #496)

Also: a 0-byte `mirror_seq1_000000.tar` passes `mirror_has_archives()` but would fail at load time.

### Suggested fix

Both functions should use the same glob (`mirror_*.tar`) AND the same minimum size check (>1MB).

---

## Bug #505: `filter_disco_values()` is dead code — DISCO mode NTP/DNS never filtered

**Status:** OPEN (code analysis confirmed)  
**Severity**: MEDIUM — Public DNS/NTP entries (8.8.8.8, time.google.com) pass through to cluster.conf in DISCO mode  
**Component**: TUI (`tui/v2/tui-lib.sh`, lines 43-66)  
**Discovered**: 2026-06-23  
**Verified**: grep confirms function is never called anywhere in the codebase

### Description

The function `filter_disco_values()` is defined in `tui-lib.sh` (line 43) and documented in
`tui/SPEC.md` as: "DISCO mode filter — filter_disco_values() strips public NTP/DNS from input fields."

However, the function is **never called** anywhere in the TUI v2 code, TUI v1 code, or any other
script. It is complete dead code.

**Impact**: In DISCO (fully disconnected) mode, if a user enters public DNS servers (8.8.8.8, 1.1.1.1)
or public NTP servers (time.google.com, pool.ntp.org) during cluster configuration, these values are
stored in `cluster.conf` and passed to the cluster. In a disconnected environment, these servers are
unreachable, potentially causing:
- DNS resolution failures if only public DNS was configured
- NTP synchronization failures if only public NTP was configured
- Cluster bootstrap delays waiting for unreachable time sources

### Code

```bash
# Defined in tui/v2/tui-lib.sh lines 43-66 — NEVER CALLED
filter_disco_values() {
    local input="$1"
    [[ -z "$input" ]] && return 0
    [[ "$_TUI_MODE" != "DISCO" ]] && { echo "$input"; return 0; }
    # ... filters out 8.8.8.8, 1.1.1.1, time.google.com, etc.
}
```

### Where it should be called

Either:
1. In `_persist_cluster_draft()` when writing `dns_servers` and `ntp_servers`
2. In the network page (`_cluster_page_network`) after the user confirms DNS/NTP input
3. In `_cluster_generate_defaults()` after loading defaults from `aba.conf`

### Suggested fix

Add filter calls before persisting DNS/NTP in DISCO mode:
```bash
# In _persist_cluster_draft():
local _filtered_dns=$(filter_disco_values "$cl_dns")
local _filtered_ntp=$(filter_disco_values "$cl_ntp")
replace-value-conf -q -n dns_servers -v "$_filtered_dns" -f "$_conf"
replace-value-conf -q -n ntp_servers -v "$_filtered_ntp" -f "$_conf"
```

---

## Bug #509: Operator set swap (same basket size) bypasses dirty detection — ISC not regenerated — FIXED

**Status:** FIXED (2026-06-24, commit `92a191b0`) — uses md5sum of sorted keys instead of count  
**File:** `tui/v2/tui-mirror.sh`
**Lines:** 977-982
**Severity:** MEDIUM
**Category:** Logic error — stale ISC after operator set change
**Found:** 2026-06-23 (code analysis)

### Description

In `_operator_menu()`, the dirty detection for operator basket changes uses a **size comparison**:

```bash
case "$choice" in
    1) local _pre_count=${#OP_BASKET[@]}
       _operator_sets "$version_short"
       if [[ ${#OP_BASKET[@]} -ne $_pre_count ]]; then
           _OP_BASKET_DIRTY=true
           _persist_operator_basket
       fi
```

The `_operator_sets()` function can **both remove and add** operators in a single call
(uncheck one set, check another). If the net basket size remains unchanged (e.g., swap
"ocp" set (5 ops) for "virt" set (5 ops)), the size comparison is equal and
`_OP_BASKET_DIRTY` is never set.

### Reproduction scenario

1. Start with basket containing "ocp" set (e.g., 5 operators)
2. Open "Select Operator Sets" (option 1)
3. Uncheck "ocp", check "virt" (assume "virt" also has 5 operators)
4. Press "Apply"
5. Basket now has 5 DIFFERENT operators — but `_pre_count == ${#OP_BASKET[@]}` (both 5)
6. `_OP_BASKET_DIRTY` stays false, `_persist_operator_basket` is NOT called
7. ISC is NOT regenerated — mirror sync/save will use the OLD operator list

### Impact

After swapping operator sets of equal size, the ImageSet Config retains the old operator
list. Subsequent `aba mirror sync` or `aba mirror save` pulls the wrong operators.
The user's selection appears correct in the TUI (basket shows new operators) but the
actual mirror operation uses stale config.

### Suggested fix

Track content changes instead of (or in addition to) size changes. Options:

**Option A** — Always mark dirty after `_operator_sets` returns (conservative):
```bash
1) _operator_sets "$version_short"
   _OP_BASKET_DIRTY=true
   _persist_operator_basket
   default_item=3
   ;;
```

**Option B** — Compare a sorted key hash before/after:
```bash
1) local _pre_keys
   _pre_keys=$(printf '%s\n' "${!OP_BASKET[@]}" | sort | md5sum)
   _operator_sets "$version_short"
   local _post_keys
   _post_keys=$(printf '%s\n' "${!OP_BASKET[@]}" | sort | md5sum)
   if [[ "$_pre_keys" != "$_post_keys" ]]; then
       _OP_BASKET_DIRTY=true
       _persist_operator_basket
   fi
   default_item=3
   ;;
```

Option A is simpler and only costs one extra ISC regen (fast, non-blocking background task).

**Note:** The SAME size-based dirty detection issue exists for option 2 (`_operator_search`,
lines 986-990). If a search result shows operators already in the basket and the user
unchecks some and checks an equal number of different ones, the basket size stays the same
but content changes — same failure mode.

---

## ~~Bug #510~~ FALSE POSITIVE — DISCO mode connection override IS handled

**Status:** NOT A BUG — `_apply_mode_connection()` (line 690-696) correctly forces
`cl_connection="mirror"` in DISCO mode. It's called at lines 697, 728, and 932
(after every `_cluster_load_conf`). The code is correct.

---

## Bug #511: Upgrade manual version entry — Cancel after invalid input shows spurious "not found" error — FIXED

**Status:** FIXED (2026-06-24, commit `0ecf8ee7`) — clear `_target_ver` on Cancel  
**File:** `tui/v2/tui-mirror.sh`
**Lines:** 576-603
**Severity:** LOW
**Category:** UX — confusing error after cancel
**Found:** 2026-06-23 (code analysis)

### Description

In `mirror_prep_upgrade()`, the manual version entry loop (case `m`) has a subtle
flow issue. When the user:

1. Picks "Manual entry"
2. Types an invalid format (e.g., "abc") — gets "Invalid format" error, loops
3. On second prompt, presses Cancel

The `break` at line 582 exits the inner loop, but `_target_ver` retains the
previously typed invalid value ("abc" from step 2). Then:

- Line 602: `[[ -z "$_target_ver" ]] && continue` — "abc" is not empty, so skip
- Line 607: `verify_release_version_exists "abc" "stable"` runs
- Line 609: Shows "Version abc not found in 'stable' channel" error

The user expects: Cancel → return to version picker (no error).
The user gets: Cancel → "Verifying abc..." → "not found" error → THEN version picker.

### Root cause

`_target_ver` is set at line 583 **inside** the inner loop body. When the user
types something and presses OK, it's stored. On the NEXT iteration when they
press Cancel, the `break` at line 582 fires BEFORE line 583, so the PREVIOUS
iteration's value persists.

### Suggested fix

Reset `_target_ver` before the `break` on cancel:

```bash
[[ $? -ne 0 ]] && { _target_ver=""; break; }
```

Or more defensively, check for validity BEFORE the verification step:

```bash
[[ -z "$_target_ver" ]] && continue
[[ ! "$_target_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?$ ]] && continue
```

---

## Bug #512: `mirror_prep_upgrade` persists target version BEFORE user confirms save — FIXED

**Status:** FIXED (2026-06-24, commit `34a22134`) — moved config write after confirmation dialog  
**File:** `tui/v2/tui-mirror.sh`
**Lines:** 617-630
**Severity:** MEDIUM
**Category:** Premature state mutation — config changed before confirmation
**Found:** 2026-06-23 (live testing)

### Description

In `mirror_prep_upgrade()`, the target version is written to `mirror.conf` and ISC
regeneration is kicked off **before** the user confirms the "Save Upgrade Images"
operation:

```bash
# Line 618: writes BEFORE confirmation
replace-value-conf -q -n ocp_version_target -v "$_target_ver" -f "$ABA_ROOT/mirror/mirror.conf"
tui_kick_isconf_regen                    # Line 619: kicks off ISC regen

# Line 622-630: THEN asks for confirmation
dlg ... --yesno "This will: ... Proceed?" 0 0
[[ $? -ne 0 ]] && return 1              # User cancels but config already changed!
```

### Live reproduction

1. Open "Prepare Upgrade for Transfer" (U) in CONNO menu
2. Previous target was 4.20.23 in mirror.conf
3. Select "Latest (4.22.1)" from the version picker
4. Verification passes, confirmation dialog appears
5. Press Cancel (or Escape)
6. Check `mirror.conf`: `ocp_version_target=4.22.1` — PERSISTED despite cancel!

```
$ grep ocp_version_target ~/aba/mirror/mirror.conf
ocp_version_target=4.22.1   # Was 4.20.23 before the cancelled operation
```

### Impact

After cancelling:
- `mirror.conf` has the new target version (user didn't want this)
- ISC was regenerated with the new target (includes upgrade images to 4.22.1)
- Next `aba mirror sync` or `aba mirror save` will download upgrade images for
  4.22.1 — potentially a MUCH larger download than intended
- User's previous target (4.20.23) is lost without any way to recover

### Suggested fix

Move the config write and ISC regen to AFTER the confirmation:

```bash
# Confirm FIRST
dlg ... --yesno "This will:\n\n\
  1. Set target version to ${_target_ver}\n\
  2. Regenerate the ImageSet Config...\n\
  3. Download upgrade images...\n\nProceed?" 0 0
[[ $? -ne 0 ]] && return 1

# THEN persist and run
replace-value-conf -q -n ocp_version_target -v "$_target_ver" -f "$ABA_ROOT/mirror/mirror.conf"
tui_kick_isconf_regen
confirm_and_execute "aba --dir mirror --target-version $_target_ver save..." "..."
```

This ensures the config is only modified when the user actually commits to the operation.

---

## Bug #513: Platform config forms and toggles persist changes before wizard Cancel — no rollback
**Status:** OPEN

**Severity:** Medium (data corruption on cancel)
**Component:** TUI v2 — cluster wizard, VMware/KVM config forms
**File:** `tui/v2/tui-cluster.sh`

### Description

Three related instances of the same anti-pattern: config files are modified immediately during a wizard-like flow, and pressing Cancel/Back does NOT revert the changes.

#### 513a: Platform toggle on page 1 immediately writes to aba.conf

**Line 986:**
```bash
replace-value-conf -q -n platform -v "$cl_platform" -f "$ABA_ROOT/aba.conf"
```

When the user toggles the Platform field (bm → vmw → kvm → bm) on the cluster wizard's Basics page, the `platform` value is immediately written to `aba.conf`. If the user then presses "Back" to cancel the wizard, `aba.conf` retains the toggled value.

#### 513b: VMware config form writes each field immediately to vmware.conf

**Lines 370, 378, 384, 391, 399, 407, 415, 423, 433** in `_configure_vmw_form()`:

Every field edit (URL, username, password, datastore, etc.) is immediately persisted via `replace-value-conf` to `vmware.conf`. The "Back/Cancel" button (rc=1|255 → `return 1` at line 347) does NOT revert any of these field-level writes.

#### 513c: KVM config form writes each field immediately to kvm.conf

**Lines 522, 530, 538, 546, 554** in `_configure_kvm_form()`:

Same pattern as VMware — each field is immediately persisted. Cancel does not revert.

### Steps to reproduce (513a)

1. Start TUI → CONNO mode → Install Cluster
2. On "Basics" page, note current platform (e.g., `vmw`)
3. Select "P" (Platform) twice to toggle to `bm`
4. Press Back to cancel the wizard
5. Check `aba.conf`: `platform=bm` — the change persisted despite cancel!

### Impact

- User intends to cancel but config files are already modified
- Next TUI session uses the unintended platform value
- For VMware/KVM forms: partial edits (e.g., URL changed but password still old) create inconsistent configs
- The "Cancel" UX contract is violated — users expect cancel to discard changes

### Suggested fix

Buffer changes in memory and only write to files on the "Continue" / "Next" action:

```bash
# _configure_vmw_form: collect all values in locals, write ONLY on Continue
case "$rc" in
    3)  # Continue → write all fields at once
        replace-value-conf -q -n GOVC_URL -v "'$v_url'" -f "$conf_path"
        replace-value-conf -q -n GOVC_USERNAME -v "'$v_user'" -f "$conf_path"
        # ... etc
        break
        ;;
    1|255)  # Cancel → discard (no writes)
        return 1
        ;;
esac
```

For the platform toggle (513a), defer the `replace-value-conf` to `_persist_cluster_draft()` which already runs after page completion.

---

## Bug #514: MAC address validation error clears ALL previously valid addresses — FIXED

**Status:** FIXED (2026-06-24, commit `2d4aabe6`) — removed `cl_macs=""` on validation failure  
**Severity:** Low-Medium (data loss on edit)
**Component:** TUI v2 — cluster wizard page 3 (interface config)
**File:** `tui/v2/tui-cluster.sh`, line 1352

### Description

When editing MAC addresses in the cluster wizard, if ANY MAC in the list fails validation, ALL MACs are cleared (`cl_macs=""`). This means:

1. User previously entered 5 valid MACs
2. User opens MAC editor to fix one MAC (adds a typo)
3. Validation fails on the typo
4. **ALL 5 MACs are cleared** — not just the invalid one
5. Next time the editor opens, it's empty — all valid MACs are lost

### Code

```bash
# tui/v2/tui-cluster.sh, lines 1349-1354
if [[ -n "$_bad_macs" ]]; then
    dlg ... --msgbox "Invalid MAC address(es):..."
    cl_macs=""          # <-- CLEARS ALL MACs
    rm -f "$_mac_edit"
    continue
fi
```

### Steps to reproduce

1. Start cluster wizard → page 3 (interface)
2. Press M to enter MACs
3. Enter 3 valid MACs (e.g., `00:11:22:33:44:55` on separate lines)
4. Press OK → MACs saved
5. Press M again → editor shows the 3 MACs
6. Add a typo to one MAC (e.g., `00:11:22:33:44:ZZ`)
7. Press OK → validation error shown
8. Press M again → editor is EMPTY — all 3 valid MACs are gone

### Impact

- Bare-metal users with many nodes (e.g., 10 MACs) lose all their work on a single typo
- Particularly painful since MACs are typically copied from hardware manifests

### Suggested fix

On validation failure, DON'T clear `cl_macs` — leave it at the previous valid value so the editor re-opens with the last known-good set:

```bash
if [[ -n "$_bad_macs" ]]; then
    dlg ... --msgbox "Invalid MAC address(es):..."
    # Don't clear cl_macs — keep previous valid value
    rm -f "$_mac_edit"
    continue
fi
```

---

## Bug #515: Day-2 "Startup" dialog says "power on VMs" for bare-metal clusters — FIXED

**Status:** FIXED (2026-06-24, commit `cdc2525a`) — uses normalize-aba-conf for platform detection  
**Severity:** Cosmetic
**Component:** TUI v2 — Day-2 lifecycle menu
**File:** `tui/v2/tui-cluster.sh`, line 2407

### Description

The `_day2_startup()` confirmation dialog always says:

> "This will power on the cluster VMs."

But for bare-metal clusters (`platform=bm`), there are no VMs. The underlying `cluster-startup.sh` script correctly handles bare-metal (shows "Please power on all bare-metal servers"), but the TUI confirmation message is always hardcoded for VM platforms.

### Code

```bash
# tui/v2/tui-cluster.sh, line 2407
--yesno "Start cluster '$cl_display'?\n\nThis will power on the cluster VMs." 0 0
```

### Suggested fix

Check the cluster's platform before displaying the message:

```bash
local _start_msg="This will power on the cluster VMs."
if [[ -f "$ABA_ROOT/$SELECTED_CLUSTER/cluster.conf" ]]; then
    local _plat
    _plat=$(grep '^platform=' "$ABA_ROOT/aba.conf" 2>/dev/null | cut -d= -f2)
    [[ "$_plat" == "bm" ]] && _start_msg="This will wait for bare-metal servers to come online."
fi
```

---

## Bug #516: Settings menu shows stale registry vendor after mirror config change — FIXED

**Status:** FIXED (2026-06-24, commit `857f905b`) — refresh `_TUI_REG_VENDOR` from file on loop  
**Severity:** Low (UX inconsistency)
**Component:** TUI v2 — Settings menu vs Mirror Config form
**Files:** `tui/v2/tui-lib.sh` (lines 1151-1265), `tui/v2/tui-mirror.sh` (lines 274-280)
**Confirmed:** Live-tested on conno 2026-06-23

### Description

The Settings menu displays `_TUI_REG_VENDOR` (an in-memory global variable), while the Mirror Config form (`_mirror_config_menu_loop`) has its own local `m_vendor` loaded fresh from `mirror.conf`. When the user toggles `reg_vendor` in the Mirror Config form:

1. `m_vendor` is toggled and written to `mirror.conf` (line 280)
2. `_TUI_REG_VENDOR` (the global) is NOT updated

When the user then opens the Settings menu, it shows the OLD vendor value from `_TUI_REG_VENDOR`.

The reverse direction works correctly: Settings → Mirror Config is consistent because Mirror Config always reads fresh from `mirror.conf`.

### Reproduction (live-tested)

1. Open CONNO main menu
2. Open Settings (C) → shows "Registry Type: Auto"
3. Exit Settings
4. Directly edit `mirror.conf` to set `reg_vendor=quay` (simulating what Mirror Config form does)
5. Open Settings (C) again → still shows "Registry Type: Auto" (stale)

### Suggested fix

Either:
- Update `_TUI_REG_VENDOR` inside `_mirror_config_menu_loop` after toggling (quick fix)
- Or re-read `_TUI_REG_VENDOR` from `mirror.conf` at the top of `_tui_settings_menu()` (more robust)

```bash
# At top of _tui_settings_menu(), refresh from file:
if [[ -f "$ABA_ROOT/mirror/mirror.conf" ]]; then
    local _raw_v
    _raw_v=$(grep '^reg_vendor=' "$ABA_ROOT/mirror/mirror.conf" 2>/dev/null | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//')
    case "${_raw_v,,}" in
        quay|docker|auto) _TUI_REG_VENDOR="${_raw_v,,}" ;;
    esac
fi
```

---

## Bug #517: "Always TUI/Terminal" doesn't skip mode dialog on retry within same command
**Status:** OPEN

**Severity:** Low (UX annoyance)
**Component:** TUI v2 — confirm_and_execute retry logic
**File:** `tui/v2/tui-lib.sh`, lines 515-601

### Description

When the user selects "Always TUI" (option 3) or "Always Terminal" (option 4) in the execution mode dialog:

1. `_TUI_EXEC_MODE` is set to "tui" or "terminal" (lines 590/593)
2. The command executes
3. If the command fails and the user presses "Retry" (exit code 2)
4. `continue` at line 598 loops back to the `while :;` at line 536
5. The execution mode dialog is shown AGAIN

The user chose "Always" but still has to re-select on retry. The `_TUI_EXEC_MODE` check at line 522 only fires on function ENTRY — it's not re-evaluated after the variable is set mid-function.

For subsequent `confirm_and_execute` calls (new commands), the mode IS remembered (line 522 fires). The bug is only within a single invocation's retry loop.

### Code path

```bash
# Line 590-592: mode is set
3) _TUI_EXEC_MODE="tui"
   _exec_in_tui "$cmd" "$title" "$post_cmd_hook" ;;

# Line 598: retry loops back to line 536 (shows dialog again)
[[ $exec_rc -eq 2 ]] && continue
```

### Suggested fix

After setting `_TUI_EXEC_MODE`, add a retry loop similar to lines 524-532:

```bash
3) _TUI_EXEC_MODE="tui"
   tui_log "Exec mode set to: always TUI"
   while :; do
       _exec_in_tui "$cmd" "$title" "$post_cmd_hook"
       local exec_rc=$?
       [[ $exec_rc -eq 2 ]] && continue
       return $exec_rc
   done
   ;;
```

---

## Bug #518: `replace-value-conf` `-v` parsing mishandles empty and hyphen-prefixed values — FIXED

**Severity:** Medium (latent — affects any config value starting with `-` or edge cases with empty values)
**Component:** Core — `replace-value-conf()` in `scripts/include_all.sh`
**File:** `scripts/include_all.sh`, line 1866
**Status:** FIXED (2026-06-24)

### Description

The `-v` argument parsing in `replace-value-conf()` used this condition:

```bash
if [[ -z "$2" || "$2" =~ ^- ]]; then
    local value=
else
    local value="$2"
    shift
fi
shift
```

Two issues:
1. **Empty value (`-v ""`):** The empty string triggers `-z "$2"`, so `value` is set empty (intended). However, the empty string argument `""` is NOT consumed (no extra shift). It remains in `$@` and falls through to the `*` catch-all case, which appends it to `files`. Mostly harmless but incorrect argument parsing.

2. **Hyphen-prefixed value (`-v "-something"`):** A value starting with `-` triggers `"$2" =~ ^-`, causing the value to be discarded and treated as "no value provided." This means config values starting with `-` cannot be set via this function. While rare, it's a latent bug.

### Fix applied

Since ALL callers always pass an explicit argument to `-v` (even `""` for empty), the fix makes `-v` unconditionally consume the next positional argument:

```bash
-v)
    shift
    local value="$1"
    shift
    ;;
```

Semantics: `-v ""` means "comment out" (empty value), `-v "--something"` means set the value to `--something`.

### Verification

- Func tests improved from 60 pass / 11 fail → 62 pass / 9 fail (2 new passes: equals-sign values, flag-like values; 0 regressions)
- 14 targeted edge-case tests pass: empty value, hyphen-prefixed, `-n`/`-v`/`-f`/`-q` as values, equals signs, spaces, pre-quoted passwords with hyphens
- Live tests on conno: TUI password workflow (`-v "'$m_pw'"` pattern), version strings (`4.21.0-rc.2`), platform switching all work correctly

---

## Bug #519: Cluster config drift detection produces false positive warnings (missing comment strip)

**Severity:** Medium (spams warnings on every operation after any cluster install)
**Component:** Core — `_state_override_cluster()` in `scripts/include_all.sh`
**File:** `scripts/include_all.sh`, line 881
**Status:** FIXED (2026-06-24, together with Bug #523)

### Description

The cluster drift detection at line 881:
```bash
_cval=$(grep "^${_field}=" cluster.conf 2>/dev/null | head -1 | cut -d= -f2-)
```

This extracts the value from `cluster.conf` WITHOUT stripping inline comments and trailing whitespace. Since `cluster.conf` uses inline comments:
```
cluster_name=ocp			# Cluster name (used with base_domain for full domain)
base_domain=example.com			# Forms the cluster domain
starting_ip=10.0.0.100			# First static node IP
```

The extracted `_cval` for `cluster_name` would be: `ocp\t\t\t# Cluster name (used with base_domain for full domain)`

But `_sval` from `state.sh` (generated by `externalize_cluster_state()`) is just: `ocp`

These will NEVER match → false positive drift warning for EVERY immutable field on EVERY operation after cluster install.

### Contrast with mirror version (line 900-901)

The mirror drift detection correctly strips comments:
```bash
_cval=$(grep "^${_field}=" mirror.conf 2>/dev/null | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//')
```

### Suggested fix

Add the same `sed` to line 881:
```bash
_cval=$(grep "^${_field}=" cluster.conf 2>/dev/null | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//')
```

---

## Bug #520: `_upgrade_preflight_check` still uses non-existent `./kubeconfig` path (Bug #488 reintroduced)

**Severity:** High (upgrade safety gate is completely non-functional)
**Component:** TUI v2 — `_upgrade_preflight_check()` in `tui/v2/tui-cluster.sh`
**File:** `tui/v2/tui-cluster.sh` (commit 9e024a64)
**Status:** FIXED (2026-06-24, together with Bug #522)

### Description

The newly added `_upgrade_preflight_check()` function (commit 9e024a64, intended to fix Bugs #420/#399) uses:
```bash
_adm_out=$(cd "$ABA_ROOT/$cluster_dir" && oc --kubeconfig ./kubeconfig adm upgrade 2>&1) || true
```

The path `./kubeconfig` does NOT exist in cluster directories. The correct kubeconfig is at:
- `iso-agent-based/auth/kubeconfig` (in-tree after install)
- `$HOME/.aba/clusters/<name>.<domain>/kubeconfig` (externalized state)

The helper function `cluster_kubeconfig()` (include_all.sh line 779) exists specifically to resolve the correct path.

### Impact

Because `./kubeconfig` doesn't exist:
1. `oc` fails with "no such file or directory"
2. `|| true` suppresses the error
3. `_adm_out` contains the error message (not cluster info)
4. `grep "Upgradeable=False"` never matches
5. Function always returns 0 (proceed)

**Result:** The Upgradeable=False safety gate is NEVER triggered. The upgrade proceeds without checking for admin-ack gates. This is exactly the scenario Bug #420 was supposed to prevent.

### Suggested fix

Replace `./kubeconfig` with the correct path resolution:
```bash
local _kc
_kc=$(cd "$ABA_ROOT/$cluster_dir" && cluster_kubeconfig "$cluster_name" "$base_domain" 2>/dev/null)
[[ -z "$_kc" ]] && _kc="$ABA_ROOT/$cluster_dir/iso-agent-based/auth/kubeconfig"
_adm_out=$(oc --kubeconfig "$_kc" adm upgrade 2>&1) || true
```

---

## Bug #521: `ntp_servers=compact` data corruption — cluster type value written to NTP field
**Status:** OPEN

**Severity:** Medium (data corruption in cluster.conf — observed, root cause uncertain)
**Component:** TUI v2 — cluster wizard persistence / `_persist_cluster_draft()`
**File:** `tui/v2/tui-cluster.sh`

### Description

On `conno`, the cluster config `~/aba/ocp/cluster.conf` was found to contain:
```
ntp_servers=compact
```

"compact" is a cluster TYPE value, not an NTP server address. This is data corruption — the wizard should never write type values into the NTP field.

### Reproduction evidence

```bash
$ grep ntp ~/aba/ocp/cluster.conf
ntp_servers=compact
```

### Root cause analysis

The corruption likely occurs when:
1. `_persist_cluster_draft()` is called (line 146: `replace-value-conf -q -n ntp_servers -v "$cl_ntp" -f "$_conf"`)
2. `cl_ntp` somehow contains "compact" (the type value) due to variable scope leakage or uninitialized state

Possible paths to corruption:
- If `cl_ntp` was never set (uninitialized) and a previous command left "compact" in the environment
- If `_cluster_load_conf` reads a malformed `cluster.conf` where `ntp_servers` was previously corrupted
- If `replace-value-conf` has an arg-parsing edge case (see Bug #518)

### Impact

- NTP configuration is silently corrupted
- The TUI displays "NTP servers: compact" on the network page (confusing)
- No validation error is shown when `_cluster_load_conf` loads the invalid value
- However, `_valid_ip_or_host_list` WOULD reject "compact" if the user edits the NTP field via the TUI dialog

### Suggested mitigation

Add validation when loading `ntp_servers` from cluster.conf:
```bash
ntp_servers) [[ "$val" =~ ^[0-9A-Za-z.,:-]+$ ]] && cl_ntp="$val" ;;
```

---

## Bug #522: Downgrade rejection uses invalid `aba --dir $cluster version` command (always skipped)

**Severity:** Medium (downgrade protection is non-functional)
**Component:** TUI v2 — `_day2_upgrade()` in `tui/v2/tui-cluster.sh`
**File:** `tui/v2/tui-cluster.sh` (commit 9e024a64)
**Status:** FIXED (2026-06-24)

### Description

The downgrade rejection added in commit 9e024a64 uses:
```bash
_cur_ver=$(aba --dir "$SELECTED_CLUSTER" version 2>/dev/null || echo "")
if [[ "$_cur_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] && ! is_version_greater "$target_ver" "$_cur_ver"; then
    dlg ... "Cannot upgrade: version '$target_ver' is not higher than current '$_cur_ver'."
    continue
fi
```

**`aba --dir $cluster version` is NOT a valid ABA command.** It fails with:
```
make: *** No rule to make target 'version'.  Stop.
```

Since `2>/dev/null` suppresses the error and `|| echo ""` catches the non-zero exit, `_cur_ver` is always empty. The regex check then fails (`"" =~ ^[0-9]+...`), and the downgrade protection is ALWAYS SKIPPED.

### Reproduction

```bash
$ cd ~/aba && ./aba --dir ocp version
make: *** No rule to make target 'version'.  Stop.
```

### Impact

Users can attempt downgrades (e.g., 4.20.20 → 4.19.0) without any TUI warning. The `aba upgrade` core command may catch this, but the TUI's friendly dialog never shows.

### Suggested fix

Query the cluster version directly via kubeconfig:
```bash
local _kc
_kc=$(cluster_kubeconfig "$cluster_name" "$base_domain" 2>/dev/null)
if [[ -n "$_kc" && -f "$_kc" ]]; then
    _cur_ver=$(oc --kubeconfig "$_kc" get clusterversion version -o jsonpath='{.status.desired.release.version}' 2>/dev/null || echo "")
fi
```

Or as a simpler fallback, read from the cluster's `aba.conf` (gives configured, not running version):
```bash
_cur_ver=$(cd "$ABA_ROOT/$SELECTED_CLUSTER" && source <(normalize-aba-conf) 2>/dev/null && echo "$ocp_version")
```

---

## Bug #523: `normalize-cluster-conf` cluster name extraction includes inline comments — state override completely broken

**Severity:** Critical (cluster config drift detection and immutable field override is 100% non-functional)
**Component:** Core — `normalize-cluster-conf()` in `scripts/include_all.sh`
**Commit:** 193cd237
**Status:** FIXED (2026-06-24)

### Description

In `normalize-cluster-conf()` at line 685:
```bash
_cn=$(grep '^cluster_name=' cluster.conf 2>/dev/null | head -1 | cut -d= -f2 | xargs)
```

This extracts the cluster name WITHOUT stripping inline comments. A typical `cluster.conf` has:
```
cluster_name=ocp			# Cluster name (used with base_domain for full domain)
```

After `cut -d= -f2 | xargs`, `_cn` becomes:
```
ocp # Cluster name (used with base_domain for full domain)
```

The subsequent glob at line 687:
```bash
for _sd_candidate in "$HOME/.aba/clusters/${_cn}."*; do
```

Tries to match:
```
/home/steve/.aba/clusters/ocp # Cluster name (used with base_domain for full domain).*
```

Which NEVER matches the actual state directory:
```
/home/steve/.aba/clusters/ocp.example.com/
```

Therefore, `_state_override_cluster()` is **NEVER called**. The entire cluster drift detection and immutable field override mechanism (added in commit 193cd237, refined in 0122cf8a) is completely non-functional.

### Live reproduction on conno

```bash
$ cd ~/aba/ocp
$ source ../scripts/include_all.sh
$ _cn=$(grep '^cluster_name=' cluster.conf 2>/dev/null | head -1 | cut -d= -f2 | xargs)
$ echo "_cn=[$_cn]"
_cn=[ocp # Cluster name (used with base_domain for full domain)]

$ ls -d $HOME/.aba/clusters/${_cn}.* 2>/dev/null
# (no output — glob fails)

$ ls $HOME/.aba/clusters/
ocp.example.com  sno.example.com
```

### Impact

- **No drift warnings** are ever generated for cluster configs, even if users edit immutable fields (cluster_name, base_domain, starting_ip, etc.) after installation
- **No state overrides** are applied — immutable fields from installed state are never enforced
- The mirror drift detection (`_state_override_mirror()`) is NOT affected (uses `basename "$PWD"` instead of parsing config)

### Suggested fix

Strip inline comments before extracting the value:
```bash
_cn=$(grep '^cluster_name=' cluster.conf 2>/dev/null | head -1 | sed 's/[[:space:]]*#.*//' | cut -d= -f2- | xargs)
```

This matches the pattern used in `_state_override_mirror()`'s `_cval` extraction (line 906).

### Note on Bug #519 interaction

Bug #519 (false positive drift warnings inside `_state_override_cluster()`) exists in the `_cval` extraction at line 881. However, since Bug #523 prevents `_state_override_cluster()` from EVER being called, Bug #519 is currently dormant. Fixing #523 without also fixing #519 would produce false positive warnings on every `aba` invocation.

---

## Bug #524: `_day2_status()` uses hard-coded kubeconfig path that doesn't exist after externalization

**Severity:** Medium (cluster status check always fails for properly installed clusters)
**Status:** FIXED (2026-06-24)
**Component:** TUI v2 — `_day2_status()` in `tui/v2/tui-cluster.sh`
**File:** `tui/v2/tui-cluster.sh`

### Description

The `_day2_status()` function at line 2164 constructs the kubeconfig path as:
```bash
local kc="$ABA_ROOT/$cl_dir/iso-agent-based/auth/kubeconfig"
```

After cluster installation and state externalization, the `iso-agent-based/` directory is removed. The kubeconfig is moved to:
```
~/.aba/clusters/<name>.<domain>/kubeconfig
```

The hard-coded path no longer exists, causing ALL `oc` commands in `_day2_status()` to fail with "Cluster API unreachable".

### Live reproduction on conno

```bash
$ ls ~/aba/ocp/iso-agent-based/auth/kubeconfig
ls: cannot access '/home/steve/aba/ocp/iso-agent-based/auth/kubeconfig': No such file or directory

$ ls ~/.aba/clusters/ocp.example.com/kubeconfig
/home/steve/.aba/clusters/ocp.example.com/kubeconfig    # <-- correct location
```

### Impact

The Day-2 → Cluster Status feature always shows "Cluster API unreachable" for any cluster that has completed installation and externalized its state (which is all properly installed clusters). Users must use `aba --dir <cluster> status` or `oc` directly.

### Contrast with other Day-2 functions

- `_day2_ssh()` delegates to `aba --dir $SELECTED_CLUSTER ssh` which resolves the kubeconfig internally ✓
- `_day2_shutdown/startup/clean` all delegate to `aba --dir ...` ✓
- Only `_day2_status()` bypasses `aba` and constructs the path directly ✗

### Suggested fix

Use `cluster_kubeconfig()` which handles both locations:
```bash
local kc
kc=$(cd "$ABA_ROOT/$cl_dir" && cluster_kubeconfig 2>/dev/null)
if [[ -z "$kc" || ! -f "$kc" ]]; then
    echo "(No kubeconfig found — cluster may not be installed)"
    # still attempt aba --dir $cl_dir info as fallback
fi
```

Or simply delegate to `aba` (consistent with other Day-2 functions):
```bash
confirm_and_execute "aba --dir $cl_dir status" "$TUI2_TITLE_DAY2_STATUS: $cl_display"
```

---

## Bug #526: Core scripts use hard-coded kubeconfig path that doesn't exist after externalization

**Severity:** High (upgrade, shutdown, startup, info all fail for externalized clusters)
**Component:** Core — multiple scripts
**Affects:** `cluster-upgrade.sh`, `cluster-graceful-shutdown.sh`, `cluster-startup.sh`, `cluster-info.sh`, `aba.sh`, `day2.sh`, `day2-config-ntp.sh`, `day2-config-osus.sh`, `oc-command.sh`, `show-cluster-login.sh`
**Status:** FIXED (2026-06-24)

### Description

Multiple core scripts hard-code the kubeconfig path as:
```bash
export KUBECONFIG=$PWD/iso-agent-based/auth/kubeconfig
```

After `aba clean` removes `iso-agent-based/`, the kubeconfig is ONLY available at:
```
~/.aba/clusters/<name>.<domain>/kubeconfig
```

The `cluster_kubeconfig()` helper function (lines 779-788) handles both locations correctly (prefers externalized, falls back to local), but these scripts weren't using it.

### Trigger scenarios

1. After `aba clean` then try day2/upgrade/shutdown/startup/info
2. Cluster directory recreated via ADR-007 (`_recreate_cluster_dir`)
3. Cluster managed from a host that didn't do the original install

### Fix applied

All 10 affected scripts now use `cluster_kubeconfig()` to resolve the kubeconfig path. Pattern:
```bash
_kc=$(cluster_kubeconfig)
[ -z "$_kc" ] && aba_abort "kubeconfig not found..."
export KUBECONFIG="$_kc"
```

Also fixed `aba.sh` auto-detect logic (lines 1103-1115) to check externalized state, not just local `iso-agent-based/` existence.

### Verified on conno

```bash
# Before fix:
$ aba --dir ocp upgrade --to 4.20.23 --yes
[ABA] Error: kubeconfig not found at /home/steve/aba/ocp/iso-agent-based/auth/kubeconfig.

# After fix:
$ aba --dir ocp upgrade --to 4.20.23 --yes
[ABA] Checking cluster access ...
[ABA] Error: Cannot access the cluster. Check KUBECONFIG=/home/steve/.aba/clusters/ocp.example.com/kubeconfig
# (correct — cluster VMs are off, but kubeconfig was found)

$ aba --dir ocp info
[ABA] To access the cluster as the system:admin user when using 'oc', run
[ABA]     export KUBECONFIG=/home/steve/.aba/clusters/ocp.example.com/kubeconfig
# (correct — previously failed with "Cluster not ready!")

$ aba --dir ocp login
oc login -u kubeadmin -p 'Na9BN-...' --insecure-skip-tls-verify https://api.ocp.example.com:6443
# (correct — password and server URL resolved from externalized state)
```

---

## Bug #525: `fetch_all_versions()` leaks `set -o pipefail` into calling shell
**Status:** FIXED (2026-06-24)

**Severity:** Low (latent — all current callers use `$(...)` subshells, but any future direct call would be affected)
**Component:** Core — `fetch_all_versions()` in `scripts/include_all.sh`
**File:** `scripts/include_all.sh` (commit a8b0e76a)

### Description

The function at line 1628 sets:
```bash
set -o pipefail
```

This modifies the calling shell's `pipefail` option permanently. Currently, all callers use command substitution (`v=$(fetch_all_versions ...)`) which runs in a subshell, so the side effect is contained. However:

1. If the function is ever called directly (e.g., `fetch_all_versions stable 4.20 | tail -1` without `$(...)`), `pipefail` would persist
2. The function never restores `pipefail` to its previous state

### Suggested fix

Save and restore pipefail:
```bash
fetch_all_versions() {
    local channel="${1:-stable}"
    local minor="$2"
    local _pf_was_set=false
    [[ -o pipefail ]] && _pf_was_set=true
    set -o pipefail
    _fetch_graph_cached "$channel" "$minor" \
        | jq -r '.nodes[].version' \
        | grep "^${minor}\." \
        | sed 's/^\([0-9]*\.[0-9]*\.[0-9]*\)$/\1-zzz/' \
        | sort -V \
        | sed 's/-zzz$//'
    local _rc=$?
    $_pf_was_set || set +o pipefail
    return $_rc
}
```

Or wrap the pipeline in a subshell: `( set -o pipefail; ... )`

---

## Bug #528: Externalized clusters invisible after `aba clean` — `.install-complete` not backed up

**Severity:** Medium (installed clusters become invisible to TUI/CLI after `aba clean`)
**Component:** Core — `externalize_cluster_state()` in `scripts/include_all.sh`
**Status:** FIXED (2026-06-24)

### Description

After a cluster is installed and externalized:
- `~/.aba/clusters/<name>.<domain>/kubeconfig` exists
- `~/.aba/clusters/<name>.<domain>/state.sh` exists (confirming installation)

But if `aba clean` is run (removes `.install-complete` and `iso-agent-based/`):
- The cluster becomes invisible to the TUI (`list_installed_clusters` requires `.install-complete`)
- `auto_complete_install()` can't probe (needs `iso-agent-based/auth/kubeconfig`)
- `_recreate_cluster_dir()` doesn't fire (requires `cluster.conf` to be MISSING)

### Root cause

`externalize_cluster_state()` backs up many marker files but NOT `.install-complete`:
```bash
for _flag in .init .preflight-done .bm-message .bm-nextstep .autopoweroff .autoupload .autorefresh .auto-agent-up .bootstrap-complete; do
    # NOTE: .install-complete is MISSING from this list
```

### Live evidence on conno

```
~/.aba/clusters/ocp.example.com/kubeconfig   — EXISTS (cluster IS installed)
~/.aba/clusters/ocp.example.com/state.sh     — EXISTS
~/aba/ocp/.install-complete                  — MISSING
~/aba/ocp/iso-agent-based/                   — MISSING
TUI shows: "No installed clusters found."    — WRONG
```

### Suggested fixes

1. Add `.install-complete` to the backup list in `externalize_cluster_state()`
2. In `_recreate_cluster_dir()`, create `.install-complete` (since externalized state implies completion)
3. In `list_installed_clusters()` / `select_installed_cluster()`, also check for `clusterstate` symlink or externalized state as a fallback signal

---

## Bug #527: `$ABA_TMP` consolidation uses local user's path on remote hosts
**Status:** LOW RISK

**Severity:** Low (functional but creates confusingly-named dirs on remote hosts)
**Component:** Core — `scripts/reg-install-remote.sh`, `scripts/reg-uninstall-remote.sh`
**Introduced in:** Commit `93e7333` (ABA_TMP consolidation)

### Description

The `$ABA_TMP` variable (e.g., `/tmp/.aba-steve/`) is expanded on the LOCAL host and then used verbatim in SSH commands on REMOTE hosts:

```bash
remote_dir="$ABA_TMP/reg-install-$$"
$_ssh "mkdir -p $remote_dir"
```

This creates `/tmp/.aba-steve/` on the remote host, regardless of who the SSH user is. If the local user is `steve` and the remote user is `root`, the remote host gets a directory named after the local user.

### Impact

- Confusing directory naming on remote hosts (audit/debug)
- If multiple local users operate on the same remote host, their directories don't collide (different names), but the naming is misleading
- No functional failure — operations complete correctly

### Suggested fix

For remote operations, derive the temp path from the remote SSH user:
```bash
remote_tmp="/tmp/.aba-${reg_ssh_user}/reg-install-$$"
$_ssh "mkdir -p $remote_tmp"
```

---

## Bug #517 (UPDATED): "Always TUI/Terminal" retry within same call still shows mode dialog

**Severity:** Low (UX annoyance, not functional)
**Component:** TUI v2 — `confirm_and_execute()` in `tui/v2/tui-lib.sh`
**Status:** OPEN — partially fixed — works for subsequent `confirm_and_execute` calls, but retry within the SAME call still shows the dialog

### Updated analysis

The fix at lines 522-533 correctly skips the mode dialog for SUBSEQUENT calls to `confirm_and_execute()` when `_TUI_EXEC_MODE` is set. However, if the user chooses "Always TUI" (option 3) and the command fails with retry (exit code 2), the `continue` at line 598 goes back to the top of the `while :; do` loop at line 536 — which shows the mode dialog again BEFORE the already-remembered mode check at line 522 (which is OUTSIDE this loop).

### Fix

Add a mode check inside the loop:
```bash
while :; do
    # If mode was just set by a previous iteration, skip dialog
    if [[ -n "$_TUI_EXEC_MODE" ]]; then
        case "$_TUI_EXEC_MODE" in
            tui)      _exec_in_tui "$cmd" "$title" "$post_cmd_hook" ;;
            terminal) _exec_in_terminal "$cmd" "$title" "$post_cmd_hook" ;;
        esac
        local exec_rc=$?
        [[ $exec_rc -eq 2 ]] && continue
        return $exec_rc
    fi
    # ... existing menu dialog ...
done
```

## Bug #530: `--gateway`/`-g` always shifts after flag even when no IP consumed — eats next argument

**Status:** FIXED (commit c0030371)
**Severity**: HIGH
**Component**: CLI (`scripts/aba.sh`, lines 684-695)
**Discovered**: 2026-06-24

### Description

The `--gateway`/`-g` flag handler always executes a `shift` after consuming the flag, regardless of whether the next token was actually used as the gateway IP value. If the user passes `--gateway` as the last flag (or followed by another flag), the shift eats the next positional argument or flag entirely.

### Root cause

The shift logic is unconditional — it assumes the next token is always the gateway value, but there is no guard checking whether the next token starts with `-` (another flag) or is absent.

### Impact

Silent argument loss. `aba --gateway --type sno cluster` would interpret `--type` as the gateway IP and then lose `sno`, producing a confusing configuration state.

---

## Bug #531: `--excl-platform false` double-shifts, eats next token

**Status:** OPEN (code analysis)
**Severity**: HIGH
**Component**: CLI (`scripts/aba.sh`, lines 790-798)
**Discovered**: 2026-06-24

### Description

When `--excl-platform` is given with an explicit `false` value, the handler shifts once for the flag and once for the value, but the outer loop also shifts — resulting in a double-shift that consumes the next unrelated argument.

### Root cause

Both the case branch and the outer `shift` at the bottom of the loop execute, causing one extra shift when the value is explicitly provided.

### Impact

The argument immediately following `--excl-platform false` is silently discarded. For example, `aba --excl-platform false --type sno cluster` loses `--type` or `sno`.

---

## Bug #532: `--op-sets`/`--ops` clear passes `-f` as value to replace-value-conf

**Status:** OPEN (code analysis)
**Severity**: HIGH
**Component**: CLI (`scripts/aba.sh`, lines 751, 775)
**Discovered**: 2026-06-24

### Description

When the user runs `aba --op-sets clear` or `aba --ops clear`, the handler calls `replace-value-conf` with a `-f` flag intended to force-clear the value. However, the argument is passed in a position where `replace-value-conf` interprets `-f` as the literal value to write, not as a flag.

### Root cause

Argument ordering error in the `replace-value-conf` invocation — `-f` is placed where the value parameter is expected.

### Impact

Instead of clearing the operator sets, the config file gets the literal string `-f` written as the value. Subsequent operations see `-f` as an operator set name and fail with confusing errors.

---

## Bug #533: VM start/kill scripts use `|| exit 0` — failure appears successful

**Status:** FIXED (commit pending)
**Severity**: HIGH
**Component**: CLI (`scripts/aba.sh`, lines 1235, 1252)
**Discovered**: 2026-06-24

### Description

The `start` and `kill` subcommands invoke VM start/kill scripts with `|| exit 0` appended, so any failure in the script is masked with a successful exit code.

### Root cause

`|| exit 0` was likely added to prevent the CLI from crashing on expected failures, but it unconditionally swallows ALL failures including real errors (permission denied, VM not found, hypervisor API errors).

### Impact

Users see "success" even when VMs failed to start or stop. In automated workflows (CI, scripted deployments), this means the pipeline continues with VMs in the wrong state, causing cascading failures later.

---

## Bug #534: Last positional overwrites cur_target — `aba delete cluster` runs `cluster` not `delete`

**Status:** FIXED (commit pending)
**Severity**: HIGH
**Component**: CLI (`scripts/aba.sh`, line 1034)
**Discovered**: 2026-06-24

### Description

When multiple positional arguments are given (e.g. `aba delete cluster`), the loop overwrites `cur_target` with each positional. The last positional wins, so `aba delete cluster` sets `cur_target=cluster` and runs the `cluster` target instead of `delete`.

### Root cause

The positional argument handler uses simple assignment (`cur_target=$1`) without checking if `cur_target` was already set. There is no multi-positional disambiguation.

### Impact

Commands with two positional words execute the wrong target. `aba delete cluster` would enter the cluster wizard instead of deleting. The user's intent is silently ignored.

---

## Bug #535: Second `-d`/`--dir` discards next argument silently

**Status:** OPEN (code analysis)
**Severity**: HIGH
**Component**: CLI (`scripts/aba.sh`, lines 123-126)
**Discovered**: 2026-06-24

### Description

If `-d`/`--dir` is specified twice on the command line, the second occurrence shifts and consumes its value, overwriting the first `--dir` value. But the shift also eats the next argument if the user accidentally placed two `--dir` flags, causing subsequent arguments to be misaligned.

### Root cause

No check for duplicate `-d`/`--dir` flags. Each occurrence blindly shifts and assigns, with the second overwrite silently discarding whatever argument follows it.

### Impact

Silent argument loss. Complex command lines with a duplicated `--dir` flag will have arguments shifted out of position, causing wrong target execution or missing config values.

---

## Bug #536: `--domain` invalid input keeps old value, no error shown

**Status:** OPEN (code analysis)
**Severity**: HIGH
**Component**: CLI (`scripts/aba.sh`, lines 642-647)
**Discovered**: 2026-06-24

### Description

When `--domain` receives an invalid domain name (e.g. containing spaces or special characters), the validation silently fails but the old config value is retained without any error message to the user.

### Root cause

The validation branch falls through without printing an error or returning a non-zero exit code when the domain value fails the regex check. The `replace-value-conf` call is simply skipped.

### Impact

The user believes they changed the domain but the config file still has the old value. The mismatch between expectation and reality leads to clusters being deployed with the wrong domain, requiring full redeployment.

---

## Bug #537: Help before target shows wrong help text

**Status:** OPEN (code analysis)
**Severity**: HIGH
**Component**: CLI (`scripts/aba.sh`, lines 360-372)
**Discovered**: 2026-06-24

### Description

When `--help` appears before the target (e.g. `aba --help cluster`), the help routing logic does not yet know the target, so it displays generic help instead of the target-specific help page. Conversely, `aba cluster --help` works correctly.

### Root cause

The `--help` flag is processed in the first pass before positional arguments are parsed, so `cur_target` is still empty when help routing runs.

### Impact

Users who naturally type `aba --help cluster` get the wrong help text, leading to confusion about available options for the `cluster` subcommand.

---

## CLI (`scripts/aba.sh`) — MEDIUM severity

---

## Bug #538: Early `-n`/`--name` has no validation of value

**Status:** FIXED — early --name handler validates DNS label format
**Severity**: MEDIUM
**Component**: CLI (`scripts/aba.sh`, lines 133-138)
**Discovered**: 2026-06-24

### Description

The `-n`/`--name` flag accepts any string value without validation. Special characters, empty strings, or reserved directory names (e.g. `scripts`, `mirror`) are accepted and written to config.

### Root cause

No call to cluster name validation logic (reserved name check, DNS-safe regex) from the CLI flag handler. Validation only exists in the TUI path.

### Impact

Users can create clusters with invalid or dangerous names via CLI, potentially overwriting ABA directories or causing downstream failures in DNS, certificate generation, or directory operations.

---

## Bug #539: Help routing missing for delete, day2, upgrade, start subcommands

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: CLI (`scripts/aba.sh`, help routing)
**Discovered**: 2026-06-24

### Description

The `--help` routing table does not have entries for `delete`, `day2`, `upgrade`, or `start` subcommands. Running `aba delete --help` either shows generic help or no help at all.

### Root cause

The help routing case statement was not updated when these subcommands were added.

### Impact

Users cannot discover available options for these subcommands through the standard `--help` mechanism.

---

## Bug #540: `--validate` only works for cluster target, ignored elsewhere

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: CLI (`scripts/aba.sh`, `--validate` flag)
**Discovered**: 2026-06-24

### Description

The `--validate` flag is parsed and stored, but only the `cluster` target checks it. Running `aba --validate mirror install` silently ignores the flag, giving the false impression that configuration was validated.

### Root cause

Only the cluster code path inspects the `validate` variable. Other targets never check it.

### Impact

Users who rely on `--validate` for non-cluster targets get a false sense of security — no validation actually runs.

---

## Bug #541: `--validate` doesn't prevent prior flags from writing config

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: CLI (`scripts/aba.sh`, `--validate` flag)
**Discovered**: 2026-06-24

### Description

Flags parsed before `--validate` (e.g. `--type`, `--domain`) have already written to config files by the time `--validate` is encountered. The validate-only mode doesn't roll back those writes.

### Root cause

Flags are processed left-to-right and `replace-value-conf` is called immediately for each flag. `--validate` only prevents the final target execution, not the config writes.

### Impact

`aba --type sno --domain test.com --validate cluster` permanently changes `cluster.conf` even though the user only wanted validation, not mutation.

---

## Bug #542: Pre-cluster config flags silently skip non-existent cluster.conf

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: CLI (`scripts/aba.sh`, config flag handlers)
**Discovered**: 2026-06-24

### Description

Config flags like `--type`, `--domain`, `--num-workers` call `replace-value-conf` on `cluster.conf`, but if no cluster directory has been created yet, the file doesn't exist and the write silently fails.

### Root cause

No existence check for `cluster.conf` before calling `replace-value-conf`. The function may fail silently or create the file in the wrong location.

### Impact

Users set config flags before creating a cluster, believe the values are saved, then create a cluster that uses defaults instead of their specified values. Confusing and wastes time.

---

## Bug #543: `--pull-secret`/`-S` has no file existence check

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: CLI (`scripts/aba.sh`, lines 804-807)
**Discovered**: 2026-06-24

### Description

The `--pull-secret`/`-S` flag accepts a file path but never checks whether the file actually exists before writing the path to config.

### Root cause

Missing `[ -f "$value" ]` check in the flag handler.

### Impact

A typo in the pull secret path silently writes a non-existent path to config. The error only surfaces much later during mirror install or cluster creation, with an unrelated error message.

---

## Bug #544: `--out` path unquoted dirname

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: CLI (`scripts/aba.sh`, line 434)
**Discovered**: 2026-06-24

### Description

The `--out` flag handler passes the path to `dirname` without quoting, causing word splitting on paths containing spaces.

### Root cause

Missing double quotes around `$out_path` in the `dirname` call.

### Impact

Bundle creation with `--out "/path/with spaces/bundle.tar"` fails or writes to the wrong directory due to word splitting.

---

## Bug #545: `bundle` command uses unquoted eval

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: CLI (`scripts/aba.sh`, lines 1137-1138)
**Discovered**: 2026-06-24

### Description

The `bundle` subcommand constructs a command string and passes it through `eval` without proper quoting. If any argument contains shell metacharacters, they will be interpreted.

### Root cause

Unquoted variable expansion inside `eval`.

### Impact

Potential command injection if bundle paths or arguments contain shell-special characters (`$`, backtick, semicolons). Also breaks on paths with spaces.

---

## Bug #546: `--cmd` only takes one token

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: CLI (`scripts/aba.sh`, lines 1024-1029)
**Discovered**: 2026-06-24

### Description

The `--cmd` flag handler only shifts once, so it captures only the first word after `--cmd`. Multi-word commands like `--cmd "oc get nodes"` only capture `oc` if not quoted properly.

### Root cause

Single shift after `--cmd` without consuming the entire quoted string. Shell word splitting turns `oc get nodes` into three separate arguments.

### Impact

Users must carefully quote `--cmd` arguments. Unquoted multi-word commands silently lose all words after the first, producing wrong or failing commands.

---

## Bug #547: `--dns`/`--ntp` consumes trailing positional as value

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: CLI (`scripts/aba.sh`, lines 657-683)
**Discovered**: 2026-06-24

### Description

The `--dns` and `--ntp` flag handlers shift and consume the next token as their value without checking if it's actually a positional argument (the target). `aba --dns cluster` sets DNS to "cluster" instead of treating "cluster" as the target.

### Root cause

No guard checking whether the next token starts with `-` or is a known target name before consuming it as the flag value.

### Impact

Users who place `--dns` or `--ntp` immediately before the target lose the target argument. The wrong value is written to config and no target executes.

---

## Bug #548: Silent exit 0 when only config flags given

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: CLI (`scripts/aba.sh`, line 1348)
**Discovered**: 2026-06-24

### Description

When the user provides only config flags with no target (e.g. `aba --type sno --domain test.com`), the CLI writes the config values and exits successfully with no output, giving no indication that no action was taken.

### Root cause

No check for empty `cur_target` after flag parsing. The code silently exits 0 without warning.

### Impact

Users believe the command did something beyond setting config values. No feedback that a target is required to actually perform an operation.

---

## Bug #549: `--version` flag requires value instead of showing ABA version

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: CLI (`scripts/aba.sh`, `--version` flag)
**Discovered**: 2026-06-24

### Description

Running `aba --version` (without a value) expects an OCP version argument. There is no way to query ABA's own version via `--version` — only `--aba-version` works, which is not discoverable.

### Root cause

`--version` is overloaded to mean "set OCP version" rather than the conventional "show program version." No disambiguation.

### Impact

Users expecting standard CLI behavior (`--version` shows program version) get an error or set the OCP version to the next argument unintentionally.

---

## Bug #550: install failure (exit 1) doesn't stop CLI execution

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: CLI (`scripts/aba.sh`, lines 203-209)
**Discovered**: 2026-06-24

### Description

When the initial `install` step fails (exit code 1), the CLI continues processing subsequent targets or steps instead of aborting.

### Root cause

The return code from the install function is not checked before proceeding to the next operation.

### Impact

A failed install (missing deps, broken state) leads to cascading failures in subsequent operations. The user sees a wall of errors instead of a clean failure at the install step.

---

## Bug #551: Missing `-v` quoting in replace-value-conf calls

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: CLI (`scripts/aba.sh`, lines 456, 502, 544, 770, 781)
**Discovered**: 2026-06-24

### Description

Multiple `replace-value-conf` calls pass the `-v` value argument without proper quoting. Values containing spaces, special characters, or empty strings are subject to word splitting.

### Root cause

Missing double quotes around `$value` in `-v "$value"` arguments across several flag handlers.

### Impact

Config values with spaces or special characters are corrupted during write. Affects `--domain`, `--pull-secret`, operator set names, and other string-valued flags.

---

## Bug #552: `--data-disk-gb`, `--num-workers`, `--num-masters` weak missing-arg handling

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: CLI (`scripts/aba.sh`, numeric flag handlers)
**Discovered**: 2026-06-24

### Description

The numeric flags `--data-disk-gb`, `--num-workers`, and `--num-masters` do not robustly handle missing arguments. If the flag appears at the end of the command line, the shift consumes nothing and the variable is set to empty or the next flag name.

### Root cause

No check for `$# -gt 0` or `[[ -n "$2" ]]` before shifting and assigning.

### Impact

`aba --num-workers cluster` sets `num_workers=cluster` instead of erroring. The string "cluster" written to config causes confusing downstream failures.

---

## Core Registry Scripts — HIGH severity

---

## Bug #553: `reg-install-quay.sh` mirror-registry install exit code never checked

**Status:** OPEN (code analysis)
**Severity**: HIGH
**Component**: Core (`scripts/reg-install-quay.sh`, lines 89-91)
**Discovered**: 2026-06-24

### Description

The `mirror-registry install` command's exit code is not checked. If the Quay mirror registry install fails (network error, port conflict, disk full), execution continues as if it succeeded.

### Root cause

Missing `|| return 1` or equivalent after the `mirror-registry install` invocation. The script proceeds to post-install steps unconditionally.

### Impact

A failed registry install leaves a half-configured registry. Subsequent `mirror save` or `mirror sync` operations fail with confusing authentication or connection errors, rather than a clear "install failed" message.

---

## Bug #554: `reg-uninstall.sh` fallback Docker path uses `|| true`, reports success on failure

**Status:** OPEN (code analysis)
**Severity**: HIGH
**Component**: Core (`scripts/reg-uninstall.sh`, lines 126, 139-140, 154-156)
**Discovered**: 2026-06-24

### Description

The Docker-based registry uninstall fallback path appends `|| true` to critical cleanup commands. If the Docker container stop/remove fails, the script reports successful uninstall.

### Root cause

Overly defensive `|| true` on Docker lifecycle commands in the fallback path, likely added to handle "container not found" cases but swallowing all errors including real failures.

### Impact

Users told "uninstall successful" while registry containers are still running. Subsequent reinstall attempts fail with port conflicts, and stale data persists.

---

## Bug #555: `reg-uninstall.sh` credentials moved to `.bk` BEFORE uninstall — no restore on failure

**Status:** OPEN (code analysis)
**Severity**: HIGH
**Component**: Core (`scripts/reg-uninstall.sh`, lines 117-119)
**Discovered**: 2026-06-24

### Description

Registry credentials (`regcreds/`) are moved to a `.bk` backup BEFORE the actual uninstall runs. If the uninstall fails, the credentials are gone and there is no automatic restore.

### Root cause

The backup move is done as a pre-step unconditionally, and the failure path does not restore from `.bk`.

### Impact

Failed uninstall leaves the system without credentials. The registry is still running but ABA cannot authenticate to it for save/sync operations. Manual intervention required to restore from `.bk`.

---

## Bug #556: `reg-uninstall.sh` SSH probe errors suppressed — empty result treated as "no registry"

**Status:** OPEN (code analysis)
**Severity**: HIGH
**Component**: Core (`scripts/reg-uninstall.sh`, lines 80-82, 108-110)
**Discovered**: 2026-06-24

### Description

SSH connectivity probes to detect remote registries suppress stderr. If SSH itself fails (key issue, host down, timeout), the empty output is interpreted as "no registry running" — a false negative.

### Root cause

`2>/dev/null` on SSH commands used for registry detection. SSH failures are indistinguishable from "registry not found."

### Impact

Remote registry uninstall is silently skipped when the remote host is unreachable. The registry keeps running, consuming resources and holding ports. The user believes it was uninstalled.

---

## Bug #557: `reg-install-remote.sh` password expansion in double-quoted SSH command breaks on `!` `"` `'`

**Status:** OPEN (code analysis)
**Severity**: HIGH
**Component**: Core (`scripts/reg-install-remote.sh`, line 126)
**Discovered**: 2026-06-24

### Description

The registry password is interpolated inside a double-quoted SSH heredoc/command string. Passwords containing `!` (bash history expansion), `"` (terminates the string), or `'` (breaks inner quoting) cause the SSH command to fail or execute unexpected commands.

### Root cause

Password variable expanded inside double quotes in an SSH command string without escaping. Bash performs history expansion on `!` in interactive-like contexts.

### Impact

Users with special characters in their registry password see cryptic SSH or authentication failures during remote mirror install. Security-conscious users with strong passwords are disproportionately affected.

---

## Bug #558: `reg-install.sh` vendor dispatch has no validation of vendor override

**Status:** FIXED — vendor allowlist already exists in reg-install.sh (case statement lines 20-23)
**Severity**: HIGH
**Component**: Core (`scripts/reg-install.sh`, line 30)
**Discovered**: 2026-06-24

### Description

The vendor dispatch uses `exec scripts/reg-install-${vendor}.sh` where `$vendor` comes from config. There is no validation that `$vendor` is one of the known values (`quay`, `docker`). An arbitrary value causes `exec` of a non-existent script.

### Root cause

Missing allowlist check for `$vendor` before constructing the script path. No `case` statement or validation.

### Impact

A corrupted or manually-edited `mirror.conf` with `vendor=arbitrary` causes an unhelpful "file not found" error. In theory, if a file named `reg-install-arbitrary.sh` existed in the scripts directory, it would be executed.

---

## Core Registry Scripts — MEDIUM severity

---

## Bug #559: `reg-uninstall.sh` fallback forces `ask=1`, breaks automation/CI

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: Core (`scripts/reg-uninstall.sh`, line 73)
**Discovered**: 2026-06-24

### Description

The uninstall fallback path forces `ask=1` (interactive confirmation), which blocks automation and CI pipelines that set `ask=` (auto-yes) in `aba.conf`.

### Root cause

Hardcoded `ask=1` override in the fallback logic, regardless of the user's `ask` setting.

### Impact

CI pipelines and scripted uninstall workflows hang waiting for interactive input when the primary uninstall path fails and falls through to the fallback.

---

## Bug #560: `reg-uninstall.sh` credentials backup creates window where regcreds/ is empty

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: Core (`scripts/reg-uninstall.sh`, lines 117-119)
**Discovered**: 2026-06-24

### Description

Between moving `regcreds/` to `.bk` and completing the uninstall, there is a time window where the credentials directory is empty. If another process (e.g. a sync job) accesses credentials during this window, it fails.

### Root cause

Non-atomic backup: `mv regcreds regcreds.bk` creates a gap before the uninstall completes and new credentials are generated.

### Impact

Race condition in concurrent operations. Low probability in normal use, but possible in automated environments with parallel jobs.

---

## Bug #561: `reg-uninstall.sh` multiple unquoted SSH variables

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: Core (`scripts/reg-uninstall.sh`, lines 80, 102, 122, 126)
**Discovered**: 2026-06-24

### Description

Several SSH command constructions use unquoted variables (`$reg_ssh_user`, `$reg_ssh_host`, `$reg_root`), which are subject to word splitting if any value contains spaces or special characters.

### Root cause

Missing double quotes around variable expansions in SSH command strings.

### Impact

Unlikely to trigger in normal use (SSH hostnames rarely have spaces), but violates defensive coding practices and could cause failures with unusual configurations.

---

## Bug #562: `reg-uninstall.sh` unnecessary eval with unquoted args in Quay fallback

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: Core (`scripts/reg-uninstall.sh`, lines 130-132)
**Discovered**: 2026-06-24

### Description

The Quay fallback uninstall path uses `eval` with unquoted arguments, introducing unnecessary shell injection risk and making the code harder to reason about.

### Root cause

Legacy code pattern using `eval` where direct execution would suffice.

### Impact

If any argument to the eval'd command contains shell metacharacters, they are interpreted. Low risk with current inputs but a latent vulnerability.

---

## Bug #563: `reg-uninstall.sh` fallback never calls `reg_close_firewall`

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: Core (`scripts/reg-uninstall.sh`, lines 53-111)
**Discovered**: 2026-06-24

### Description

The primary uninstall path calls `reg_close_firewall` to close the registry port in the firewall, but the fallback path skips this step. After a fallback uninstall, the firewall port remains open.

### Root cause

The fallback code path was written independently and does not call the same cleanup functions as the primary path.

### Impact

Firewall rules leak after fallback uninstall. The registry port (typically 8443) remains open, which is a minor security concern and may cause confusion on reinstall.

---

## Bug #564: `reg-install-remote.sh` unguarded glob `mirror-registry-*.tar.gz`

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: Core (`scripts/reg-install-remote.sh`, line 120)
**Discovered**: 2026-06-24

### Description

The glob `mirror-registry-*.tar.gz` is used without a nullglob guard. If no matching file exists, the literal unexpanded glob string is passed as an argument, causing a confusing "file not found" error.

### Root cause

Missing `shopt -s nullglob` or explicit file existence check before using the glob.

### Impact

When the mirror-registry tarball is missing, the error message shows the literal glob pattern instead of a clear "mirror-registry tarball not found" message.

---

## Bug #565: `reg-install-remote.sh` unquoted `$reg_root` in remote commands

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: Core (`scripts/reg-install-remote.sh`, lines 66, 70)
**Discovered**: 2026-06-24

### Description

The `$reg_root` variable is used unquoted in remote SSH command strings. If `reg_root` contains spaces (unlikely but possible), the commands break.

### Root cause

Missing double quotes around `$reg_root` in SSH command construction.

### Impact

Failure when registry root path contains spaces. Defensive coding concern.

---

## Bug #566: `reg-install-remote.sh` SSH failure silently skips stale detection

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: Core (`scripts/reg-install-remote.sh`, lines 95-97)
**Discovered**: 2026-06-24

### Description

The SSH command that checks for stale registry state on the remote host does not check its exit code. If SSH fails (host unreachable, auth error), the stale detection is skipped and install proceeds, potentially conflicting with an existing registry.

### Root cause

Missing exit code check after the SSH probe command.

### Impact

Installing a second registry on top of an existing one, causing port conflicts and data corruption.

---

## Bug #567: `reg-install-quay.sh` unquoted paths `$temp_aba_key`, `$HOME/.ssh/quay_installer`

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: Core (`scripts/reg-install-quay.sh`, lines 27-35)
**Discovered**: 2026-06-24

### Description

SSH key paths `$temp_aba_key` and `$HOME/.ssh/quay_installer` are used unquoted in file operations (cp, chmod, ssh-keygen). If `$HOME` contains spaces, these operations fail.

### Root cause

Missing double quotes around path variables.

### Impact

Failure when home directory path contains spaces. Unlikely on Linux but possible in custom environments.

---

## Bug #568: `reg-install.sh` and `reg-uninstall.sh` hardcoded `scripts/` paths assume CWD has symlink

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: Core (`scripts/reg-install.sh` and `scripts/reg-uninstall.sh`, line 8)
**Discovered**: 2026-06-24

### Description

Both scripts use `scripts/reg-install-${vendor}.sh` as relative paths, assuming CWD is a directory containing a `scripts/` symlink. If invoked from an unexpected CWD (e.g. during testing), the path resolution fails.

### Root cause

Hardcoded relative path assuming specific CWD, rather than computing the path relative to the script's own location.

### Impact

Scripts fail with "file not found" when invoked from unexpected directories. Normally masked because Make sets CWD correctly, but fragile.

---

## Bug #569: `setup-cluster.sh` mirror relink after cd — `normalize-cluster-conf` reads wrong `./cluster.conf`

**Status:** OPEN (code analysis)
**Severity**: MEDIUM
**Component**: Core (`scripts/setup-cluster.sh`, lines 101-106)
**Discovered**: 2026-06-24

### Description

After changing directory to the cluster dir, `normalize-cluster-conf` is called with `./cluster.conf`. If the mirror symlink relink changed directories or CWD is not the cluster dir at that point, the wrong `cluster.conf` is read.

### Root cause

CWD-dependent relative path used after a directory change that may not have completed or may have failed silently.

### Impact

Cluster configuration from the wrong directory is loaded, potentially mixing settings from different clusters. Rare but possible.

---

## TUI DISCO/Bundle — HIGH severity

---

## Bug #570: ESC treated as "Full bundle" on same-filesystem prompt

**Status:** OPEN (code analysis)
**Severity**: HIGH
**Component**: TUI (`tui/v2/tui-mirror.sh`, lines 1386-1406)
**Discovered**: 2026-06-24

### Description

When the TUI prompts whether to create a light or full bundle on the same filesystem, pressing ESC (dialog exit code 255) falls through to the "Full bundle" code path instead of canceling the operation.

### Root cause

The dialog return code handler does not have a case for exit code 255 (ESC). It only checks for explicit "light" vs "full" selection, and the default/else branch proceeds with full bundle.

### Impact

Users who press ESC to cancel the bundle dialog inadvertently start a full bundle creation, which can take significant time and disk space. No way to cancel without Ctrl-C.

---

## Bug #572: Bundle prereqs use stale `ocp_version` (not re-sourced)

**Status:** FIXED (commit c0030371)
**Severity**: HIGH
**Component**: TUI (`tui/v2/tui-mirror.sh`, lines 1310-1313)
**Discovered**: 2026-06-24

### Description

The bundle prerequisite checks use `$ocp_version` from the initial config source, but if the user changed the OCP version via the wizard or CLI during the session, the variable is stale. Bundle validation uses the wrong version.

### Root cause

`mirror.conf` is not re-sourced before the bundle prereq checks. The in-memory `$ocp_version` reflects the value from session start, not the current config.

### Impact

Bundle created for wrong OCP version. If the user upgraded from 4.20 to 4.21 and then creates a bundle, the bundle may contain 4.20 images, making the air-gapped target cluster deploy the wrong version.

---

## Bug #573: ISC regen is async before upgrade save — race condition

**Status:** FIXED — `run_once -q -w` wait at line 631 ensures ISC generation completes before save proceeds
**Severity**: HIGH
**Component**: TUI (`tui/v2/tui-mirror.sh`, lines 629-634)
**Discovered**: 2026-06-24

### Description

The ImageSetConfiguration (ISC) regeneration is kicked off asynchronously (background process) immediately before the upgrade save operation reads the ISC. There is a race where the save begins before regen completes, using a partial or stale ISC.

### Root cause

`tui_kick_isconf_regen()` starts regen in background without waiting for completion before the save path reads the ISC file.

### Impact

Upgrade save may package the wrong set of images — either missing new-version images or including stale old-version images. The resulting bundle or sync is incomplete, causing cluster upgrade failures in air-gapped environments.

---

## TUI DISCO/Bundle — MEDIUM severity

---

## Bug #574: ESC on light/full bundle dialog not distinguished from "No"

**Status:** FIXED — ESC (rc=255) now returns 1 (cancel) at line 1384, distinct from No button which goes to full bundle
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-mirror.sh`, lines 1386-1392)
**Discovered**: 2026-06-24

### Description

The light/full bundle selection dialog treats ESC (255) the same as "No" — both fall into the same code path. Users cannot distinguish between "cancel this dialog" and "I don't want a light bundle."

### Root cause

No separate handler for dialog exit code 255 vs the explicit "No" button.

### Impact

UX confusion — pressing ESC should cancel the operation entirely, but instead it makes a choice on behalf of the user.

---

## Bug #575: Silent no-op when Install Cluster gate fails or cancels

**Status:** OPEN — gate failure (rc=1) falls through case at line 274 with no user feedback
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-disco.sh`, lines 272-277)
**Discovered**: 2026-06-24

### Description

When the "Install Cluster" gate check fails or the user cancels, the DISCO wizard silently returns to the menu with no error message or indication of what happened.

### Root cause

The gate function's non-zero return is caught but no user-facing feedback is generated.

### Impact

Users click "Install Cluster," nothing happens, and they don't know why. They may repeatedly try without realizing a prerequisite is missing.

---

## Bug #576: Mirror config Continue skips validation for review/local modes

**Status:** LOW RISK — individual fields validated inline during editing; Continue path only lacks hostname-required check for non-remote modes
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-mirror.sh`, lines 194-202)
**Discovered**: 2026-06-24

### Description

The mirror configuration "Continue" button in review or local modes skips the config validation step that runs in the normal flow. Invalid configurations can proceed to install.

### Root cause

Validation call is inside a conditional that excludes review and local mode paths.

### Impact

Users in review/local modes can proceed with invalid mirror configurations, causing failures during mirror install that are harder to diagnose than a validation error.

---

## Bug #577: Operator search/basket edit breaks ref-count

**Status:** INVALID — code refactored to flat OP_BASKET hash map with md5sum change detection; ref-counting no longer exists
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-mirror.sh`, lines 1194-1203, 1254-1260)
**Discovered**: 2026-06-24

### Description

When operators are added or removed through the search or basket edit interfaces, the operator reference count tracking is not properly updated. Removing an operator from one set doesn't decrement its ref-count, so removing the last set that uses it leaves a phantom reference.

### Root cause

The search/basket edit code paths bypass the ref-count update logic in `_operator_sets`.

### Impact

Operator basket becomes inconsistent with set membership. ISC regeneration may include operators that were removed or exclude operators that should be present.

---

## Bug #578: `mkdir -p` failure silently skips same-device bundle UX

**Status:** LOW RISK — if mkdir fails, stat returns empty and same-device check is skipped; rare in practice
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-mirror.sh`, lines 1375-1382)
**Discovered**: 2026-06-24

### Description

The bundle creation path attempts `mkdir -p` for the target directory. If it fails (permissions, read-only filesystem), the error is not caught and the same-device optimization UX is silently skipped.

### Root cause

Missing exit code check after `mkdir -p`. The code assumes directory creation always succeeds.

### Impact

Bundle creation proceeds without the same-device hardlink optimization, potentially doubling disk usage. No error tells the user the target directory couldn't be created.

---

## Bug #579: ISC wait loop may time out too early (5s)

**Status:** FIXED — hardcoded 5s timeout replaced with `run_once -q -w` which blocks until task completes
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-mirror.sh`, lines 763-772)
**Discovered**: 2026-06-24

### Description

The ISC (ImageSetConfiguration) regeneration wait loop has a 5-second timeout. On slow systems or with large operator catalogs, ISC regeneration can take longer, causing the wait to time out and proceed with a stale or incomplete ISC.

### Root cause

Hardcoded 5-second timeout that doesn't account for system load or catalog size.

### Impact

Stale ISC used for mirror save/sync, resulting in missing images in the mirror. Manifests as failed cluster installations in disconnected environments.

---

## Bug #580: Bundle creation doesn't ensure operator basket/ISC flushed

**Status:** LOW RISK — basket persisted immediately after every change (lines 982, 992, 1002); always flushed before user reaches bundle
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-mirror.sh`, lines 1307-1436)
**Discovered**: 2026-06-24

### Description

The bundle creation flow does not verify that pending operator basket changes have been flushed to disk and the ISC has been regenerated before starting the bundle. If the user made operator changes and immediately creates a bundle, the bundle may not reflect the latest operator selection.

### Root cause

No synchronization barrier between operator basket editing and bundle creation. The dirty flag may be set but not yet acted upon.

### Impact

Bundle created with wrong operator set. Air-gapped environment gets a bundle missing required operators or containing unwanted ones.

---

## Bug #581: Stale `$?` used for cluster gate result

**Status:** FIXED — `case "$?"` used immediately after `tui_install_cluster_gate` with no intervening commands
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-disco.sh`, lines 273-274)
**Discovered**: 2026-06-24

### Description

The cluster install gate result is checked via `$?`, but intervening commands between the gate call and the `$?` check overwrite the exit status. The check always sees the exit code of the last intervening command, not the gate.

### Root cause

`$?` is checked after other statements have executed, overwriting the gate function's exit code.

### Impact

The gate check is effectively bypassed — it always appears to pass regardless of the actual gate result. Users can proceed to cluster install with unmet prerequisites.

---

## TUI Cluster Wizard — HIGH severity

---

## Bug #582: Review page mirror display uses stale `reg_host`/`reg_port` locals

**Status:** FIXED — review page now re-sources `normalize-mirror-conf` at display time (line 1586) for fresh values
**Severity**: HIGH
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 1575-1579, 1592-1594)
**Discovered**: 2026-06-24

### Description

The cluster wizard review page displays mirror registry host and port from local variables that were set at page entry time. If the user changed mirror configuration during the wizard session (e.g. via Advanced menu), the review page shows stale values.

### Root cause

Local variables `reg_host` and `reg_port` are captured once when entering the review page and not refreshed from the current `mirror.conf`.

### Impact

Users confirm a configuration showing the wrong mirror registry details. The actual cluster install uses the updated config, but the user approved based on stale information. Can lead to unintended deployments against the wrong registry.

---

## Bug #583: `cluster_kubeconfig` called without sourcing `normalize-cluster-conf`

**Status:** FIXED — both calls (lines 2164 and 2239) now `source <(normalize-cluster-conf)` before `cluster_kubeconfig`
**Severity**: HIGH
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 2170-2171, 2243-2245)
**Discovered**: 2026-06-24

### Description

The `cluster_kubeconfig` function is called at points where `normalize-cluster-conf` has not been sourced, meaning the variables it depends on (`$cluster_name`, auth paths) may be unset or stale.

### Root cause

Missing `. normalize-cluster-conf` call before `cluster_kubeconfig` invocations in the day-2 and upgrade code paths.

### Impact

Wrong kubeconfig path returned — operations run against the wrong cluster or fail with "kubeconfig not found." In day-2 operations, this could apply changes to an unintended cluster.

---

## Bug #584: Install wizard ignores cancel from `confirm_and_execute`

**Status:** BY DESIGN — wizard exits to main menu after execute stage regardless of outcome (comment at line 1710 documents this)
**Severity**: HIGH
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 1712-1732, 764-767)
**Discovered**: 2026-06-24

### Description

When the user cancels the final `confirm_and_execute` dialog before cluster install, the cancel return code is not checked. The wizard proceeds to post-install steps (cleanup, status update) as if install succeeded.

### Root cause

Missing return code check after `confirm_and_execute`. The code unconditionally falls through to post-install logic.

### Impact

After canceling, the user sees post-install status updates and cleanup for an install that never happened. The cluster state markers may be set incorrectly, causing confusion about whether the cluster was actually created.

---

## Bug #585: False-positive artifact cleanup when normalize fails

**Status:** FIXED — artifact cleanup logic no longer exists in the install preparation path
**Severity**: HIGH
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 1687-1695)
**Discovered**: 2026-06-24

### Description

When `normalize-cluster-conf` fails (corrupt config, missing fields), the error triggers the artifact cleanup path. This cleanup removes partially-created cluster files even though the failure was in config normalization, not in cluster creation.

### Root cause

The cleanup logic is triggered by any failure in the install preparation path, not just by actual install failures. Normalize failures are not distinguished from install failures.

### Impact

Cluster configuration files are deleted when the normalization step has a transient error (e.g. missing optional field). The user loses their cluster config and must re-enter all values.

---

## TUI Cluster Wizard — MEDIUM severity

---

## Bug #586: ESC treated as Skip on platform config gate

**Status:** OPEN — case `*` at line 292 catches both ESC (255) and Skip/No (1) identically, returning 0 without distinction
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 287-289)
**Discovered**: 2026-06-24

### Description

When the platform configuration gate dialog appears and the user presses ESC, the exit code 255 is treated as "Skip" rather than "Cancel." The wizard proceeds without platform config instead of returning to the previous page.

### Root cause

No handler for exit code 255 in the platform gate dialog. The default/else branch is "skip."

### Impact

Users who press ESC to cancel accidentally skip platform configuration, leading to clusters created without proper VMware/KVM settings. Requires cluster deletion and recreation.

---

## Bug #587: Post-review failures return to edit pages, not review

**Status:** NEEDS LIVE TEST — no explicit page-jump-back logic visible in current code; behavior depends on how confirm_and_execute failure propagates
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 1668-1677, 1707, 769-776)
**Discovered**: 2026-06-24

### Description

When a validation or preparation step fails after the review page, the wizard returns the user to individual edit pages instead of back to the review page. The user must re-navigate through all pages to return to review.

### Root cause

Error recovery jumps to the page that owns the failing field rather than to the review page with an error annotation.

### Impact

Poor UX — users who made one small mistake must click through multiple wizard pages again. Frustrating for complex configurations with many pages.

---

## Bug #588: `_check_platform_config` uses wrong paths (cluster dir not `ABA_ROOT`)

**Status:** FIXED — function now checks `$dir/vmware.conf`, `vmware.conf` (CWD/ABA_ROOT), and `$HOME/.vmware.conf` (line 1744)
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 1748-1756)
**Discovered**: 2026-06-24

### Description

The `_check_platform_config` function checks for platform config files (`vmware.conf`, `kvm.conf`) in the cluster directory instead of `$ABA_ROOT`. Platform config files are global, not per-cluster.

### Root cause

Path construction uses the cluster directory context instead of the ABA root directory.

### Impact

Platform config check always fails for new clusters (no config file in their directory), forcing unnecessary re-configuration. Existing platform configs at the project root are ignored.

---

## Bug #589: `_platform_config_missing` doesn't verify config after form

**Status:** OPEN — after calling `_configure_vmw_form`/`_configure_kvm_form` (line 1772), no return code check or file-existence verification
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 1776-1780)
**Discovered**: 2026-06-24

### Description

After the platform config form is displayed and the user fills it in, `_platform_config_missing` does not re-check whether the config file was actually created/saved. It assumes the form always succeeds.

### Root cause

No post-form validation. The function returns success after showing the form, regardless of whether the user completed it or canceled.

### Impact

User cancels the platform config form but the wizard proceeds as if configuration is complete. Install fails later with a confusing "missing platform config" error.

---

## Bug #590: Upgrade preflight silently passes when `oc adm upgrade` fails

**Status:** OPEN — line 2241 uses `|| true` so command failure is swallowed; preflight returns 0 if output lacks "Upgradeable=False"
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 2243-2254)
**Discovered**: 2026-06-24

### Description

The upgrade preflight check runs `oc adm upgrade` to verify cluster upgrade readiness, but doesn't check the command's exit code. If the command fails (cluster unreachable, auth expired), the preflight is considered passed.

### Root cause

Missing exit code check after `oc adm upgrade` in the preflight validation.

### Impact

Users proceed to upgrade a cluster that isn't ready (not healthy, unreachable, or in a bad state). The upgrade fails mid-way, potentially leaving the cluster in a partially-upgraded state that's harder to recover from than a pre-flight failure.

---

## Bug #591: Upgrade version parse continues past list end

**Status:** LOW RISK — parser uses strict version regex that won't match non-version output; unlikely to produce phantom versions
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 2268-2276, 2286-2290)
**Discovered**: 2026-06-24

### Description

The version parsing logic that extracts available upgrade versions from `oc adm upgrade` output does not properly detect the end of the version list. It may parse trailing output (warnings, status messages) as version numbers.

### Root cause

The parser uses a simple line-by-line scan without a robust end-of-list sentinel. Trailing output that matches the version regex pattern is incorrectly included.

### Impact

Phantom version numbers appear in the upgrade picker. Selecting a phantom version fails with "version not found" during the actual upgrade.

---

## Bug #592: Manual upgrade skips downgrade check when cluster-version fails

**Status:** OPEN — line 2380 regex condition skips check entirely when `_cur_ver` is empty (cluster unreachable)
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 2382-2388)
**Discovered**: 2026-06-24

### Description

The manual version entry path for upgrades checks for downgrades by comparing the entered version against the current cluster version. If the cluster version query fails, the comparison is skipped and any version (including downgrades) is accepted.

### Root cause

The current version variable is empty when the cluster-version query fails, and the comparison `is_version_greater "" "4.21.5"` returns true (empty is "less than" anything), so the downgrade check passes.

### Impact

Users can accidentally initiate a cluster downgrade, which OpenShift does not support. The upgrade command fails, potentially leaving the cluster in a bad state.

---

## Bug #593: Unquoted variables in eval/aba command construction

**Status:** LOW RISK — `$cl_name` is DNS-label validated (no spaces/special chars) and `_exec_in_tui` has metacharacter guard at line 625
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 193-199, 1547, 1679)
**Discovered**: 2026-06-24

### Description

Several places construct `aba` command strings using unquoted variable expansions inside `eval` or direct execution. Variables like cluster name, domain, or paths with spaces cause word splitting.

### Root cause

Missing double quotes around variable expansions in command string construction.

### Impact

Cluster names or domains with unusual characters cause command parsing failures. While cluster name validation may prevent most cases, the unquoted variables are a latent injection risk.

---

## Bug #594: CWD changed without restore in `_day2_status`

**Status:** NOT A BUG — `cd "$ABA_ROOT"` at line 2171 sets CWD to project root, the expected CWD for all TUI operations
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 2173-2196)
**Discovered**: 2026-06-24

### Description

The `_day2_status` function changes the current working directory (cd) to the cluster directory but does not restore CWD on return. Subsequent operations that depend on CWD being the ABA root will fail or operate on wrong files.

### Root cause

Missing `cd -` or `pushd/popd` pattern. The `cd` is a permanent CWD change for the calling context.

### Impact

After viewing day-2 status, other wizard pages or menu operations may read wrong config files or fail to find scripts. The error manifests as seemingly random failures in unrelated operations.

---

## Bug #595: Global mirror config leaked on Interfaces page

**Status:** OPEN — `source <(normalize-mirror-conf)` at line 1221 injects `reg_host`, `reg_port` into function scope without `local`
**Severity**: MEDIUM
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 1211-1213)
**Discovered**: 2026-06-24

### Description

The Interfaces page sources global mirror configuration variables that leak into the cluster wizard's variable scope. Mirror-specific variables (registry host, port, credentials path) override or conflict with cluster-specific variables.

### Root cause

`source mirror.conf` or similar at the Interfaces page level without localizing the variables. The sourced variables persist in the function's scope and leak to subsequent pages.

### Impact

Cluster configuration pages after the Interfaces page may display or use mirror config values instead of cluster-specific values. Can cause subtle configuration errors where the cluster is pointed at the wrong registry or uses wrong credentials.

---

## Bug #596 — `verify-cluster-conf` error message says "aba.conf" instead of "cluster.conf" for dns_servers

**Status:** OPEN — error message at line 1079 says "cluster.conf" but the `[ ! -n $ports ]` check is unquoted making it always true
**Severity:** LOW — Cosmetic/misleading error message
**Found:** 2026-06-24 (code review + live test)
**Component:** Core ABA (`scripts/include_all.sh`, line 1077)

### Description

In the `verify-cluster-conf` function, the error message for invalid `dns_servers` says:
```
Error: dns_servers is invalid in aba.conf [not-an-ip]
```

But this function validates `cluster.conf`, not `aba.conf`. The commented-out line 1076 has the correct file reference ("cluster.conf"), suggesting a copy-paste error when the active line was written.

### Steps to reproduce

```bash
cd ~/aba/sno
dns_servers='not-an-ip' source scripts/include_all.sh && verify-cluster-conf 2>&1
# Output: Error: dns_servers is invalid in aba.conf [not-an-ip]
```

### Expected

Error should say "dns_servers is invalid in cluster.conf".

### Fix

Line 1077 in `include_all.sh`: change `aba.conf` to `cluster.conf` in the error message.

---

## Bug #597 — TUI returns to main menu after `aba reset --force` with stale state

**Status:** OPEN — `confirm_and_execute` then `return 0` (line 1937) exits advanced menu back to caller with stale in-memory config
**Severity:** MEDIUM — TUI continues with stale config after destructive reset
**Found:** 2026-06-24 (code review)
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, line 1928-1929)

### Description

The "Reset ABA" action in the Advanced menu runs `aba reset --force` which deletes all config files (aba.conf, mirror.conf, cluster directories, etc.). After the reset completes, the TUI calls `return 0` which returns to the calling main menu (CONNO/DISCO/DIRECT).

The problem is the TUI continues running with all its shell variables (ocp_version, ocp_channel, platform, mirror state, etc.) still set from before the reset. The menu will show stale status indicators and operations may fail confusingly because the underlying files no longer exist.

### Expected

After `aba reset --force`, the TUI should either:
1. Exit completely with a message like "ABA has been reset. Please restart the TUI."
2. Re-initialize all state by re-sourcing config and re-detecting mode.

### Impact

Users who reset ABA via the TUI and then try to perform operations without restarting will encounter confusing errors or stale data.

---

## Bug #598 — `verify-cluster-conf` uses unquoted `$ports` variable

**Status:** OPEN — `[ ! -n $ports ]` at line 1078 is unquoted; when empty, expands to `[ ! -n ]` which is always true
**Severity:** LOW — Coding style violation, potential edge case
**Found:** 2026-06-24 (code review)
**Component:** Core ABA (`scripts/include_all.sh`, line 1082)

### Description

Line 1082 in `include_all.sh`:
```bash
if [ ! -n $ports ]; then
```

The `$ports` variable is not quoted. If `ports` is empty, this works because `[ ! -n ]` evaluates to false. But if `ports` contains spaces or special characters, the test could fail or produce unexpected results.

### Expected

Should use:
```bash
if [ ! -n "$ports" ]; then
```

Or better: `if [ -z "${ports:-}" ]; then`

---

## Bug #599 — Bug #405 (`_tui_reject_squote` only blocks `'`) is FIXED

**Status:** FIXED
**Severity:** N/A
**Found:** 2026-06-24 (code review)
**Component:** TUI v2 (`tui/v2/tui-lib.sh`, line 386)

### Description

Bug #405 reported that `_tui_reject_squote` only blocked single quotes. The function now also blocks backtick, dollar sign, and backslash:
```bash
if [[ "$1" == *"'"* || "$1" == *'`'* || "$1" == *'$'* || "$1" == *'\\'* ]]; then
```

This fix addresses the original concern about shell metacharacters in config values.

---

## Bug #600 — Bug #471 (typo "reprecated") is FIXED

**Status:** FIXED
**Severity:** N/A
**Found:** 2026-06-24 (code review on conno)
**Component:** Core ABA (`scripts/include_all.sh`)

### Description

The typo "reprecated" (should be "deprecated") has been corrected. `grep -r 'reprecated' scripts/` returns no matches on the current dev branch.

---

## Bug #601 — `aba --version X.Y --channel <chan>` resolves version using wrong channel

**Status:** OPEN — line 488 uses `$ocp_channel` (from aba.conf) instead of `$chan` (from --channel flag) for x.y expansion
**Severity:** MEDIUM — Silent wrong behavior
**Found:** 2026-06-25 (live testing on conno)
**Component:** Core ABA (`scripts/aba.sh`, lines 462-514)

### Description

When `--version` (short form `X.Y`) is specified BEFORE `--channel` on the command line, the version resolution uses the OLD channel from `aba.conf` instead of the newly-specified channel. This is because arguments are parsed sequentially, and `--version` resolves immediately using `$ocp_channel` (line 488) before `--channel` has a chance to update it.

### Steps to reproduce

```bash
# aba.conf has ocp_channel=stable
aba --version 4.20 --channel candidate
grep '^ocp_version=' aba.conf
# → ocp_version=4.20.25 (stable's latest 4.20)
# Expected: 4.20.26 (candidate's latest 4.20)
```

### Root cause

Line 488 in `aba.sh`:
```bash
echo $ver | grep -q -E "^[0-9]+\.[0-9]+$" && ver=$(fetch_latest_z_version "$ocp_channel" "$ver")
```
At this point, `$ocp_channel` still has the old value from aba.conf because `--channel` hasn't been processed yet. The `$chan` variable on line 474 correctly falls back to `$ocp_channel`, but `$ocp_channel` is stale.

### Expected

Argument order should not matter. Either:
1. Parse all flags first (two-pass), then resolve, OR
2. Document that `--channel` must come before `--version`

### Workaround

Always specify `--channel` BEFORE `--version`:
```bash
aba --channel candidate --version 4.20  # Works correctly
```

---

## Bug #602 — Day-2 menu label says "after mirror load/sync" in DIRECT mode

**Status:** OPEN — "Configure OperatorHub (after mirror load/sync)" label at line 2055 not conditioned on mode
**Severity:** LOW — Cosmetic/misleading
**Found:** 2026-06-25 (live TUI testing on conno)
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`, line 2047)

### Description

The Day-2 menu item "R" has a hard-coded label: `Configure OperatorHub (after mirror load/sync)`. This label is displayed regardless of the current TUI mode. In DIRECT mode, there is no mirror — the label is misleading.

### Steps to reproduce

1. Start TUI in CONNO mode
2. Advanced → Switch to Fully Connected (direct)
3. Open Day-2 menu
4. Observe: "Configure OperatorHub (after mirror load/sync)" — makes no sense in DIRECT mode

### Expected

In DIRECT mode, the label should be mode-appropriate, e.g. "Configure OperatorHub" (without the mirror reference).

---

## Bug #603 — `aba --ntp` accepts any string without validation

**Status:** FIXED — --ntp now validates hostname/IP format
**Severity:** MEDIUM — Silently accepts garbage values
**Found:** 2026-06-25 (live CLI testing on conno)
**Component:** Core ABA (`scripts/aba.sh`, lines 676-687)

### Description

The `--ntp` flag accepts any value without validation. While `--dns` validates IP format (but not octet range), `--ntp` does zero validation — it directly concatenates all non-option arguments and writes them to aba.conf.

### Steps to reproduce

```bash
aba --ntp 'invalid!ntp'
grep '^ntp_servers=' aba.conf
# → ntp_servers='invalid!ntp'   (accepted without error)
```

### Expected

NTP values should be validated (at minimum: valid hostname or IP address format). The TUI's `_valid_ip_or_host_list` validates properly.

### Related

- Bug #477: `--starting-ip` accepts `999.999.999.999` (format-only regex, no octet check)
- Bug #603b: `--gateway-ip` also uses format-only regex without octet validation
- `--api-vip` and `--ingress-vip` DO validate octets properly (lines 700-730) — inconsistency

---

## Bug #604 — Inconsistent IP validation across CLI flags

**Status:** FIXED — all IP-accepting CLI flags now use _valid_ipv4() with octet-range check
**Severity:** MEDIUM — Some flags validate octets, others don't
**Found:** 2026-06-25 (code review)
**Component:** Core ABA (`scripts/aba.sh`)

### Description

IP address validation is inconsistent across CLI flags:

| Flag | Format check | Octet range check |
|------|-------------|-------------------|
| `--api-vip` | Yes | **Yes** (o1-o4 <= 255) |
| `--ingress-vip` | Yes | **Yes** (o1-o4 <= 255) |
| `--starting-ip` | Yes | **No** (999.999.999.999 accepted) |
| `--gateway-ip` | Yes | **No** (999.999.999.999 accepted) |
| `--dns` | Yes | **No** (999.999.999.999 accepted) |
| `--ntp` | **No** | **No** (any string accepted) |

### Expected

All IP-accepting flags should validate octet range (0-255), consistent with `--api-vip` and `--ingress-vip`.

---

## Bug #605 — Bug #23 (`_operator_menu` marks basket dirty without changes) is FIXED

**Status:** FIXED
**Severity:** N/A
**Found:** 2026-06-25 (code review)
**Component:** TUI v2 (`tui/v2/tui-mirror.sh`, lines 976-1003)

### Description

Bug #23 reported that `_operator_menu` set `_OP_BASKET_DIRTY=true` unconditionally after visiting submenus. The code now uses md5sum hash comparison before/after each submenu call — the dirty flag is only set when the basket actually changes.

---

## Bug #606 — TUI: Install wizard doesn't pre-check `.install-complete` before full walkthrough

**Status:** OPEN — wizard starts full multi-page flow without checking if cluster is already installed
**Severity:** Medium (UX — user goes through 4-page wizard only to fail at the end)
**Found:** 2026-06-25 (TUI testing on conno)
**Component:** TUI v2 (`tui/v2/tui-cluster.sh`)

### Steps to reproduce

1. Have an already-installed cluster (e.g. `sno` with `.install-complete` file)
2. Open TUI → Install Cluster
3. Do NOT edit the cluster name — just click "Next" through all 4 pages
4. On the review page, click "Install"
5. The install fails with "This cluster has already been deployed successfully!"

### Root cause

The `.install-complete` check (line 927) only triggers inside the `N)` case — i.e., when the user manually edits the cluster name. If the user keeps the default name and clicks "Next", no pre-check happens. The failure only surfaces when `aba cluster --name sno --step install` runs the Makefile's `check` target.

### Expected

The `.install-complete` check should also run:
- When the "Next" button is clicked on the basics page (`return 0` at line 895)
- Or at the start of `_cluster_execute()` before building the review page

### Suggested fix

Add a check in `_cluster_page_basics` when rc=3 (Next), or at the top of `_cluster_execute`, that tests for `.install-complete` and warns the user.

---

## Bug #607 — CLI: `--target-version` z-stream resolution uses `$ocp_channel` instead of `$chan`

**Status:** OPEN — line 542 uses `$ocp_channel` for `fetch_latest_z_version` instead of `$chan` from `--channel` flag
**Severity:** Medium (wrong upgrade version resolved)
**Found:** 2026-06-25 (code review)
**Component:** CLI (`scripts/aba.sh`, line 542)

### Description

In the `--target-version` processing (lines 516-548 of `aba.sh`), line 530 correctly checks `$chan` (set by a preceding `--channel` flag). However, line 542 uses `$ocp_channel` instead of `$chan` for the z-stream resolution:

```
echo $tgt_ver | grep -q -E "^[0-9]+\.[0-9]+$" && tgt_ver=$(fetch_latest_z_version "$ocp_channel" "$tgt_ver")
```

This means `aba --channel candidate --target-version 4.21` resolves the z-stream using the OLD channel from `aba.conf` (e.g., `stable`), not the `candidate` channel just specified.

### Expected

Line 542 should use `$chan` (or `${chan:-$ocp_channel}`) instead of `$ocp_channel`.

### Relationship

Related to Bug #601 (same class of bug — argument ordering dependency).

---

## Bug #608 — TUI: Delete Cluster help text says "removes the cluster directory" but it doesn't

**Status:** OPEN — help text (line 1835) says "removes the cluster directory" but `aba delete` only removes directory with `--force`
**Severity:** Low (misleading help text, not functional bug)
**Found:** 2026-06-25 (TUI testing via tmux)
**Component:** TUI (`tui/v2/tui-cluster.sh`, `cluster_delete` function)

### Description

The "Delete Cluster" help dialog in the Day-2 menu states:

> "Delete removes the cluster directory and all generated resources (kubeconfig, manifests, ISOs, state markers)."

However, after running `aba --dir sno delete`:
- The VM is destroyed (correct)
- The state directory `~/.aba/clusters/sno.example.com` is removed (correct)
- But the cluster config directory `~/aba/sno/` is **preserved** — including `cluster.conf`, chrony YAML files, and symlinks

The help text incorrectly states the "cluster directory" is removed. The config directory (`~/aba/sno/`) is preserved for potential re-installation, which is good behavior but contradicts the help text.

### Expected

The help text should say something like:
> "Delete destroys VMs (on virtualized platforms) and removes generated state (kubeconfig, manifests, ISOs, state markers). The cluster configuration directory (cluster.conf) is preserved for re-installation."

### Evidence

```
$ ls ~/aba/sno/
99-master-chrony-conf-override.yaml  aba.conf  cli  cluster.conf  clusterstate  Makefile  scripts  templates  vmware.conf
```

After `aba delete`, the directory still exists with `cluster.conf` preserved.

---

## Bug #609 — TUI: Inconsistent default channel fallback in `mirror_prep_upgrade`

**Status:** LOW RISK — `${ocp_channel:-fast}` at line 509 uses "fast" as fallback, but `ocp_channel` is always sourced from aba.conf before this point
**Severity:** Low (edge case — `ocp_channel` is usually set from aba.conf)
**Found:** 2026-06-25 (code review)
**Component:** TUI (`tui/v2/tui-mirror.sh`, line 510)

### Description

In `mirror_prep_upgrade()` (line 510 of `tui-mirror.sh`):
```bash
local _channel="${ocp_channel:-fast}"
```

The default fallback for `ocp_channel` is "fast". However, all other TUI functions use "stable" as the default:
- `_mirror_op_confirm()` line 429: `local _chan="${ocp_channel:-stable}"`
- `mirror_create_bundle()` line 1317: `local _chan="${ocp_channel:-stable}"`

If `ocp_channel` is unset (unlikely in normal operation, but possible in edge cases), the upgrade preparation dialog would query the "fast" channel instead of "stable", potentially showing different/newer versions.

### Expected

Line 510 should use `"${ocp_channel:-stable}"` for consistency with the rest of the TUI.

### Impact

Low — `ocp_channel` is typically always set from `aba.conf`. However, the inconsistency could lead to confusing behavior if the variable is somehow unset.

---

## Bug #610 — Regression: `mirror_prep_upgrade` no longer rejects downgrades/same-version

**Status:** OPEN — no version comparison between `_current_ver` and `_target_ver` before confirmation dialog at line 617
**Severity:** Medium (user can prepare downgrade images, wasting time and storage)
**Found:** 2026-06-25 (code review during DISCO workflow testing)
**Live verified:** 2026-06-25 — entered "4.20.18" as target from "4.20.20", TUI accepted it and showed confirmation "Download upgrade images (4.20.20 → 4.20.18)"
**Component:** TUI (`tui/v2/tui-mirror.sh`, `mirror_prep_upgrade` function)

### Description

Bug #395 ("Prepare Upgrade accepts downgrade/same-version without warning") was marked FIXED by adding a numeric comparison that rejected `_target_ver <= _current_ver`. However, the subsequent refactor of `mirror_prep_upgrade` (which converted it from a free-text input to a menu-based version picker) **removed the downgrade check entirely**.

The new code (lines 499-653) validates that the target version exists in the Cincinnati graph (`verify_release_version_exists`), but does NOT check whether the target is actually higher than the current configured version (`ocp_version`).

This means a user can:
1. Have OCP 4.20.20 configured
2. Select "Previous" from the version picker (e.g. 4.20.19)
3. The version is valid in the graph, so it passes validation
4. Proceed to save downgrade images — wasting time and disk space

### Old code (removed)

```bash
IFS='.' read -r _cur_major _cur_minor _cur_patch <<< "$_current_ver"
IFS='.' read -r _tgt_major _tgt_minor _tgt_patch <<< "$_target_ver"
local _cur_num=$(( _cur_major * 1000000 + _cur_minor * 1000 + _cur_patch ))
local _tgt_num=$(( _tgt_major * 1000000 + _tgt_minor * 1000 + _tgt_patch ))
if [[ $_tgt_num -le $_cur_num ]]; then
    # rejected with message
fi
```

### Expected

After the version is selected and before the confirmation dialog (around line 606), add a downgrade check using `is_version_greater`:
```bash
if [[ "$_current_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] && ! is_version_greater "$_target_ver" "$_current_ver"; then
    dlg --backtitle "$(ui_backtitle)" --msgbox \
        "Target version '$_target_ver' must be higher than current version '$_current_ver'.\n\nDowngrades are not supported." 0 0
    continue
fi
```

### Impact

User can accidentally save downgrade images, wasting potentially hours of oc-mirror time and gigabytes of disk space on an operation that will fail at cluster upgrade time.

### Live Verification

Tested on conno host via tmux "tui-debugging" session:
1. Opened "Prepare Upgrade for Transfer" from CONNO menu
2. Selected "Manual entry"
3. Entered "4.20.19" (lower than current 4.20.20)
4. Version was verified against Cincinnati graph (passed — 4.20.19 exists)
5. TUI showed confirmation: "Download upgrade images (4.20.20 → 4.20.19)"
6. **No warning about downgrade** — TUI was ready to proceed with saving downgrade images

---

## Bug #611 — TUI: Wizard shows unconfirmed version in "Current" option after declining

**Status:** NOT A BUG — `_direct_version()` has no confirmation dialog; "Current" shows previously-selected in-memory version which is correct wizard navigation
**Severity:** Medium (cosmetic / UX confusion)
**Component:** `tui/v2/tui-direct.sh`, `_direct_version()`

### Description

When a user selects a channel and version in the wizard, then declines on the confirmation dialog ("No"), the in-memory `ocp_version` is NOT reverted to its previous value. This causes:

1. The backtitle to show the unconfirmed version (e.g. `stable 5.0.0-ec.3`)
2. The version picker's "Current" option to display the unconfirmed version
3. If the user switches channels (e.g. candidate → stable), the "Current" option shows a version that doesn't even belong to the new channel

The issue self-heals when the wizard is exited (Cancel/Back), because `normalize-aba-conf` reloads from `aba.conf`. But while inside the wizard, the stale state causes confusion.

### Root Cause

In `_direct_version()` (tui-direct.sh), the version selection at line ~463 sets `ocp_version` in-memory immediately:
```
l) ocp_version="$latest" ;;
```
The confirmation dialog at line 131 can reject this, but `ocp_version` is already changed. When `step="channel"` loops back, the version picker reads the stale `ocp_version` for the "Current" option.

### Suggested Fix

Save the previous `ocp_version` before entering the version step, and restore it if the user declines confirmation.

### Live Verification

Tested on conno host via tmux "tui-debugging" session:
1. From CONNO main menu → "W" Rerun Wizard → "Reconfigure"
2. Selected "candidate" channel
3. Selected "l Latest (5.0.0-ec.3)"
4. Declined on confirmation ("No")
5. Back at channel selection — backtitle shows `candidate 5.0.0-ec.3` (should be `stable 4.20.20`)
6. Selected "stable" channel
7. Version picker shows "Current (5.0.0-ec.3)" — an EC version shown under stable channel
8. Selected "m" Manual entry — pre-filled with "5.0.0-ec.3"

---

## Bug #612 — TUI: Reserved cluster name gives misleading "Invalid DNS label" error

**Status:** FIXED — TUI shows specific error from _valid_cluster_name instead of generic message
**Severity:** Low (UX / error message quality)
**Component:** `tui/v2/tui-cluster.sh`, cluster name input; `tui/v2/tui-strings2.sh`

### Description

When the user enters a reserved ABA directory name (e.g. "mirror", "scripts", "test") as a cluster name, the TUI shows:

```
Invalid cluster name.

Must be a valid DNS label:
• Start with a lowercase letter
• End with a letter or digit (not hyphen)
• Only lowercase a-z, 0-9, hyphens
• Maximum 63 characters
```

This is misleading because "mirror" IS a valid DNS label — the actual reason is that it's a reserved ABA directory name. The core function `_valid_cluster_name()` in `include_all.sh` correctly identifies reserved names with a proper error message ("'mirror' is a reserved ABA directory name"), but the TUI discards this message and shows a generic DNS label error.

### Root Cause

In `tui-cluster.sh` line 919:
```
if ! aba cluster --name "$input" --validate >/dev/null 2>&1; then
    dlg ... "$TUI2_MSG_INVALID_CLUSTER_NAME" ...
```

The `>/dev/null 2>&1` suppresses the actual error message from `_valid_cluster_name()`, and a hardcoded generic error is shown instead.

### Suggested Fix

Capture the stderr from `aba cluster --name "$input" --validate` and display it in the dialog, or distinguish between DNS validation failure and reserved name rejection.

### Live Verification

Tested on conno host via tmux "tui-debugging" session:
1. From CONNO main menu → "I" Install Cluster
2. Selected "N" Cluster name
3. Entered "mirror"
4. Got generic "Invalid cluster name" with DNS label rules — no mention of reserved name

---

## Bug #613 — TUI: Invalid MAC addresses kept in memory after validation warning

**Status:** FIXED — MAC validation now assigns to cl_macs only after passing checks

**Severity**: MEDIUM — Invalid MACs can be persisted to `macs.conf` if user doesn't re-enter  
**Component**: TUI (`tui/v2/tui-cluster.sh`, lines 1349-1360)  
**Discovered**: 2026-06-25

### Description

In `_cluster_page_iface()`, when the user enters MAC addresses via the editbox ("M" option for bare-metal), the code normalizes and assigns the input to `cl_macs` on line 1351 **before** validating the MAC format on lines 1353-1354. If validation fails (invalid format), the code shows a warning dialog and `continue`s to the outer loop, but `cl_macs` still contains the invalid MAC data.

### Code flow

```bash
# Line 1349: Read user input
local raw=$(<"$_TUI_TMP")
# Line 1351: Assign to cl_macs BEFORE validation
cl_macs=$(echo "$raw" | tr ',; ' '\n' | sed '/^$/d' | tr -d ' \t')
# Line 1353-1354: Validate AFTER assignment
_bad_macs=$(echo "$cl_macs" | grep -vE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' || true)
if [[ -n "$_bad_macs" ]]; then
    # Line 1356-1358: Warning shown but cl_macs NOT reverted
    dlg ... --msgbox "Invalid MAC address(es):..." 0 0 || true
    rm -f "$_mac_edit"
    continue  # back to outer loop — cl_macs still has invalid data
fi
```

### Impact

1. After dismissing the warning, the interface page menu shows "MACs: N entered" with the invalid count
2. If the user advances to the next page without re-entering MACs, `_persist_cluster_draft()` (line 176) writes `cl_macs` to `macs.conf`
3. The install would later fail when ABA tries to use invalid MAC addresses for VMs

### Suggested Fix

Save `cl_macs` before the assignment and restore it if validation fails:

```bash
local _prev_macs="$cl_macs"
cl_macs=$(echo "$raw" | tr ',; ' '\n' | sed '/^$/d' | tr -d ' \t')
if [[ -n "$_bad_macs" ]]; then
    cl_macs="$_prev_macs"  # Revert to previous valid state
    dlg ... --msgbox "Invalid MAC address(es):..." 0 0 || true
    ...
fi
```

---

## Bug #614 — TUI: Wizard "Next" button (Extra button) not reachable via keyboard Tab cycling

**Status:** BY DESIGN — `dialog --extra-button` Tab cycling is a known dialog(1) utility limitation; can't be fixed in ABA code
**Severity**: HIGH — Wizard pages cannot be advanced via keyboard in some dialog versions  
**Component**: TUI (`tui/v2/tui-cluster.sh`, wizard pages 1-4)  
**Discovered**: 2026-06-25

### Description

The cluster wizard uses `dialog --extra-button --extra-label "Next"` to add a "Next" button for page navigation. However, dialog's Tab cycling for `--menu` with `--extra-button` skips the Extra button entirely:

- Tab cycle observed: Menu list → OK (Select) → Cancel (Back) → Help → back to list
- The Extra (Next) button is never focused during Tab cycling
- Users cannot advance wizard pages using keyboard-only navigation

### Visual layout vs Tab order

```
Buttons displayed:  <Select>    < Next >    < Back >    < Help >
Tab cycle:          Select (1) ──────────→ Back (2) ──→ Help (3)
                                    ↑ Next is SKIPPED ↑
```

### Live Verification

Tested on conno host via tmux "tui-debugging" session:
1. From CONNO main menu → "I" Install Cluster → Page 1 (Basics)
2. Tab × 1 → Enter → triggered "Select" (OK, rc=0) — opened name edit
3. Tab × 2 → Enter → triggered "Back" (Cancel, rc=1) — exited wizard
4. Tab × 3 → Enter → triggered "Help" (rc=2) — showed help dialog
5. Tab × 4 → Enter → back to list, "Select" processed current item
6. Extra/Next button was never reachable via Tab

### Impact

- All wizard pages (Basics, Network, Interfaces, VM Resources) use this button pattern
- Keyboard-only users cannot advance through the wizard
- Mouse users can click "Next" but tmux/SSH automation cannot
- This affects both human users without a mouse and automated testing

### Workaround

Unknown. Dialog's `--default-button extra` might make Extra the default (reachable via Enter without Tab), but this would change the default action from "Select" to "Next".

### Suggested Fix

Consider one of:
1. Use `--default-button extra` to make "Next" the default (Enter advances, not selects)
2. Replace the 4-button pattern (Select/Next/Back/Help) with a 2-button pattern (OK=Next, Cancel=Back) and use shortcut keys for item selection
3. Add a dedicated "N" menu item at the bottom of each page's item list for "Next →" navigation

## Bug #615 — TUI: Cluster wizard accepts starting IP outside machine network without validation

**Status:** OPEN — no subnet containment check between `starting_ip` and `machine_network` in the wizard flow
**Severity:** Medium (cluster install will fail later with confusing errors)
**Found:** 2026-06-25 (live testing DIRECT mode cluster wizard)
**Live verified:** 2026-06-25 — Set machine_network=192.168.2.0/24, starting_ip=10.0.0.100 (completely different subnet), wizard advanced to Interfaces page without any warning or validation error
**Component:** TUI (`tui/v2/tui-cluster.sh`, `_cluster_page_network` function)

### Description

The cluster wizard's Network page (`_cluster_page_network`) does not validate that the starting IP address falls within the configured machine network CIDR when the user presses "Next" (Extra button). Line 1043 returns 0 immediately without any cross-field validation:

```bash
case "$rc" in
    3) return 0 ;;  # Next — no validation at all!
```

This means a user can configure:
- Machine network: `192.168.2.0/24`
- Starting IP: `10.0.0.100` (completely different subnet)

The wizard will accept this and proceed through all remaining pages. The mismatch will only be caught later when the cluster installation fails with confusing errors about unreachable nodes.

Similarly, the gateway is not validated against the machine network either (e.g., gateway `10.0.0.1` with network `192.168.2.0/24`).

### Expected Behavior

When pressing "Next" on the Network page, the wizard should validate that:
1. Starting IP is within the machine network CIDR
2. Gateway is within the machine network CIDR (or at least on the same subnet)
3. API VIP and Ingress VIP (if set) are within the machine network

### Suggested Fix

Add a validation block before `return 0` on the "Next" path (rc=3) in `_cluster_page_network`:

```bash
3)
    # Validate starting IP is within machine network
    if [[ -n "$cl_starting_ip" && -n "$cl_network" ]]; then
        if ! _ip_in_cidr "$cl_starting_ip" "$cl_network"; then
            dlg --backtitle "$(ui_backtitle)" --msgbox \
                "Starting IP $cl_starting_ip is not within\nmachine network $cl_network" 0 0
            continue
        fi
    fi
    return 0
    ;;

---

## Bug #616 — TUI: ESC in DIRECT/DISCO mode (entered from CONNO) exits entire TUI instead of returning to CONNO

**Status:** OPEN — ESC at line 758 triggers `confirm_quit` → `exit 0`; no mechanism to return to calling CONNO mode
**Severity:** Medium (user loses entire TUI session unexpectedly)
**Found:** 2026-06-25 (live testing mode switch CONNO → DIRECT)
**Live verified:** 2026-06-25 — Switched from CONNO to DIRECT via Advanced → Switch to Fully Connected. Pressed ESC in DIRECT menu → "Confirm Exit" dialog appeared. Confirmed → entire TUI exited with exit summary.
**Component:** TUI (`tui/v2/tui-direct.sh` line 758, `tui/v2/tui-disco.sh` line 238)

### Description

When the user switches from CONNO to DIRECT or DISCO mode via Advanced menu (e.g. `tui-cluster.sh` line 1990: `direct_main || true`), pressing ESC/Exit in the sub-mode's menu exits the entire TUI (`exit 0`) instead of returning to the CONNO menu.

Both `disco_main()` and `direct_main()` have identical exit handling:

```bash
1|255)
    if confirm_quit; then
        clear
        _show_v2_exit_summary
        exit 0   # <-- kills entire TUI, not just the sub-mode
    fi
    continue
    ;;
```

The parent code in `tui-cluster.sh` expects the sub-mode function to `return`:

```bash
_TUI_MODE="DIRECT"
direct_main || true   # expects direct_main to return, not exit
_TUI_MODE="CONNO"     # THIS LINE NEVER EXECUTES if direct_main exits
```

### UX Impact

1. **Cancel button mislabeled:** Shows "Exit" when it should say "Back" (to CONNO)
2. **Exit dialog misleading:** "Exit ABA TUI?" — user may only want to leave DIRECT mode
3. **Session loss:** Confirming Exit kills the entire TUI, losing CONNO state
4. **`_TUI_DISCO_FROM_CONNO` flag unused:** Variable exists (set on line 2021 of tui-cluster.sh) but the ESC handler doesn't check it

### Live Verification Steps

1. Started TUI in CONNO mode on conno host
2. Main menu → "A" Advanced
3. Selected "X" Switch to Fully Connected (direct)
4. DIRECT action menu appeared with "Exit" button
5. Pressed ESC → "Confirm Exit" dialog: "Exit ABA TUI?"
6. Pressed Enter (Exit) → TUI exited completely with "TUI v2 complete." message
7. Shell prompt returned — TUI session entirely terminated

### Suggested Fix

In both `disco_main()` and `direct_main()`, check whether the mode was entered from CONNO. If so:
1. Change cancel-label from "Exit" to "Back"
2. On ESC, `return 0` instead of `exit 0` (no confirm_quit needed)

```bash
# At the ESC handler:
if [[ "${_TUI_DISCO_FROM_CONNO:-false}" == "true" ]]; then
    return 0   # back to CONNO menu
fi
# ... existing confirm_quit + exit 0 path for standalone mode
```

---

## Bug #617 — TUI: VMware/ESXi password input overly restricts valid characters ($, `, ")

**Status:** OPEN — `_tui_prompt_password` rejects `$`, `` ` ``, `"` for Quay compatibility, but is also used for vSphere passwords (line 391) which have no such restriction
**Severity:** Medium (blocks users with valid vSphere passwords containing $, `, or ")
**Found:** 2026-06-25 (code review of `_tui_prompt_password`)
**Component:** TUI (`tui/v2/tui-lib.sh` lines 399-449, `tui/v2/tui-cluster.sh` line 386)

### Description

The `_tui_prompt_password` function rejects passwords containing `$`, `` ` ``, and `"` characters. This validation was added because the upstream Quay mirror-registry installer cannot handle these characters (Ansible shell interpolation bug). However, the same function is also used for the VMware/ESXi password input (`tui-cluster.sh` line 386), where these characters are perfectly valid.

The password is stored in `vmware.conf` as:
```
GOVC_PASSWORD='p@$$w0rd'
```

Single-quoted values in bash protect ALL characters except `'` itself. Since `govc` receives the password via environment variable (not command line), `$`, `` ` ``, and `"` work correctly. The ONLY character that genuinely can't be stored is `'` (single quote).

### UX Impact

Users with vSphere passwords containing `$`, `` ` ``, or `"` are blocked by the TUI with:
```
Password cannot contain: '  "  `  $
(The upstream Quay mirror-registry tool cannot handle these.)
```

This message explicitly references "Quay mirror-registry" which is irrelevant for the VMware context.

### Suggested Fix

Add an optional parameter to `_tui_prompt_password` to control which characters are rejected:

```bash
_tui_prompt_password() {
    local prompt="${1:-Enter password:}"
    local min_len="${2:-1}"
    local reject_mode="${3:-quay}"  # "quay" = strict, "basic" = only reject '
    ...
    if [[ "$reject_mode" == "quay" ]]; then
        # Reject ', ", `, $ (Quay upstream limitation)
        ...
    else
        # Only reject ' (can't be stored in single-quoted value)
        if [[ "$pw1" == *"'"* ]]; then
            ...
        fi
    fi
}
```

Call sites:
- Mirror password: `_tui_prompt_password "..." 8 "quay"` (keep current restriction)
- VMware password: `_tui_prompt_password "..." 1 "basic"` (allow $, `, ")

---

## Bug #618 — Core: normalize-vmware-conf fails to unset inherited GOVC_DATACENTER on ESXi, causing cluster install failures

**Status:** FIXED (commit 30417197, verified on conno)
**Severity:** High (blocks ALL cluster installations after TUI Platform Settings is opened with template vmware.conf on ESXi)
**Found:** 2026-06-25 (live testing + code analysis of `normalize-vmware-conf`)
**Component:** Core (`scripts/include_all.sh` lines 1110-1148, `scripts/install-vmware.conf.sh`)

### Description

When `normalize-vmware-conf` detects a standalone ESXi host (HostAgent), it DELETES the `GOVC_DATACENTER` and `GOVC_CLUSTER` lines from its output (line 1128, sed `-e "/GOVC_DATACENTER/d" -e "/GOVC_CLUSTER/d"`). The intent is to prevent these vCenter-only variables from being used on ESXi.

However, **deleting a line from output does NOT unset a previously-exported variable**. If the calling process already has `GOVC_DATACENTER` exported (e.g., from a prior `source <(normalize-vmware-conf)` call), the stale value persists in the environment because nothing explicitly clears it.

### Reproduction Steps

1. Start the TUI (CONNO mode)
2. Navigate to Advanced → Platform Settings → VMware vSphere
3. The TUI sources `normalize-vmware-conf` to populate the form (line ~308 of `tui-cluster.sh`)
4. If `vmware.conf` is the template (with `GOVC_DATACENTER=Datacenter`), and the target host is unreachable (vcenter.lan), normalize falls into the vCenter path and exports `GOVC_DATACENTER=Datacenter`
5. Press Back/Cancel to exit the form — the export persists in the TUI process
6. Restore/fix vmware.conf with correct ESXi values (GOVC_URL=10.0.1.40, GOVC_DATACENTER=)
7. Attempt cluster install → `install-vmware.conf.sh` sources `normalize-vmware-conf`
8. ESXi is detected correctly, but GOVC_DATACENTER line is DELETED from output (not set to empty)
9. The inherited `GOVC_DATACENTER=Datacenter` remains in the child's environment
10. All `govc` lookups fail: "datacenter 'Datacenter' not found"

### Proof

```bash
cd ~/aba
source scripts/include_all.sh

# Step 1: Simulate TUI opening Platform Settings with template
cp templates/vmware.conf vmware.conf  # Has GOVC_DATACENTER=Datacenter
source <(normalize-vmware-conf)
echo "GOVC_DATACENTER=$GOVC_DATACENTER"  # Output: Datacenter

# Step 2: Restore real ESXi config (GOVC_DATACENTER= empty)
cp ~/.vmware.conf vmware.conf
source <(normalize-vmware-conf)
echo "GOVC_DATACENTER=$GOVC_DATACENTER"  # Output: Datacenter (STALE!)

# Step 3: govc fails
govc datastore.info Datastore4-S4
# ERROR: govc: datacenter 'Datacenter' not found
```

### Root Cause

`scripts/include_all.sh` line 1128:
```bash
echo "$vars" | sed -e "s#VC_FOLDER.*#VC_FOLDER=/ha-datacenter/vm#g" -e "/GOVC_DATACENTER/d" -e "/GOVC_CLUSTER/d"
```

The sed DELETES lines containing GOVC_DATACENTER/GOVC_CLUSTER instead of explicitly setting them to empty. This is a no-op if the variable was already exported in the calling process.

### Suggested Fix

After the `echo "$vars" | sed ...` line in the ESXi branch, explicitly output empty values:

```bash
# ESXi branch (line 1128-1130):
echo "$vars" | sed -e "s#VC_FOLDER.*#VC_FOLDER=/ha-datacenter/vm#g" -e "/GOVC_DATACENTER/d" -e "/GOVC_CLUSTER/d"
echo "$vars" | grep -q "VC_FOLDER" || echo "export VC_FOLDER=/ha-datacenter/vm"
echo "export GOVC_DATACENTER="   # Explicitly clear inherited value
echo "export GOVC_CLUSTER="      # Explicitly clear inherited value
echo export VC=
```

This ensures any previously-exported GOVC_DATACENTER/GOVC_CLUSTER values are overwritten with empty strings when ESXi is detected.

---

## Bug #620 — Core: verify-cluster-conf silently accepts empty `ports` due to unquoted variable

**Status:** FIXED — quoted $ports variable; empty ports now correctly skipped

- **Status:** OPEN (verified on conno)
- **Severity**: Medium (validation bypass — empty ports in cluster.conf not caught)
- **Component**: `scripts/include_all.sh` → `verify-cluster-conf()`
- **Found by**: Code review + CLI verification

### Symptom

When `cluster.conf` has an empty `ports=` value (or `ports` is not set at all), `verify-cluster-conf()` should report an error but silently passes. This means a cluster.conf with no port configuration can proceed to installation without warning.

### Root Cause

Line 1078 in `scripts/include_all.sh`:

```bash
if [ ! -n $ports ]; then
```

The `$ports` variable is **unquoted**. When `ports` is empty:
- The shell expands this to: `[ ! -n ]` (two arguments: `!` and `-n`)
- In the two-argument form of `test`, `[ ! expr ]` checks if the string is empty
- Since `-n` is not empty, this evaluates to **false** (exit code 1)
- The error block is never reached

### Reproduction

```bash
$ ports=""
$ if [ ! -n $ports ]; then echo "DETECTED"; else echo "BUG: missed"; fi
BUG: missed

$ if [ ! -n "$ports" ]; then echo "DETECTED"; else echo "BUG: missed"; fi
DETECTED
```

### Suggested Fix

Quote the variable:

```bash
if [ ! -n "$ports" ]; then
```

Or better:

```bash
if [ -z "$ports" ]; then
```

---

## Bug #621 — Core: `aba bundle --out` command injection via `eval` with unquoted variables

**Status:** OPEN — code review + CLI verification

- **Status:** OPEN (code review + CLI verification)
- **Severity**: High (command injection — local privilege escalation via crafted path)
- **Component**: `scripts/aba.sh` line 1145
- **Found by**: Code review

### Symptom

A crafted `--out` path argument containing single quotes can escape the quoting in `opt_out` and inject arbitrary commands when `eval` is used on line 1145.

### Root Cause

Line 441 in `scripts/aba.sh`:
```bash
opt_out="--out '$1'"
```

Line 1145:
```bash
eval $ABA_ROOT/scripts/make-bundle.sh $opt_out $opt_force $opt_light
```

The `$opt_out` variable contains the user-supplied path wrapped in single quotes. However, if the user's path itself contains single quotes, the quoting is broken:

1. User runs: `aba bundle --out "/tmp/x' && id && echo '"`
2. `opt_out` becomes: `--out '/tmp/x' && id && echo ''`
3. After `eval`: executes `make-bundle.sh --out /tmp/x` THEN `id` THEN empty echo

The TUI path is partially protected by `_tui_reject_squote` (rejects single quotes). But:
- The CLI (`aba bundle --out ...`) has **NO single-quote sanitization** for the path
- Line 437 only checks `grep -q "^-"` (rejects paths starting with `-`) and directory existence

### Reproduction

```bash
# Hypothetical - DO NOT run if untrusted input is possible
$ aba bundle --out "/tmp/safe' && echo INJECTED && echo '"
# If /tmp/safe directory check passes, eval will execute: echo INJECTED
```

### Additional Issue: Unquoted `$(dirname $1)` on line 437

```bash
[ "$1" ] && [ ! -d $(dirname $1) ] && aba_abort "..."
```

If `$1` contains spaces, word splitting occurs in both `dirname`'s output and the `-d` test. E.g., `aba bundle --out "/path with spaces/file"` will fail incorrectly.

### Suggested Fix

Remove `eval` entirely. Use an array for arguments:

```bash
local -a bundle_args=()
[ -n "$opt_out_path" ] && bundle_args+=(--out "$opt_out_path")
[ -n "$opt_force" ] && bundle_args+=(--force)
[ -n "$opt_light" ] && bundle_args+=(--light)
"$ABA_ROOT/scripts/make-bundle.sh" "${bundle_args[@]}"
```

Also quote `$(dirname "$1")` on line 437.

---

## Bug #622 — TUI: `_configure_vmw_form` password clearing uses glob that could match real passwords

**Status:** OPEN — code review

- **Status:** OPEN (code review)
- **Severity**: Low (unlikely edge case — password would need to match `<*>` glob)
- **Component**: `tui/v2/tui-cluster.sh` line 320
- **Found by**: Code review

### Symptom

If a VMware/ESXi password happens to match the glob pattern `<*>` (i.e., starts with `<` and ends with `>`), the TUI incorrectly clears it, treating it as the template placeholder `<password>`.

### Root Cause

Line 320 in `tui/v2/tui-cluster.sh`:
```bash
[[ "$v_pass" == "<"*">" ]] && v_pass=""
```

This uses shell glob matching (not regex). Any string starting with `<` and ending with `>` matches, including legitimate passwords like `<MyS3cr3t>` or `<admin123>`.

### Suggested Fix

Use an exact match instead of a glob:

```bash
[[ "$v_pass" == "<password>" ]] && v_pass=""
```

Or match the specific placeholder text that `vmware.conf` uses.

---

## Bug #623 — Core/TUI: CLI accepts `eus` channel but TUI does not offer it

**Status:** OPEN — code review

- **Status:** OPEN (code review)
- **Severity**: Low (UX inconsistency — users must use CLI for EUS channel)
- **Component**: `scripts/aba.sh` lines 444-461 vs `tui/v2/tui-direct.sh` `_direct_channel`
- **Found by**: Code review

### Symptom

The `aba` CLI accepts `--channel eus` as a valid channel option, but the TUI's channel selection dialog (`_direct_channel`) only presents: stable, fast, candidate. Users who need EUS (Extended Update Support) must use the CLI, with no indication from the TUI that this option exists.

### Root Cause

`scripts/aba.sh` line 452:
```bash
stable|fast|candidate|eus)
```

`tui/v2/tui-direct.sh` `_direct_channel` (around line 276):
```bash
1 "Stable" ...
2 "Fast" ...
3 "Candidate" ...
```

No `eus` option in the radiolist.

### Suggested Fix

Add EUS to the TUI channel selection:
```bash
4 "EUS (Extended Update Support)" off
```

---

## Bug #624 — TUI: No support for `register`/`unregister` — forces CLI for existing external registries

**Status:** OPEN — code review + manual verification

- **Status:** OPEN (code review + manual verification)
- **Severity**: Medium (missing feature — users cannot use TUI for a documented core workflow)
- **Component**: `tui/v2/abatui2.sh` (CONNO menu), `tui/v2/tui-disco.sh` (DISCO menu)
- **Found by**: Code review + TUI testing

### Symptom

Users who have an existing external mirror registry (not installed by ABA) cannot use the TUI to register it. They MUST drop to the CLI and run:
```bash
aba -d mirror register --reg-host registry.example.com --pull-secret-mirror /path/to/ps.json --ca-cert /path/to/ca.pem
```

The TUI's "Install Mirror" option always installs a NEW Quay or Docker registry. There is no menu item for "Connect to Existing Registry" or "Register External Registry."

### Root Cause

The TUI menu code in `abatui2.sh` (CONNO menu, line ~571) and `tui-disco.sh` (DISCO menu) only has:
- Install Mirror (M)
- Sync (Y)
- Save (S)

There is NO tag or menu entry for `register` or `unregister`. The `tui/v2/` directory contains zero occurrences of the word "register" (verified via grep).

### Impact

1. README line 282 claims the TUI "covers the complete workflow" including "mirror configuration (local or remote registry)" — this is misleading since register is CLI-only
2. Users following the README section "Using an Existing Registry" (lines 1068-1086) cannot complete the workflow via TUI
3. Named mirror + register workflow (README lines 1329-1338) is entirely CLI-only

### Suggested Fix

Add a "Register External Registry" option to the mirror section of both CONNO and DISCO menus. The dialog should prompt for:
- Registry hostname
- Registry port (default 8443)
- Path to pull-secret-mirror.json
- Path to rootCA.pem

Then run: `aba --dir mirror register --reg-host ... --pull-secret-mirror ... --ca-cert ...`

Also add "Unregister" option to allow disconnecting from an external registry.

---

## Docbug #625 — README overstates TUI capabilities (claims "complete workflow")

**Status:** FIXED — changed wording to "mirror installation (local or remote Quay/Docker; ")

- **Status:** FIXED (changed wording to "mirror installation (local or remote Quay/Docker)")
- **Severity**: Low (misleading documentation)
- **Component**: `README.md` line 282
- **Found by**: Documentation review

### Symptom

README line 282 states:
> "The TUI covers the complete workflow: mode selection (partially disconnected, fully disconnected, or direct), channel/version/platform wizard, operator selection, mirror configuration (local or remote registry), image sync/save/load, bundle creation, cluster installation..."

The phrase "mirror configuration (local or remote registry)" implies the TUI can configure an existing external registry. It cannot — `register`/`unregister` are CLI-only (see Bug #624).

### Suggested Fix

Add a note clarifying:
> "For connecting to an existing external registry, use the CLI: `aba -d mirror register` (see [Using an Existing Registry](#using-an-existing-registry))."

Or change "mirror configuration (local or remote registry)" to "mirror installation (local or remote Quay/Docker)".

---

## Docbug #626 — README: No documentation section for shutdown/startup/rescue workflow

**Status:** FIXED — added "Cluster Shutdown & Startup" section to README

- **Status:** FIXED (added "Cluster Shutdown & Startup" section to README)
- **Severity**: Low (missing documentation section)
- **Component**: `README.md`
- **Found by**: Documentation review

### Symptom

The README mentions "Graceful cluster shutdown and startup" as a feature (line 130) and lists `aba shutdown`, `aba startup`, and `aba rescue` in the command reference table (lines 1244-1246). However, there is NO dedicated documentation section explaining:

1. When to use `aba shutdown` vs `aba stop` vs `aba poweroff`/`aba kill`
2. What `--wait` does (wait until all nodes power off?)
3. The correct startup procedure after shutdown (just `aba startup`? Any post-startup steps?)
4. When to use `aba rescue` (after failed startup? What does it do — uncordon, approve CSRs?)
5. The difference between graceful shutdown (OpenShift-level drain/cordon) and VM-level stop

### Impact

Users must guess the correct workflow or read source code. The TUI (Day-2 menu) provides "Graceful cluster shutdown" and "Graceful cluster startup" but no in-TUI help beyond the generic menu descriptions.

### Suggested Fix

Add a "Cluster Lifecycle" or "Shutdown & Startup" section under Day-2 Operations explaining the workflow:
```
## Graceful Cluster Shutdown & Startup

### Shutdown
aba shutdown --wait    # Gracefully drain, cordon, and shut down all nodes

### Startup
aba startup            # Power on all VMs and wait for cluster to become healthy

### Recovery
aba rescue             # Uncordon nodes, approve pending CSRs (use after startup issues)
```

---

## Docbug #627 — README: No documentation about bastion-level proxy for ABA operations

**Status:** FIXED — added proxy note in "Partially Disconnected Prerequisites" section

- **Status:** FIXED (added proxy note in "Partially Disconnected Prerequisites" section)
- **Severity**: Low (missing documentation)
- **Component**: `README.md`
- **Found by**: Documentation review

### Symptom

The README documents proxy settings for **cluster nodes** (`int_connection=proxy`, `http_proxy`/`https_proxy`/`no_proxy` in `cluster.conf`). However, there is NO documentation about configuring proxy settings on the **bastion host itself** for ABA operations like:

- `aba -d mirror sync` (requires Internet for `oc-mirror`)
- `aba -d mirror save` (requires Internet for `oc-mirror`)
- `aba bundle` (requires Internet for image download)
- `aba ocp-versions` (requires Internet)
- `./install` (requires Internet for git clone and tool downloads)

In a partially disconnected environment where the bastion reaches the Internet through a proxy, users need to set `http_proxy`/`https_proxy`/`no_proxy` environment variables BEFORE running ABA. This is standard Linux knowledge but not documented anywhere in the README.

### Impact

Users in proxy environments may not realize they need to export proxy vars before running `aba sync`/`aba save`/`aba bundle`, leading to connection timeouts and confusing error messages.

### Suggested Fix

Add a note in the "Partially Disconnected Prerequisites" section:
> **Bastion proxy**: If the bastion itself requires a proxy to reach the Internet, set the standard proxy environment variables (`http_proxy`, `https_proxy`, `no_proxy`) in your shell before running ABA. ABA tools (`oc-mirror`, `oc`, `curl`) inherit these settings.

---

## Docbug #628 — README: "Uninstalling ABA" section omits cluster deletion step

**Status:** OPEN — documentation review

- **Status:** OPEN (documentation review)
- **Severity**: Medium (data loss / orphan VMs)
- **Component**: `README.md` lines 1520-1531
- **Found by**: Documentation review

### Symptom

The "Uninstalling ABA" section instructs users to:
```
aba -d mirror uninstall
rm -rf aba
```

But does NOT mention **deleting clusters** before uninstalling. If the user has running VMware/KVM VMs managed by ABA, running `rm -rf aba` will:
1. Lose the kubeconfig and cluster state
2. Leave orphan VMs running indefinitely
3. Make cleanup difficult (no cluster directory to `aba delete` from)

### Impact

Users who follow the uninstall instructions literally will orphan running VMs (VMware or KVM). These VMs consume resources and hold IPs, and the only recovery is manual VM deletion via `govc`/`virsh` or vCenter UI.

### Suggested Fix

Add cluster deletion BEFORE mirror uninstall:
```
cd aba
aba -d <cluster-name> delete   # Delete each cluster's VMs
aba -d mirror uninstall         # Uninstall the registry
cd ..
rm -rf aba
sudo rm $(which aba) $(which abatui)
```

Or at minimum, add a warning: "**Warning:** If you have running clusters installed by ABA, delete them first with `aba -d <name> delete` to avoid orphaning VMs."

---

## Bug #629 — Core: VLAN validation uses bare `vlan` instead of `$vlan`

**Status:** INVALID — false positive — bash `[[ ]]` treats bare words in `-ge`/`-le` as variable names

- **Status:** INVALID (false positive — bash `[[ ]]` treats bare words in `-ge`/`-le` as variable names)
- **Severity**: ~~High~~ N/A
- **Component**: `scripts/include_all.sh` (`verify-cluster-conf`)
- **Found by**: Code review

### Symptom

Setting `vlan=100` in `cluster.conf` fails validation with "vlan is invalid" or "integer expression expected".

### Root Cause

In `verify-cluster-conf`, the VLAN range check uses `vlan -ge 1 && vlan -le 4094` (missing `$` prefix) instead of `$vlan -ge 1 && $vlan -le 4094`. Bash treats the literal word `vlan` as a command operand, not the variable value.

### Suggested Fix

Change `vlan -ge 1 && vlan -le 4094` to `$vlan -ge 1 && $vlan -le 4094`.

---

## Bug #630 — Core: `cluster-upgrade.sh` OSUS fallback does not check exit code

**Status:** OPEN — code review

- **Status:** OPEN (code review)
- **Severity**: High
- **Component**: `scripts/cluster-upgrade.sh` ~lines 310-318
- **Found by**: Code review

### Symptom

When `oc adm upgrade --to` fails and the fallback `--to-image` command also fails, the script prints "Upgrade command accepted by cluster" and enters monitoring — even though upgrade was never actually started.

### Root Cause

The fallback `$_image_cmd` exit code is never checked. The script unconditionally proceeds to monitoring regardless of success/failure.

### Suggested Fix

Check `$_image_cmd` exit code; abort if both `--to` and `--to-image` fail.

---

## Bug #631 — Core: `cluster-upgrade.sh` channel change not error-checked

**Status:** OPEN — code review

- **Status:** OPEN (code review)
- **Severity**: Medium
- **Component**: `scripts/cluster-upgrade.sh` ~lines 281-285
- **Found by**: Code review

### Symptom

If `oc adm upgrade channel` fails (e.g. RBAC or invalid channel), the upgrade proceeds with the wrong channel.

### Root Cause

`oc adm upgrade channel "$_required_channel"` runs without checking exit code; `_channel_changed=1` is set unconditionally.

---

## Bug #632 — Core: `replace-value-conf` updates only first matching file

**Status:** INVALID — intentional behavior — "Step through the files by priority" design

- **Status:** INVALID (intentional behavior — "Step through the files by priority" design)
- **Severity**: ~~Medium~~ N/A
- **Component**: `scripts/include_all.sh` (`replace-value-conf`)
- **Found by**: Code review

### Symptom

When called with multiple `-f` files (e.g. `aba --domain new.example.com` updating both `aba.conf` and `cluster.conf`), only the first file containing the key is updated; later files remain stale.

### Root Cause

The loop returns after the first successful `sed`; later files are never processed.

---

## Bug #633 — Core: `reg-create-imageset-config.sh` no error checks; premature `.created` stamp

**Status:** OPEN — code review

- **Status:** OPEN (code review)
- **Severity**: Medium
- **Component**: `scripts/reg-create-imageset-config.sh` ~lines 76-81
- **Found by**: Code review

### Symptom

If ISC generation fails (broken catalog, missing operator index), the `.created` marker is still written. Subsequent runs skip regeneration, leaving a broken/partial ISC.

### Root Cause

Exit codes from `j2` and `add-operators-to-imageset.sh` are ignored; `touch data/.created` runs before operators are added.

---

## Bug #634 — Core: `create-cluster-conf.sh` ignores `verify-aba-conf` failure

**Status:** OPEN — code review

- **Status:** OPEN (code review)
- **Severity**: Medium
- **Component**: `scripts/create-cluster-conf.sh` ~line 17
- **Found by**: Code review

### Symptom

Invalid `aba.conf` (e.g. `platform=bogus`) doesn't stop cluster.conf creation. The resulting cluster.conf is rendered from bad global config.

### Root Cause

`verify-aba-conf` is called without `|| exit 1`.

---

## Bug #635 — Core: `aba.sh --ntp` accepts arbitrary invalid values

**Status:** FIXED — duplicate of #603; --ntp validates hostname/IP format

- **Status:** OPEN (code review)
- **Severity**: Medium
- **Component**: `scripts/aba.sh` ~lines 676-687
- **Found by**: Code review

### Symptom

`aba --ntp not-a-valid-host` writes garbage to config. Unlike `--dns` (which has IP regex validation), `--ntp` accepts any string.

### Root Cause

No validation on the NTP argument before writing to config.

---

## Bug #636 — Core: `aba.sh --gateway-ip` lacks octet-range validation

**Status:** FIXED — _valid_ipv4() rejects octets > 255 in --gateway-ip

- **Status:** OPEN (code review)
- **Severity**: Medium
- **Component**: `scripts/aba.sh` ~lines 688-699
- **Found by**: Code review

### Symptom

`aba --gateway 999.999.999.999` is accepted and written to config.

### Root Cause

Regex accepts format but doesn't check octets ≤255 (unlike `--api-vip`/`--ingress-vip` which do).

---

## Bug #637 — Core: `cluster-upgrade.sh` uses `grep -P` (GNU Perl regex, not portable)

**Status:** OPEN — code review; works on RHEL 8/9 (supported platforms); only affects exotic environments

- **Status:** OPEN (code review) — works on RHEL 8/9 (supported platforms); only affects exotic environments
- **Severity**: Low (portability concern only — not a bug on supported platforms)
- **Component**: `scripts/cluster-upgrade.sh` ~lines 84-86
- **Found by**: Code review

### Symptom

On hosts without Perl-regex grep (s390x, ppc64le BusyBox environments), `aba upgrade --dry-run` shows empty version list or errors.

### Root Cause

`grep -oP` is GNU-specific and not available on all RHEL variants.

---

## Bug #638 — Core: ADR-007 state restore picks first arbitrary glob match

**Status:** OPEN — code review

- **Status:** OPEN (code review)
- **Severity**: Low
- **Component**: `scripts/aba.sh` ~lines 98-100
- **Found by**: Code review

### Symptom

If two clusters share the same basename (e.g. `sno.lab.local` and `sno.example.com`), deleting the `sno/` directory and running `aba -d sno info` may restore from the wrong backup.

### Root Cause

`for _candidate in "$HOME/.aba/clusters/${_cn}."*` uses first matching glob entry; no domain disambiguation.

---

## Bug #639 — Core: ADR-007 cluster-dir recreation masks `make init` failure

**Status:** OPEN — code review

- **Status:** OPEN (code review)
- **Severity**: Medium
- **Component**: `scripts/aba.sh` ~lines 103-107
- **Found by**: Code review

### Symptom

When recreating a cluster directory from externalized state, a failed `make init` is silenced (`2>/dev/null || true`). User gets confusing errors later.

### Root Cause

`make -s -C "$target_dir" init 2>/dev/null || true` masks the real failure.

---

## Bug #640 — TUI: ISC generation failure reported as success (return 0)

**Status:** OPEN — code review

- **Status:** OPEN (code review)
- **Severity**: Medium
- **Component**: `tui/v2/tui-mirror.sh` ~line 762
- **Found by**: Code review

### Symptom

When ISC generation fails, the error dialog is shown but the function returns 0. Callers treat the action as successful; user may proceed to save/sync/load with missing/stale ISC.

### Root Cause

Error path shows dialog but `return 0` instead of non-zero.

---

## Bug #641 — TUI: DISCO auto-wizard swallows mirror install/load failures

**Status:** OPEN — code review

- **Status:** OPEN (code review)
- **Severity**: Medium
- **Component**: `tui/v2/tui-disco.sh` lines 116-124
- **Found by**: Code review

### Symptom

On a fresh DISCO host, the auto-wizard runs `mirror_install` and `disco_load_images`. If either fails (cancelled, bad archive), DISCO main menu opens with no indication of failure.

### Root Cause

Return codes from `mirror_install` and `disco_load_images` are ignored; `_disco_bundle_wizard_gate` always returns 0.

---

## Bug #642 — TUI: Operator search grep treats `-` prefixed queries as options

**Status:** OPEN — TUI testing on conno — searched for "-e", got "No operators matching '-e' found" instead of matches

- **Status:** VERIFIED (TUI testing on conno — searched for "-e", got "No operators matching '-e' found" instead of matches)
- **Severity**: Medium
- **Component**: `tui/v2/tui-mirror.sh` lines 1161-1165
- **Found by**: Code review

### Symptom

Searching for operators with a query starting with `-` (e.g. `-e`, `--help`) causes grep errors or unexpected behavior.

### Root Cause

`grep -hiF "$query"` without `--` separator before the pattern.

### Suggested Fix

Change to `grep -hiF -- "$query"`.

---

## Bug #643 — TUI: Command injection guard does not block bare `&&`

**Status:** INVALID — false positive — `'&&'` in bash `[[ =~ ]]` matches literal `&&`, quotes are not part of matched text

- **Status:** INVALID (false positive — `'&&'` in bash `[[ =~ ]]` matches literal `&&`, quotes are not part of matched text)
- **Severity**: ~~Medium~~ N/A
- **Component**: `tui/v2/tui-lib.sh` line 604
- **Found by**: Code review

### Symptom

The metacharacter guard regex `[\`\$\;\|\>\<]|'&&'` matches the literal 4-char sequence `'&&'` (with quotes), not a bare ` && ` shell separator.

### Root Cause

Pattern matches `'&&'` (single-quoted literal string) instead of `&&` (bare command separator). A command containing `foo && bar` passes the guard.

### Suggested Fix

Change `'&&'` to `&&` in the regex pattern (or `\&\&`).

---

## Bug #644 — TUI: Cluster wizard allows Next with empty base domain

**Status:** OPEN — TUI on conno: cleared domain in aba.conf, started wizard, "Base domain: (not set; " → pressed Next → proceeded to page 2 without error)

- **Status:** VERIFIED (TUI on conno: cleared domain in aba.conf, started wizard, "Base domain: (not set)" → pressed Next → proceeded to page 2 without error)
- **Severity**: Medium
- **Component**: `tui/v2/tui-cluster.sh` lines 894-895, 942-956
- **Found by**: Code review

### Symptom

In the cluster wizard Basics page, clearing the base domain and pressing Next proceeds without validation. Install may fail or use a fallback domain.

### Root Cause

No required-field check on base domain before page 1 advances.

---

## Bug #645 — TUI: Mid-wizard cluster rename leaves orphan directory

**Status:** OPEN — code review

- **Status:** OPEN (code review)
- **Severity**: Low
- **Component**: `tui/v2/tui-cluster.sh` lines 910-938, 185-212
- **Found by**: Code review

### Symptom

Changing cluster name during the wizard (e.g. `ocp` → `prod`) creates a new `prod/` directory but never removes the old `ocp/` directory and its generated `cluster.conf`.

### Root Cause

Rename only updates in-memory state; old directory is never cleaned up.

---

## Bug #646 — TUI: Operator menu Back bypasses empty-basket warning

**Status:** OPEN — code review

- **Status:** OPEN (code review)
- **Severity**: Low
- **Component**: `tui/v2/tui-mirror.sh` lines 945-966
- **Found by**: Code review

### Symptom

In the Operator selection menu with an empty basket, pressing Done warns "Continue without any operators?" but pressing Back exits silently.

### Root Cause

Empty-basket confirmation only fires on Done (rc=3), not on Back (1|255).

---

## Bug #647 — TUI: "mirror installed" status shown for registered (external) mirrors

**Status:** OPEN — TUI on conno shows "Status: mirror installed" for a registered Quay mirror

- **Status:** VERIFIED (TUI on conno shows "Status: mirror installed" for a registered Quay mirror)
- **Severity**: Low (misleading UX label)
- **Component**: `tui/v2/tui-lib.sh` line 772 (`mirror_state_label()`)
- **Found by**: TUI testing + code review

### Symptom

After registering an existing external Quay registry with `aba -d mirror register`, the TUI main menu shows "Status: mirror installed" (yellow). This is confusing because the mirror was NOT installed by ABA — it was registered (connected to).

### Root Cause

`mirror_state_label()` only has three states: "no mirror", "mirror installed", "mirror ready". It uses the `.available` marker file which exists for both installed AND registered mirrors. There's no differentiation based on `reg_vendor=existing` in `state.sh`.

### Suggested Fix

Check `regcreds/state.sh` for `reg_vendor=existing` and show "mirror registered" or "mirror connected" instead of "mirror installed". Also, the Day-2 "Uninstall Mirror" action (tui-cluster.sh line 1975) should detect registered mirrors and run `unregister` instead of `uninstall`, or show a different label.

---

## Bug #648 — TUI: "Uninstall Mirror" fails for registered mirrors

**Status:** OPEN — CLI on conno tmux — `aba -d mirror uninstall` shows "externally-managed registry" error

- **Status:** VERIFIED (CLI on conno tmux — `aba -d mirror uninstall` shows "externally-managed registry" error)
- **Severity**: Medium (TUI action fails with error instead of offering correct action)
- **Component**: `tui/v2/tui-cluster.sh` line 1975
- **Found by**: Code review

### Symptom

In the Day-2/Advanced menu, pressing "U" (Uninstall Mirror) on a registered (not installed) mirror fails with: "This is an externally-managed registry (registered, not installed by ABA). Use 'aba -d ... unregister' to remove the local credentials."

### Root Cause

The TUI always runs `aba --dir mirror uninstall` without checking if the mirror is registered (vendor=existing). The core script correctly refuses to uninstall a registered mirror, but the TUI doesn't handle this case gracefully.

### Suggested Fix

Before running uninstall, check `reg_vendor` from `state.sh`. If `existing`, run `aba --dir mirror unregister` instead (or show a different dialog explaining this is an external registry).

---

## Bug #649 — Core: `reg_vendor` missing from `_state_override_mirror` immutable list

**Status:** OPEN — TUI on conno shows "Registry Type: Docker" in Settings for a registered Quay mirror; `resolved_reg_vendor(; ` returns "docker" instead of "existing")

- **Status:** VERIFIED (TUI on conno shows "Registry Type: Docker" in Settings for a registered Quay mirror; `resolved_reg_vendor()` returns "docker" instead of "existing")
- **Severity**: Low (functional impact mitigated by direct state.sh checks in uninstall scripts, but causes confusing TUI display)
- **Component**: `scripts/include_all.sh` line 931 (`_state_override_mirror`)
- **Found by**: Testing registered mirror workflow on conno

### Symptom

After registering an external Quay registry with `aba -d mirror register`, `normalize-mirror-conf` still returns `reg_vendor=docker` (from mirror.conf) instead of `reg_vendor=existing` (from state.sh). This causes:
- `resolved_reg_vendor()` to return "docker" instead of "existing"
- TUI displaying wrong mirror type in settings
- Potential confusion for scripts that check vendor type

### Root Cause

`_state_override_mirror()` (line 931) has:
```
local _immutable="reg_host reg_port reg_root reg_user reg_pw"
```
`reg_vendor` is NOT in this list. After `register`, state.sh correctly stores `reg_vendor=existing`, but normalize-mirror-conf doesn't override the stale `mirror.conf` value.

### Mitigation

The `reg-uninstall.sh` script directly sources `state.sh` and checks `reg_vendor=existing` independently (line 23), so uninstall is safely blocked. But other paths may be confused.

### Suggested Fix

Add `reg_vendor` to the `_immutable` list in `_state_override_mirror`:
```bash
local _immutable="reg_host reg_port reg_root reg_user reg_pw reg_vendor"
```

---

## Bug #650 — TUI: Platform toggle in cluster wizard writes to aba.conf immediately (before wizard completes)

**Status:** OPEN — tested on conno tmux: toggled vmw→kvm, pressed Back to cancel, aba.conf still shows kvm

- **Status:** VERIFIED (tested on conno tmux: toggled vmw→kvm, pressed Back to cancel, aba.conf still shows kvm)
- **Severity**: Medium (persistent config change from a cancelled wizard)
- **Component**: `tui/v2/tui-cluster.sh` line 990
- **Found by**: Code review + TUI testing

### Symptom

In the cluster wizard (page 1 "Cluster – Basics"), toggling the Platform field (P) immediately writes the new platform value to `aba.conf` via `replace-value-conf`. If the user then presses "Back" to cancel the wizard, the platform change persists in `aba.conf`. The user never intended to permanently change the platform — they were just exploring options.

### Root Cause

Line 990 in `tui-cluster.sh`:
```bash
replace-value-conf -q -n platform -v "$cl_platform" -f "$ABA_ROOT/aba.conf"
```
This executes on every toggle, not when the wizard completes. Other wizard fields (cluster name, domain, type) are held in local variables and only written at the end.

### Suggested Fix

Remove the immediate `replace-value-conf` call from the platform toggle case. Instead, save the platform choice to `aba.conf` only when the wizard completes (same pattern as other fields). This would require collecting all wizard changes and writing them at commit time.

---

## Bug #651 — Core: `--ntp` flag accepts arbitrary values without validation

**Status:** FIXED — duplicate of #603; --ntp validates hostname/IP format

- **Status:** VERIFIED (CLI on conno: `aba cluster --name test --ntp "not-a-host!!!!"` — accepted without error)
- **Severity**: Low (misconfiguration caught later at cluster install time, not at input time)
- **Component**: `scripts/aba.sh` lines 676-687
- **Found by**: Code review + CLI testing

### Symptom

The `--ntp` CLI flag accepts any arbitrary string including invalid hostnames, special characters, and garbage input. Unlike `--dns` and `--gateway-ip` which have regex validation, `--ntp` has no validation at all.

### Root Cause

The `--ntp` handling in `aba.sh` (lines 676-687) splits on commas and assigns directly without checking each value is a valid hostname or IP. The `--dns` flag has `^([0-9]{1,3}\.){3}[0-9]{1,3}$` validation but `--ntp` has none.

### Suggested Fix

Add hostname/IP validation regex similar to `--dns` validation, but also accept valid hostnames (since NTP can use pool hostnames like `pool.ntp.org`).

---

## Bug #652 — Core: `--gateway-ip` and `--starting-ip` regex allows invalid octets > 255

**Status:** FIXED — _valid_ipv4() helper validates all IP-accepting CLI flags

- **Status:** VERIFIED (CLI on conno: `aba cluster --name test --gateway-ip 999.999.999.999` — accepted without error)
- **Severity**: Low (caught by later validation, but confusing at input time)
- **Component**: `scripts/aba.sh` lines 688-695 (gateway), 871-878 (starting-ip)
- **Found by**: Code review + CLI testing

### Symptom

The IP address validation regex `^([0-9]{1,3}\.){3}[0-9]{1,3}$` used for both `--gateway-ip` and `--starting-ip` accepts octets larger than 255 (e.g. `999.999.999.999`). Valid IPs must have octets 0-255.

### Root Cause

The regex only checks "1-3 digits per octet" but doesn't verify the numeric value is ≤ 255.

### Suggested Fix

Use a function to validate each octet: split on `.`, check each part is numeric and ≤ 255. Or use a more specific regex pattern.

---

## Bug #653 — Core: `--data-disk-gb` with no argument aborts instead of clearing value

**Status:** OPEN — CLI on conno: `aba cluster --name testdisk --data-disk-gb` → "Error: argument invalid [] after option --data-disk-gb"

- **Status:** VERIFIED (CLI on conno: `aba cluster --name testdisk --data-disk-gb` → "Error: argument invalid [] after option --data-disk-gb")
- **Severity**: Low (help says `[<size>]` implying optional, but code requires a numeric argument)
- **Component**: `scripts/aba.sh` lines 880-886
- **Found by**: Code review + CLI testing

### Symptom

Running `aba cluster --name test --data-disk-gb` (with no value, intending to clear the data disk setting) gives:
```
[ABA] Error: argument invalid [] after option --data-disk-gb
```

The help text says `--data-disk-gb [<size>]` where `[<size>]` implies the argument is optional ("or empty for none").

### Root Cause

The `--data-disk-gb` handler does not follow the same optional-argument pattern as `--vlan`:
```bash
# --vlan (correct optional handling):
if [[ -n $2 && $2 != -* ]]; then
    vlan_val=$2; shift
fi
_set_cluster_conf vlan "$vlan_val" "$_flag"
shift

# --data-disk-gb (always requires value):
if echo "$2" | grep -q -E '^[0-9]+$'; then
    _set_cluster_conf data_disk "$2" "$1"
else
    aba_abort "argument invalid [$2] after option $1"
fi
shift 2
```

### Suggested Fix

Use the same pattern as `--vlan`: check if `$2` exists and doesn't start with `-`; if missing, set `data_disk=""` (clear). This makes `aba cluster --data-disk-gb` equivalent to "remove data disk".

---

## Bug #654: TUI "Install locally" fails due to env var inheritance of reg_ssh_key

**Status:** OPEN — reproduced on conno via TUI + direct CLI testing

- **Status:** VERIFIED (reproduced on conno via TUI + direct CLI testing)
- **Severity**: Medium (local mirror install via TUI always fails if mirror was previously configured for remote)
- **Component**: `tui/v2/tui-mirror.sh` lines 28-346, `scripts/reg-install.sh` line 32
- **Found by**: TUI testing + code tracing

### Symptom

When using the TUI to install a mirror locally (Menu → M → "Install locally"), the install fails with:
```
[ABA] Registry configured for *remote* install (reg_ssh_key is defined in mirror.conf).
[ABA] Error: But conno.example.com reaches this localhost instead!
```

This happens even though the TUI correctly comments out `reg_ssh_key` in `mirror.conf` before running the install.

### Root Cause

Environment variable inheritance from the TUI process to the child `aba` process:

1. `_mirror_config_menu_loop` sources `normalize-mirror-conf` at line 42, which exports `reg_ssh_key=~/.ssh/id_rsa` into the TUI's environment
2. At lines 336-337, the TUI correctly comments out `reg_ssh_key` in mirror.conf via `replace-value-conf -q -n reg_ssh_key -v ""`
3. At line 338, `confirm_and_execute "aba --dir mirror install"` runs the command via `bash -c "$tui_cmd"` (tui-lib.sh line 628)
4. The child `bash -c` process inherits `reg_ssh_key` from the TUI's environment
5. When `reg-install.sh` does `source <(normalize-mirror-conf)`, the file doesn't output `reg_ssh_key` (commented), but the inherited env var persists
6. `reg-install.sh` line 32 checks `if [ "$reg_ssh_key" ]` — TRUE (from inherited env), triggers remote install path

### Proof

```bash
# With env var set (simulates TUI inheritance):
export reg_ssh_key=~/.ssh/id_rsa; aba -d mirror install --yes 2>&1 | head -5
# → "[ABA] Registry configured for *remote* install (reg_ssh_key is defined in mirror.conf)."

# Without env var (clean shell):
unset reg_ssh_key; aba -d mirror install --yes 2>&1 | head -5
# → "[ABA] Install Docker registry on localhost (conno)..."
```

### Suggested Fix

Two options (both should ideally be applied):

1. **TUI fix** (tui-mirror.sh, after line 337): Add `unset reg_ssh_key reg_ssh_user` to clear inherited env vars:
```bash
elif [[ "$_variant" == "local" ]]; then
    tui_log "Saving mirror config: host=$m_host port=$m_port vendor=$m_vendor"
    replace-value-conf -q -n reg_ssh_user -v "" -f "$mcf"
    replace-value-conf -q -n reg_ssh_key -v "" -f "$mcf"
    unset reg_ssh_key reg_ssh_user  # Prevent env inheritance to child aba process
    confirm_and_execute "aba --dir mirror install" "Install Local Mirror" _invalidate_mirror_cache
```

2. **Core fix** (reg-install.sh, after line 12): Re-read the file authoritatively and unset vars not in output:
```bash
source <(normalize-mirror-conf)
# If reg_ssh_key is commented in file, clear any inherited env value
grep -q "^reg_ssh_key=" mirror.conf 2>/dev/null || unset reg_ssh_key
```

---

## Bug #655: `make-bundle.sh` typo "Deleteing" in user-visible warning

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — typo in user-visible message)
- **Component**: `scripts/make-bundle.sh` line 129
- **Found by**: Code review

### Symptom

When running `aba bundle --force`, the warning message displays "Deleteing" instead of "Deleting":
```
[ABA] Deleteing all files under aba/mirror/data! (--force set)
```

### Root Cause

Simple typo at line 129:
```bash
aba_warning "Deleteing all files under aba/mirror/data! (--force set)" >&2
```

### Suggested Fix

Change "Deleteing" to "Deleting".

---

## Bug #656: `make-bundle.sh` bundle output message missing `[ABA]` prefix

**Status:** OPEN — code review — confirmed by FIXME comment in source

- **Status:** VERIFIED (code review — confirmed by FIXME comment in source)
- **Severity**: Low (cosmetic — inconsistent output formatting)
- **Component**: `scripts/make-bundle.sh` lines 119-120
- **Found by**: Code review

### Symptom

The bundle output file path message is printed without the standard `[ABA]` prefix:
```
Bundle output file = /tmp/ocp-bundle-4.20.20.tar
```

All other ABA messages use the `[ABA]` prefix for consistency.

### Root Cause

Line 119-120:
```bash
# FIXME MNIssing [ABA]
echo "Bundle output file = $bundle_dest_file" >&2
```

The developer left a FIXME comment acknowledging the issue but never fixed it.

### Suggested Fix

Replace `echo` with `aba_info`:
```bash
aba_info "Bundle output file = $bundle_dest_file" >&2
```

---

## Bug #657: TUI Day-2 menu missing "Rescue" option

**Status:** OPEN — code review — `aba rescue` exists as CLI but not in TUI Day-2 menu

- **Status:** VERIFIED (code review — `aba rescue` exists as CLI but not in TUI Day-2 menu)
- **Severity**: Medium (feature gap — users must use CLI for cluster rescue)
- **Component**: `tui/v2/tui-cluster.sh` lines 2036-2110 (`cluster_day2_menu`)
- **Found by**: Code review + cross-referencing with `aba.sh` command list

### Symptom

The TUI Day-2 / Cluster Management menu lists:
- Configure OperatorHub, NTP, OSUS
- Cluster status, SSH
- Upgrade, Shutdown, Startup
- Clean, Delete

But there is NO "Rescue" option, even though `aba rescue` exists as a full CLI command (scripts/cluster-rescue.sh). Users who need to recover a shut-down cluster with lost kubeconfig must exit the TUI and use the CLI.

### Root Cause

`cluster_day2_menu()` in `tui-cluster.sh` never added a "Rescue" menu item. The `rescue` target is listed in `aba.sh` line 1045 and dispatches to `scripts/cluster-rescue.sh`, but the TUI never integrated it.

### Suggested Fix

Add a Rescue option to the Day-2 menu under the "Lifecycle" section:
```bash
"" "──── Lifecycle ────────────────────"
"U" "Upgrade cluster (beta)"
"G" "Graceful cluster shutdown"
"T" "Graceful cluster startup"
"E" "Rescue cluster (uncordon + approve CSRs)"
```

And add the handler:
```bash
E) _day2_rescue ;;
```

With a `_day2_rescue` function similar to `_day2_shutdown`.

---

## Bug #658: `cluster-rescue.sh` uses spaces instead of tabs for indentation

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (coding style violation — spaces on lines 23-26, tabs everywhere else)
- **Component**: `scripts/cluster-rescue.sh` lines 23-26
- **Found by**: Code review

### Symptom

Lines 23-26 use 8 spaces for indentation instead of tabs, violating the project's "tabs for indentation" rule:
```bash
        ssh -F ~/.aba/ssh.conf -i $ssh_key_file core@$ip mkdir -p scripts
        scp -F ~/.aba/ssh.conf -i $ssh_key_file scripts/include_all.sh core@$ip:scripts
        scp -F ~/.aba/ssh.conf -i $ssh_key_file $0 core@$ip:
        ssh -F ~/.aba/ssh.conf -i $ssh_key_file core@$ip -- sudo bash $(basename $0) --exec
```

All other lines in the file use tabs.

### Root Cause

Likely a copy-paste from a different source with spaces.

### Suggested Fix

Replace the 8 spaces with a single tab on lines 23-26.

---

## Bug #659: `verify-config.sh` line 73 — typo "endpoiont" AND wrong label "Ingress" (should be "API")

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — typo + misleading label in error message)
- **Component**: `scripts/verify-config.sh` line 73
- **Found by**: Code review

### Symptom

When `api_vip` is missing and DNS resolution fails, the error message is:
```
Ingress endpoiont: api_vip must be defined for this cluster configuration!
```

Two problems:
1. "endpoiont" is a typo — should be "endpoint"
2. "Ingress" is wrong — this is the API VIP validation block, not the ingress block

### Root Cause

Line 73:
```bash
aba_abort "Ingress endpoiont: api_vip must be defined for this cluster configuration!"
```

Compare with line 60 (correct):
```bash
aba_info "API endpoint: api_vip=$api_vip is defined"
```

### Suggested Fix

Change to:
```bash
aba_abort "API endpoint: api_vip must be defined for this cluster configuration!"
```

---

## Bug #660: `verify-config.sh` line 79 — typo "endpoiont"

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — typo in info message)
- **Component**: `scripts/verify-config.sh` line 79
- **Found by**: Code review

### Symptom

Info message displays:
```
Ingress endpoiont: ingress_vip=10.0.1.100 is defined
```

### Root Cause

Line 79:
```bash
aba_info "Ingress endpoiont: ingress_vip=$ingress_vip is defined"
```

### Suggested Fix

Change to:
```bash
aba_info "Ingress endpoint: ingress_vip=$ingress_vip is defined"
```

---

## Bug #661: `tui-disco.sh` inconsistent indentation throughout

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (coding style — violates "tabs for indentation" rule)
- **Component**: `tui/v2/tui-disco.sh` multiple locations
- **Found by**: Code review

### Symptom

Mixed indentation levels within functions:
- Lines 195-199 (menu `items+=()`) use 2 tabs while lines 188-194 use 3 tabs
- Lines 272-278 (Install case) use 1 tab while adjacent case items use 3 tabs
- Line 241 (`;;`) uses 4 tabs while parent case items use 2-3 tabs

### Root Cause

Likely copy-paste from different contexts or iterative editing without normalizing indentation.

### Suggested Fix

Normalize all indentation in `disco_main()` to use consistent tab depth matching the enclosing block structure.

---

## Bug #662: `abatui2.sh` CONNO menu — inconsistent indentation in case statement

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (coding style)
- **Component**: `tui/v2/abatui2.sh` lines 648-700+
- **Found by**: Code review

### Symptom

The CONNO menu case statement mixes 1-tab, 2-tab, and 3-tab indentation for different menu items:
- `$TUI2_CONNO_TAG_INSTALL_MIRROR` at 2 tabs
- `$TUI2_CONNO_TAG_PREP_UPGRADE` at 1 tab
- `$TUI2_CONNO_TAG_SYNC` at 1 tab then 3 tabs for nested code

### Root Cause

Iterative editing without normalizing indentation across menu case items.

### Suggested Fix

Normalize all case items in the CONNO menu to consistent 2-tab indentation.

---

## Bug #663: `tui-cluster.sh` `tui_advanced_menu()` — inconsistent indentation

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (coding style)
- **Component**: `tui/v2/tui-cluster.sh` lines 1844-2030
- **Found by**: Code review

### Symptom

The `tui_advanced_menu()` function has mixed indentation:
- Lines 1878-1882 (Danger Zone items) use 1 tab inside a 2-tab block
- Lines 1920-1930 ("W"/"R" cases) use 2 tabs while lines 1931-1966 ("P" case) use 3 tabs
- Lines 2004-2027 ("Z" case) use 4 tabs in places

### Root Cause

Same pattern — iterative editing without normalizing.

### Suggested Fix

Normalize indentation within `tui_advanced_menu()`.

---

## Bug #664: `cluster-startup.sh` uses file existence instead of `platform` variable

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Medium (violates architecture rule — file presence must not infer settings)
- **Component**: `scripts/cluster-startup.sh` line 36
- **Found by**: Code review

### Symptom

The script uses `[ ! -s vmware.conf ] && [ ! -s kvm.conf ]` to determine if the platform is bare-metal. This violates the project rule: "File presence (e.g. vmware.conf existing) must NEVER be used to infer settings — only the config variable (e.g. platform=vmw in aba.conf) is authoritative."

### Root Cause

Line 36:
```bash
if [ ! -s vmware.conf ] && [ ! -s kvm.conf ]; then
```

This checks for the ABSENCE of vmware.conf and kvm.conf to infer bare-metal mode, instead of reading the `platform` variable from `aba.conf`.

### Suggested Fix

Source `normalize-aba-conf` and use the `platform` variable:
```bash
source <(normalize-aba-conf)
if [ "$platform" = "bm" ] || [ -z "$platform" ]; then
```

---

## Bug #665: `cluster-graceful-shutdown.sh` uses file existence instead of `platform` variable

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Medium (same violation as Bug #664)
- **Component**: `scripts/cluster-graceful-shutdown.sh` line 280
- **Found by**: Code review

### Symptom

Uses `[ -s vmware.conf ] || [ -s kvm.conf ]` to decide whether to wait for power-off instead of using the `platform` variable from `aba.conf`.

### Root Cause

Line 280:
```bash
if [ "$wait" ] && { [ -s vmware.conf ] || [ -s kvm.conf ]; }; then
```

### Suggested Fix

Use `platform` from `aba.conf`:
```bash
source <(normalize-aba-conf)
if [ "$wait" ] && { [ "$platform" = "vmw" ] || [ "$platform" = "kvm" ]; }; then
```


---

## Bug #666: `tui-direct.sh` `version)` case block has inconsistent indentation

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (style)
- **Component**: `tui/v2/tui-direct.sh` lines 125-148
- **Found by**: Code review

### Symptom

In the `direct_wizard()` function, the `version)` case arm is indented one extra tab level compared to the other case arms (`pull_secret)`, `channel)`, `platform)`, `operators)`) which are all at one tab from the `case` keyword.

### Root Cause

Lines 125-148: `version)` is at two tabs while all other arms are at one tab. The content inside the `next)` subcase also has varying indentation levels (e.g., `step="platform"` at L143 is at five tabs).

### Suggested Fix

Align `version)` to the same indentation level as the other case arms (one tab from `case`), and normalize the inner indentation.

---

## Bug #667: `reg-save.sh` dead code — `r=1` variable set but never used

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (dead code)
- **Component**: `scripts/reg-save.sh` line 17
- **Found by**: Code review

### Symptom

The variable `r` is assigned `r=1` on the retry argument parsing line but is never referenced anywhere else in the script.

### Root Cause

Line 17:
```bash
[ "$1" ] && [ $1 -gt 0 ] && r=1 && try_tot=`expr $1 + 1` && aba_info "Attempting..."
```

Compare with `reg-sync.sh` line 16 which does the same without `r=1`:
```bash
[ "$1" ] && [ $1 -gt 0 ] && try_tot=`expr $1 + 1` && aba_info "Attempting..."
```

The `r=1` is likely a leftover from earlier code.

### Suggested Fix

Remove `r=1 &&` from the line.

---

## Bug #668: `reg-load.sh` uses raw `echo "[ABA]..."` instead of `aba_info`

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (inconsistency)
- **Component**: `scripts/reg-load.sh` line 30
- **Found by**: Code review

### Symptom

`reg-load.sh` prints its retry message with raw `echo "[ABA] ..."` while `reg-save.sh` and `reg-sync.sh` use `aba_info` for the same message. This means the message prints even when `INFO_ABA` is disabled (e.g., when `--quiet` is passed).

### Root Cause

Line 30:
```bash
echo "[ABA] Attempting $try_tot times to load the images into the registry."
```

Should be:
```bash
aba_info "Attempting $try_tot times to load the images into the registry."
```

### Suggested Fix

Replace `echo "[ABA] ..."` with `aba_info "..."`.

---

## Bug #669: `reg-verify.sh` uses deprecated `-o` operator in test

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (deprecated syntax)
- **Component**: `scripts/reg-verify.sh` line 20
- **Found by**: Code review

### Symptom

Uses the deprecated `-o` (OR) operator inside `[ ]` which is flagged by ShellCheck (SC2166) and can produce unexpected results with certain variable values.

### Root Cause

Line 20:
```bash
if [ ! "$reg_host" -o ! "$reg_port" ]; then
```

### Suggested Fix

```bash
if [ ! "$reg_host" ] || [ ! "$reg_port" ]; then
```

---

## Bug #670: `reg-verify.sh` unquoted variable in `echo` command

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (style, minor functional risk)
- **Component**: `scripts/reg-verify.sh` line 52
- **Found by**: Code review

### Symptom

Unquoted `$mirrors` in `echo $mirrors | tr '\n' ' '` causes word splitting and glob expansion. If a mirror hostname contains whitespace or glob chars (unlikely but possible), the output would be mangled.

### Root Cause

Line 52:
```bash
"Value in pull-secret-mirror.json: $(echo $mirrors | tr '\n' ' ')" \
```

### Suggested Fix

```bash
"Value in pull-secret-mirror.json: $(echo "$mirrors" | tr '\n' ' ')" \
```


---

## Bug #671: `create-agent-config.sh` uses `((current_ip++))` — violates coding standard

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (latent — `current_ip` is always a large number for IP addresses, but violates project rule)
- **Component**: `scripts/create-agent-config.sh` line 74
- **Found by**: Code review

### Symptom

The `((current_ip++))` arithmetic violates the project coding standard: "NEVER use `(( var++ ))` — when `var` is 0, `(( 0 ))` returns exit code 1, which crashes under `set -e` or an ERR trap."

While `current_ip` is always a large numeric IP value (never 0), this still violates the coding convention and sets a bad precedent.

### Root Cause

Line 74:
```bash
    ((current_ip++))
```

### Suggested Fix

```bash
    current_ip=$(( current_ip + 1 ))
```

---

## Bug #672: `create-agent-config.sh` trailing whitespace on empty line

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (style violation)
- **Component**: `scripts/create-agent-config.sh` line 8
- **Found by**: Code review

### Symptom

Line 8 contains a single space character instead of being truly empty. Violates the project rule: "Empty lines must have NO characters (no trailing whitespace)."

### Suggested Fix

Remove the trailing space on line 8.

---

## Bug #673: `reg-create-imageset-config.sh` uses deprecated `-o` operator

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (deprecated syntax)
- **Component**: `scripts/reg-create-imageset-config.sh` line 53
- **Found by**: Code review

### Symptom

Uses deprecated `-o` (OR) operator inside `[ ]`.

### Root Cause

Line 53:
```bash
[ ! "$ocp_channel" -o ! "$ocp_version" ] && aba_abort "..."
```

### Suggested Fix

```bash
{ [ ! "$ocp_channel" ] || [ ! "$ocp_version" ]; } && aba_abort "..."
```

---

## Bug #674: `create-install-config.sh` multiple deprecated `-a`/`-o` operators

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (deprecated syntax, recurring pattern)
- **Component**: `scripts/create-install-config.sh` lines 57, 76, 96, 230, 235
- **Found by**: Code review

### Symptom

Five instances of deprecated `-a` (AND) and `-o` (OR) operators inside `[ ]` test:

- L57: `[ "$platform" = "vmw" -o "$platform" = "kvm" ]`
- L76: `[ "$platform" = "bm" -a $hostPrefix -eq 23 ]` (also unquoted `$hostPrefix`)
- L96: `[ "$http_proxy" -o "$https_proxy" ]`
- L230: `[ "$additional_trust_bundle" -a "$pull_secret" ]`
- L235: `[ "$additional_trust_bundle" -a "$image_content_sources" ]`

### Suggested Fix

Replace with `&&` / `||` between separate test commands, e.g.:
```bash
[ "$platform" = "vmw" ] || [ "$platform" = "kvm" ]
[ "$platform" = "bm" ] && [ "$hostPrefix" -eq 23 ]
```


---

## Docbug #675: README Command Reference — broken markdown table cell for `aba cluster`

**Status:** OPEN — visual inspection

- **Status:** VERIFIED (visual inspection)
- **Severity**: Medium (renders incorrectly for users)
- **Component**: `README.md` line 1293
- **Found by**: Documentation review

### Symptom

The Cluster Commands table entry for `aba cluster` is broken because the `|` character inside `<sno|compact|standard>` is interpreted as a markdown table cell delimiter:

```
| `aba cluster --name --type <sno | compact                                                       |
```

The rendered output shows a garbled row with "compact" in the Description column.

### Suggested Fix

Escape the pipe characters inside the command cell:

```markdown
| `aba cluster --name <n> --type <sno\|compact\|standard>` | Create cluster directory and configuration |
```

---

## Docbug #676: README — missing commands in Command Reference table

**Status:** OPEN — documentation review

- **Status:** VERIFIED (documentation review)
- **Severity**: Low (user convenience)
- **Component**: `README.md` lines 1269-1350 (Command Reference)
- **Found by**: Documentation review

### Symptom

Several commands mentioned elsewhere in the README are NOT listed in the Command Reference tables:

1. `aba version` — mentioned at L265 ("Check your installed version: `aba version`") but not in the Command Reference
2. `aba -d mirror imagesetconf` — mentioned at L527 (Light Bundles manual steps) but not in Mirror Registry Commands
3. `aba -d mirror clean` — mentioned in FAQ L1773 but not in Mirror Registry Commands

### Suggested Fix

Add entries to the appropriate Command Reference tables:

| `aba version` | Show installed ABA version |
| `aba -d mirror imagesetconf` | Generate/regenerate ImageSetConfiguration |
| `aba -d mirror clean` | Remove oc-mirror working state (preserves saved images and config) |

---

## Docbug #677: README — "Using an Existing Registry" section is too brief

**Status:** OPEN — documentation review

- **Status:** VERIFIED (documentation review)
- **Severity**: Medium (users need more guidance)
- **Component**: `README.md` lines 1123-1141
- **Found by**: Documentation review

### Symptom

The "Using an Existing Registry" section only shows two example commands and a few one-liners. It does not explain:

1. **Pull secret format requirements**: The JSON file must have `{"auths":{"host:port":{"auth":"base64-encoded-user:password"}}}` structure. The `auth` field must be base64-encoded `user:password`.
2. **Host/port matching**: The `--reg-host` and `--reg-port` values must match the key in the pull secret's `auths` object. If they don't match, `aba verify` will warn about a mismatch.
3. **CA certificate**: Must be the root CA that signed the registry's TLS certificate (not an intermediate cert).
4. **`reg_path` support**: Registries using a subpath (e.g. `registry.example.com:8443/myrepo`) are supported via `reg_path` in `mirror.conf`, but this is not mentioned in the register section.
5. **`skipTLS` option**: Not mentioned — useful for registries with self-signed certs that can't be properly validated.
6. **How to create a pull secret**: Only briefly mentioned via `aba -d mirror password`, but this command requires an already-registered mirror. No instructions for creating a pull secret from scratch for an existing registry.
7. **Verification steps**: Beyond `aba -d mirror verify`, no guidance on what to check if verification fails.

### Suggested Fix

Expand the section with a "Requirements" subsection and troubleshooting notes.

---

## Docbug #678: README — duplicate perma-link comment

**Status:** OPEN — documentation review

- **Status:** VERIFIED (documentation review)
- **Severity**: Low (cosmetic)
- **Component**: `README.md` lines 402-403
- **Found by**: Documentation review

### Root Cause

```html
<!-- perma-link: bundle README_FIRST.md -->
<!-- perma-link: bundle README_FIRST.md -->
```

Two identical perma-link comments appear consecutively. Only one is needed.


---

## Bug #679: `day2.sh` uses deprecated `-a` operator

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (deprecated syntax)
- **Component**: `scripts/day2.sh` line 93
- **Found by**: Code review

### Symptom

Uses deprecated `-a` (AND) operator inside `[ ]` test.

### Root Cause

Line 93:
```bash
if [ -s "$regcreds_dir/rootCA.pem" -a ! "$cm_existing" ]; then
```

### Suggested Fix

```bash
if [ -s "$regcreds_dir/rootCA.pem" ] && [ ! "$cm_existing" ]; then
```

---

## Bug #680: `day2.sh` unnecessary `$(echo ...)` for string assignment

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (style)
- **Component**: `scripts/day2.sh` line 224
- **Found by**: Code review

### Symptom

Uses `$(echo mirror/data/working-dir)` to assign a simple string literal, creating a needless subshell.

### Root Cause

Line 224:
```bash
latest_working_dir=$(echo mirror/data/working-dir)
```

### Suggested Fix

```bash
latest_working_dir="mirror/data/working-dir"
```

---

## Bug #681: `day2.sh` uses `echo_red` instead of `aba_warning`

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (inconsistency)
- **Component**: `scripts/day2.sh` line 264
- **Found by**: Code review

### Symptom

Uses the raw `echo_red` function for an error message while the rest of the script uses `aba_warning` / `aba_info` / `aba_abort` consistently. The `echo_red` function bypasses ABA's logging infrastructure.

### Root Cause

Line 264:
```bash
echo_red "Error: CatalogSource file does not exist: [$f]" >&2
```

Also at line 283:
```bash
echo_red "Error: Cannot parse CatalogSource name: [$f]" >&2
```

### Suggested Fix

Use `aba_warning` or `aba_abort` instead:
```bash
aba_warning "CatalogSource file does not exist: [$f]"
```

---

## Bug #682: `day2.sh` indentation uses spaces instead of tabs

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (style violation)
- **Component**: `scripts/day2.sh` lines 277-280
- **Found by**: Code review

### Symptom

The `case` pattern matching inside the CatalogSource name normalization block appears to use spaces (or mixed tabs/spaces) for indentation, violating the project coding standard ("Use TABS for indentation, never spaces").

### Root Cause

Lines 277-280 — indentation does not follow the tab convention used by the rest of the file.


---

## Bug #683: Systemic: all `process_args $*` calls use unquoted `$*`

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Medium (latent — arguments with spaces would be mishandled)
- **Component**: 9 scripts across `scripts/`
- **Found by**: Code review

### Symptom

Every call to `process_args` uses unquoted `$*`, which causes word splitting on arguments containing spaces. While ABA arguments typically don't contain spaces, this violates shell best practices and could cause subtle bugs with paths or values containing spaces (e.g., `--name "my cluster"`).

### Affected Files

```
scripts/create-cluster-conf.sh:107
scripts/setup-cluster.sh:15
scripts/setup-mirror.sh:13
scripts/vmw-start.sh:9
scripts/vmw-stop.sh:9
scripts/vmw-refresh.sh:9
scripts/kvm-stop.sh:9
scripts/kvm-start.sh:9
scripts/kvm-refresh.sh:8
```

### Root Cause

All use: `. <(process_args $*)`

### Suggested Fix

Use: `. <(process_args "$@")`

Note: `process_args` itself may need to handle `"$@"` properly — verify the function signature accepts variable arguments.


---

## Bug #684: `include_all.sh` color echo functions use spaces instead of tabs

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — violates coding standard)
- **Component**: `scripts/include_all.sh` lines 50-131
- **Found by**: Code review

### Symptom

The `_color_echo()`, `_print_colored()`, and `color_demo()` functions all use 4-space indentation instead of tabs. The rest of `include_all.sh` uses tabs consistently.

### Root Cause

These functions were likely added or refactored with an editor configured for spaces. Lines 50-131 use 4-space indentation throughout.

### Suggested Fix

Convert all spaces to tabs in lines 50-131.


---

## Bug #685: `include_all.sh` `aba_debug()` uses spaces instead of tabs

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — violates coding standard)
- **Component**: `scripts/include_all.sh` lines 164-197
- **Found by**: Code review

### Symptom

The `aba_debug()` function uses 4-space indentation instead of tabs.

### Root Cause

Same as Bug #684 — editor was likely set to spaces when this function was written.


---

## Bug #686: `include_all.sh` mixed spaces/tabs in `aba_abort()` and `aba_warning()`

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — violates coding standard)
- **Component**: `scripts/include_all.sh` lines 217, 226
- **Found by**: Code review

### Symptom

- `aba_abort()` line 217: `exit 1` indented with 8 spaces instead of a tab.
- `aba_warning()` line 226: `local prefix="Warning"` indented with 8 spaces instead of a tab, while subsequent lines in the same function use tabs.

### Root Cause

Copy-paste or editor inconsistency. Mixing spaces and tabs within the same function.


---

## Bug #687: `include_all.sh` deprecated `-a` operator in `verify-aba-conf()` and `verify-cluster-conf()`

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (deprecated POSIX syntax, but functional)
- **Component**: `scripts/include_all.sh` lines 540, 1000
- **Found by**: Code review

### Symptom

Uses deprecated `-a` operator inside `[ ]` test commands:

```
L540:  [ -f aba.conf -a ! -s aba.conf ]
L1000: [ -f cluster.conf -a ! -s cluster.conf ]
```

### Suggested Fix

Replace with `&&`:
```bash
[ -f aba.conf ] && [ ! -s aba.conf ]
[ -f cluster.conf ] && [ ! -s cluster.conf ]
```


---

## Bug #688: `include_all.sh` deprecated `-o` operator in `confirm()` and `edit_file()`

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (deprecated POSIX syntax, but functional)
- **Component**: `scripts/include_all.sh` lines 1239-1240, 1252
- **Found by**: Code review

### Symptom

Uses deprecated `-o` operator inside `[ ]` test commands:

```
L1239: [ "$def_response" == "y" ] && [ "$yn" == "y" -o "$yn" == "Y" ]
L1240: [ "$def_response" == "n" ] && [ "$yn" == "n" -o "$yn" == "N" ]
L1252: [ ! "$editor" -o "$editor" == "none" ]
```

### Suggested Fix

Replace with `||` in separate `[ ]` tests or use `[[ ]]`:
```bash
[[ "$yn" == "y" || "$yn" == "Y" ]]
[[ -z "$editor" || "$editor" == "none" ]]
```


---

## Bug #689: `include_all.sh` unquoted variables in `verify-aba-conf()` and `verify-mirror-conf()`

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (latent — values unlikely to contain glob characters, but violates best practices)
- **Component**: `scripts/include_all.sh` lines 547-549, 553, 630, 639, 641, 643
- **Found by**: Code review

### Symptom

Multiple `echo $variable | grep` patterns use unquoted variables:

```
L547: echo $ocp_version | grep ...
L548: echo $ocp_channel | grep ...
L549: echo $platform    | grep ...
L553: echo $op_sets | grep ...
L630: echo $reg_host | grep ...
L639: echo $data_dir | grep ...
L641: echo $reg_path | grep ...
L643: echo $reg_ssh_key | grep ...
```

If any variable contains glob characters (`*`, `?`, `[`) or starts with `-n`/`-e`, the unquoted echo would misbehave.

### Suggested Fix

Quote all variables: `echo "$var" | grep ...` or use `printf '%s\n' "$var" | grep ...`.


---

## Bug #690: `include_all.sh` `_run_oc_mirror_with_retry()` uses `echo_red` instead of `aba_warning`

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (inconsistent logging — same pattern as Bug #681)
- **Component**: `scripts/include_all.sh` lines 3136, 3147
- **Found by**: Code review

### Symptom

Uses raw `echo_red` for user-facing error messages instead of `aba_warning`:

```
L3136: echo_red "[ABA] oc-mirror $action failed (exit=$ret: $decoded) ..." >&2
L3147: echo_red "         Consider using the --retry option!" >&2
```

This bypasses the `[ABA]` prefix convention and `aba_warning`'s multi-line formatting.


---

## Bug #691: `include_all.sh` `run_once()` global-failed-clean block — severely inconsistent indentation

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — code works, but indentation is misleading)
- **Component**: `scripts/include_all.sh` lines 2455-2474
- **Found by**: Code review

### Symptom

The global-failed-clean block in `run_once()` has inconsistent indentation across the `if/elif/fi` structure:

```
L2455:  if [[ -f "$exitf" ]]; then        (3 tabs)
L2456:      rc="$(cat "$exitf" ...)"       (4 tabs)
L2457:  if [[ "$rc" -ne 0 ]]; then         (3 tabs — should be 4)
L2461:  fi                                 (3 tabs — should be 4)
L2462:  elif [[ -e "$d" ]]; then           (2 tabs — should be 3)
L2467:      if ( exec 9>>... ); then       (3 tabs)
L2471:          else                       (4 tabs — should be 3)
L2473:          fi                          (4 tabs — should be 3)
L2474:      fi                             (3 tabs)
```

The code is functionally correct but the visual structure is misleading.


---

## Bug #692: TUI missing "Register" option for existing external registries

**Status:** OPEN — code review + CLI test

- **Status:** VERIFIED (code review + CLI test)
- **Severity**: Medium (feature gap — users must fall back to CLI)
- **Component**: `tui/v2/tui-mirror.sh`, `tui/v2/abatui2.sh`
- **Found by**: Code review + TUI testing

### Symptom

The CLI supports registering an existing external registry via:
```
aba -d mirror register --pull-secret-mirror <file> --ca-cert <file>
```

But the TUI has NO menu option for this. The CONNO mode main menu offers:
- Install Mirror (local/remote)
- Sync/Save/Load/Bundle
- No "Register existing registry"

Users who want to use an existing registry that was set up outside of ABA must use the CLI.

### Suggested Fix

Add a "Register Existing" option to the mirror section of the CONNO menu, alongside "Install Mirror". The TUI should prompt for:
- Pull secret file path
- CA certificate file path
- Registry hostname/port (or infer from pull secret)

Then call `aba -d mirror register`.


---

## Bug #693: `tui-mirror.sh` `mirror_prep_upgrade()` inconsistent indentation in case block

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic)
- **Component**: `tui/v2/tui-mirror.sh` lines 569-603
- **Found by**: Code review

### Symptom

The `c)` and `m)` case items at lines 569 and 576 use one fewer tab than the `t)`, `l)`, `p)` items at lines 566-568. Similarly, lines 582-583 inside the `m)` block have inconsistent indentation compared to surrounding code.


---

## Bug #694: `tui-mirror.sh` `mirror_view_isc()` — broken indentation in E) and O) case blocks

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic)
- **Component**: `tui/v2/tui-mirror.sh` lines 822-830, 857-864
- **Found by**: Code review

### Symptom

The `E)` case block has `--editbox` at 4 tabs but the `if [[ $? -eq 0 ]]` at 4 tabs and `fi` at 5 tabs — inconsistent with the 5-tab baseline for code inside `case`. The `O)` case block (lines 857-864) has items at 4 tabs instead of the expected 5 tabs.


---

## Bug #695: `abatui2.sh` CONNO menu Transfer section indentation mismatch

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic)
- **Component**: `tui/v2/abatui2.sh` lines 577-580
- **Found by**: Code review

### Symptom

In the `items+=()` array for the CONNO menu, the "Transfer" section (lines 577-580) uses one fewer tab than the surrounding "Mirror" and "Cluster" sections (lines 571-576, 581-588).


---

## Bug #696: `tui-cluster.sh` `tui_advanced_menu()` Danger Zone items indentation mismatch

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic)
- **Component**: `tui/v2/tui-cluster.sh` lines 1878-1882
- **Found by**: Code review

### Symptom

The Danger Zone section in `tui_advanced_menu()` uses one tab of indentation (lines 1878-1882), while the surrounding code uses two tabs (lines 1849-1877). This creates visual inconsistency in the menu construction code.


---

## Bug #697: `make-bundle.sh` case block uses spaces instead of tabs

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — violates coding standard)
- **Component**: `scripts/make-bundle.sh` lines 48-70
- **Found by**: Code review

### Symptom

The `case "$1" in` block for argument parsing uses 2-space indentation instead of tabs.


---

## Bug #698: `make-bundle.sh` typo "Deleteing" and FIXME "MNIssing"

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic)
- **Component**: `scripts/make-bundle.sh` lines 119, 129
- **Found by**: Code review

### Symptom

- Line 119: Comment says `# FIXME MNIssing [ABA]` — "MNIssing" should be "Missing".
- Line 129: `aba_warning "Deleteing all files..."` — "Deleteing" should be "Deleting".


---

## Bug #699: `make-bundle.sh` deprecated `-a` and `-o` operators

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (deprecated POSIX syntax)
- **Component**: `scripts/make-bundle.sh` lines 127, 174
- **Found by**: Code review

### Symptom

```
L127: [ -d mirror/data -a "$(ls mirror/data 2>/dev/null)" ]
L174: [ -s mirror/data/imageset-config.yaml -o -f mirror/mirror.conf -o "$image_set_files_exist" ]
```


---

## Bug #700: `make-bundle.sh` uses `echo_red` and `echo_magenta` for user-facing messages

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (inconsistent logging)
- **Component**: `scripts/make-bundle.sh` lines 179-181, 236-238
- **Found by**: Code review

### Symptom

Lines 179-181 use `echo_red` for error messages instead of `aba_warning`.
Lines 236-238 use `echo_magenta "[ABA] ..."` for informational messages instead of `aba_info`.

Line 120 uses raw `echo "Bundle output file = ..."` without `[ABA]` prefix (already has a FIXME comment acknowledging this).


---

## Bug #701: `aba.sh` systemic use of deprecated `-o` and `-a` operators (60+ instances)

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (deprecated POSIX syntax, but functional)
- **Component**: `scripts/aba.sh` — throughout argument parsing (lines 41-959) and logic (lines 1362-1691)
- **Found by**: Code review

### Symptom

`aba.sh` uses deprecated `-o` (or) and `-a` (and) operators inside `[ ]` test commands extensively — over 60 instances. Most are in the argument parsing section (e.g., `[ "$1" = "--help" -o "$1" = "-h" ]`) and some in logic gates (e.g., `[ "$have_args" -a ! "$BUILD_COMMAND" ]`).

### Key Examples

```
L41:   [ "$1" = "--aba-version" -o "$1" = "version" ]
L46:   [ "$git_branch" -a "$git_commit" ]
L366:  [ "$_ht" = "mirror" -o "$_ht" = "save" -o ... ]  (6 -o operators on one line!)
L1362: [ "$have_args" -a ! "$BUILD_COMMAND" ]
```

### Suggested Fix

Replace with `||` / `&&` in separate `[ ]` tests, or use `[[ ]]` with `||` / `&&`. Note: This is a large refactoring task — 60+ lines to change. Consider doing it as a batch modernization pass.


---

## Bug #702: `aba.sh` typo "synchonized" in partially-disconnected prompt

**Status:** OPEN — TUI testing + code review

- **Status:** VERIFIED (TUI testing + code review)
- **Severity**: Low (cosmetic — user-facing typo)
- **Component**: `scripts/aba.sh` line 1858
- **Found by**: TUI testing on conno

### Symptom

The CLI wizard prompt reads:
```
Install OpenShift from a mirror registry that is synchonized directly from the Internet?
```

"synchonized" should be "synchronized".

### Root Cause

Typo in the string literal at `scripts/aba.sh:1858`.


---

## Bug #703: `download-catalog-index.sh` uses `read` without `-r` flag

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — operator names don't typically contain backslashes)
- **Component**: `scripts/download-catalog-index.sh` line 232
- **Found by**: Code review

### Symptom

`read pkg def_ch < <(awk ...)` uses `read` without the `-r` flag, which means backslash sequences in operator names or channel names would be interpreted. Should use `read -r` per shell best practices.

### Also Affected

`scripts/preflight-check-vsphere.sh` lines 106 and 132 have the same pattern (`read host port` without `-r`).


---

## Bug #704: `backup.sh` deprecated `-o` operator

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (deprecated POSIX syntax)
- **Component**: `scripts/backup.sh` line 57
- **Found by**: Code review

### Symptom

```
L57: [ ! -f ~/.aba.previous.backup -o ! "$inc" ]
```


---

## Bug #705: `backup.sh` typo "transfering" (should be "transferring")

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — user-facing typo)
- **Component**: `scripts/backup.sh` lines 176, 195
- **Found by**: Code review

### Symptom

Both instances say "After transfering the install bundle" — should be "After transferring".


---

## Bug #706: `backup.sh` uses `echo_magenta`/`echo_cyan` for user-facing messages

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (inconsistent logging)
- **Component**: `scripts/backup.sh` lines 155-160, 168, 189
- **Found by**: Code review

### Symptom

Uses `echo_magenta` and `echo_cyan` for important user-facing messages instead of `aba_info` or `aba_warning`. These bypass the `[ABA]` prefix convention.


---

## Bug #707: Deprecated `-o`/`-a` operators widespread across scripts/ (beyond aba.sh)

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (deprecated POSIX syntax — works but fragile with special values)
- **Component**: Multiple scripts under `scripts/`
- **Found by**: Code review (systemic grep)

### Symptom

Beyond `aba.sh` (Bug #701, 51 instances) and `include_all.sh` (Bugs #687, #688, 6 instances), the deprecated `-o` and `-a` operators appear in these additional scripts:

| Script | Count |
|--------|-------|
| `create-install-config.sh` | 5 |
| `verify-config.sh` | 4 |
| `create-containers-auth.sh` | 2 |
| `cluster-rescue.sh` | 2 |
| `make-bundle.sh` | 2 (Bug #699) |
| `reg-create-imageset-config.sh` | 1 |
| `day2.sh` | 1 |
| `cluster-startup.sh` | 1 |
| `cluster-graceful-shutdown.sh` | 1 |
| `vmw-refresh.sh` | 1 |
| `reg-verify.sh` | 1 |
| `add-operators-to-imageset.sh` | 1 |
| `backup.sh` | 1 (Bug #704) |
| `ssh-rendezvous.sh` | 1 |
| `reset-gate.sh` | 1 |
| `create-mirror-conf.sh` | 1 |
| `cluster-config.sh` | 1 |
| `cluster-config-check.sh` | 1 |

Total: ~85 instances across the codebase. Replace with `] && [` (for `-a`) or `] || [` (for `-o`), or use `[[ ]]` compound tests.


---

## Bug #708: `day2.sh` uses `echo_red` for error messages

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (inconsistent logging)
- **Component**: `scripts/day2.sh` lines 264, 283
- **Found by**: Code review

### Symptom

Uses `echo_red "Error: ..."` for error messages instead of `aba_warning` or `aba_abort`. Bypasses the `[ABA]` prefix convention:
- L264: `echo_red "Error: CatalogSource file does not exist: [$f]"`
- L283: `echo_red "Error: Cannot parse CatalogSource name: [$f]"`


---

## Bug #709: `day2.sh` mixed indentation in CatalogSource case block

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — indentation)
- **Component**: `scripts/day2.sh` lines 277-279
- **Found by**: Code review

### Symptom

The case patterns use 4 leading spaces + 3 tabs instead of just 3 tabs. All surrounding code uses tabs only.


---

## Bug #710: `verify-config.sh` typo "endpoiont" (should be "endpoint")

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — user-facing typo)
- **Component**: `scripts/verify-config.sh` lines 73, 79
- **Found by**: Code review

### Symptom

- L73: `aba_abort "Ingress endpoiont: api_vip must be defined ..."`
- L79: `aba_info "Ingress endpoiont: ingress_vip=$ingress_vip is defined"`

Both should say "endpoint".


---

## Bug #711: `reg-load.sh` has un-commented `set -x` debug flag (unlike reg-save/reg-sync)

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Medium (functional — passes `y` as first arg enables shell tracing in production)
- **Component**: `scripts/reg-load.sh` line 29
- **Found by**: Code review (cross-script comparison)

### Symptom

```
L29: [ "$1" == "y" ] && set -x && shift  # If the debug flag is "y"
```

This is active in `reg-load.sh` but commented out in `reg-save.sh` (line 16: `##[ "$1" == "y" ]`) and `reg-sync.sh` (line 15: `#[ "$1" == "y" ]`). If a user accidentally passes `y` as the first arg, shell tracing is enabled, flooding the terminal with debug output. This is a leftover from debugging.

### Suggested Fix

Comment out the line to match `reg-save.sh` and `reg-sync.sh`.


---

## Bug #712: `reg-load.sh` uses raw `echo "[ABA]..."` instead of `aba_info`

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (inconsistent logging)
- **Component**: `scripts/reg-load.sh` line 30
- **Found by**: Code review

### Symptom

L30 uses `echo "[ABA] Attempting $try_tot times..."` while the equivalent line in `reg-save.sh` (L17) uses `aba_info`. Same pattern in `reg-sync.sh` (L16) also uses `aba_info`.


---

## Bug #713: `vmw-create.sh` typo "hirerachy" (should be "hierarchy")

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — code comment)
- **Component**: `scripts/vmw-create.sh` line 65
- **Found by**: Code review


---

## Bug #714: `cluster-rescue.sh` uses spaces instead of tabs for indentation

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — coding style)
- **Component**: `scripts/cluster-rescue.sh` lines 23-26
- **Found by**: Code review

### Symptom

Lines 23-26 (SSH/SCP commands) use 8 spaces for indentation instead of tabs. All surrounding code uses tabs.


---

## Docbug #715: README broken markdown table in Cluster Commands

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Medium (renders incorrectly — users see garbled table)
- **Component**: `README.md` line 1293
- **Found by**: Documentation review

### Symptom

The `|` characters inside `<sno | compact | standard>` are interpreted as table column separators, breaking the row:

```
| `aba cluster --name --type <sno | compact                                                       |
```

Should escape or reformat to avoid the pipe character inside the table cell.


---

## Docbug #716: README numbered list renders as four "1." items

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — confusing numbering)
- **Component**: `README.md` lines 1223, 1230, 1249, 1258
- **Found by**: Documentation review

### Symptom

The "Connected Installation" steps section has four items all numbered `1.` instead of `1., 2., 3., 4.`. Code blocks between the items break Markdown auto-numbering, so each item starts a new list.


---

## Docbug #717: README TUI description overstates "complete workflow"

**Status:** OPEN — code review + TUI testing

- **Status:** VERIFIED (code review + TUI testing)
- **Severity**: Low (inaccurate documentation)
- **Component**: `README.md` line 282
- **Found by**: Documentation review + Bug #692

### Symptom

Line 282 says: "The TUI covers the complete workflow: mode selection..."

But the TUI is missing the "Register existing registry" workflow (Bug #692). Users who rely on the TUI description will be surprised that they need the CLI for this feature.


---

## Bug #718: `check-macs.sh` uses spaces instead of tabs (entire file)

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — coding style)
- **Component**: `scripts/check-macs.sh` (72 indented lines, all spaces)
- **Found by**: Code review

### Symptom

The entire file uses 8-space indentation instead of tabs. This is the only script in the codebase with 100% space indentation.


---

## Bug #719: `monitor-install.sh` uses spaces instead of tabs in associative array

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — coding style)
- **Component**: `scripts/monitor-install.sh` lines 56-62
- **Found by**: Code review

### Symptom

The `declare -A wait_for_exit_reasons` associative array uses 4-space indentation instead of tabs.


---

## Bug #720: `monitor-install.sh` uses `echo_red`/`echo_yellow` for error messages

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (inconsistent logging)
- **Component**: `scripts/monitor-install.sh` lines 47, 68-71
- **Found by**: Code review

### Symptom

Uses `echo_yellow "[ABA] Running: ..."` and `echo_red "[ABA] Something went wrong..."` instead of `aba_info` and `aba_warning`. Manually constructs the `[ABA]` prefix.


---

## Bug #721: `generate-image.sh` uses `echo_cyan`/`echo_yellow` for user messages

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (inconsistent logging)
- **Component**: `scripts/generate-image.sh` lines 31, 34, 37, 103
- **Found by**: Code review

### Symptom

Uses `echo_cyan "Cluster configuration"` and `echo_yellow "[ABA] Running: ..."` instead of `aba_info`. Manually constructs the `[ABA]` prefix on L103.


---

## Bug #722: `generate-image.sh` comment typo "avalable" (should be "available")

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — comment typo)
- **Component**: `scripts/generate-image.sh` line 119
- **Found by**: Code review

### Symptom

Comment says "the built in 'additionalNTPSources' feature is not avalable" — should be "available".


---

## Bug #723: `install-rpms.sh` typo "occured" (should be "occurred")

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — user-facing typo)
- **Component**: `scripts/install-rpms.sh` line 33
- **Found by**: Code review

### Symptom

`echo_red "Warning: an error occured during rpm installation..."` — typo. Also uses `echo_red`/`echo_magenta` instead of `aba_warning`/`aba_info` (L33-35).


---

## Bug #724: Systemic use of `echo_red`/`echo_yellow`/`echo_cyan`/`echo_magenta` instead of `aba_info`/`aba_warning`/`aba_abort`

**Status:** OPEN — code review — systemic grep

- **Status:** VERIFIED (code review — systemic grep)
- **Severity**: Low (inconsistent logging — bypasses `[ABA]` prefix)
- **Component**: Multiple scripts under `scripts/`
- **Found by**: Code review

### Symptom

Beyond `include_all.sh` (where the functions are defined), raw color echo functions are used for user-facing messages in these scripts:

| Script | Count |
|--------|-------|
| `aba.sh` | 36 |
| `backup.sh` | 15 |
| `cluster-config.sh` | 11 |
| `check-version-mismatch.sh` | 8 |
| `create-cluster-conf.sh` | 6 |
| `make-bundle.sh` | 6 |
| `monitor-install.sh` | 5 |
| `generate-image.sh` | 4 |
| `monitor-bootstrap.sh` | 3 |
| `install-rpms.sh` | 3 |
| Other scripts | ~15 |

Total: ~112 instances across 20+ scripts. These bypass the `[ABA]` prefix convention and make output inconsistent. Should be replaced with `aba_info`, `aba_warning`, or `aba_abort` as appropriate.


---

## Bug #725: `make-bundle.sh` typos: "behand", "Deleteing", "reuqired", "MNIssing"

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — typos in user-facing messages and comments)
- **Component**: `scripts/make-bundle.sh` lines 81, 119, 129, 287
- **Found by**: Code review

### Symptom

Multiple typos in `make-bundle.sh`:
- L81: `# This will have been completed behand` → "beforehand"
- L119: `# FIXME MNIssing [ABA]` → "Missing"
- L129: `aba_warning "Deleteing all files..."` → "Deleting"
- L287: `# Pull reuqired release` → "required"


---

## Bug #726: `make-bundle.sh` L120 raw `echo` for user-facing bundle output path

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (inconsistent logging — `echo` instead of `aba_info`)
- **Component**: `scripts/make-bundle.sh` line 120
- **Found by**: Code review

### Symptom

Line 120: `echo "Bundle output file = $bundle_dest_file" >&2` uses raw `echo` instead of `aba_info`. There's even a FIXME comment on L119 acknowledging this: `# FIXME MNIssing [ABA]`. The fix is to replace with `aba_info "Bundle output file = $bundle_dest_file"`.


---

## Bug #727: `make-bundle.sh` mixed indentation in arg-parsing block

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — style violation)
- **Component**: `scripts/make-bundle.sh` lines 47-70
- **Found by**: Code review

### Symptom

The `while`/`case` argument parsing block at lines 47-70 uses 2-space indentation for the `case` keyword and 4-space indentation for case patterns, while the rest of the script uses tabs. This violates the project's "tabs only" coding convention.


---

## Bug #728: `cluster-config.sh` potential divide-by-zero on line 99

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Medium (functional — arithmetic error)
- **Component**: `scripts/cluster-config.sh` line 99
- **Found by**: Code review

### Symptom

```bash
PORTS_PER_NODE=$(expr ${#CP_MAC_ADDRS_ARRAY[@]} / $CP_REPLICAS)
```

If `$CP_REPLICAS` is empty or 0 (which can happen if the validation on line 151 hasn't been reached yet, or if `jq` returns an unexpected value), this `expr` will fail with "division by zero". Additionally, `expr` is a legacy command; `$(( ... ))` should be used for arithmetic.


---

## Bug #729: `cluster-config.sh` uses spaces for indentation in `distribute_macs()` function

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — style violation)
- **Component**: `scripts/cluster-config.sh` lines 28-57
- **Found by**: Code review

### Symptom

The `distribute_macs()` function uses 4-space indentation throughout (lines 28-57), while the rest of the script and the project convention requires tabs.


---

## Bug #730: `add-operators-to-imageset.sh` mixed indentation on line 166

**Status:** OPEN — code review — `cat -A`

- **Status:** VERIFIED (code review — `cat -A`)
- **Severity**: Low (cosmetic — style violation)
- **Component**: `scripts/add-operators-to-imageset.sh` line 166
- **Found by**: Code review

### Symptom

Line 166 uses 4 spaces + 1 tab instead of just 1 tab for indentation:
```
    \tif [ "$catalog_file_errors" ]; then
```
Confirmed with `cat -A`. All other indentation in the file uses tabs.


---

## Bug #731: `create-containers-auth.sh` line 62 indentation with spaces instead of tab

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — style violation)
- **Component**: `scripts/create-containers-auth.sh` line 62
- **Found by**: Code review

### Symptom

Line 62 uses 7 spaces for indentation instead of tabs:
```bash
       cp $regcreds_dir/pull-secret-mirror.json $XDG_RUNTIME_DIR/containers/auth.json || true
```
This contrasts with the surrounding code which uses tabs.


---

## Bug #732: `create-cluster-conf.sh` lines 20 and 156 — `echo_red` without `>&2` redirect

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Medium (functional — error message goes to stdout)
- **Component**: `scripts/create-cluster-conf.sh` lines 20, 156
- **Found by**: Code review

### Symptom

Lines 20 and 156 use `echo_red "Error: ..."` but WITHOUT `>&2`. The error messages go to stdout, where they could be captured by command substitution or piped, making them invisible to the user:
```bash
# Line 20 — no >&2:
echo_red "Error: 'ocp_version' not set in aba/aba.conf. ..."
# Line 156 — no >&2:
echo_red "Error: failed to render cluster.conf (is python3 installed?)."
```
In contrast, lines 97-100 correctly use `>&2`. Should use `aba_abort` instead.


---

## Bug #733: `cluster-config.sh` extensive use of backticks instead of `$()`

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (style — deprecated syntax)
- **Component**: `scripts/cluster-config.sh` lines 74, 78, 82, 86, 90, 94, 113, 117, 124, 128, 138
- **Found by**: Code review

### Symptom

The script uses backtick command substitution throughout (11+ instances), e.g.:
```bash
CLUSTER_NAME=`echo "$ICONF_TMP" | jq -r .metadata.name`
```
Backticks are deprecated in favor of `$()`. Backticks don't nest, are harder to read, and can cause quoting issues.


---

## Bug #734: `day2-config-osus.sh` line 23 — typo "Signatires"

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — typo in comment)
- **Component**: `scripts/day2-config-osus.sh` line 23
- **Found by**: Code review

### Symptom

Comment reads `# Stop processing (CatalogSources and Signatires etc)` — should be "Signatures".


---

## Bug #735: `|| exit 1` inside `$()` does NOT propagate to parent — 7 scripts affected

**Status:** OPEN — code review — confirmed pattern

- **Status:** VERIFIED (code review — confirmed pattern)
- **Severity**: Medium-High (functional — error silently swallowed)
- **Component**: 5 scripts with incorrect error handling pattern
- **Found by**: Code review

### Symptom

These scripts place `|| exit 1` INSIDE the command substitution:

```bash
# WRONG: exit 1 runs in subshell, eval gets empty output, returns 0
eval "$(scripts/cluster-config.sh || exit 1)"    # check-macs.sh:10
eval $(scripts/cluster-config.sh $@ || exit 1)   # monitor-install.sh:27
eval $(scripts/cluster-config.sh $@ || exit 1)   # monitor-bootstrap.sh:12
eval $(scripts/cluster-config.sh $@ || exit 1)   # wait-agent-up.sh:12
eval $(scripts/cluster-config.sh $@ || exit 1)   # cluster-rescue.sh:15
eval `scripts/cluster-config.sh || exit 1`       # vmw-upload.sh:22
eval `scripts/cluster-config.sh || exit 1`       # vmw-delete.sh:21
```

When `cluster-config.sh` fails:
1. `|| exit 1` runs inside the `$()` subshell
2. The subshell exits with code 1
3. `$()` returns empty output
4. `eval ""` succeeds (exit code 0)
5. Parent script **continues with NO variables set** (CLUSTER_NAME, CP_IP_ADDRESSES, etc.)

### Correct pattern (used by 16 other scripts):

```bash
eval "$(scripts/cluster-config.sh)" || exit 1
```

Here `|| exit 1` is OUTSIDE `$()`, so if eval (or the quoted output) fails, the parent script exits.

### Additional issues in the unquoted variants:
- `$@` is unquoted (should be `"$@"`)
- `$(...)` is unquoted (word splitting on output)


---

## Bug #736: `configure-pxe.sh` line 2 — typo "nuse"

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — typo in comment)
- **Component**: `scripts/configure-pxe.sh` line 2
- **Found by**: Code review

### Symptom

Comment reads `# Create PXE env (not in nuse)` — should be "not in use".


---

## Bug #737: `tui-disco.sh` and `tui-direct.sh` inconsistent indentation throughout case blocks

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — style violation)
- **Component**: `tui/v2/tui-disco.sh`, `tui/v2/tui-direct.sh`, `tui/v2/abatui2.sh`
- **Found by**: Code review

### Symptom

Multiple `case`/`esac` blocks and `items+=()` array constructions have inconsistent indentation, mixing 1-tab and 2-tab indentation levels within the same block. Examples:

- `tui-disco.sh` L188-199: items array starts at 2 tabs, switches to 1 tab mid-array
- `tui-disco.sh` L233-243: case patterns alternate between 1-tab and 2-tab indentation
- `tui-disco.sh` L272-278: inner case at 1-tab instead of 2-tab
- `tui-direct.sh` L125-149: version case at 2-tab, other cases at 1-tab
- `tui-direct.sh` L467-499: manual entry loop has wildly mixed indentation
- `abatui2.sh` L577-580: items at 1-tab, surrounding items at 2-tab

While not functionally broken, the inconsistency makes the code harder to read and maintain.


---

## Bug #738: `include_all.sh` `aba-track()` function uses spaces for indentation

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — style violation)
- **Component**: `scripts/include_all.sh` lines 2048-2064
- **Found by**: Code review

### Symptom

The `aba-track()` function on lines 2048-2064 uses 4-space indentation instead of tabs, violating the project's "tabs only" coding convention.


---

## Bug #739: Unquoted `$*` in `process_args` calls across 9 scripts

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (quoting — functionally safe due to `process_args` regex guard)
- **Component**: 9 scripts
- **Found by**: Code review

### Symptom

Nine scripts call `. <(process_args $*)` with unquoted `$*`. This is technically a word-splitting risk, though `process_args()` validates input with a regex that rejects spaces in values, making this functionally safe in practice.

Affected scripts:
- `create-cluster-conf.sh` L107
- `setup-cluster.sh` L15
- `vmw-stop.sh` L9
- `vmw-start.sh` L9
- `vmw-refresh.sh` L9
- `kvm-start.sh` L9
- `kvm-stop.sh` L9
- `kvm-refresh.sh` L8
- `setup-mirror.sh` L13

Should be changed to `. <(process_args "$@")` for consistency with bash best practices.


---

## Bug #740: `reg-uninstall.sh` line 73 — comment says "respect -y flag" but code doesn't

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Medium (functional — `-y` flag ignored in fallback path)
- **Component**: `scripts/reg-uninstall.sh` line 73
- **Found by**: Code review

### Symptom

The comment on line 72-73 says:
```bash
# Enable interactive prompting, but respect -y flag if the user passed it
export ask=1
```

But `export ask=1` unconditionally enables prompting, overriding the `ask=` (empty) set by `normalize-aba-conf` when `-y` (`ASK_OVERRIDE`) was passed. So if the user runs `aba -y -d mirror uninstall` and the fallback path is triggered (no state.sh), they will be prompted despite explicitly requesting non-interactive mode.

### Fix

```bash
[ ! "$ASK_OVERRIDE" ] && export ask=1
```

This preserves the safety prompt for interactive use while respecting the explicit `-y` flag.


---

## Bug #741: Systemic `read` without `-r` flag across multiple scripts

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic/best-practice — backslash interpretation in `read`)
- **Component**: Multiple scripts (systemic)
- **Found by**: Code review

### Symptom

Without `-r`, `read` interprets backslash sequences (e.g., `\n`, `\\`), which can mangle
input containing backslashes. While most affected inputs are unlikely to contain backslashes,
it violates ShellCheck SC2162 and is inconsistent with other `read -r` calls in the same scripts.

### Affected scripts

| Script | Line | Variable |
|--------|------|----------|
| `reset-gate.sh` | 10 | `yn` |
| `add_ntp_ignition_to_iso.sh` | 27 | `item` |
| `preflight-check-vsphere.sh` | 106, 132 | `host port` |
| `reg-existing-create-pull-secret.sh` | 13, 16 | `reg_user`, `reg_pw` |
| `download-catalog-index.sh` | 76, 232 | `op_name op_default_channel`, `pkg def_ch` |
| `aba.sh` | 1687, 1763 | `target_ver`, `new_editor` |
| `include_all.sh` | 1234 | `yn` |

### Fix

Add `-r` to all `read` calls. The `reg-existing-create-pull-secret.sh` case is particularly
important because the password field could contain backslashes.


---

## Bug #742: `reg-existing-create-pull-secret.sh` uses `echo` to encode password (process table exposure)

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (security best-practice)
- **Component**: `scripts/reg-existing-create-pull-secret.sh` line 19, `scripts/reg-common.sh` line 438
- **Found by**: Code review

### Symptom

```bash
enc_password=$(echo -n "$reg_user:$reg_pw" | base64 -w0)
```

`echo` creates a child process whose arguments (including the password) are briefly visible
in `/proc/*/cmdline` and `ps` output. While the exposure window is brief, `printf` is preferred:

```bash
enc_password=$(printf '%s' "$reg_user:$reg_pw" | base64 -w0)
```

### Fix

Replace `echo -n "..."` with `printf '%s' "..."` in both locations.


---

## Bug #743: `vmw-create.sh` line 65 typo "hirerachy" → "hierarchy"

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — comment typo)
- **Component**: `scripts/vmw-create.sh` line 65
- **Found by**: Code review

### Symptom

```bash
scripts/vmw-create-folder.sh "$cluster_folder"  # This will create a folder hirerachy, if needed
```

"hirerachy" should be "hierarchy".


---

## Bug #744: `eval "$(scripts/cluster-config.sh)" || exit 1` silently loses exit code (~17 scripts)

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Medium (functional — error propagation failure)
- **Component**: Multiple scripts (systemic)
- **Found by**: Code review

### Symptom

The pattern `eval "$(scripts/cluster-config.sh)" || exit 1` does NOT correctly propagate
failures from `cluster-config.sh`:

1. `$(scripts/cluster-config.sh)` captures stdout regardless of exit code
2. If the script fails with empty output, `eval ""` returns 0
3. The `|| exit 1` never triggers
4. If the script fails with PARTIAL output, those partial exports are eval'd, leaving
   inconsistent state

### Affected scripts (~17)

`vmw-create.sh`, `vmw-stop.sh`, `vmw-start.sh`, `vmw-ls.sh`, `vmw-kill.sh`, `vmw-on.sh`,
`vmw-exists.sh`, `kvm-create.sh`, `kvm-start.sh`, `kvm-stop.sh`, `kvm-on.sh`, `kvm-ls.sh`,
`kvm-kill.sh`, `kvm-exists.sh`, `kvm-delete.sh`, `kvm-upload.sh`,
`cluster-graceful-shutdown.sh` (L245, L264)

Note: `check-macs.sh` uses the Bug #735 variant: `eval "$(scripts/cluster-config.sh || exit 1)"`.

### Fix

```bash
_cc_output=$(scripts/cluster-config.sh) || exit 1
eval "$_cc_output"
```

This ensures the exit code is checked BEFORE eval'ing any output.


---

## Bug #745: `let` usage is fragile under `set -e` (4 scripts)

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (latent — `let` returns exit code 1 when expression evaluates to 0)
- **Component**: Multiple scripts
- **Found by**: Code review

### Symptom

`let expr` returns exit code 1 when the expression evaluates to 0, just like `(( ))`.
Under `set -e` or an ERR trap, this would crash the script.

| Script | Line | Expression |
|--------|------|------------|
| `include_all.sh` | 1298 | `let pause=$pause+$backoff` |
| `include_all.sh` | 1299 | `let count=$count+1` |
| `cluster-startup.sh` | 135 | `let i=$i+$pause` |
| `vmw-create.sh` | 151 | `let i=$i+1` |
| `kvm-create.sh` | 137 | `let i=$i+1` |

Currently safe because the expressions never evaluate to 0 in normal usage.
However, `let` is fragile and inconsistent with the project's own coding convention:
"Use `var=$(( var + 1 ))` instead of `(( var++ ))`."

### Fix

Replace all `let` expressions with arithmetic assignment:
```bash
pause=$(( pause + backoff ))
count=$(( count + 1 ))
i=$(( i + 1 ))
```


---

## Bug #746: `reg-save.sh` dead variable `r=1` on line 17

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — unused variable)
- **Component**: `scripts/reg-save.sh` line 17
- **Found by**: Code review

### Symptom

```bash
[ "$1" ] && [ $1 -gt 0 ] && r=1 && try_tot=`expr $1 + 1` && ...
```

The variable `r` is set to 1 but never referenced anywhere in the script. It appears to be
a leftover from a removed retry-loop implementation.


---

## Bug #747: `generate-image.sh` line 43 — `eval "$config || exit 1"` has `|| exit 1` inside eval string

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: HIGH (functional — incorrect error handling in ISO generation)
- **Component**: `scripts/generate-image.sh` line 43
- **Found by**: Code review

### Symptom

```bash
config=$(scripts/cluster-config.sh)
# ...
eval "$config || exit 1"
```

The `|| exit 1` is INSIDE the quoted string, so it becomes part of the eval'd code:
```bash
eval "export CLUSTER_NAME=mycluster
export BASE_DOMAIN=example.com
...
export LAST_VAR=value || exit 1"
```

The `|| exit 1` only applies to the LAST export statement. All previous statements execute
regardless of errors.

The developer likely intended:
```bash
eval "$config" || exit 1
```

But even that has the same issue as Bug #744. The correct pattern is:
```bash
config=$(scripts/cluster-config.sh) || exit 1
eval "$config"
```

### Impact

If `cluster-config.sh` produces malformed output or fails partway through, the ISO
generation proceeds with incomplete/incorrect cluster configuration variables. The ERR trap
from `include_all.sh` mitigates this (catches the `$(...)` failure on line 26), so in
practice the wrong-pattern on line 43 is only reached when line 26 succeeds.


---

## Bug #748: `generate-image.sh` line 119 — typo "avalable" → "available"

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — comment typo)
- **Component**: `scripts/generate-image.sh` line 119
- **Found by**: Code review

### Symptom

```bash
# Note that the built in 'additionalNTPSources' feature is not avalable for all latest ocp versions
```

"avalable" should be "available".


---

## Bug #749: `backup.sh` line 176 typo "transfering" → "transferring"

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — user-facing message typo)
- **Component**: `scripts/backup.sh` line 176
- **Found by**: Code review

### Symptom

```bash
aba_info "After transfering the install bundle file and the image set archive file(s) to your internal bastion"
```

"transfering" should be "transferring" (double r).


---

## Bug #750: `day2.sh` lines 77-83 — `else` branch is unreachable dead code

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — dead code)
- **Component**: `scripts/day2.sh` lines 77-83
- **Found by**: Code review

### Symptom

Line 28 exits the script if `$int_connection` is non-empty:
```bash
if [ "$int_connection" ]; then
    ... exit 0
fi
```

Line 77 then checks:
```bash
if [ ! "$int_connection" ]; then
    ...
else
    aba_info "Assuming internet connection (e.g. proxy) in use, not disabling default catalog sources"
fi
```

Since we can only reach line 77 if `$int_connection` is empty (we would have exited on line 32 otherwise),
the `else` block on lines 82-83 is unreachable dead code.

### Fix

Remove the `else` branch, or simplify the conditional to just the body (no `if` needed since
it's always true at this point).


---

## Bug #751: Wrong variable/file names in validation error messages (3 instances)

**Status:** FIXED — corrected 3 error message strings (prefix_length, dns_servers file ref)

- **Status:** VERIFIED (code review)
- **Severity**: Medium (functional — misleading error messages lead user to "fix" the wrong setting)
- **Component**: `scripts/include_all.sh` lines 572, 1013, 1073
- **Found by**: Code review

### Symptom

Three error messages report the wrong variable or wrong config file:

**1. Line 572 (`verify-aba-conf`)**: Validates `$prefix_length` but says "machine_network":
```bash
[ "$prefix_length" ] && ! echo $prefix_length | grep ... && { echo_red "Error: machine_network is invalid in aba.conf" >&2; }
```
Fix: `"Error: prefix_length is invalid in aba.conf [$prefix_length]"`

**2. Line 1013 (`verify-cluster-conf`)**: Same bug — validates `$prefix_length` but says "machine_network":
```bash
echo $prefix_length | grep ... || { echo_red "Error: machine_network is invalid in cluster.conf" >&2; }
```
Fix: `"Error: prefix_length is invalid in cluster.conf [$prefix_length]"`

**3. Line 1073 (`verify-cluster-conf`)**: Validates `dns_servers` in cluster.conf but says "aba.conf":
```bash
[ "$dns_servers" ] && ! echo $dns_servers | grep -q -P $PERL_DNS_IP_REGEX && { echo_red "Error: dns_servers is invalid in aba.conf [$dns_servers]" >&2; ret=1; }
```
Fix: `"Error: dns_servers is invalid in cluster.conf [$dns_servers]"`


---

## Bug #752: `aba-get-version.sh` line 32 — typo "Cannot access https://access mirror.openshift.com/"

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic — misleading error URL)
- **Component**: `scripts/aba-get-version.sh` line 32
- **Found by**: Code review

### Symptom

```bash
aba_abort "Error: Cannot access https://access mirror.openshift.com/.  Ensure you have Internet access..."
```

The URL has an extra word "access" — should be `https://mirror.openshift.com/`. This shows
users an incorrect URL that doesn't exist, making it harder to diagnose connectivity issues.

### Fix

```bash
aba_abort "Cannot access https://mirror.openshift.com/. Ensure you have Internet access to download the needed images."
```

Also note: the message includes the redundant "Error:" prefix which `aba_abort` already implies.


---

## Bug #753: `reg-common.sh` state.sh — Docker registry passwords with single quotes break uninstall

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Medium (functional — state.sh becomes unparseable, blocking uninstall)
- **Component**: `scripts/reg-common.sh` lines 442-454
- **Found by**: Code review

### Symptom

state.sh is written with:
```bash
cat > "$regcreds_dir/state.sh" <<-EOF
    reg_pw='$reg_pw'
    ...
EOF
```

For Docker registries, password validation (in `verify-mirror-conf`) does NOT check for
single quotes (the `case` check on line 649-655 only applies when vendor is not docker).

So a Docker registry password like `my'pass` produces:
```
reg_pw='my'pass'
```

This is invalid bash syntax. When `reg-uninstall.sh` sources `state.sh`, it fails with
a parse error, preventing registry uninstall.

### Fix

Use `printf '%q'` to safely shell-escape the password:
```bash
reg_pw=$(printf '%q' "$reg_pw")
```

Or extend the Quay-only password validation in `verify-mirror-conf` to also cover Docker.


---

## Bug #754: TUI v2 does not check for `dialog` binary before first use

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (edge case — `dialog` is installed by `./install` required packages)
- **Component**: `tui/v2/abatui2.sh`
- **Found by**: Code review

### Symptom

The TUI v2 startup checks for critical functions (L132-137) and terminal availability (L43),
but does NOT verify that the `dialog` binary is installed. If `dialog` was removed (e.g.,
`dnf remove dialog`), the first `dlg()` call crashes with:
```
dialog: command not found
```

The v1 TUI (`tui/abatui.sh` L159) had auto-install logic for missing packages.
The v2 TUI lacks this check.

### Fix

Add to startup guard section:
```bash
command -v dialog >/dev/null 2>&1 || { echo "FATAL: 'dialog' not installed. Run: dnf install dialog"; exit 1; }
```


---

## Bug #755: `aba-get-version.sh` leaks temp directory (no cleanup)

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (resource leak — temp dir never removed)
- **Component**: `scripts/aba-get-version.sh` line 27
- **Found by**: Code review

### Symptom

```bash
export tmp_dir=$(mktemp -d "$ABA_TMP/ver-XXXX")
```

Creates a temp directory under `$ABA_TMP` but never removes it — no `trap` and no explicit
`rm -rf "$tmp_dir"`. Every invocation creates a new `ver-XXXX` directory that persists.

Other scripts (e.g., `install-vmware.conf.sh`, `install-kvm.conf.sh`) properly clean up
their temp dirs.

### Fix

Add cleanup:
```bash
trap 'rm -rf "$tmp_dir"' EXIT
```


## Bug #756: `cluster-config.sh` — unquoted `$WORKER_REPLICAS` causes bash error when empty

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Medium (bash syntax error on malformed/missing install-config.yaml)
- **Component**: `scripts/cluster-config.sh` lines 123, 157
- **Found by**: Code review

### Symptom

```bash
# Line 123:
if [ $WORKER_REPLICAS -ne 0 ]; then
# Line 157:
if [ $WORKER_REPLICAS -ne 0 ]; then
```

If `WORKER_REPLICAS` is empty (e.g., from a hand-edited `install-config.yaml` missing
`.compute[0].replicas`), line 119 clears it: `echo "$WORKER_REPLICAS" | grep -q "null" && WORKER_REPLICAS=`.
Then line 123 becomes `[ -ne 0 ]` → `bash: [: -ne: unary operator expected` (exit code 2).

Under `#!/bin/bash -e`, this crashes the script before the validation block at line 155
(`[ ! "$WORKER_REPLICAS" ] && echo_red ...`) ever runs.

### Fix

Quote the variable with a default:
```bash
if [ "${WORKER_REPLICAS:-0}" -ne 0 ]; then
```

Or reorder so the validation block runs first.


## Bug #757: `cluster-config.sh` — divide-by-zero risk in `PORTS_PER_NODE` calculation

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (only hits with corrupt agent-config.yaml; control plane replicas are always >= 1)
- **Component**: `scripts/cluster-config.sh` line 99
- **Found by**: Code review

### Symptom

```bash
PORTS_PER_NODE=$(expr ${#CP_MAC_ADDRS_ARRAY[@]} / $CP_REPLICAS)
```

If `CP_REPLICAS` is 0 or empty (e.g., from a malformed `install-config.yaml`), `expr`
produces a divide-by-zero error: `expr: division by zero`.

In practice, valid cluster configs always have `CP_REPLICAS >= 1`. But the script lacks
a guard — the crash occurs before the validation block at lines 147-155 that checks for
empty `CP_REPLICAS`.

### Fix

Add a guard:
```bash
[ "${CP_REPLICAS:-0}" -eq 0 ] && CP_REPLICAS=1  # prevent divide-by-zero; validation catches later
```

Or reorder so validation runs before the arithmetic.


## Bug #758: `cluster-config.sh` — unquoted output lines produce malformed exports

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (values from YAML are typically space-free; breaks with unusual hostnames)
- **Component**: `scripts/cluster-config.sh` lines 76, 80, 84, 88
- **Found by**: Code review

### Symptom

```bash
echo export CLUSTER_NAME=$CLUSTER_NAME
echo export BASE_DOMAIN=$BASE_DOMAIN
echo export RENDEZVOUSIP=$RENDEZVOUSIP
echo export CP_REPLICAS=$CP_REPLICAS
```

These output lines are consumed by callers via `eval "$(scripts/cluster-config.sh)"`.
If any value contains spaces or shell metacharacters (e.g., a base domain like
`my domain.com`), the eval'd export statement breaks:
`export BASE_DOMAIN=my domain.com` → `domain.com: command not found`.

### Fix

Quote the values in the output:
```bash
echo "export CLUSTER_NAME=\"$CLUSTER_NAME\""
```


## Bug #759: `create-agent-config.sh` — space indentation in functions (should be tabs)

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Cosmetic (violates project coding style)
- **Component**: `scripts/create-agent-config.sh` lines 23-99
- **Found by**: Code review

### Symptom

Functions `to_numeric()`, `from_numeric()`, `calculate_cidr_range()`, `generate_ip_array()`,
`generate_random_hex()`, and `replace_hash_with_random_hex()` (lines 23-99) all use
4-space indentation, while the rest of the file and the project coding standard require tabs.

### Fix

Convert spaces to tabs within these function bodies.


## Bug #760: `create-agent-config.sh` — typo "genrated"

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Cosmetic (typo in code comment)
- **Component**: `scripts/create-agent-config.sh` line 160
- **Found by**: Code review

### Symptom

```bash
# Note, double (or more of) the number of mac addresses are genrated in case port bonding is required
```

"genrated" should be "generated".


## Bug #761: `reg-verify.sh` — dots in `$reg_host` treated as regex wildcards

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (false-positive match unlikely in practice, but technically incorrect)
- **Component**: `scripts/reg-verify.sh` line 48
- **Found by**: Code review

### Symptom

```bash
if ! echo "$mirrors" | grep -q "^$reg_host:$reg_port$"; then
```

`$reg_host` is used in a regex pattern where dots (`.`) match ANY character. For example,
if `reg_host=foo.bar.com`, the pattern `^foo.bar.com:8443$` would also match
`fooXbar_com:8443` or `foo-bar.com:8443`.

### Fix

Use fixed-string matching:
```bash
if ! echo "$mirrors" | grep -qxF "$reg_host:$reg_port"; then
```

Or escape dots:
```bash
local _escaped_host="${reg_host//./\\.}"
if ! echo "$mirrors" | grep -q "^${_escaped_host}:${reg_port}$"; then
```


## Bug #762: `tui-disco.sh` — inconsistent indentation in menu items array

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Cosmetic (incorrect indentation level)
- **Component**: `tui/v2/tui-disco.sh` lines 195-198
- **Found by**: Code review

### Symptom

In the `disco_main()` function, the `items+=()` array has inconsistent indentation.
The Registry and Cluster section entries (lines 189-194) use 3 tabs (inside the `items+=()`
parentheses), but the Advanced section entries (lines 195-198) drop to 2 tabs:

```bash
		items+=(
			"" "──── Registry ──────────────────────"   # 3 tabs
			"$TUI2_DISCO_TAG_INSTALL_REG" "$reg_label"  # 3 tabs
			...
		"" "──── Advanced ──────────────────────"        # 2 tabs (wrong)
		"$TUI2_DISCO_TAG_SETTINGS"    "..."             # 2 tabs (wrong)
		)
```

### Fix

Align all items to 3 tabs inside the array assignment.


## Bug #763: `cluster-config.sh` — backtick usage throughout

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (style — backticks work but `$()` is preferred for readability and nesting)
- **Component**: `scripts/cluster-config.sh` lines 74, 78, 82, 86, 90, 94, 113, 117, 124, 128, 138
- **Found by**: Code review

### Symptom

Nearly every command substitution in the script uses backtick syntax:

```bash
CLUSTER_NAME=`echo "$ICONF_TMP" | jq -r .metadata.name`
BASE_DOMAIN=`echo "$ICONF_TMP" | jq -r .baseDomain`
RENDEZVOUSIP=`echo "$ACONF_TMP" | jq -r '.rendezvousIP'`
```

This is the deprecated form. The project standard is `$()`.

### Fix

Replace all backtick command substitutions with `$(...)`.


## Bug #764: `create-install-config.sh` — unquoted `$ssh_key_file` in multiple operations

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (SSH key paths rarely contain spaces, but breaks if they do)
- **Component**: `scripts/create-install-config.sh` lines 220, 224, 226
- **Found by**: Code review

### Symptom

```bash
if [ -s $ssh_key_file.pub ]; then          # line 220
	ssh-keygen -t rsa -f $ssh_key_file -N ''  # line 224
export ssh_key_pub=$(cat $ssh_key_file.pub)   # line 226
```

If `$ssh_key_file` contains spaces (e.g., a user sets `ssh_key_file="/home/user/my keys/id_rsa"`),
all three lines break: the test splits into multiple arguments, ssh-keygen writes to the wrong path,
and cat fails.

### Fix

Quote all occurrences:
```bash
if [ -s "$ssh_key_file.pub" ]; then
	ssh-keygen -t rsa -f "$ssh_key_file" -N ''
export ssh_key_pub=$(cat "$ssh_key_file.pub")
```


## Bug #765: `install` script — `is_repo_available()` uses deprecated `-a` test operator and unquoted `$0`

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic + fragile with unusual `$0` values)
- **Component**: `install` lines 110, 115
- **Found by**: Code review

### Symptom

```bash
is_repo_available() {
	[ -s ./scripts/aba.sh -a -x ./scripts/aba.sh ] && return 0   # deprecated -a
	[ "$0" = "--" -o "$0" = "bash" ] && return 1                  # deprecated -o
	cd $(dirname $0)                                               # unquoted $0
	return 0
}
```

Three issues in one function:
1. Deprecated `-a` test operator (should be `&&` between two `[` tests)
2. Deprecated `-o` test operator (should be `||` between two `[` tests)
3. Unquoted `$(dirname $0)` — if the script path contains spaces, `cd` receives multiple args

### Fix

```bash
is_repo_available() {
	[ -s ./scripts/aba.sh ] && [ -x ./scripts/aba.sh ] && return 0
	[ "$0" = "--" ] || [ "$0" = "bash" ] && return 1
	cd "$(dirname "$0")"
	return 0
}
```


---

## Bug #766: `day2-config-osus.sh` — redundant duplicate `cincinnati-operator` check

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (dead code — inner `if` identical to outer `if`)
- **Component**: `scripts/day2-config-osus.sh` lines 156-164
- **Found by**: Code review

### Symptom

```bash
if ! oc get packagemanifests | grep -q ^cincinnati-operator; then
	if ! oc get packagemanifests | grep -q ^cincinnati-operator; then
		aba_abort \
			"cincinnati-operator not available in OperatorHub for this cluster." \
			...
	fi
fi
```

The inner `if` on line 157 is identical to the outer `if` on line 156. If the outer
check passes (operator not found), the inner check will always pass too — it runs the
exact same command on the exact same cluster state. The duplicate adds ~2s latency
(extra `oc get packagemanifests` call) with no functional benefit.

### Fix

Remove the duplicate inner `if`:
```bash
if ! oc get packagemanifests | grep -q ^cincinnati-operator; then
	aba_abort \
		"cincinnati-operator not available in OperatorHub for this cluster." \
		...
fi
```

Or if the intent was a retry (to tolerate transient API failures), add a sleep:
```bash
if ! oc get packagemanifests | grep -q ^cincinnati-operator; then
	sleep 5
	if ! oc get packagemanifests | grep -q ^cincinnati-operator; then
		aba_abort ...
	fi
fi
```


---

## Bug #767: `day2-config-osus.sh` — space indentation in mirror registry CA block

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Cosmetic (violates project tab-only indentation style)
- **Component**: `scripts/day2-config-osus.sh` lines 195-196
- **Found by**: Code review

### Symptom

```bash
if [ -s "$regcreds_dir/rootCA.pem" ]; then
        ca_cert="$(cat "$regcreds_dir/rootCA.pem" | sed ...)"    # 8 spaces
        aba_info "Using root CA file at ..."                      # 8 spaces
	kubectl patch configmap ...                               # tab (correct)
```

Lines 195-196 use 8-space indentation while the rest of the function uses tabs.
This is a copy-paste artifact.

### Fix

Replace leading spaces with tabs on lines 195-196.


---

## Bug #768: `make-bundle.sh` — doubled word "standard standard" in comment

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Cosmetic (typo in code comment)
- **Component**: `scripts/make-bundle.sh` line 92
- **Found by**: Code review

### Symptom

```bash
# Be sure the standard standard output of this command is ONLY tar output and nothing else!
```

"standard standard" — one "standard" is duplicated.

### Fix

```bash
# Be sure the standard output of this command is ONLY tar output and nothing else!
```


---

## Bug #769: `day2-config-ntp.sh` — triple-redundant butane installation

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (dead code — two of three installation paths are unreachable)
- **Component**: `scripts/day2-config-ntp.sh` lines 18, 115, 118-130
- **Found by**: Code review

### Symptom

Butane is installed three different ways in the same script:

1. **Line 18**: `scripts/cli-download-all.sh --wait oc butane` — the correct, modern
   approach via the CLI download framework. This blocks until butane is installed to `~/bin/`.

2. **Line 115**: `make -s ~/bin/butane` — a redundant second attempt via make. Since
   line 18 already installed butane, this is a no-op. If butane is somehow missing
   despite line 18, this call has no `|| true` — under the ERR trap it would abort
   the script before the fallback on line 118 can run.

3. **Lines 118-130**: A third fallback using `which butane`, `dnf install`, or raw
   `curl` download. This code is unreachable: if line 18 succeeded, butane exists;
   if line 115 failed, the script already aborted.

### Fix

Remove lines 115-130 entirely. Line 18 handles the installation.
If extra safety is desired, replace lines 115-130 with:
```bash
command -v butane >/dev/null || aba_abort "butane not found despite cli-install. Check ~/bin/ and PATH."
```


---

## Bug #770: `day2.sh` — unnecessary `$(echo ...)` for literal string assignment

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Cosmetic (wasteful — spawns a subshell for a literal string)
- **Component**: `scripts/day2.sh` line 224
- **Found by**: Code review

### Symptom

```bash
latest_working_dir=$(echo mirror/data/working-dir)
```

This spawns a subshell just to echo a literal string. Should be a direct assignment:

```bash
latest_working_dir=mirror/data/working-dir
```

The `$(echo ...)` was likely a remnant from when this was a dynamic path (e.g.,
`$(echo mirror/data/working-dir/*/)`), but was simplified without removing the
subshell wrapper.


---

## Bug #771: `tui-cluster.sh` — inconsistent indentation within `case "$choice"` block

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Cosmetic (mixed 1-tab and 2-tab indentation for case labels)
- **Component**: `tui/v2/tui-cluster.sh` lines 909-989
- **Found by**: Code review

### Symptom

Within `_cluster_page_basics()`, the `case "$choice" in` statement (line 909) is at
2-tab indent level. But case labels within it use inconsistent indentation:

```bash
		case "$choice" in                # 2 tabs
	N)                                    # 1 tab (wrong)
		while :; do                       # 2 tabs
			...
		D)                                # 2 tabs (correct)
			while :; do                   # 3 tabs
	T)                                    # 1 tab (wrong)
		case "$cl_type" in               # 2 tabs
	P)                                    # 1 tab (wrong)
```

Labels `N)`, `T)`, `P)`, `W)` use 1 tab while `D)` uses 2 tabs. The inner code
for each label is also at different indent levels.

### Fix

Align all case labels and their bodies to a consistent indentation level
(2 tabs for labels, 3 tabs for body, matching `D)`).


---

## Bug #772: `let` used for arithmetic instead of `$(( ))` — same risk as `(( var++ ))`

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Medium (functional — `let expr` returns exit code 1 when result is 0, crashing under ERR trap)
- **Component**: Multiple scripts (systemic)
- **Found by**: Code review

### Symptom

The project coding standard prohibits `(( var++ ))` because when `var` is 0, `(( 0 ))`
returns exit code 1, crashing under `set -e` or an ERR trap. The same problem applies
to the `let` builtin:

```bash
let i=$i+1        # when i=-1: result is 0, exit code 1 → crash under ERR trap
let pause=$pause+$backoff  # if both are 0: result is 0 → exit code 1
```

Affected files:
- `scripts/include_all.sh` lines 1298-1299: `let pause=$pause+$backoff` and `let count=$count+1`
- `scripts/cluster-startup.sh` line 135: `let i=$i+$pause`
- `scripts/vmw-create.sh` line 151: `let i=$i+1`
- `scripts/kvm-create.sh` line 137: `let i=$i+1`

While these specific instances may not hit the zero-result case in practice (pause
starts at a positive value, i starts at 0 and increments), `let` has the same
fundamental exit-code-zero-equals-failure behavior as `(( ))`, and is inconsistent
with the project standard of using `var=$(( var + 1 ))`.

### Fix

Replace all `let` expressions with `$(( ))` assignments:
```bash
pause=$(( pause + backoff ))
count=$(( count + 1 ))
i=$(( i + 1 ))
i=$(( i + pause ))
```


---

## Bug #773: `day2.sh` — always-true conditional wrapping 140-line block

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (misleading code — conditional can never be false)
- **Component**: `scripts/day2.sh` lines 224, 228
- **Found by**: Code review

### Symptom

```bash
latest_working_dir=$(echo mirror/data/working-dir)   # line 224

if [ "$latest_working_dir" ]; then                     # line 228
    # ... 140 lines of code ...
else
    # ... warning messages ...                          # lines 357-369
fi
```

Line 224 assigns a literal string via `$(echo ...)` (see Bug #770). Since the value
is always `mirror/data/working-dir`, the `if [ "$latest_working_dir" ]` test on line
228 is always true. The `else` branch (lines 357-369) is dead code.

This was likely a remnant from when `latest_working_dir` was dynamically computed
(e.g., `$(ls -td mirror/data/working-dir/*/ | head -1)`), and the conditional was
meaningful. When the code was simplified to a static path, the dynamic computation
was replaced with a literal but the conditional was not removed.

### Fix

1. Replace line 224 with: `latest_working_dir=mirror/data/working-dir`
2. Remove the `if [ "$latest_working_dir" ]` conditional on line 228
3. Remove the `else` block (lines 357-369) or convert it to a comment explaining
   the expected failure scenario
4. Remove the closing `fi` on line 370


---

## Bug #774: Duplicate word "the the" in two scripts

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Cosmetic (typo in code comment)
- **Component**: `scripts/create-install-config.sh` line 65, `scripts/create-agent-config.sh` line 105
- **Found by**: Code review

### Symptom

Both files contain the same comment with a doubled word:

```bash
# Set the rendezvous_ip to the the first master's ip
```

### Fix

```bash
# Set the rendezvous_ip to the first master's ip
```


---

## Bug #775: `day2.sh` — space indentation in CatalogSource `case` block

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Cosmetic (violates project tab-only indentation style)
- **Component**: `scripts/day2.sh` lines 277-280
- **Found by**: Code review

### Symptom

Within the CatalogSource name normalization `case` block:

```bash
		case "$cs_name" in
    			redhat-operator)	cs_name="redhat-operators" ;;
    			certified-operator)	cs_name="certified-operators" ;;
    			community-operator)	cs_name="community-operators" ;;
		esac
```

Lines 277-279 use a mix of spaces and tabs (4 spaces + 3 tabs) while the `case`
and `esac` lines use pure tabs. This is a copy-paste artifact.

### Fix

Replace mixed indentation with 3 tabs (matching the surrounding code).


---

## Bug #776: `aba.sh` — broken indentation in `--debug` and `--light` elif blocks

**Status:** OPEN — code review

- **Status:** VERIFIED (code review)
- **Severity**: Low (cosmetic/confusing — functionally correct since bash ignores indentation)
- **Component**: `scripts/aba.sh` lines 391-397
- **Found by**: Code review

### Symptom

```bash
	elif [ "$1" = "--debug" -o "$1" = "-D" ]; then   # 1 tab (correct)
	export INFO_ABA=1                                  # 0 tabs (wrong!)
	shift                                              # 0 tabs (wrong!)
elif [ "$1" = "--light" ]; then                        # 0 tabs (wrong!)
	export opt_light="--light"                         # 1 tab (wrong!)
	shift                                              # 1 tab (wrong!)
	elif [ "$1" = "ocp-versions" ...                   # 1 tab (correct again)
```

Lines 392-397 have lost their indentation relative to the enclosing `while` loop
and surrounding `elif` blocks (which use 1-tab for elif, 2-tab for body). The
`--debug` body is at 0 tabs, `--light` elif is at 0 tabs with 1-tab body.

This looks like copy-paste damage. While bash doesn't care about indentation,
this makes the code structure very hard to read and could lead to maintenance errors.

### Fix

Re-indent to match the surrounding pattern:
```bash
	elif [ "$1" = "--debug" -o "$1" = "-D" ]; then
		export INFO_ABA=1
		shift
	elif [ "$1" = "--light" ]; then
		export opt_light="--light"
		shift
```


## Bug #777: `tui-cluster.sh` — inconsistent indentation in Day-2 menu case block

**Status:** OPEN — cosmetic indentation inconsistency still present in tui-cluster.sh Day-2 menu case block

**Severity:** Cosmetic (code review)
**Component:** TUI — `tui/v2/tui-cluster.sh`
**Symptom:**

Lines 2057, 2105-2107 in the Day-2 menu `case` block:

```bash
		"U" "Upgrade cluster (beta)" \
		"G" "Graceful cluster shutdown" \
		"T" "Graceful cluster startup" \
	"" "──── Cleanup ──────────────────────" \      # 1 tab (should be 3)
		"C" "Clean (remove artifacts, retry install)" \
		"K" "Delete cluster" \
...
	case "$choice" in
		R) _day2_run "day2" ;;
		...
		U) _day2_upgrade ;;
	G) _day2_shutdown ;;    # 1 tab (should be 2)
	T) _day2_startup ;;     # 1 tab (should be 2)
	C) _day2_clean ;;       # 1 tab (should be 2)
		K) _day2_delete ;;
```

The Cleanup separator (L2057) is at 1-tab but surrounding items use 3-tab.
The `case` handlers for G, T, C (L2105-2107) are at 1-tab but R, N, O, S, H, U, K
use 2-tab. This is inconsistent within the same `case` block.

### Fix

Align all menu items and case handlers to match surrounding indentation.


## Bug #778: `verify-config.sh` — deprecated `-a` operator in test conditionals

**Status:** OPEN — deprecated `-a` on lines 34, 35, 39 and `-o` on line 97 still present

**Severity:** Low (code review, systemic)
**Component:** Core — `scripts/verify-config.sh`
**Symptom:**

Lines 34, 35, 39 use deprecated `-a` (AND) operator inside `[ ]`:

```bash
[ $num_masters -eq 1 -a $num_workers -eq 0 ] && SNO=1       # L34
[ $num_masters -ne 1 -a $num_masters -ne 3 ]                  # L35
if [ $num_masters -eq 1 -a $num_workers -ne 0 ]; then         # L39
```

Additionally, all numeric variables (`$num_masters`, `$num_workers`) are unquoted,
risking a syntax error if they're ever empty.

Line 97 also has deprecated `-o` operator:
```bash
[ "$api_vip" -o "$ingress_vip" ] && \
```

These are instances of Bug #707 (deprecated `-a`/`-o` operators).

### Fix

Use `[[ ]]` with `&&`/`||`, or chain separate `[ ]` tests. Quote variables.


## Bug #779: `verify-config.sh` — typo "endpoiont" (two instances)

**Status:** OPEN — "endpoiont" typo still present on lines 73 and 79

**Severity:** Cosmetic (typo, user-facing)
**Component:** Core — `scripts/verify-config.sh`
**Symptom:**

Line 73: `aba_abort "Ingress endpoiont: api_vip must be defined..."`
Line 79: `aba_info "Ingress endpoiont: ingress_vip=$ingress_vip is defined"`

"endpoiont" should be "endpoint" — these messages are user-facing.

### Fix

```bash
s/endpoiont/endpoint/g
```


## Bug #780: `verify-config.sh` — unquoted `$actual_ip_of_api` in `replace-value-conf`

**Status:** LOW RISK — unquoted vars on lines 69 and 89 confirmed; IP addresses won't contain spaces in practice

**Severity:** Low (code review)
**Component:** Core — `scripts/verify-config.sh`
**Symptom:**

Line 69: `replace-value-conf -n api_vip -v $actual_ip_of_api cluster.conf`
Line 89: `replace-value-conf -n ingress_vip -v $actual_ip_of_ingress cluster.conf`

Both `$actual_ip_of_api` and `$actual_ip_of_ingress` are unquoted. If `dig`
returns multiple lines (e.g., round-robin DNS), word splitting would cause
unexpected behavior. This is a systemic quoting issue.

### Fix

Quote the variables: `-v "$actual_ip_of_api"`.


## Bug #781: `init.sh` — unquoted `$PREFIX` in `source` and `cp` commands

**Status:** LOW RISK — unquoted `$PREFIX` on lines 6 and 10; PREFIX is hardcoded `/opt/aba` (no spaces)

**Severity:** Low (code review)
**Component:** Core — `scripts/init.sh`
**Symptom:**

Lines 6, 10:
```bash
source $PREFIX/scripts/include_all.sh
cp $PREFIX/templates/aba.conf .
```

`$PREFIX` is `/opt/aba` (hardcoded, no spaces), so this works in practice.
However, unquoted variable expansion is inconsistent with project standards.

### Fix

Quote: `source "$PREFIX/scripts/include_all.sh"`.


## Bug #782: `wait-agent-up.sh` — `eval` with unquoted `$@` in `cluster-config.sh` call

**Status:** OPEN — `eval $(scripts/cluster-config.sh $@ || exit 1)` pattern still present on line 12

**Severity:** Medium (code review, functional risk)
**Component:** Core — `scripts/wait-agent-up.sh`
**Symptom:**

Line 12: `eval $(scripts/cluster-config.sh $@ || exit 1)`

This has two issues:
1. `$@` is unquoted, so arguments with spaces will be split (instance of Bug #739)
2. `eval $(cmd || exit 1)` is the problematic pattern where `|| exit 1` executes
   inside the subshell, not in the outer shell (instance of Bug #744)

Additionally, line 15: `[ ! -f $ASSETS_DIR/rendezvousIP ]` has unquoted `$ASSETS_DIR`.
Line 22: `AGENT_IP=$(cat $ASSETS_DIR/rendezvousIP)` — unquoted.
Line 42: `echo_red "[ABA] Agent not detected"` — raw color function (instance of Bug #724).

### Fix

Use `eval "$(scripts/cluster-config.sh "$@")" || exit 1` and quote variables.


## Bug #783: `oc-command.sh` — `eval oc $cmd` allows arbitrary command injection

**Status:** LOW RISK — `eval oc $cmd` still on line 28; operator tool only, not user-facing web service

**Severity:** Medium (code review, security risk)
**Component:** Core — `scripts/oc-command.sh`
**Symptom:**

Line 28: `eval oc $cmd`

`$cmd` comes from user input (`$*` on line 13: `cmd="$*"`). Using `eval` with
user-provided input is dangerous — shell metacharacters in the arguments would
be interpreted. For example:
```bash
aba run --cmd 'get pods; rm -rf /'
```
would execute `oc get pods` AND `rm -rf /`.

While this is an operator tool (not a web-facing service), the `eval` is
unnecessary for the intended use case.

### Fix

Replace `eval oc $cmd` with `oc $cmd` (word-splitting on `$cmd` is actually desired
here for multi-word oc subcommands, but `eval` adds unnecessary metachar expansion).
Or better: pass arguments as an array.


## Bug #784: `check-cluster-installed.sh` — raw `echo_red` instead of `aba_abort`

**Status:** OPEN — `echo_red` still used on lines 9-10 instead of `aba_abort`

**Severity:** Cosmetic (code review)
**Component:** Core — `scripts/check-cluster-installed.sh`
**Symptom:**

Lines 9-10:
```bash
echo_red "This cluster has already been deployed successfully!" && \
echo_red "Run 'aba clean; aba install' to re-install..." && exit 1
```

Uses raw `echo_red` color function instead of `aba_abort` or `aba_warning`.
This is an instance of Bug #724 (inconsistent logging functions).

### Fix

Use `aba_abort "This cluster has already been deployed..."`.


## Bug #785: `cluster-info.sh` — raw `echo_red` for error message

**Status:** OPEN — `echo_red` still used on line 16 instead of `aba_abort`

**Severity:** Cosmetic (code review)
**Component:** Core — `scripts/cluster-info.sh`
**Symptom:**

Line 16: `[ -z "$kc" ] && echo_red "Cluster not ready!..." && exit 1`

Uses raw `echo_red` instead of `aba_abort`. Instance of Bug #724.

### Fix

Use `aba_abort`.


## Bug #786: `configure-pxe.sh` — typo "nuse" in comment

**Status:** OPEN — "not in nuse" typo still present on line 2

**Severity:** Cosmetic (typo)
**Component:** Core — `scripts/configure-pxe.sh`
**Symptom:**

Line 2: `# Create PXE env (not in nuse)` — "nuse" should be "use".

### Fix

`# Create PXE env (not in use)`


## Bug #787: `add-operators-to-imageset.sh` — space indentation on line 166

**Status:** OPEN — mixed spaces+tabs on line 166 still present

**Severity:** Cosmetic (code review)
**Component:** Core — `scripts/add-operators-to-imageset.sh`
**Symptom:**

Line 166: `    	if [ "$catalog_file_errors" ]; then`

This line uses mixed spaces and tabs (4 spaces + 1 tab) while surrounding code
uses consistent tab indentation. Also, line 127 (`local comment=""`) is at 1-tab
inside `add_op()` but should be at 2-tabs to match the containing `if` block.

### Fix

Use consistent tab indentation.


## Bug #788: `add-operators-to-imageset.sh` — `eval` to expand array is fragile

**Status:** LOW RISK — `eval echo '${'$catalog'[@]}'` on line 284; works for operator names in practice

**Severity:** Low (code review, functional risk)
**Component:** Core — `scripts/add-operators-to-imageset.sh`
**Symptom:**

Line 284: `list=$(eval echo '${'$catalog'[@]}')`

This uses `eval` to indirectly expand an array variable. While it works, it is
fragile — if operator names contain shell metacharacters, `eval echo` would
interpret them. Bash namerefs (`declare -n`) would be safer.

### Fix

```bash
declare -n list_ref="$catalog"
list="${list_ref[@]}"
```


## Bug #789: `add-operators-to-imageset.sh` — unquoted `$op_sets` in `echo` pipe

**Status:** LOW RISK — unquoted `$op_sets` still present; operator set names don't contain glob chars

**Severity:** Low (code review)
**Component:** Core — `scripts/add-operators-to-imageset.sh`
**Symptom:**

Line 186: `if echo $op_sets | grep -qe ...` — unquoted `$op_sets` means glob
expansion could occur if the value contains `*` or `?`.
Line 204: `for op_set_name in $(echo $op_sets | tr "," " ")` — same issue.
Line 248: `for op in $(echo $ops | tr "," " ")` — same issue.

### Fix

Quote: `echo "$op_sets"`, `echo "$ops"`.


## Bug #790: `vmw-create.sh` — `eval $cmd` with unquoted variable for govc command

**Status:** OPEN — `eval $cmd` with unquoted variable still present on line 139

**Severity:** Medium (code review, functional risk)
**Component:** Core — `scripts/vmw-create.sh`
**Symptom:**

Line 138-139:
```bash
cmd="govc vm.network.add -vm $vm_name -net.adapter vmxnet3 -net.address '$sub_mac'"
aba_debug Running: $cmd; eval $cmd
```

The `$cmd` variable contains single-quoted `'$sub_mac'` which requires `eval` to
interpret. However, `eval $cmd` with an unquoted variable is dangerous — if
`$vm_name` or `$sub_mac` contain shell metacharacters, they'd be interpreted.

Additionally, `aba_debug Running: $cmd` has unquoted `$cmd`.

Line 151: `let i=$i+1` — instance of Bug #772 (`let` with arithmetic risk).

### Fix

Avoid `eval` — call `govc` directly:
```bash
govc vm.network.add -vm "$vm_name" -net.adapter vmxnet3 -net.address "$sub_mac"
```


## Bug #791: `verify-release-image.sh` — unquoted `$openshift_install_mirror` in file test

**Status:** LOW RISK — unquoted `$openshift_install_mirror` on lines 51 and 69; path constructed from safe values

**Severity:** Low (code review)
**Component:** Core — `scripts/verify-release-image.sh`
**Symptom:**

Line 51: `if [ ! -x $openshift_install_mirror ]; then`

`$openshift_install_mirror` is constructed from `$ocp_version`, `$reg_host`,
`$reg_port` — normally safe, but unquoted variable in a test conditional is
inconsistent with project standards.

Line 69: `[ -x openshift-install ] && mv openshift-install $openshift_install_mirror`
— also unquoted.

### Fix

Quote: `[ ! -x "$openshift_install_mirror" ]`.


## Bug #792: `install-pull-secret.sh` — unquoted `$pull_secret_file` in file test and grep

**Status:** LOW RISK — unquoted `$pull_secret_file` on lines 16, 18, 20; paths unlikely to contain spaces

**Severity:** Low (code review)
**Component:** Core — `scripts/install-pull-secret.sh`
**Symptom:**

Line 16: `if [ -s $pull_secret_file ]; then`
Line 18: `if grep -q registry.redhat.io $pull_secret_file; then`
Line 20: `if jq empty $pull_secret_file; then`

All three have unquoted `$pull_secret_file`. If the file path contains spaces
(unlikely but possible in user config), these would fail.

### Fix

Quote all instances: `"$pull_secret_file"`.


## Bug #793: `reg-create-imageset-config.sh` — deprecated `-o` operator and unquoted vars

**Status:** DUPLICATE — instance of Bug #707; deprecated `-o` still present on line 53

**Severity:** Low (code review)
**Component:** Core — `scripts/reg-create-imageset-config.sh`
**Symptom:**

Line 53: `[ ! "$ocp_channel" -o ! "$ocp_version" ]` — deprecated `-o` operator
(instance of Bug #707).

Line 55: `export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)` — unquoted
`$ocp_version`.

### Fix

Replace `-o` with `||` pattern, quote variables.


## Bug #794: `ssh-rendezvous.sh` — deprecated `-a` operator and unquoted variables

**Status:** OPEN — deprecated `-a` on line 8 and unquoted `$ssh_key_file`, `$ip`, `$*` on lines 22-25

**Severity:** Low (code review)
**Component:** Core — `scripts/ssh-rendezvous.sh`
**Symptom:**

Line 8: `[ -f aba.conf -a ! -L aba.conf ]` — deprecated `-a` (instance of Bug #707).

Line 22: `ssh -F ~/.aba/ssh.conf -i $ssh_key_file core@$ip -- $*`
Line 25: `ssh -F ~/.aba/ssh.conf -i $ssh_key_file core@$ip`

`$ssh_key_file`, `$ip`, and `$*` are all unquoted. `$*` is especially risky — if
the user passes arguments with spaces, they'll be word-split. Use `"$@"` instead.

### Fix

Quote variables and use `"$@"` instead of `$*`.


## Bug #795: `monitor-bootstrap.sh` — `eval` with unquoted `$@` in `cluster-config.sh` call

**Status:** OPEN — `eval $(scripts/cluster-config.sh $@ || exit 1)` on line 12; echo_yellow/echo_red on L32, L52-53

**Severity:** Medium (code review, functional risk)
**Component:** Core — `scripts/monitor-bootstrap.sh`
**Symptom:**

Line 12: `eval $(scripts/cluster-config.sh $@ || exit 1)`

Same two issues as Bug #782:
1. `$@` is unquoted (instance of Bug #739)
2. `eval $(cmd || exit 1)` problematic pattern (instance of Bug #744)

Line 20: `[ ! -f $ASSETS_DIR/rendezvousIP ]` — unquoted `$ASSETS_DIR`.
Line 22: `no_proxy="$(cat $ASSETS_DIR/rendezvousIP),$no_proxy"` — unquoted.
Line 31: `exec_cmd="openshift-install ... --dir $ASSETS_DIR $opts"` — unquoted vars.
Line 32: `echo_yellow "[ABA] Running: $exec_cmd"` — raw color function (Bug #724).
Line 52: `echo_red "[ABA] Something went wrong..."` — raw color function (Bug #724).
Line 53: `echo_yellow "[ABA] Reason: ..."` — raw color function (Bug #724).

### Fix

Use `eval "$(scripts/cluster-config.sh "$@")" || exit 1`, quote variables,
replace raw color functions with `aba_info`/`aba_warning`/`aba_abort`.


## Bug #796: `monitor-bootstrap.sh` — space indentation in associative array

**Status:** OPEN — 4-space indentation in `declare -A wait_for_exit_reasons` on lines 40-47

**Severity:** Cosmetic (code review)
**Component:** Core — `scripts/monitor-bootstrap.sh`
**Symptom:**

Lines 40-47: The `wait_for_exit_reasons` associative array uses 4-space
indentation instead of project-standard tabs:

```bash
declare -A wait_for_exit_reasons=(
    [3]="Installation configuration error"
    [4]="Infrastructure failed"
```

### Fix

Use tab indentation.


## Bug #797: `aba-get-version.sh` — multiple deprecated patterns

**Status:** OPEN — backticks (L41), `which` (L46), `expr` (L41), UUOC (L36,43), unquoted vars throughout

**Severity:** Low (code review, systemic)
**Component:** Core — `scripts/aba-get-version.sh`
**Symptom:**

Line 5: `dir=$(dirname $0)` — unquoted `$0`.
Line 6: `cd $dir` — unquoted `$dir`.
Line 31: Long `curl` line with unquoted `$tmp_dir` inside the URL.
Line 36: UUOC: `cat $tmp_dir/.release.txt | grep ...` — use `grep ... $tmp_dir/.release.txt`.
Line 40: `echo $stable_ver | grep | cut` — unquoted.
Line 41: Backticks: `` stable_ver_point=`expr ...` `` (instance of Bug #763).
Also uses `expr` (instance of Bug #728/757).
Line 43: `cat $tmp_dir/.release.txt| grep ...` — UUOC, missing space before pipe.
Line 46: `which openshift-install` — should use `command -v` (instance of Bug #709).

The script also appears to have large commented-out blocks (lines 56-86), suggesting
it may be partially deprecated/abandoned code.

### Fix

Quote variables, use `$()` instead of backticks, `command -v` instead of `which`,
remove commented-out code.


## Bug #798: `vmw-upload.sh` — deprecated backticks in `eval` call

**Status:** OPEN — backtick eval on line 22 still present

**Severity:** Low (code review)
**Component:** Core — `scripts/vmw-upload.sh`
**Symptom:**

Line 22: `` eval `scripts/cluster-config.sh || exit 1` ``

Uses backticks instead of `$()` (instance of Bug #763) and the problematic
`eval $(cmd || exit 1)` pattern (instance of Bug #744).

Line 30: `echo Uploading image $ASSETS_DIR/agent.$ARCH.iso ...` — raw `echo`
with unquoted variables instead of `aba_info` (Bug #724).

### Fix

Use `eval "$(scripts/cluster-config.sh)" || exit 1` and `aba_info`.


## Bug #799: `reg-existing-create-pull-secret.sh` — `read` without `-r` flag

**Status:** OPEN — `read -p` (L13) and `read -sp` (L16) both missing `-r` flag

**Severity:** Low (code review)
**Component:** Core — `scripts/reg-existing-create-pull-secret.sh`
**Symptom:**

Line 13: `read -p "Enter username [init]: " reg_user`
Line 16: `read -sp "Enter password: " reg_pw`

Both `read` calls are missing the `-r` flag. If the user types a backslash in
their username or password, it will be treated as a line continuation rather
than a literal character. This is an instance of Bug #741.

Line 27: `podman login ... $reg_host:$reg_port` — unquoted variables.

### Fix

Add `-r` flag: `read -rp "..."`.


## Bug #800: `ask.sh` — unquoted `$@` in function call

**Status:** OPEN — `ask $@` on line 8 instead of `ask "$@"`

**Severity:** Low (code review)
**Component:** Core — `scripts/ask.sh`
**Symptom:**

Line 8: `ask $@`

`$@` should be quoted as `"$@"` to preserve argument boundaries. If the prompt
message contains spaces, this would cause word splitting.

### Fix

`ask "$@"`


## Bug #801: `check-macs.sh` — space indentation throughout entire file

**Status:** OPEN — 8-space indentation used throughout instead of tabs

**Severity:** Cosmetic (code review)
**Component:** Core — `scripts/check-macs.sh`
**Symptom:**

The entire file uses 8-space indentation instead of tabs. Lines 9, 13-14, 21-22,
27-31, etc. all use spaces. This is inconsistent with the project standard of
tab-only indentation.

### Fix

Convert all indentation from spaces to tabs.


## Bug #802: `ensure-cli.sh` — space indentation throughout entire file

**Status:** OPEN — 4-space indentation in case block (lines 13-53)

**Severity:** Cosmetic (code review)
**Component:** Core — `scripts/ensure-cli.sh`
**Symptom:**

Lines 13-53 use 4-space indentation inside the `case` block instead of tabs.
Inconsistent with project standard.

### Fix

Convert indentation from spaces to tabs.


## Bug #803: `vmw-create.sh` — typo "hirerachy" in comment

**Status:** OPEN — "hirerachy" typo still present on line 65

**Severity:** Cosmetic (typo)
**Component:** Core — `scripts/vmw-create.sh`
**Symptom:**

Line 65: `scripts/vmw-create-folder.sh "$cluster_folder"  # This will create a folder hirerachy, if needed`

"hirerachy" should be "hierarchy".

### Fix

`# This will create a folder hierarchy, if needed`


## Bug #804: `tui-cluster.sh` — inconsistent indentation in `_day2_upgrade` DISCO case

**Status:** OPEN — indentation inconsistency in `_day2_upgrade` DISCO case block still present

**Severity:** Cosmetic (code review)
**Component:** TUI — `tui/v2/tui-cluster.sh`
**Symptom:**

Lines 2285-2287 in the `_day2_upgrade` function's `case "$_TUI_MODE"`:

```bash
		case "$_TUI_MODE" in
			CONNO)                    # 3 tabs
				_upgrade_hint="..."   # 4 tabs
				;;
	DISCO)                            # 1 tab (should be 3)
		_upgrade_hint="..."           # 2 tabs (should be 4)
		;;
			*)                        # 3 tabs
```

`DISCO)` and its body are at 1-tab/2-tab while `CONNO)` and `*)` are at
3-tab/4-tab. This is an instance of the systemic indentation inconsistency
in `case` blocks (related to Bug #762).

### Fix

Align `DISCO)` to match `CONNO)` at 3-tab with 4-tab body.


## Bug #805: `install-pull-secret.sh` — FIXME comment suggests script may be redundant

**Status:** OPEN — FIXME on line 3 still present; script only validates, doesn't install

**Severity:** Low (code review, documentation)
**Component:** Core — `scripts/install-pull-secret.sh`
**Symptom:**

Line 3: `# FIXME: Does this script do anything, other than verify?`

The developer's own FIXME suggests uncertainty about the script's purpose.
The script only validates the pull secret file — it doesn't install anything
despite the name "install-pull-secret.sh". This is misleading.

### Fix

Either rename to `verify-pull-secret.sh` or remove the FIXME if the current
behavior is correct by design.


## Bug #806: `aba-get-version.sh` — script appears mostly abandoned

**Status:** OPEN — lines 56-86 commented out; interactive selection loop disabled

**Severity:** Low (code review, maintenance)
**Component:** Core — `scripts/aba-get-version.sh`
**Symptom:**

Lines 56-86 are entirely commented out (the interactive version selection loop).
The script now only fetches and displays versions but doesn't actually set them.
The filename suggests it should "get" (select/set) a version, but it only prints
available versions.

The script has no header contract and multiple stale patterns (backticks, `which`,
`expr`, UUOC, unquoted vars).

### Fix

Either restore the interactive functionality, rename to clarify its role
(e.g. `show-ocp-versions.sh`), or remove if superseded by TUI version picker.


## Bug #807: `. <(echo $* | tr " " "\n")` pattern — code injection via sourcing user input

**Status:** OPEN — pattern still present in vmw-start.sh:10, vmw-stop.sh:10, kvm-start.sh:10, kvm-stop.sh:10

**Severity:** Medium (code review, security/robustness)
**Component:** Core — `scripts/vmw-start.sh`, `vmw-stop.sh`, `kvm-start.sh`, `kvm-stop.sh`
**Symptom:**

Multiple scripts (vmw-start.sh:10, vmw-stop.sh:10, kvm-start.sh:10, kvm-stop.sh:10)
use this pattern:

```bash
. <(echo $* | tr " " "\n")
```

This converts space-delimited `key=val` arguments into newline-separated
assignments and sources them into the current shell. Problems:
1. `$*` is unquoted — glob expansion can occur
2. Any argument could inject arbitrary bash code (e.g., `workers=$(rm -rf /)`)
3. This bypasses the safer `process_args` function (which is also called on L9)

The pattern appears to be a legacy workaround for extracting `workers=1` or
`masters=1` from the command line.

### Fix

Remove the `. <(echo $* ...)` line and rely exclusively on `process_args` for
argument parsing.


## Bug #808: `vmw-delete.sh` — deprecated backticks in `eval` call

**Status:** OPEN — backtick eval on line 21 still present

**Severity:** Low (code review)
**Component:** Core — `scripts/vmw-delete.sh`
**Symptom:**

Line 21: `` eval `scripts/cluster-config.sh || exit 1` ``

Uses backticks instead of `$()` (instance of Bug #763) and the problematic
`eval $(cmd || exit 1)` pattern (instance of Bug #744).

Line 36: `echo $cluster_folder/$vm` — unquoted variables.
Line 63-65: `exec_cmd="govc object.destroy $cluster_folder"` / `$exec_cmd` — unquoted
variable execution.

### Fix

Use `eval "$(scripts/cluster-config.sh)" || exit 1` and quote variables.


## Bug #809: `kvm-upload.sh` — raw `echo_red` instead of `aba_abort`

**Status:** OPEN — `echo_red` on line 34 instead of `aba_abort`

**Severity:** Cosmetic (code review)
**Component:** Core — `scripts/kvm-upload.sh`
**Symptom:**

Line 34: `echo_red "ISO file failed to upload to KVM host!"`

Uses raw `echo_red` instead of `aba_abort`. Instance of Bug #724.

### Fix

Use `aba_abort "ISO file failed to upload to KVM host!"`.


## Bug #810: `vmw-upload.sh` — raw `echo` for user-facing message

**Status:** OPEN — raw `echo Uploading image ...` with unquoted vars on line 30

**Severity:** Cosmetic (code review)
**Component:** Core — `scripts/vmw-upload.sh`
**Symptom:**

Line 30: `echo Uploading image $ASSETS_DIR/agent.$ARCH.iso to [$ISO_DATASTORE] ...`

Uses raw `echo` with unquoted variables instead of `aba_info`. Instance of Bug #724.

### Fix

Use `aba_info "Uploading image ..."`.


## Bug #811: `reg-existing-create-pull-secret.sh` — password visible in process table

**Status:** LOW RISK — `echo -n` on line 19; bash `echo` is a builtin so not visible in process table in practice

**Severity:** Medium (security, code review)
**Component:** Core — `scripts/reg-existing-create-pull-secret.sh`
**Symptom:**

Line 19: `export enc_password=$(echo -n "$reg_user:$reg_pw" | base64 -w0)`

The password is passed to `echo` as a command-line argument, making it visible
in `/proc/$pid/cmdline` (process table). While bash's `echo` is typically a
builtin (invisible to `ps`), this is fragile — if `echo` is aliased or overridden,
the password leaks.

This is similar to Bug #742 (password exposure via command arguments).

### Fix

Use `printf '%s' "$reg_user:$reg_pw" | base64 -w0` which is always a builtin.


## Bug #812: `listopdeps.sh` — multiple deprecated patterns and suppressed stderr

**Status:** OPEN — `which podman &>/dev/null` on line 36, unquoted vars, UUOC still present

**Severity:** Low (code review, systemic)
**Component:** Core — `scripts/listopdeps.sh`
**Symptom:**

Line 36: `! which podman &>/dev/null` — uses `which` (should be `command -v`,
instance of Bug #709) and `&>/dev/null` which suppresses stderr (violates
stderr suppression rule for non-guard checks).

Line 46-47: `podman stop $existing_id >/dev/null` — unquoted `$existing_id`.
Line 47: `podman rm $existing_id >/dev/null` — same.
Line 53: `podman create ... >/dev/null|| exit 1` — missing space before `||`.
Line 58: `cat configs-$catalog-$version/$operator/catalog.json | jq ...` — UUOC
and unquoted variables.

Line 4: `$(basename $0)` — unquoted `$0`.

The script does not source `include_all.sh` and uses raw `echo` for all output.

### Fix

Use `command -v`, quote variables, remove unnecessary `cat`.


## Bug #813: `cluster-config-check.sh` — deprecated `-o` operator and unquoted vars

**Status:** OPEN — `[ ! -s $ICONF -o ! -s $ACONF ]` on line 14

**Severity:** Low (code review)
**Component:** Core — `scripts/cluster-config-check.sh`
**Symptom:**

Line 14: `if [ ! -s $ICONF -o ! -s $ACONF ]; then`

Uses deprecated `-o` operator (instance of Bug #707) and has unquoted
`$ICONF` and `$ACONF`.

### Fix

Use `[[ ! -s "$ICONF" ]] || [[ ! -s "$ACONF" ]]`.


## Bug #814: `download-catalog-index.sh` — `read` without `-r` in `_extract_from_yaml`

**Status:** FIXED — line 195 now uses `read -r pkg def_ch`

**Severity:** Low (code review)
**Component:** Core — `scripts/download-catalog-index.sh`
**Symptom:**

Line 232: `read pkg def_ch < <(awk ...)`

Missing `-r` flag on `read`. If an operator name or channel contained a backslash,
it would be interpreted as a line continuation. Instance of Bug #741.

### Fix

Use `read -r pkg def_ch < <(...)`.


## Bug #815: TUI missing "Register External Mirror" option — CLI-only workflow

**Status:** FEATURE REQUEST — TUI has no "Register existing registry" option; CLI `aba register` works; enhancement not a defect

**Severity:** Medium (TUI feature gap, functional test)
**Component:** TUI — `tui/v2/tui-mirror.sh`
**Symptom:**

The TUI's `mirror_install()` function (line 364) only offers two options:
1. "Install locally (this host)"
2. "Install on remote host (via SSH)"

There is **no option to register an existing/external mirror registry**.

The CLI workflow `aba -d <mirror> register --pull-secret-mirror <file> --ca-cert <file>`
works correctly (tested: register → verify → uninstall-rejected → unregister → 
re-register → hostname reconciliation all pass). But this entire workflow is
invisible in the TUI.

A user working through the TUI who has an existing registry (e.g., Harbor, Artifactory,
or a registry managed by another team) has no way to register it — they would need
to drop to the CLI, which defeats the purpose of the TUI.

**Tested flows (all pass via CLI):**
- `aba mirror --name exttest` — creates named mirror directory
- `aba -d exttest register --reg-host bastion.example.com --pull-secret-mirror <ps> --ca-cert <ca>` — registers external registry
- `aba -d exttest verify` — confirms connectivity (correctly reports no release image yet)
- `aba -d exttest uninstall` — correctly refuses with "use unregister" message
- `aba -d exttest unregister` — removes local creds, backs up to regcreds.bk/
- Re-register after unregister — works cleanly
- Wrong hostname reconciliation — correctly auto-corrects from pull secret

### Fix

Add a third option to `mirror_install()`:
```
"3" "Register existing registry (already running)"
```
This would prompt for pull secret file path and CA cert file path (or auto-detect
from common locations), then call `aba --dir mirror register ...`.


## Bug #816: `reg-register.sh` — `sed -i` used instead of `replace-value-conf`

**Status:** OPEN — `sed -i` on lines 56-57 and 77-78 instead of `replace-value-conf`

**Severity:** Low (code review, inconsistency)
**Component:** Core — `scripts/reg-register.sh`
**Symptom:**

Lines 56-57 and 77-78:
```bash
sed -i "s/^reg_host=.*/reg_host=$_inferred_host/" mirror.conf
sed -i "s/^reg_port=.*/reg_port=$_inferred_port/" mirror.conf
```

Uses raw `sed -i` instead of the project's `replace-value-conf` function. This
approach strips inline comments from the replaced line (the original template has
comments like `# FQDN of the registry host`).

### Fix

Use `replace-value-conf -q -n reg_host -v "$_inferred_host" -f mirror.conf`.


## Bug #817: `reg-register.sh` — `state.sh` values not quoted

**Status:** OPEN — `reg_host=$reg_host` and `reg_port=$reg_port` written unquoted in state.sh on lines 108-110; missing `reg_user`/`reg_pw` fields

**Severity:** Low (code review, robustness)
**Component:** Core — `scripts/reg-register.sh`
**Symptom:**

Lines 107-112:
```bash
cat > "$regcreds_dir/state.sh" <<-EOF
reg_vendor=existing
reg_host=$reg_host
reg_port=$reg_port
reg_installed_at="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
```

`reg_host` and `reg_port` values are written unquoted. If `reg_host` contained
spaces or special characters, the resulting `state.sh` would be unparseable.
While unlikely for hostnames, this is inconsistent with `reg-common.sh` which
quotes `reg_pw` with single quotes.

Also, the heredoc lacks `reg_user`, `reg_pw`, `reg_ssh_key`, and `reg_ssh_user`
fields that other registry types write (via `reg-common.sh`). This means
`source state.sh` from an "existing" registry gives a different variable
set than from an installed registry, which could break code that assumes
all state.sh files have the same shape.

### Fix

Quote values and include all standard state.sh fields (with empty defaults for
fields that don't apply to external registries).


## Bug #818: `reg-save.sh` / `reg-load.sh` / `reg-sync.sh` — backticks and unquoted variables

**Status:** OPEN — backtick `` `expr $1 + 1` `` still present in reg-save.sh:17, reg-load.sh:30, reg-sync.sh:16

**Severity:** Low (code review, systemic)
**Component:** Core — `scripts/reg-save.sh`, `scripts/reg-load.sh`, `scripts/reg-sync.sh`
**Symptom:**

Multiple instances of deprecated patterns across these three scripts:

1. **Backticks for `expr`**: `reg-save.sh` L17, `reg-load.sh` L30, `reg-sync.sh` L16 all use:
   ```
   try_tot=`expr $1 + 1`
   ```
   Instance of Bug #763 (backticks) and Bug #728/757 (expr).

2. **Unquoted `$pull_secret_file`**: `reg-sync.sh` L61, L64: `[ -s $pull_secret_mirror_file ]`
   and `[ -s $pull_secret_file ]` — risking word splitting if path has spaces.

3. **Unquoted `aba_info` arguments**: `reg-sync.sh` L62: `aba_info Using $pull_secret_mirror_file ...`
   — the arguments are unquoted, risking glob expansion.

4. **Deprecated `-a` operator**: `make-bundle.sh` L127: `[ -d mirror/data -a "$(ls mirror/data 2>/dev/null)" ]`
   — instance of Bug #707.

5. **Typos**: `make-bundle.sh` L81: "behand" (behind), L119: "FIXME MNIssing" (Missing), 
   L129: "Deleteing" (Deleting).

### Fix

Replace backticks with `$(...)`, use `$(( ))` instead of `expr`, and quote variables.


## Bug #819: `make-bundle.sh` — `echo_red`/`echo_cyan`/`echo_magenta` instead of `aba_info`/`aba_warning`/`aba_abort`

**Status:** OPEN — `echo_red` (L179-181), `echo_magenta` (L236-238) still present

**Severity:** Cosmetic (code review)
**Component:** Core — `scripts/make-bundle.sh`
**Symptom:**

Lines 155-161, 168, 179, 189, 247-248: raw color echo functions used instead
of standard ABA logging. Instance of Bug #724.


## Bug #820: `make-bundle.sh` — unquoted `$dest` in file tests and `$file_list` in `tar`

**Status:** LOW RISK — unquoted `$dest` and `$file_list` still present; paths unlikely to contain spaces in practice

**Severity:** Low (code review)
**Component:** Core — `scripts/make-bundle.sh`
**Symptom:**

Lines 39, 42: `[ -d $dest ]`, `[ -s $dest ]` — unquoted variable.
Line 235: `tar cf "${dest}" --transform "s,^${repo_dir},aba," $file_list` — 
while `$dest` is quoted, `$file_list` is unquoted (though intentionally 
word-split for tar arguments). However, paths containing spaces would break.


## Bug #821: `generate-image.sh` — `eval "$config || exit 1"` is broken

**Status:** OPEN — `eval "$config || exit 1"` still present on line 43; `|| exit 1` executes inside eval context

**Severity:** Medium (functional risk)
**Component:** Core — `scripts/generate-image.sh`
**Symptom:**

Line 43: `eval "$config || exit 1"`

The `|| exit 1` is inside the double-quoted string being eval'd, so it applies
to the last command _within_ config output, not to the eval itself. If `config`
contains multiple lines, only the last line's failure triggers exit. If the 
`cluster-config.sh` call on line 26 fails but produces partial output, the
script proceeds with incomplete data.

Also line 104: `$openshift_install_mirror agent create image --dir $ASSETS_DIR $opts`
has unquoted `$ASSETS_DIR` and `$opts`.

Lines 46-58, 106, 116: multiple unquoted `$ASSETS_DIR` in file tests, `rm -rf`, `cp`.

Line 103: `echo_yellow` instead of `aba_info` (Bug #724).

### Fix

Change to:
```bash
eval "$config" || exit 1
```
And quote all variable expansions.


## Bug #822: `create-agent-config.sh` — space indentation throughout

**Status:** OPEN — 2/4-space indentation used in functions (lines 22-99) instead of tabs

**Severity:** Cosmetic (code review)
**Component:** Core — `scripts/create-agent-config.sh`
**Symptom:**

Lines 22-99: functions `to_numeric`, `from_numeric`, `calculate_cidr_range`, 
`generate_ip_array`, `generate_random_hex`, `replace_hash_with_random_hex` all
use 2-space or 4-space indentation instead of tabs.

Line 60: `read -r first_usable last_usable <<< $(...)` — unquoted command substitution
after `<<<`. Should be `<<< "$(calculate_cidr_range "$cidr")"`.

Line 74: `((current_ip++))` — will crash under `set -e` if `current_ip` is 0.
Instance of Bug #772 / project arithmetic rule.

Line 107: `echo $starting_ip` — unquoted variable in pipe.

### Fix

Convert to tab indentation. Quote variables. Use `current_ip=$((current_ip + 1))`.


## Bug #823: `create-install-config.sh` — deprecated `-o` and `-a` operators + unquoted vars

**Status:** OPEN — deprecated `-o` (L57, 96) and `-a` (L76, 230, 235) still present

**Severity:** Low (code review, systemic)
**Component:** Core — `scripts/create-install-config.sh`
**Symptom:**

Line 57: `[ "$platform" = "vmw" -o "$platform" = "kvm" ]` — deprecated `-o` (Bug #707).
Line 76: `[ "$platform" = "bm" -a $hostPrefix -eq 23 ]` — deprecated `-a` (Bug #707) 
and unquoted `$hostPrefix`.
Line 96: `[ "$http_proxy" -o "$https_proxy" ]` — deprecated `-o`.
Line 98, 99, 208: `cat $pull_secret_file | jq .` — unquoted var and UUOC (Bug #728/757).
Lines 150, 157, 174, 220-226: unquoted `$pull_secret_file`, `$ssh_key_file` in 
file tests and `cat` commands.
Line 210: `aba_info Using pull secret file at $pull_secret_file...` — unquoted args.

### Fix

Use `[[ ]]` with `&&`/`||`, quote all variables, use `jq . "$pull_secret_file"`.


## Bug #824: `setup-mirror.sh` / `setup-cluster.sh` — `. <(process_args $*)` with unquoted `$*`

**Status:** LOW RISK — unquoted `$*` in `. <(process_args $*)` on setup-mirror.sh:13 and setup-cluster.sh:15; ABA args never have spaces

**Severity:** Low (code review, robustness)
**Component:** Core — `scripts/setup-mirror.sh` L13, `scripts/setup-cluster.sh` L15,
                 `scripts/create-cluster-conf.sh` (same pattern)
**Symptom:**

Unquoted `$*` in `. <(process_args $*)` — if any argument contained spaces or 
glob characters, it would be split/expanded. Instance of Bug #807 pattern 
(source from process substitution with unquoted arguments).

Also `setup-cluster.sh` L21, L28, L29, L38: unquoted `$name` in `mkdir`, 
file/dir tests.

### Fix

Quote `$*`: `. <(process_args "$@")` (or `"$*"`).


## Bug #825: `reg-verify.sh` — unquoted `$mirrors` in `echo` (line 52)

**Status:** LOW RISK — unquoted `$mirrors` still present on line 52; hostnames won't glob-match in practice

**Severity:** Low (code review)
**Component:** Core — `scripts/reg-verify.sh`
**Symptom:**

Line 52: `$(echo $mirrors | tr '\n' ' ')` — unquoted `$mirrors` in `echo`.
If a hostname glob-matched a file, it would expand.

### Fix

Quote: `$(echo "$mirrors" | tr '\n' ' ')`.


## Bug #826: README.md — broken markdown table row for `aba cluster` command

**Status:** FIXED — line 1305 now uses escaped pipes: `<sno\|compact\|standard>`

**Severity:** Cosmetic (Docbug)
**Component:** Documentation — `README.md`
**Symptom:**

Line 1293:
```
| `aba cluster --name --type <sno | compact                                                       |
```

The `|` character inside `<sno | compact | standard>` is being interpreted as
a markdown table column separator, resulting in a broken row that renders 
incorrectly. The "Description" column is missing.

Should be:
```
| `aba cluster --name <n> --type <sno\|compact\|standard>` | Create a cluster directory and optionally install |
```

### Fix

Escape the pipe characters inside the command: `<sno\|compact\|standard>` or
use backticks to wrap the whole value.


## Bug #827: README.md — no documentation section for the TUI v2 features

**Status:** OPEN — TUI mentioned in passing but no dedicated section explaining navigation, modes, settings, or execution modes

**Severity:** Low (Docbug, documentation gap)
**Component:** Documentation — `README.md`
**Symptom:**

The TUI is mentioned in passing (Quick Start, Install ABA, a few tips throughout),
but the README has no dedicated section explaining:
- How to navigate the TUI (key bindings, ESC to go back, etc.)
- The three TUI modes (CONNO, DISCO, DIRECT) and how they're auto-detected
- The Settings menu (auto-answer, registry vendor, retry count)
- The "Run in TUI" vs "Run in Terminal" execution modes
- How the TUI relates to CLI commands (what it wraps)
- Known TUI limitations (e.g., no "register external mirror" option — Bug #815)

The only TUI-specific doc is `ai/TUI_NAVIGATION_WITH_TMUX_HOWTO.md` (internal).


## Bug #828: README.md — no mention of `aba --verify` or `verify_conf` setting

**Status:** FIXED — README now has "Controlling validation with `verify_conf`" section (line 648) and examples

**Severity:** Low (Docbug, documentation gap)
**Component:** Documentation — `README.md`
**Symptom:**

The pre-flight validation section (line 627) documents the checks (DNS, NTP, IP 
conflicts, vSphere), but doesn't document the `verify_conf` setting in `aba.conf`
or the `--verify` CLI flag that controls which checks are performed.

The only mention is in the pre-flight script itself: "To skip network and vSphere
checks, run: aba --verify conf". Users who encounter false-positive pre-flight
failures (e.g., multi-homed bastions, airgapped NTP) have no documented way to
skip them without reading the source.


## Bug #829: README.md — `aba -d mirror password` undocumented

**Status:** OPEN — listed in Command Reference (L1295) and mentioned at L1153 but no detailed usage docs

**Severity:** Low (Docbug)
**Component:** Documentation — `README.md`
**Symptom:**

The Command Reference table lists `aba -d mirror password` with description
"Regenerate pull secret for existing registry" but there is no further
documentation anywhere in the README explaining:
- When/why you would use this command
- What it actually does (regenerates htpasswd + creates new pull secret)
- Whether it requires the registry to be running
- How it interacts with registered (external) vs installed registries


## Bug #830: `create-agent-config.sh` — `((current_ip++))` crash risk under `set -e`

**Status:** OPEN — `((current_ip++))` still present on line 74; violates project arithmetic rule (latent — IP values never 0)

**Severity:** Low (functional risk, code review)
**Component:** Core — `scripts/create-agent-config.sh`
**Symptom:**

Line 74: `((current_ip++))` — if `current_ip` evaluates to 0 (which won't 
happen in practice for IP addresses, but violates the project's arithmetic rule),
`(( 0 ))` returns exit code 1. The script uses `#!/bin/bash` without `-e` on
the shebang, but `set -e` could be inherited from callers.

This is a theoretical risk since IP numeric values are always > 0, but the 
project rule explicitly bans `(( var++ ))`. Should use:
`current_ip=$((current_ip + 1))`.


## Bug #831: `cluster-config.sh` — pervasive deprecated patterns

**Status:** OPEN — 11+ backtick instances (L74-138), `expr` (L99), space indentation, echo_red all present

**Severity:** Low (code review, systemic)
**Component:** Core — `scripts/cluster-config.sh`
**Symptom:**

This script has the highest density of deprecated patterns in the codebase:

1. **Backticks** on lines 74, 78, 82, 86, 90, 94, 113, 117, 124, 128, 138 — 
   11 instances (Bug #763).

2. **Unquoted variables** on lines 65, 71, 72, 76, 80, 84, 88, 99, 123, 145,
   148-155 — exported vars like `echo export CLUSTER_NAME=$CLUSTER_NAME` 
   should be `echo "export CLUSTER_NAME=\"$CLUSTER_NAME\""`.

3. **UUOC** on lines 71, 72: `cat $ICONF | yaml2json` — use 
   `yaml2json < "$ICONF"`.

4. **Deprecated `-o`** on line 65: `[ ! -s $ICONF -o ! -s $ACONF ]` (Bug #707).

5. **`expr`** on line 99: `expr ${#CP_MAC_ADDRS_ARRAY[@]} / $CP_REPLICAS` 
   (Bug #728/757).

6. **`echo_red`** on lines 148-155, 159-161 — should use `aba_warning` or 
   `aba_abort` (Bug #724).

7. **Space indentation** in functions `yaml2json` (L23-25) and 
   `distribute_macs` (L29-57).

### Fix

Replace all backticks with `$(...)`, quote all variables, use `[[ ]]` with 
`||`, replace `expr` with `$((...))`, use `aba_warning`/`aba_abort`, convert 
to tab indentation.


## Bug #832: `generate-image.sh` — raw `echo_yellow` for user-facing message

**Status:** OPEN — `echo_yellow` (L103) and `echo_cyan` (L31, L34, L37) still used instead of `aba_info`

**Severity:** Cosmetic (code review)
**Component:** Core — `scripts/generate-image.sh`
**Symptom:**

Line 103: `echo_yellow "[ABA] Running: $openshift_install_mirror agent create image..."` 

Uses raw `echo_yellow` instead of `aba_info` (Bug #724). Also includes `[ABA]`
prefix manually instead of letting the logging function add it.

Line 31: `echo_cyan "Cluster configuration"` — same pattern (Bug #724).


## Bug #833: `check-version-mismatch.sh` — UUOC, unquoted vars, raw `echo_red`

**Status:** OPEN — `cat $f | yaml2json` UUOC (L38-40), `echo_red` (L44-51), space indentation (L20-23) all still present

**Severity:** Low (code review, systemic)
**Component:** Core — `scripts/check-version-mismatch.sh`
**Symptom:**

1. Lines 38-40: `cat $f | yaml2json | jq ...` — three UUOC instances (Bug #728/757).
   Use `yaml2json < "$f" | jq ...`.

2. Line 30: `echo $ocp_version | cut -d. -f1-2` — unquoted variable.

3. Line 42: `is_version_greater $aba_ocp_ver "$om_ocp_max_ver"` — partially
   unquoted `$aba_ocp_ver`.

4. Lines 44-51: `echo_red` used for user-facing warnings instead of 
   `aba_warning` (Bug #724).

5. Space indentation in `yaml2json()` function (L20-23).

### Fix

Quote variables, use `aba_warning`, eliminate UUOC, use tab indentation.


## Bug #834: `reset-gate.sh` — `read` without `-r`, deprecated `-o` operator

**Status:** OPEN — `read yn` (L10) missing `-r` and deprecated `-o` (L11) both present

**Severity:** Low (code review)
**Component:** Core — `scripts/reset-gate.sh`
**Symptom:**

Line 10: `read yn` — missing `-r` flag (Bug #741).

Line 11: `[ "$yn" = "y" -o "$yn" = "Y" ]` — deprecated `-o` (Bug #707).

### Fix

Use `read -r yn` and `[[ "$yn" == [yY] ]]`.


## Bug #835: `add_ntp_ignition_to_iso.sh` — unquoted vars, UUOC

**Status:** OPEN — unquoted `$iso_dir` (L22, L26, L49, L53) and UUOC `cat $iso_dir/chrony.conf | base64` (L36) still present

**Severity:** Low (code review)
**Component:** Core — `scripts/add_ntp_ignition_to_iso.sh`
**Symptom:**

Line 22: `$iso_dir/agent.$ARCH.iso` — unquoted in `coreos-installer` argument.

Line 26: `cat > $iso_dir/chrony.conf` — unquoted `$iso_dir`.

Line 36: `cat $iso_dir/chrony.conf | base64 -w 0` — UUOC (Bug #728/757) AND
unquoted `$iso_dir`.

Line 49: `$iso_dir/tmp.ign > $iso_dir/custom_ign.ign` — unquoted paths.

Line 53: `$iso_dir/custom_ign.ign $iso_dir/agent.$ARCH.iso` — unquoted paths.

### Fix

Quote all `"$iso_dir"` expansions. Use `base64 -w 0 < "$iso_dir/chrony.conf"`.


## Bug #836: `install-govc.sh` — `which` instead of `command -v`

**Status:** OPEN — `which govc >/dev/null 2>&1` on line 3

**Severity:** Low (code review)
**Component:** Core — `scripts/install-govc.sh`
**Symptom:**

Line 3: `which govc >/dev/null 2>&1` — uses deprecated `which` (Bug #709).

### Fix

Use `command -v govc >/dev/null 2>&1`.


## Bug #837: `kvm-create.sh` — `let i=$i+1` arithmetic

**Status:** OPEN — `let i=$i+1` still present on line 137; violates project arithmetic rule

**Severity:** Low (code review)
**Component:** Core — `scripts/kvm-create.sh`
**Symptom:**

Line 137: `let i=$i+1` — uses `let` for arithmetic (Bug #772). When `i` is 0,
`let 0+1` evaluates to non-zero so doesn't crash, but `let` itself returns
exit code based on the expression value and is banned by project convention.

### Fix

Use `i=$((i + 1))`.


## Bug #838: `vmw-create-folder.sh` — unquoted variables throughout

**Status:** OPEN — unquoted `$vc_folder` (L14, 19, 25, 30, 34) and `$0` (L4)

**Severity:** Low (code review)
**Component:** Core — `scripts/vmw-create-folder.sh`
**Symptom:**

Line 4: `$(basename $0)` — unquoted `$0`.

Line 14: `echo $vc_folder | grep -q ^/` — unquoted `$vc_folder`.

Lines 19, 25, 30, 34: `govc folder.create $vc_folder` and 
`dirname $vc_folder` — all unquoted.

### Fix

Quote all variables: `"$vc_folder"`, `"$0"`, etc.


## Bug #839: `create-mirror-conf.sh` — deprecated `-o` operator

**Status:** DUPLICATE — `[ ! "$ocp_version" -o ! "$domain" ]` on line 17; instance of Bug #707 (systemic `-o` usage)

**Severity:** Low (code review)
**Component:** Core — `scripts/create-mirror-conf.sh`
**Symptom:**

Line 17: `[ ! "$ocp_version" -o ! "$domain" ]` — deprecated `-o` (Bug #707).

Line 28: `$(basename $PWD)` — unquoted `$PWD`.

### Fix

Use `[[ -z "$ocp_version" || -z "$domain" ]]`. Quote `$(basename "$PWD")`.


## Bug #840: `reg-install-quay.sh` — unquoted variables in SSH and file ops

**Status:** LOW RISK — unquoted SSH vars still present; values are hostnames/paths without spaces in practice

**Severity:** Low (code review)
**Component:** Core — `scripts/reg-install-quay.sh`
**Symptom:**

Lines 27, 33, 34, 35, 39, 40, 42: unquoted `$temp_aba_key`, `$temp_aba_pub_key`,
`$ssh_conf_file`, `$reg_host`, `$flag_file`.

Example L40: `ssh -F $ssh_conf_file -i $temp_aba_key $reg_host touch $flag_file`
— multiple unquoted variables that could contain spaces.

### Fix

Quote all variables in SSH commands and file operations.


## Bug #841: `reg-unregister.sh` — unquoted `$(basename $PWD)` in error msg

**Status:** LOW RISK — unquoted `$(basename $PWD)` on line 24; dir names won't have spaces in ABA

**Severity:** Cosmetic (code review)
**Component:** Core — `scripts/reg-unregister.sh`
**Symptom:**

Line 24: `$(basename $PWD)` — unquoted `$PWD` inside command substitution.

### Fix

Use `$(basename "$PWD")`.


## Bug #842: `install-vmware.conf.sh` — unquoted `aba_debug` args, unquoted vars

**Status:** OPEN — unquoted multi-word args to `aba_debug` (L103, 113, 117, 125) and `aba_info` (L131, 146) still present

**Severity:** Low (code review, systemic)
**Component:** Core — `scripts/install-vmware.conf.sh`
**Symptom:**

Lines 103, 113, 117, 125: `aba_debug` called with unquoted multi-word arguments.
E.g. `aba_debug Checking for $PWD/vmware.conf file ..` — this passes multiple
separate arguments instead of a single string.

Line 146: `aba_info Checking govc config file: $PWD/vmware.conf` — unquoted 
`aba_info` with `$PWD`.

Line 131: `aba_info vmware.conf exists but is empty ...` — unquoted multi-word
argument to `aba_info`.

### Fix

Quote all `aba_debug`/`aba_info` arguments:
`aba_debug "Checking for $PWD/vmware.conf file ..."`.


## Bug #843: `install-kvm.conf.sh` — same unquoted `aba_debug`/`aba_info` pattern

**Status:** OPEN — unquoted args to `aba_debug` (L58, 61, 66, 74) and `aba_info` (L80, 103); also `sed -i` (L91-92) instead of `replace-value-conf`

**Severity:** Low (code review, systemic)
**Component:** Core — `scripts/install-kvm.conf.sh`
**Symptom:**

Lines 58, 61, 66, 74: `aba_debug` with unquoted multi-word arguments.

Lines 80, 103: `aba_info` with unquoted multi-word arguments.

Lines 91-92: `sed -i` used to modify `kvm.conf` instead of `replace-value-conf`
(Bug #816 pattern). This strips inline comments.

### Fix

Quote all `aba_debug`/`aba_info` arguments. Use `replace-value-conf` instead of
`sed -i` for config file modifications.


## Bug #844: `kvm-create.sh` — `2>/dev/null` used to suppress `virsh destroy` error

**Status:** LOW RISK — `virsh destroy ... 2>/dev/null || true` on L134; cosmetic in core scripts

**Severity:** Cosmetic (code review)
**Component:** Core — `scripts/kvm-create.sh`
**Symptom:**

Line 134: `virsh -c "$LIBVIRT_URI" destroy "$vm_name" 2>/dev/null || true`

While `|| true` is present (exit code handled), `2>/dev/null` suppresses stderr
which violates the project rule against suppressing stderr. Use `|| true` alone
to handle expected failure when VM is already off.

### Fix

Remove `2>/dev/null`: `virsh -c "$LIBVIRT_URI" destroy "$vm_name" || true`.

**Note:** This is in core scripts, not test code, and the suppress is on a
known-safe operation (VM already off), so severity is cosmetic. The test-code
rules are stricter.


## Bug #845: `vmw-create-folder.sh` — `govc folder.create` stderr suppressed

**Status:** OPEN — `govc folder.create $vc_folder >/dev/null 2>&1` on line 30 suppresses both stdout and stderr

**Severity:** Cosmetic (code review)
**Component:** Core — `scripts/vmw-create-folder.sh`
**Symptom:**

Line 30: `govc folder.create $vc_folder >/dev/null 2>&1` — suppresses both
stdout and stderr. If the folder creation fails for a reason other than
"already exists" or "not found", the error is silently swallowed.

### Fix

At minimum, keep stderr visible: `govc folder.create "$vc_folder" >/dev/null`.


## Bug #846: `cli-download-all.sh` — calls undefined `aba_warn` function

**Status:** OPEN — `aba_warn` (L127) used instead of `aba_warning`; emits "command not found" when triggered

**Severity:** Functional (code review)
**Component:** Core — `scripts/cli-download-all.sh`
**Symptom:**

Line 127: `aba_warn "govc download skipped ..."` — `aba_warn` is not defined in
`include_all.sh`; only `aba_warning` exists. When this code path runs (govc
download failure on non-vmw platforms), it emits `aba_warn: command not found`
instead of the intended warning message.

### Fix

Change `aba_warn` to `aba_warning`.


## Bug #847: `include_all.sh` — unquoted `$ports` in verify-cluster-conf

**Status:** OPEN — `[ ! -n $ports ]` on line 1078; when `$ports` is empty, evaluates incorrectly as `[ ! -n ]` (always false)

**Severity:** Functional (code review)
**Component:** Core — `scripts/include_all.sh`
**Symptom:**

Line 1078: `[ ! -n $ports ]` — `$ports` is unquoted. If `ports` is empty, this
expands to `[ ! -n ]` which always evaluates to false (the string `-n` is
non-empty). If `ports` contains spaces, the test breaks with "too many
arguments". Should be `[ -z "$ports" ]`.

### Fix

Use `[ -z "$ports" ]` or `[ ! -n "$ports" ]`.


## Bug #848: `download-catalog-index.sh` — skipped-file reporting is dead code

**Status:** OPEN — `rm -rf "$tmp_dir"` (L303) deletes `$_skipped_file` before it is read (L317); warnings never fire

**Severity:** Functional (code review)
**Component:** Core — `scripts/download-catalog-index.sh`
**Symptom:**

Line 303: `rm -rf "$tmp_dir"` runs in the cleanup, but the skipped-directory
reporting at lines 317–327 reads `$_skipped_file` which lives under `$tmp_dir`.
The file is deleted before it can be read, so `skipped_count` is always 0 and
skipped-directory warnings never fire.

### Fix

Move the skipped-file reporting before `rm -rf "$tmp_dir"`, or save the skipped
file outside of `$tmp_dir`.


## Bug #849: `include_all.sh` — `((++running))` violates arithmetic rule

**Status:** OPEN — `(( ++running ))` on line 2898 violates project arithmetic convention; should be `running=$(( running + 1 ))`

**Severity:** Moderate (code review)
**Component:** Core — `scripts/include_all.sh`
**Symptom:**

Line 2898: `(( ++running ))` — uses pre-increment syntax which is banned by
project rules. While `++` avoids the 0-exit-code trap (unlike `var++`), it
still uses the `(( ))` arithmetic pattern which is inconsistent with the
project standard of `var=$(( var + 1 ))`.

### Fix

Use `running=$(( running + 1 ))`.


## Bug #850: `include_all.sh` — verify functions use wrong config name in error

**Status:** OPEN — line 1073 `verify-cluster-conf()` says "aba.conf" in error but validates `cluster.conf`; line 1013 says "machine_network" instead of "prefix_length"

**Severity:** Minor (code review)
**Component:** Core — `scripts/include_all.sh`
**Symptom:**

Line 1073: `verify-cluster-conf()` says the error is in `aba.conf` but this
function validates `cluster.conf`. Copy-paste error from `verify-aba-conf`.

Lines 572, 1013: `prefix_length` validation errors say "machine_network is
invalid" instead of "prefix_length is invalid" (copy-paste mistake).

### Fix

Correct the error messages to reference the right config file/variable.


## Bug #851: `include_all.sh` — deprecated `-a`/`-o` operators in multiple locations

**Status:** OPEN — deprecated `-a` (L540, L1000) and `-o` (L1239-1240, L1252) all still present

**Severity:** Moderate (code review, systemic)
**Component:** Core — `scripts/include_all.sh`
**Symptom:**

Line 540: `[ -f aba.conf -a ! -s aba.conf ]` — deprecated `-a`.
Line 1000: Same deprecated `-a` pattern for `cluster.conf`.
Lines 1239–1240: `[ "$yn" == "y" -o "$yn" == "Y" ]` — deprecated `-o`.
Line 1252: `[ ! "$editor" -o "$editor" == "none" ]` — deprecated `-o`.

### Fix

Replace with `[[ ... && ... ]]` or `[[ ... || ... ]]`.


## Bug #852: `include_all.sh` — `let` arithmetic in `try_cmd()`

**Status:** OPEN — `let pause=$pause+$backoff` (L1298) and `let count=$count+1` (L1299) still present; `let` can fail under `set -e`

**Severity:** Moderate (code review)
**Component:** Core — `scripts/include_all.sh`
**Symptom:**

Lines 1298–1299: `let pause=$pause+$backoff` and `let count=$count+1` — `let`
returns exit status 1 when the expression evaluates to 0, which can abort under
`set -e`. Use `var=$(( var + expr ))` instead.

### Fix

Replace with `pause=$(( pause + backoff ))` and `count=$(( count + 1 ))`.


## Bug #853: `backup.sh` — deprecated `-o`, echo_* usage, typos

**Status:** OPEN — deprecated `-o` (L57), echo_magenta/cyan/red, "transfering" typo (L176, 195) all still present

**Severity:** Moderate (code review)
**Component:** Core — `scripts/backup.sh`
**Symptom:**

Line 57: `[ ! -f ~/.aba.previous.backup -o ! "$inc" ]` — deprecated `-o`.
Lines 155–160: `echo_magenta` for user-facing messages instead of `aba_warning`.
Lines 168, 189: `echo_cyan` instead of `aba_info`.
Lines 247–248: `echo_red` for tar failure instead of `aba_abort`.
Lines 176, 195: Typo "transfering" → "transferring".
Line 263: Logic mismatch — comments say timestamp not updated for `--repo`, but
`touch ~/.aba.previous.backup` always runs.

### Fix

Replace deprecated operators and raw color functions. Fix typos.


## Bug #854: `day2-config-osus.sh` — deprecated `-o`, echo_* usage

**Status:** OPEN — deprecated `-o` (L274), `echo_yellow` (L232), `echo_white` (L181), "Signatires" typo (L23) all still present

**Severity:** Moderate (code review)
**Component:** Core — `scripts/day2-config-osus.sh`
**Symptom:**

Line 274: `test "$scheme" = http -o "$scheme" = https` — deprecated `-o`.
Line 232: `echo_yellow "[ABA] OSUS operator subscription..."` — should use
`aba_warning`.
Line 181: `echo_white "CA cert already added"` — should use `aba_info`.
Lines 195–196: Space indentation instead of tabs.
Line 23: Typo "Signatires" → "Signatures".

### Fix

Replace deprecated operators. Use `aba_warning`/`aba_info`. Fix typo and
indentation.


## Bug #855: `vmw-create.sh` — `eval $cmd` with unquoted govc command

**Status:** DUPLICATE — same issue as Bug #790; `eval $cmd` on line 139

**Severity:** Functional (code review)
**Component:** Core — `scripts/vmw-create.sh`
**Symptom:**

Lines 138–139: Builds a command string with `cmd="govc ... -vm $vm_name ..."`,
then executes with `eval $cmd`. The `$vm_name` is unquoted in the string, and
`$cmd` is unquoted in the `eval`. If `vm_name` contains shell metacharacters or
spaces, this can lead to injection or command failure.

Lines 146–148: Same pattern with `$cmd` for `govc vm.power`.

### Fix

Use direct command execution with properly quoted arguments instead of building
command strings for `eval`.


## Bug #856: `cluster-upgrade.sh` — unquoted command execution

**Status:** OPEN — `$upgrade_cmd` (L326) and `$_image_cmd` (L331) executed unquoted; word-splitting risk on image refs

**Severity:** Moderate (code review)
**Component:** Core — `scripts/cluster-upgrade.sh`
**Symptom:**

Line 308: `_upgrade_out=$($upgrade_cmd 2>&1)` — `$upgrade_cmd` is unquoted,
causing word-splitting on spaces in image refs or flags.
Line 313: `$_image_cmd` executed unquoted — same risk.

### Fix

Use arrays or proper quoting for command construction.


## Bug #857: `monitor-install.sh` / `monitor-bootstrap.sh` — unquoted vars, echo_*

**Status:** OPEN — `echo_yellow`/`echo_red` still used in both scripts (monitor-install.sh L47, 68-71; monitor-bootstrap.sh L32, 52-53)

**Severity:** Moderate (code review)
**Component:** Core — `scripts/monitor-install.sh`, `scripts/monitor-bootstrap.sh`
**Symptom:**

Both scripts share the same patterns:
- Unquoted `$ASSETS_DIR` in file tests and `cat` commands.
- `$exec_cmd` executed unquoted.
- `echo_yellow "[ABA] Running: ..."` and `echo_red "[ABA] Something went wrong"`
  instead of `aba_info`/`aba_warning`.
- `eval $(scripts/cluster-config.sh $@ ...)` — unquoted to eval.
- 4-space indentation in `declare -A` blocks.

### Fix

Quote all variable expansions. Replace echo_* with aba_* functions. Fix
indentation to use tabs.


## Bug #858: `cluster-rescue.sh` — unquoted SSH paths, space indentation

**Status:** OPEN — unquoted `$ssh_key_file`, `$ip`, `$(basename $0)` (L23-26); 8-space indentation (L23-26); `eval $(cluster-config.sh $@)` (L15) all still present

**Severity:** Moderate (code review)
**Component:** Core — `scripts/cluster-rescue.sh`
**Symptom:**

Lines 23–26: Unquoted `$ssh_key_file`, `$ip`, `$0`, `$(basename $0)` in SSH
and SCP commands. Breaks on paths containing spaces.
Lines 23–26: 8-space indentation instead of tabs.
Line 15: `eval $(scripts/cluster-config.sh $@ ...)` — metacharacter-unsafe.

### Fix

Quote all variable expansions. Fix indentation to use tabs.


## Bug #859: `include_all.sh` — `verify_release_version_exists()` edge case

**Status:** LOW RISK — `${ver%.*}` on line 1836 still yields `4` for input `4.22`; function documents three-segment input (e.g. `4.22.2`) and is called with full versions in practice

**Severity:** Functional (edge case, code review)
**Component:** Core — `scripts/include_all.sh`
**Symptom:**

Lines 1836–1837: For a two-segment version like `4.22`, `${ver%.*}` yields `4`
(not `4.22`), so the wrong Cincinnati channel-minor is queried. This can cause
the version lookup to fail for short-form version inputs.

### Fix

Use `_ver_minor()` helper for consistent minor version extraction.


## Bug #860: `include_all.sh` — dead/unused code
**Status:** LOW RISK

**Severity:** Cosmetic (code review)
**Component:** Core — `scripts/include_all.sh`
**Symptom:**

Line 114–131: `color_demo()` — defined, never called.
Line 154–160: `echo_warn()` — defined, never called.
Line 268–283: Large commented-out old `aba_warning()` implementation.
Line 1276: `try_cmd()`: `local out=">/dev/null 2>&1"` assigned but never used.
Line 1570–1572: `_is_ga_version()` — defined, never called.
Line 3841–3845: `need_check` variable set but never read.
Line 3838: `quiet` parameter in `check_internet_connectivity()` — never used.

### Fix

Remove dead code. Remove unused variables.

---

## Bug #861: TUI DISCO mode — wizard auto-runs mirror_install even when registry is running but `.available` marker missing
**Status:** OPEN

**Severity:** Moderate (UX — TUI exits unexpectedly in DISCO mode)
**Component:** TUI v2 — `tui-disco.sh` `_disco_bundle_wizard_gate()` line 116
**Found:** 2026-06-25 (live testing on disco host)

### Description

In DISCO mode, the `_disco_bundle_wizard_gate()` function checks `mirror_available` (line 116), which tests for the `.available` marker file. If this file is missing — even though the Quay registry is running and responsive — the wizard auto-runs `mirror_install`. This can cause:

1. **Re-installation over a running registry**, potentially corrupting data
2. **Immediate TUI exit** if `mirror_install` fails (e.g., disk full)
3. **User confusion** — the registry is up but the TUI thinks it's not installed

On disco, the `.available` marker was missing (likely because the disk became 100% full after a prior install), but the Quay containers were running (quay-redis, quay-app, both up 20+ hours) and `https://disco.example.com:8443/v2/` returned a valid response.

### Root Cause

`mirror_available()` in `tui-lib.sh` only checks the marker file (`$ABA_ROOT/mirror/.available`). It does not probe the actual registry. The marker file can be lost due to disk-full conditions, manual cleanup, or filesystem issues.

### Fix

Before auto-running `mirror_install`, add a secondary check: probe the registry URL (e.g., `curl -sk https://${reg_host}:${reg_port}/v2/`). If the registry responds, skip auto-install and log a warning about the missing marker file.

---

## Bug #862: TUI DISCO mode — disk-full causes cascade of `command not found` errors when `exec` fails
**Status:** LOW RISK

**Severity:** Low (environmental — but poor error handling)
**Component:** TUI v2 startup path, `scripts/aba.sh` line 214
**Found:** 2026-06-25 (live testing on disco host with 100% disk usage)

### Description

When disco's root filesystem is 100% full, the TUI startup exhibits a cascade of errors:
- `run_once` lock files can't be created → `No space left on device` errors
- If `exec` to `abatui2.sh` fails due to filesystem pressure, bash falls through to the old v1 TUI code embedded in `aba.sh`, producing dozens of `aba_debug: command not found`, `normalize-aba-conf: command not found`, `echo_yellow: command not found` errors

The TUI should detect low disk space at startup and warn the user before attempting any operations.

### Fix

Add a disk space check early in the TUI startup (e.g., after `ABA_ROOT` is set). If available space is below a threshold (e.g., 100MB), display a warning dialog and exit gracefully instead of proceeding into a broken state.

---

## Bug #863: TUI cluster install summary — "Mirror: (none — direct install)" shown in Partially Disconnected mode
**Status:** LOW RISK

**Severity:** Cosmetic (UX confusion — misleading mode/mirror combination in summary)
**Component:** TUI v2 — `tui-cluster.sh` cluster install confirmation dialog
**Found:** 2026-06-25 (live testing on conno)

### Description

In CONNO mode (Partially Disconnected), the cluster install summary shows:
```
Mode:    Partially Disconnected
Mirror:  (none — direct install)
```

This occurs when the user toggles "Image source" to "direct" in the Interfaces page. While technically valid (a connected host can do a direct install), the combination of "Partially Disconnected" mode label with "no mirror — direct install" is confusing. Users may wonder why they're in "Partially Disconnected" mode if they're doing a direct install.

### Fix

Either:
1. Change the summary text to clarify: "Mirror: direct (bypassing mirror — requires internet)" when in CONNO mode
2. Or add a note: "Note: Using direct install from a partially disconnected host requires internet access to Red Hat registries"

---

## Bug #864: TUI Day-2 menu — no "Rescue" option despite `aba rescue` being a documented CLI command
**Status:** FEATURE REQUEST

**Severity:** Medium (missing TUI feature — users must exit TUI for cluster rescue)
**Component:** TUI v2 — `tui-cluster.sh` `cluster_day2_menu()` (duplicate of Bug #624 aspect)
**Found:** 2026-06-25 (live testing on conno — confirmed from Day-2 menu inspection)

### Description

The Day-2 / Cluster Management menu includes Upgrade, Shutdown, Startup, Clean, and Delete — but NOT "Rescue". The `aba rescue` command exists as a full CLI command (`scripts/cluster-rescue.sh`) that recovers clusters after shutdown with lost kubeconfig. Users who need this critical recovery feature must exit the TUI and use the CLI.

This was already partially noted in Bug #624 (missing TUI features) but warrants explicit tracking since Rescue is a critical operational workflow.

### Fix

Add a "Rescue cluster (recover after shutdown)" menu item in the Lifecycle section of the Day-2 menu, between Startup and Clean.

---

## Bug #865: `vm-kvm.sh` — `vmp_power_on` and `vmp_power_off` swallow all failures
**Status:** OPEN

**Severity:** Functional (code review)
**Component:** Core — `scripts/vm-kvm.sh` lines 45-60
**Found:** 2026-06-25 (code review)

### Description

KVM power primitives use `2>/dev/null || true` on `virsh start` (line 48) and `virsh shutdown` (line 54), hiding ALL failures — including permissions, missing domains, libvirt connectivity issues. Unlike the VMware counterpart (`vm-vmw.sh` line 55-56), KVM does not check `vmp_is_on` before starting, so duplicate starts and real failures are indistinguishable. `vm_start()` in `vm-provider.sh` cannot detect failure and may hang in `_vm_wait_all`.

### Fix

Mirror VMware pattern: add `vmp_is_on "$vm" && return 0` guard before start; remove `2>/dev/null || true` to propagate real errors.

---

## Bug #866: `vm-vmw.sh` — `vmp_create_vm` has no intermediate error checks between govc steps
**Status:** OPEN

**Severity:** Functional (code review)
**Component:** Core — `scripts/vm-vmw.sh` lines 113-151
**Found:** 2026-06-25 (code review)

### Description

`vmp_create_vm` runs many `govc` commands in sequence (VM create, disk attach, network config, CD-ROM attach, ISO upload) with no intermediate validation. Under `set -e` in callers like `vmw-create.sh`, later steps abort on failure, but a partially created VM remains (e.g., VM created but disk attach failed). No cleanup is attempted on mid-sequence failure.

### Fix

Check each `govc` command's return code; on failure, attempt cleanup (`govc vm.destroy`) or `aba_abort` with clear context about which step failed.

---

## Bug #867: `reg-install-docker.sh` — `podman run` exit code not checked
**Status:** OPEN

**Severity:** Functional (code review)
**Component:** Core — `scripts/reg-install-docker.sh` lines 84-97
**Found:** 2026-06-25 (code review)

### Description

The script runs `podman run -d ...` to start the Docker registry container but does not check the exit code before proceeding to firewall configuration, state saving, and curl verification. If the container fails to start (port conflict, image corruption, SELinux denial), the script continues to the verification step and produces a misleading "not reachable" abort message instead of reporting the container start failure.

Additionally, the script has no `set -e` or `set -euo pipefail`, so failures in `openssl`, `htpasswd`, or `podman` commands may not abort the script at all.

### Fix

Add `|| aba_abort "Failed to start registry container"` after `podman run`. Consider adding `set -euo pipefail` at the top of the script.

---

## Bug #868: `reg-uninstall-quay.sh` — fragile cleanup chain for ansible runner container
**Status:** OPEN

**Severity:** Functional (code review)
**Component:** Core — `scripts/reg-uninstall-quay.sh` lines 30-32
**Found:** 2026-06-25 (code review)

### Description

Cleanup uses `podman stop ansible_runner_instance && podman rm ansible_runner_instance`. If `stop` fails, the `&&` prevents `rm` from running, leaving a stuck container. The container check uses `podman ps -a | grep quay.io.*ansible_runner_instance` which is fragile (greedy regex, matches on image name not container name).

### Fix

Use `podman rm -f ansible_runner_instance || true` (force-remove handles both running and stopped containers). Replace grep with `podman ps -a --format '{{.Names}}' | grep -qx 'ansible_runner_instance'`.

---

## Bug #869: `list-operators.sh` — `read` only processes first package from multi-package catalogs
**Status:** OPEN

**Severity:** Functional (edge case, code review)
**Component:** Core — `scripts/list-operators.sh` lines 109, 130
**Found:** 2026-06-25 (code review)

### Description

`read -r pkg def_ch < <(jq ...)` reads only the first line of jq output. If a catalog directory contains multiple `olm.package` entries (which is valid for some operator bundles), only the first package is processed and displayed. The remaining packages are silently ignored.

### Fix

Loop over all jq/awk output lines instead of reading a single line.

---

## Bug #870: `list-operators.sh` — YAML display-name fallback is dead code
**Status:** OPEN

**Severity:** Moderate (code review)
**Component:** Core — `scripts/list-operators.sh` lines 125-153
**Found:** 2026-06-25 (code review)

### Description

`_extract_from_yaml` accepts a `$dir` parameter but never uses it for display-name lookup. The JSON path falls back to `_display_name_from_bundles "$dir"` when no inline display name is found, but the YAML path does not. YAML catalogs without an inline `displayName:` always show `-` as the display name.

### Fix

When the YAML grep finds no display name, call `_display_name_from_bundles "$dir"` like the JSON path does.

---

## Bug #871: `vm-kvm.sh` / `vm-vmw.sh` — `_vmw_vm_json` stderr suppression causes false "VM not found"
**Status:** OPEN

**Severity:** Moderate (code review)
**Component:** Core — `scripts/vm-vmw.sh` line 22, `scripts/vm-kvm.sh` line 23
**Found:** 2026-06-25 (code review)

### Description

Both VM adapters suppress stderr on their existence/state check functions. VMware: `govc vm.info ... 2>/dev/null`; KVM: `virsh dominfo ... >/dev/null 2>&1`. When authentication, network, or libvirt/vCenter connection errors occur, the suppressed stderr makes the error indistinguishable from "VM not found". This can cause `vmp_exists` to return false for existing VMs, leading to duplicate VM creation attempts.

### Fix

Remove stderr suppression on VM state queries. Check exit code first; only interpret output if the command succeeded.

---

## Bug #872: `preflight-check.sh` — unquoted `$host` inside `bash -c` creates injection risk
**Status:** OPEN

**Severity:** Moderate (code review)
**Component:** Core — `scripts/preflight-check.sh` line 75
**Found:** 2026-06-25 (code review)

### Description

The NTP UDP probe uses `timeout 3 bash -c "echo >/dev/udp/$host/123" 2>/dev/null` where `$host` is expanded inside double quotes before passing to `bash -c`. A malformed or malicious `ntp_servers` value containing shell metacharacters could inject commands.

### Fix

Validate hostnames before use (e.g., `grep -qE '^[A-Za-z0-9._-]+$'`), or pass host via environment: `host="$host" bash -c 'echo >/dev/udp/$host/123'`.

---

## Bug #873: `preflight-check.sh` — `grep -oP` requires PCRE (not portable)
**Status:** OPEN

**Severity:** Moderate (code review)
**Component:** Core — `scripts/preflight-check.sh` line 142
**Found:** 2026-06-25 (code review)

### Description

`grep -oP 'dev \K\S+'` requires PCRE support (`grep -P`). This fails on systems with busybox grep or grep builds without PCRE (e.g., some minimal container images).

### Fix

Use awk: `ip -o route get "$ip" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'`.

---

## Docbug #874: README.md — Command Reference table has corrupted markdown (broken row)

**Status:** FIXED (commit ac710128)
**Severity:** Moderate (documentation)
**Component:** Documentation — `README.md` line ~1291
**Found:** 2026-06-25 (documentation review)

### Description

The `aba cluster` row in the Command Reference markdown table is split across two rows (`| compact |` on its own line), causing the table to render incorrectly in GitHub/rendered markdown.

### Fix

Fix the table row to a single line.

---

## Docbug #875: README.md — FAQ uses invalid command shorthands (`aba sync`, `aba save/load`)

**Status:** FIXED (commit ac710128)
**Severity:** Moderate (documentation)
**Component:** Documentation — `README.md` lines ~1692, ~1750
**Found:** 2026-06-25 (documentation review)

### Description

FAQ sections reference `aba sync`, `aba save/load`, and `aba load/sync` which are not valid top-level commands. The correct forms are `aba -d mirror sync`, `aba -d mirror save`, `aba -d mirror load`.

### Fix

Replace all shorthand references with correct commands.

---

## Docbug #876: README.md — TUI documentation is minimal (no keyboard UX, menu structure, or mode flags)

**Status:** FIXED (commit ac710128)
**Severity:** Medium (documentation)
**Component:** Documentation — `README.md` lines ~271-284, ~1342
**Found:** 2026-06-25 (documentation review)

### Description

TUI documentation consists of a brief paragraph and a single Command Reference row. Missing: `aba tui` as alternative entry point, mode flags (`--direct`, `--disco`, `--conno`), keyboard navigation, menu structure overview, `dialog` dependency, offline bundle behavior, and when TUI vs CLI is preferable.

### Fix

Add a TUI subsection covering: launch options, mode detection, keyboard UX, menu structure, and limitations vs CLI.

---

## Docbug #877: README.md — `~/.aba/` not mentioned in uninstall steps

**Status:** FIXED (commit ac710128)
**Severity:** Medium (documentation)
**Component:** Documentation — `README.md` lines ~1577-1597
**Found:** 2026-06-25 (documentation review)

### Description

The uninstall section documents `rm -rf aba` and removing binaries but does not mention `~/.aba/` which contains externalized cluster state, runner state, cache, SSH config, and logs. This directory is explicitly preserved by `aba reset` and would survive a repo removal, potentially causing confusion on reinstall.

### Fix

Add step: `rm -rf ~/.aba` for full removal, with a warning about cluster kubeconfig data stored there.

---

## Docbug #878: README.md — Day-0 Hello World example requires running cluster but doesn't say so

**Status:** FIXED (commit ac710128)
**Severity:** Medium (documentation, broken example)
**Component:** Documentation — `README.md` lines ~726-741
**Found:** 2026-06-25 (documentation review)

### Description

After `aba iso`, the example immediately runs `oc get configmap ...` which requires a running cluster and credentials. ISO generation alone does not make `oc` work. New users would get confusing errors.

### Fix

Split into steps: generate ISO → boot/install → monitor → verify with `oc get` after `. <(aba shell)`.

---

## Docbug #879: README.md — `aba vmw` / `aba kvm` setup commands not documented

**Status:** FIXED (commit ac710128)
**Severity:** Medium (documentation, missing topic)
**Component:** Documentation — README.md Prerequisites/VMware/KVM sections
**Found:** 2026-06-25 (documentation review)

### Description

Code requires `aba vmw` / `aba kvm` before VM lifecycle operations (`aba.sh` line 1065-1070 says "Run `aba vmw` first"). README only mentions editing `vmware.conf` / `kvm.conf` manually. The interactive setup commands are undocumented.

### Fix

Add setup steps documenting `aba vmw` (interactive vCenter configuration) and `aba kvm`.

---

## Bug #880: TUI DISCO mode — Back/Cancel during auto-run wizard exits TUI instead of showing action menu
**Status:** OPEN

**Severity:** Moderate (UX — user loses TUI session, must restart)
**Component:** TUI v2 — `tui-disco.sh` `_disco_bundle_wizard_gate()` lines 116-126
**Found:** 2026-06-26 (live testing on disco)

### Description

In DISCO mode, the bundle wizard auto-runs `mirror_install` and then `disco_load_images` (lines 116-124). If the user presses "Back" on the load confirmation dialog, or if the load fails and the user dismisses the error, the TUI exits completely instead of falling through to the DISCO action menu.

**Reproduced:** On disco with a freshly cleaned disk. After the wizard auto-installed the mirror, it auto-proceeded to image load. Pressing "Back" on the load dialog exited the TUI. On retry, the load failed (auth error) and dismissing the error also exited the TUI.

The expected behavior is: after the wizard's auto-install/load steps complete (or are cancelled), drop into the DISCO action menu so the user can troubleshoot, retry, or perform other tasks.

### Root Cause

`_disco_bundle_wizard_gate()` calls `disco_load_images` at line 123. If this function returns non-zero (user cancelled or load failed), the gate function returns 1, and `disco_main()` at line 135 (`_disco_bundle_wizard_gate || return 1`) returns, exiting the TUI.

### Fix

Change the gate function to return 0 after the auto-load attempt regardless of outcome — let the user reach the action menu where they can manually retry, troubleshoot, or skip:

```bash
if mirror_available && ! _mirror_has_release_image; then
    disco_load_images || true   # Don't block menu entry on load failure
fi
return 0
```

---

## Bug #881: `reg-install-quay.sh` — stale `ansible_runner_instance` container blocks reinstall
**Status:** OPEN

**Severity:** Moderate (Functional — install fails, requires manual intervention)
**Component:** Core ABA — `scripts/reg-install-quay.sh` line 89
**Found:** 2026-06-26 (live testing on disco)

### Description

If `aba install` (Quay) is interrupted mid-execution or run twice in quick succession, the `ansible_runner_instance` container from the first run may still exist. The `mirror-registry install` command does not use `--replace` and fails with:

```
Error: creating container storage: the container name "ansible_runner_instance" is already in use by <id>.
You have to remove that container to be able to reuse that name: that name is already in use, or use --replace
```

**Reproduced:** On disco. First `aba install` ran directly (SSH interrupted but remote process completed). Second `aba install` ran in tmux — failed with container name collision.

### Root Cause

`reg-install-quay.sh` line 89 calls `./mirror-registry install` without checking for or cleaning up a stale `ansible_runner_instance` container. The `mirror-registry` installer creates a container with a fixed name and doesn't handle pre-existing containers.

### Fix

Before calling `mirror-registry install`, check if a stale `ansible_runner_instance` container exists from a previous run and remove it:

```bash
if podman container exists ansible_runner_instance 2>/dev/null; then
    aba_warning "Removing stale ansible_runner_instance container from a previous install attempt"
    podman rm -f ansible_runner_instance
fi
```

Note: This is NOT manual Quay lifecycle management — it's cleaning up the *installer's own transient container*, not a Quay runtime container. The `mirror-registry` tool should handle this itself but doesn't.

---

## Bug #882: `reg-verify.sh` — message uses old command shorthands (`aba sync`, `aba save/load`)
**Status:** OPEN

**Severity:** Low (Cosmetic — misleading user guidance)
**Component:** Core ABA — `scripts/reg-verify.sh` line 69
**Found:** 2026-06-26 (live testing on disco)

### Description

When `aba verify` detects the registry is working but images aren't loaded, it prints:

```
Images may not have been mirrored yet (run: aba sync or aba save/load)
```

These are the old command shorthands. The correct commands are `aba -d mirror sync` or `aba -d mirror save` / `aba -d mirror load`. Same issue already fixed in README.md (Docbug #875).

### Fix

Change line 69 of `scripts/reg-verify.sh`:

```bash
"Images may not have been mirrored yet (run: aba -d mirror sync or aba -d mirror save/load)"
```

---

## Bug #883: TUI mirror config — vendor change doesn't auto-adjust port
**Status:** OPEN

**Severity:** Low (UX — user must manually fix port)
**Component:** TUI v2 — `tui-mirror.sh` mirror config dialog
**Found:** 2026-06-26 (live TUI testing on disco)

### Description

When changing the registry vendor in the mirror config dialog from `auto`/`quay` (port 8443) to `docker` (port 5000), the port field is NOT automatically adjusted. The user must manually navigate to the Port field and change 8443 → 5000. This is error-prone — a user could easily proceed with port 8443 for a Docker registry, which would fail at install time.

### Fix

When the vendor is changed, auto-update the port to the default for that vendor:
- `quay` → 8443
- `docker` → 5000
- `auto` → leave as-is (or set to 8443 since auto defaults to quay when available)

---

## Bug #884: TUI terminal mode — "Press R to retry" requires Enter (misleading prompt)
**Status:** LOW RISK

**Severity:** Low (UX — confusing interaction)
**Component:** TUI v2 — `tui-lib.sh` `_exec_in_terminal()` line 737
**Found:** 2026-06-26 (live TUI testing on disco)

### Description

After a command fails in terminal mode, the prompt says:

```
Press R to retry, ENTER to return to menu...
```

"Press R" implies a single keypress, but `read -rp` (without `-n 1`) waits for Enter. User types R, nothing happens, then must press Enter. The actual interaction is "Type R then Enter", not "Press R".

### Root Cause

Line 737 of `tui-lib.sh`:
```bash
read -rp "Press R to retry, ENTER to return to menu... " _reply
```

Uses `read -r` without `-n 1`, so it buffers until Enter.

### Fix

Either:
1. Use `read -rn 1` to accept a single keypress (matching the prompt wording)
2. Or change the prompt to: `Type R+Enter to retry, or just Enter to return to menu...`

Option 1 is better UX.

---

## Bug #888: TUI Day-2 menu — separator items with empty tags are selectable, cause menu refresh
**Status:** OPEN

**Severity:** Medium (UX — confusing behavior when navigating Day-2 menu)
**Component:** TUI v2 — `tui-cluster.sh` `cluster_day2_menu()` (lines 2055-2066)
**Found:** 2026-06-26 (live TUI testing on conno)

### Description

The Day-2 menu uses separator items with empty tags (`""`) for section headers (Configuration, Status, Lifecycle, Cleanup). These separators are selectable in dialog's `--menu` widget. When the user accidentally navigates to a separator and presses Enter, the menu returns an empty string, which causes the menu to silently refresh without any action.

This is confusing because:
1. The user thinks they selected a real item but nothing happens
2. The menu just redraws in the same state

This also affects the CONNO action menu and any other menu using the same separator pattern.

### Fix

Use dialog's `--no-tags` option to hide tags and use item descriptions for display, OR use non-empty separator tags (e.g. `"---1"`, `"---2"`) and handle them in the case statement with `continue`, OR use dialog's `--separator` feature if available.

Alternatively, in the case statement handling the menu choice, add:
```bash
"") continue ;;  # separator item selected — ignore
```

---

## Bug #885: TUI wizard — VMware platform selection doesn't prompt for vCenter config when ~/.vmware.conf missing
**Status:** OPEN

**Severity:** Medium (UX — user must manually configure VMware later, wizard gives no guidance)
**Component:** TUI v2 — wizard flow in `abatui2.sh`
**Found:** 2026-06-26 (live TUI testing on conno)

### Description

When running the TUI wizard in CONNO mode and selecting "VMware vSphere" as the platform, the wizard does NOT prompt for vCenter configuration (hostname, username, password, datacenter, etc.) even when `~/.vmware.conf` does not exist.

**Reproduced:** On conno after `aba reset --force` and renaming `~/.vmware.conf` to `~/.vmware.conf.hidden`. The wizard went: Channel → Version → Platform (selected VMware) → Operators → action menu. No VMware config dialog appeared.

The user is left at the action menu with platform=vmw but no vCenter configuration. They must know to go to Advanced → Platform Settings to configure it manually.

### Fix

After platform selection, if `platform=vmw` and `~/.vmware.conf` does not exist (or is empty), the wizard should either:
1. Launch the VMware configuration dialog (same as Advanced → Platform Settings)
2. Or display a prominent message: "VMware selected but vCenter not configured. Go to Advanced → Platform Settings before installing a cluster."

---

## Bug #886: TUI DISCO mode — menu cursor always defaults to "View ISC", makes it impossible to select other items
**Status:** OPEN

**Severity:** High (UX — navigating DISCO action menu is extremely difficult)
**Component:** TUI v2 — `tui-disco.sh` DISCO action menu
**Found:** 2026-06-26 (live TUI testing on disco)

### Description

In the Fully Disconnected action menu, the cursor always defaults to "V  View ImageSet Config" regardless of what was previously selected. When pressing Down and Enter, the cursor consistently lands on the ISC viewer instead of other items (Install Registry, Load, Advanced).

Multiple attempts to navigate to different menu items (Install Registry, Advanced) all resulted in the ISC viewer opening. The `default_item` parameter for the dialog appears to be set incorrectly, causing it to always highlight "V" (View ISC).

This makes it nearly impossible to use the DISCO action menu via arrow key navigation. Users must use the Home/End keys or try multiple times.

### Root Cause

In `tui-disco.sh` line 136:
```bash
local default_item="$TUI2_DISCO_TAG_VIEW_ISC"
```

The initial `default_item` is hardcoded to View ISC. So when the DISCO action menu first opens, the cursor starts on "V" (View ISC) instead of the first item (R - Install Registry). After selecting an item, `default_item` is updated to the user's last choice (line 247), but the initial position is confusing.

### Fix

Change line 136 to set the initial `default_item` to the first actionable item (Install Registry) rather than View ISC:
```bash
local default_item="$TUI2_DISCO_TAG_INSTALL_REG"
```

---

## Bug #887: TUI Platform Settings — selecting a platform immediately applies it (no confirmation)
**Status:** OPEN

**Severity:** Medium (UX — accidental platform switch has no undo)
**Component:** TUI v2 — `tui-cluster.sh` Advanced → Platform Settings (lines 1958-1972)
**Found:** 2026-06-26 (live TUI testing on conno)

### Description

In Advanced → Platform Settings, selecting a platform from the menu (M/V/K) immediately writes the new `platform=` value to `aba.conf` AND opens the platform configuration dialog. There is no confirmation prompt ("Change platform from vmw to kvm?").

If the user accidentally selects the wrong platform (e.g. presses Down one too many times and lands on KVM instead of VMware), `aba.conf` is silently changed. The user must then navigate back and re-select the correct platform to fix it.

The `default_item` correctly highlights the current platform, so pressing Enter without navigating selects the right one. But a single accidental arrow key press changes the platform without any warning or confirmation.

### Fix

Add a confirmation dialog before changing the platform: "Change platform from vmw to kvm? This will update aba.conf."

---

## Bug #889: Core — `aba upgrade` fails on conditional updates — no clear message
**Status:** FIXED — detect conditional update, surface Reason/Message, abort with manual command

**Severity:** High (functional — upgrade fails with confusing output)
**Component:** Core — `scripts/cluster-upgrade.sh` lines 326-334
**Found:** 2026-06-26 (verified via TUI on conno, upgrading sno 4.20.20 → 4.20.23)

### Design decision

**ABA MUST NEVER use `--allow-not-recommended`.** Conditional updates carry known risks
that require explicit human judgment. ABA must surface the reason clearly and abort —
the user can run the upgrade manually if they accept the risk.

### Description

When upgrading a cluster via `aba upgrade --to 4.20.23`, the upgrade fails because
the target is a "conditional update". The current error handling (line 332) calls
`aba_abort` which dumps the raw upgrade command, while line 327 echoes the FULL
`oc adm upgrade` output — including the suggestion to use `--allow-not-recommended`
which ABA should never do.

The user sees a wall of text and a confusing suggestion instead of a clear explanation.

### Current behavior

```
error: the update 4.20.23 is not one of the recommended updates, but is available as a conditional update.
To accept the Recommended=False risk and to proceed with update use --allow-not-recommended.
  Reason: ControlPlaneStatusGreyIcon
  Message: Control plane status indicator remains grey and never shows green...
[ABA] Upgrade command failed (exit=1): oc adm upgrade --to 4.20.23
```

### Expected behavior

```
[ABA] Version 4.20.23 is a conditional update with known risks:
[ABA]   Reason: ControlPlaneStatusGreyIcon
[ABA]   Message: Control plane status indicator remains grey...
[ABA] ABA does not support conditional updates. To proceed manually:
[ABA]   oc adm upgrade --to 4.20.23 --allow-not-recommended
```

### Fix

Add an `elif` case (before the generic abort) that detects "not one of the recommended
updates", extracts the Reason/Message lines, shows them in a clean ABA-formatted
message, and exits — without using `--allow-not-recommended` itself.

---

## Bug #890: TUI — Upgrade Gate dialog uses --defaultno, easy to accidentally cancel
**Status:** LOW RISK

**Severity:** Low (UX — easy to accidentally cancel the upgrade gate)
**Component:** TUI v2 — `tui-cluster.sh` `_upgrade_preflight_check` line 2246
**Found:** 2026-06-26 (live TUI testing on conno)

### Description

When the upgrade preflight check detects `Upgradeable=False`, a confirmation dialog is shown with "Continue" and "Cancel" buttons. The dialog uses `--defaultno`, which means the default (highlighted) button is "Cancel".

Users who press Enter expecting to confirm ("Continue") will instead press "Cancel" and be returned to the version selection menu. This is counterintuitive because the dialog text says to continue "if you have resolved any required actions", implying the user has already decided to proceed.

While `--defaultno` is a safety measure (preventing accidental upgrades past gates), the dialog wording and button ordering make it confusing. The "Continue" button is visually on the left but not selected by default.

### Fix

Either:
1. Remove `--defaultno` and make "Continue" the default (simpler UX), or
2. Change the dialog text to make it clearer that Cancel is the default: "Press Tab to select Continue, or press Enter to cancel."

---

## Bug #891: TUI Wizard — Channel change shows stale versions from previous channel
**Status:** OPEN

**Severity:** High (functional — user selects "stable" but sees candidate channel versions)
**Component:** TUI v2 — `tui-direct.sh` / `abatui2.sh` wizard version picker
**Found:** 2026-06-26 (live TUI testing on conno, switching from candidate to stable)

### Description

In the DIRECT mode wizard (also affects CONNO wizard via shared code), when the user:
1. Previously configured `candidate` channel with version `4.21.0-rc.2`
2. Selects "Rerun Wizard"
3. Selects "Reconfigure"
4. Picks "stable" as the new channel

The version picker dialog shows:
- Title: "Select OpenShift version (**candidate** channel)" — wrong channel!
- Versions: `5.0.0-ec.3` (Latest), `4.22.2` (Previous), `4.21.0-rc.2` (Current) — these are candidate channel versions, NOT stable channel versions

### Root Cause

The version prefetch tasks are cached via `run_once` with keys like `ocp:${_channel}:latest_version`. When the user changes the channel from candidate to stable, the wizard's version step reads the cached candidate channel results because:
1. The `run_once` cache already has results for the candidate channel from TUI startup
2. The new channel hasn't triggered a fresh fetch yet (or the fetch completed but the display code is using the old channel variable)
3. The dialog title explicitly says "(candidate channel)" which proves the channel variable wasn't updated before rendering

### Fix

Ensure the version step reads the channel selection from the wizard's current step state (not from the stale global `ocp_channel`), and invalidates/re-runs the version fetch when the channel changes.

---

## Bug #892: TUI — "aba register" workflow missing from TUI (CLI-only)
**Status:** FEATURE REQUEST

**Severity:** Medium (UX gap — common workflow requires CLI)
**Component:** TUI v2 — all mode menus
**Found:** 2026-06-26 (code review — no "register" references in tui/v2/*.sh)

### Description

The `aba register` / `aba unregister` workflow (for connecting to an existing external registry) is available via CLI (`aba -d mirror register --pull-secret-mirror ... --ca-cert ...`) but has no TUI entry point. Users who want to register an existing mirror must exit the TUI and use the CLI.

The README documents this workflow under "Register an existing external registry as a named mirror" and the CLI's `--help` includes the `register` target, but the TUI does not expose it in any menu.

### Fix

Add a "Register External Mirror" option to the CONNO main menu (alongside "Install Mirror") and/or to the Advanced menu.

---

## Bug #893: TUI — Platform config form creates config file from template even on Cancel
**Status:** OPEN

**Severity:** Medium (UX — false "configured" status after canceling config form)
**Component:** TUI v2 — `tui-cluster.sh` `_configure_vmw_form` line 314 / `_configure_kvm_form` line 485
**Found:** 2026-06-26 (live TUI testing on conno — KVM config from scratch)

### Description

When the user:
1. Selects KVM (or VMware) platform on the Basics page — shows "⚠" (not configured)
2. Presses Next → gate detects missing `kvm.conf` → prompts "Configure Now"
3. Selects "Configure Now" → enters the config form
4. Immediately presses Back/Cancel/Escape to leave without making any changes

The platform now shows "✓" (configured) because `kvm.conf` was created from the template when the form opened (line 485-487):
```bash
if [[ ! -s "$conf_path" ]]; then
    cp "$ABA_ROOT/templates/kvm.conf" "$conf_path"
fi
```

The file contains only template placeholder values (e.g. `qemu+ssh://kvm-user@kvmhost.lan/system`) which are not valid for actual use.

### Root Cause

The config form creates the file at the beginning (before the user has made any edits), but on Cancel/Back, the file is not cleaned up. The checkmark display logic (`[[ -s "$ABA_ROOT/kvm.conf" || -s "$HOME/.kvm.conf" ]]`) considers any non-empty file as "configured".

### Fix

Either:
1. Don't copy the template until the user presses "Continue" (deferred creation), or
2. Track whether the file was freshly created and delete it on Cancel/Back, or
3. Add a validation check (e.g. verify URI is not the default placeholder) before showing "✓"

---

## Bug #894: TUI — "Run in Terminal" mode double-prompts user for shutdown/startup/delete (pre-confirmed by TUI dialog)
**Status:** LOW RISK

**Severity:** Low (UX annoyance — user confirms in TUI dialog, then CLI asks again)
**Component:** TUI v2 — `tui-lib.sh` `_exec_in_terminal` / `tui-cluster.sh` `_day2_shutdown`, `_day2_startup`
**Found:** 2026-06-26 (live TUI testing on conno — shutdown + startup flow)
**Verified:** Yes (live TUI on conno with installed sno.example.com cluster)

### Description

When the user runs lifecycle operations (Graceful Shutdown, Graceful Startup, Delete Cluster) through the TUI Day-2 menu in "Run in Terminal" mode:

1. TUI shows a confirmation dialog ("Gracefully shut down cluster 'sno.example.com'?" / "Start cluster 'sno.example.com'?") with Yes/Cancel buttons
2. User presses "Shutdown" / "Start" to confirm
3. TUI launches the command in terminal (e.g. `aba --dir sno shutdown --wait`)
4. The CLI script **prompts again**: "Gracefully shut down the cluster? (Y/n):" / "Start the above virtual machine(s)? (Y/n):"

The user must confirm **twice** for the same action.

### Root Cause

In `_exec_in_terminal` (tui-lib.sh, line 688-690):
```bash
if [[ "$(_tui_abaconf_raw_ask)" == "yes" ]]; then
    [[ "$cmd" != *" --yes"* ... ]] && cmd="$cmd --yes"
fi
```

The `--yes` flag is only appended when the TUI's auto-answer setting is ON. When auto-answer is OFF (default), the command runs without `--yes`, so the underlying CLI script's `ask()` function prompts the user again.

In contrast, `_exec_in_tui` (line 629) sets `ASK_OVERRIDE=1` environment variable unconditionally, which suppresses the prompt.

### Fix

For commands where the TUI has **already shown a confirmation dialog** (shutdown, startup, delete), `_exec_in_terminal` should unconditionally append `--yes` to the command, regardless of the auto-answer setting. The TUI dialog IS the confirmation — the CLI should not re-ask.

Option 1: `_exec_in_terminal` always sets `ASK_OVERRIDE=1` in the environment (like `_exec_in_tui` does)
Option 2: The `confirm_and_execute` caller passes a flag indicating pre-confirmation, and `_exec_in_terminal` appends `--yes` in that case
Option 3: The specific Day-2 functions (`_day2_shutdown`, `_day2_startup`) append `--yes` to their command strings since they already have their own confirmation dialog

---

## Bug #895: TUI — Cluster status view shows `Upgradeable=False` but no explanation visible without scrolling
**Status:** LOW RISK

**Severity:** Low (UX — critical info requires scrolling)
**Component:** TUI v2 — `tui-cluster.sh` `_day2_status`
**Found:** 2026-06-26 (live TUI testing on conno — cluster status for sno.example.com)
**Verified:** Yes (live TUI)

### Description

The cluster status view (`_day2_status`) uses a `--textbox` dialog to show cluster operator status, node status, pending pods, and upgrade status. On a freshly installed cluster with the Sigstore admin-ack requirement (`AdminAckRequired`):

- The status line `Upgradeable=False` is visible at about 70% scroll position
- The detailed reason (`AdminAckRequired`) and the actionable message (about Sigstore signatures) are **only visible after scrolling further down** (83%+ position)

For users who see `Upgradeable=False` and don't scroll, they miss the explanation of WHY and what to do about it. The most important information (the actionable reason) is the hardest to find.

### Fix

Consider reorganizing the status view to put the upgrade status section at the top (before the long operator table), since it contains the most actionable information. Or add a summary line at the top: "⚠ Cluster not upgradeable: AdminAckRequired — scroll to Upgrade Status for details."

---

## Bug #896: Docbug — README.md missing TUI v2 documentation section

**Status:** FIXED — README now has a full TUI section (lines 273-288) with launch commands, mode flags, navigation tips, and workflow coverage

**Severity:** Medium (documentation gap — users don't know TUI exists or how to use it)
**Component:** README.md
**Found:** 2026-06-26 (code review)
**Verified:** By reading README.md

### Description

The README.md file documents the CLI workflow extensively but has no section explaining the TUI v2 (`aba tui`) features, how to launch it, or its capabilities. The TUI is a major user-facing feature that covers most of the ABA workflow (mirror install, sync/load, cluster install, Day-2 operations, upgrade, bundle creation) but is not documented in the README.

Users discovering ABA through the README would not know the TUI exists unless they run `aba --help` and notice the `tui` command.

### Fix

Add a "TUI (Text User Interface)" section to the README explaining:
1. How to launch it (`aba tui` or `./tui/v2/abatui2.sh`)
2. What modes it supports (CONNO, DISCO, DIRECT)
3. Key navigation tips (keyboard shortcuts, Tab cycling)
4. What workflows it covers vs CLI-only features

---

## Bug #897: `aba tui` (with space) fails — `dialog` broken by trace logging pipe redirect

**Severity:** Medium (users who type the intuitive `aba tui` get a broken TUI)
**Component:** `scripts/aba.sh` (lines 252-253, 1128-1130)
**Found:** 2026-06-26 (functional testing on disco)
**Verified:** Yes — `aba tui` on disco produces broken dialog, `abatui` works fine
**Status:** FIXED

### Description

Running `aba tui` (with a space) fails — the TUI produces corrupted `dialog` output. Running `abatui` (no space, symlink) works perfectly.

### Root cause

When invoked as `abatui`, the basename check at line 214 fires immediately and `exec`s the TUI before any fd redirection. When invoked as `aba tui`, the script reaches line 253 which replaces stdout/stderr with pipes to `tee` (for trace logging). By the time the `tui)` case at line 1128 `exec`s the TUI, fd 1/2 are pipes, not TTYs — breaking `dialog`.

### Fix (applied)

Changed the `tui)` case in `aba.sh` to output a message directing the user to run `abatui` instead:
```bash
tui)
    echo "Please run 'abatui' (without a space) to launch the TUI." >&2
    exit 1
;;
```

---

## Bug #898: TUI — `aba register` workflow has no TUI equivalent
**Status:** DUPLICATE — same as Bug #892

**Severity:** Medium (missing TUI feature — users must drop to CLI for register workflow)
**Component:** TUI v2 (all files under `tui/v2/`)
**Found:** 2026-06-26 (functional testing on conno)
**Verified:** Yes — grep confirms no "register" string exists in any TUI file

### Description

The `aba register` command (for connecting to an existing external registry) has no TUI equivalent. Users who want to register an existing registry must use the CLI directly. The "Install Mirror" TUI option only supports installing a new local or remote mirror, not registering/connecting to an existing one.

### Fix

Add a "Register External Registry" option to the main menu (CONNO mode) or Advanced menu.

---

## Bug #899: TUI — No way to cancel/interrupt a running operation from within the TUI
**Status:** FEATURE REQUEST

**Severity:** Low (UX limitation — users must wait or kill the TUI externally)
**Component:** `tui/v2/tui-lib.sh` (progressbox execution)
**Found:** 2026-06-26 (functional testing — cluster install on conno)
**Verified:** Yes — during cluster install, TUI progress box blocks for 30-40 min with no cancel option

### Description

When a long-running operation (e.g., cluster install with `openshift-install agent wait-for install-complete`) runs inside the TUI progressbox, the user cannot cancel, go back, or perform any other TUI action. The entire TUI is blocked. The only way to stop is killing externally.

### Fix

Consider adding a cancel option or offering to detach long-running operations to background.

## Bug #900: TUI — Welcome screen ASCII art banner broken (newlines collapsed) — FIXED

**Severity:** Medium (visual defect — first thing users see)
**Component:** `tui/v2/abatui2.sh` (splash screen, lines 766–778)
**Found:** 2026-06-26 (dialog layout testing on conno after git pull)
**Verified:** Yes — reproduced via tmux on conno (tui-debugging session)
**Status:** FIXED by commit `62ad4544` — `dlg()` now detects real `$'\n'` newlines vs literal `\n` escape sequences and appends trailing spacing using the matching style

### Description

The welcome splash screen uses a multi-line bash string with **real newlines** (not `\n` escape sequences) for the ASCII art banner. However, `dialog --yesno` does not preserve real newlines by default — it treats them as spaces and wraps the text as a single paragraph.

**Expected:**
```
  __   ____   __
 / _\ (  _ \ / _\     ABA v1.1.0
/    \ ) _ (/    \    Install & configure
\_/\_/(____/\_/\_/    air-gapped OpenShift quickly!

Follow the setup wizard or see the README.md file for more.
```

**Actual (all art lines concatenated into 2 wrapped lines):**
```
  __   ____   __  / _\ (  _ \ / _\     ABA v1.1.0 /    \ ) _
(/    \    Install & configure \_/\_/(____/\_/\_/    air-gapped
OpenShift quickly!  Follow the setup wizard...
```

### Root Cause

The `dlg()` wrapper passes text through to `dialog` without `--cr-wrap`. The `dialog` utility interprets `\n` (literal backslash-n) as line breaks, but treats **real embedded newlines** (`$'\n'`) as spaces. The `show_help()` function correctly uses `--cr-wrap` (line 384), but the welcome `--yesno` call does not.

### Fix

Either:
1. Convert the multi-line bash string to use `\n` escape sequences instead of real newlines, **OR**
2. Add `--cr-wrap` to the `dlg()` wrapper for `--yesno`/`--msgbox` types (but test that this doesn't break other dialogs using `\n` escapes)

Option 1 is safer and more targeted.

---

## Test Flows Completed (2026-06-26, Session 2)

### CONNO: SNO2 full lifecycle via TUI — PASSED
- **Cluster:** sno2.example.com (10.0.1.202, vmw, CONNO mode)
- **Install:** TUI wizard → Review → Install → Run in TUI. Agent alive, bootstrap complete, cluster installed (~40 min). All 34 cluster operators AVAILABLE. No bugs found.
- **Day-2 OperatorHub:** TUI auto-prompted after install → Applied OperatorHub config. Warning about missing CatalogSources (expected — operators not yet synced).
- **Day-2 NTP:** TUI Day-2 → NTP → sno2 selected → MCO applied chrony config, NTP synced (10.0.1.8), rhel.pool.ntp.org unreachable (expected on internal network).
- **Cluster Status:** TUI Day-2 → Status → Comprehensive view with operators, nodes, pods, upgrade status. Well formatted.
- **Graceful Shutdown:** TUI Day-2 → Shutdown → Confirmed → Node powered off in ~2m16s. Clean dialog with cert expiry warnings.
- **Graceful Startup:** TUI Day-2 → Startup → Showed "(shut down)" state correctly → VM powered on → API alive in ~30s → All nodes Ready → Console accessible → All operators available. Clean workflow.
- **Delete Cluster:** TUI Day-2 → Delete → Confirmed → VM destroyed, cluster state cleaned.

### DISCO: Mirror uninstall/reinstall/reload via TUI — PASSED
- **Mirror Uninstall:** TUI Advanced → Uninstall Mirror → Confirmed → Docker registry stopped, data removed, firewall port closed. Main menu correctly updated to "no mirror", dependency hints shown on Load/Install.
- **Mirror Reinstall:** TUI → Install Registry → Install locally → Config preserved from previous install → Docker registry installed successfully.
- **Mirror Reload:** TUI → Load images → Confirmed → oc-mirror loaded 193/193 release + 4/4 operator images in ~5m. Main menu updated to "mirror ready".
- **Advanced Menu:** "Uninstall Mirror" option correctly appears/disappears based on mirror state.

### TUI Dynamic Status Verification
- Main menu "Status:" line correctly shows: "no mirror" → "mirror installed" → "mirror ready" based on actual registry state
- "(installed)" tag on registry menu item appears/disappears correctly
- "[install registry]" / "[load mirror first]" dependency hints show correctly
- "(loaded)" / "(synced)" tags update correctly after operations

### DIRECT mode: sno3-ext.example.com full install via TUI — PASSED
- **Cluster:** sno3-ext.example.com (192.168.2.213, vmw, DIRECT mode on Ext Network)
- **Config:** Wizard reconfigure → stable 4.20.20 → vmw → Networking auto-detected 192.168.2.0/24 → Image source toggled to "direct (public registries)" → Review shows "Mirror: (none — direct install)"
- **Install:** ISO generated, VM created on Ext Network, Agent alive in ~1m22s, bootstrap complete, all operators progressed, install complete
- **No bugs found** during DIRECT mode cluster installation flow

---

## Bugs Found by Code Review (2026-06-26, Session 2)

The following bugs were found via static code analysis of the `main..dev` diff and TUI v2 source code. Multiple independent reviews confirmed the highest-severity findings. Bugs marked "Needs TUI/CLI verification" have not yet been reproduced live.

## Bug #901: TUI — Nested mode-switch ESC kills entire TUI instead of returning to parent — BY DESIGN

**Severity:** N/A — BY DESIGN (confirmed by developer)
**Component:** `tui/v2/tui-direct.sh` (753–758), `tui/v2/tui-disco.sh` (233–238)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** BY DESIGN — ESC from mode-switch sub-menus intentionally exits the TUI

### Description

When CONNO Advanced → "Switch to Fully Connected" calls `direct_main`, or CONNO → DISCO via `disco_main`, ESC in the nested menu calls `exit 0` instead of `return`. This kills the entire TUI process rather than returning to the CONNO parent menu.

The sub-menus that DO handle ESC correctly: Advanced, Settings, Day-2, cluster install wizard pages.

### Fix

Replace `exit 0` with `return 0` (or `break` from the menu loop) in `tui-direct.sh:755` and `tui-disco.sh:235` for nested entry paths.

## Bug #902: TUI — Initial setup wizard ESC exits without quit confirmation

**Severity:** High
**Component:** `tui/v2/tui-direct.sh` (325–327, 113), `tui/v2/abatui2.sh` (477, 827–846)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace — needs live verification
**Status:** OPEN

### Description

On first launch with incomplete config, pressing ESC on the channel selection step causes the wizard to return 1 → mode entry returns 1 → main loop breaks → TUI exits with summary. No `confirm_quit()` dialog is shown.

By contrast, "Rerun Wizard" uses `direct_wizard || true` — ESC there correctly returns to the main menu.

## Bug #903: TUI — Splash screen ESC exits immediately without confirmation

**Severity:** Medium
**Component:** `tui/v2/abatui2.sh` (781–784)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

Main menus show `confirm_quit()` on ESC; the splash/welcome screen does not — it calls `exit 0` directly. Inconsistent with the help text that says "At the main menu, ESC offers to exit."

## Bug #904: TUI — Help text claims wizard ESC always returns to main menu (incorrect)

**Severity:** Low
**Component:** `tui/v2/tui-strings2.sh` (405)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

`TUI2_MSG_EXIT_HELP` says "In a wizard, ESC returns to the main menu." But on initial setup, wizard ESC exits the TUI entirely (Bug #902).

## Bug #905: TUI — Progressbox ESC may leave command running as orphan process

**Severity:** Medium
**Component:** `tui/v2/tui-lib.sh` (648–652)
**Found:** 2026-06-26 (code review)
**Verified:** Needs live verification
**Status:** OPEN — unverified

### Description

`_exec_in_tui` pipes `bash -c "$tui_cmd"` into `dialog --progressbox`. If the user closes the progressbox with ESC before the command finishes, the child process may continue running with no TUI feedback.

## Bug #906: TUI — CONNO mode silently overrides user's image source selection

**Severity:** High
**Component:** `tui/v2/tui-cluster.sh` (698–710, 741, 945)
**Found:** 2026-06-26 (code review — confirmed by 4 independent reviews)
**Verified:** Code trace — needs live verification
**Status:** OPEN

### Description

In CONNO mode, `_apply_mode_connection()` forces `cl_connection="mirror"` whenever the mirror is available and has a release image. This runs on wizard entry, after page 1 "Next", and when loading existing `cluster.conf`. If the user explicitly sets `proxy` or `direct` on the Interfaces page, navigating back to page 1 and pressing Next silently reverts their choice. `_persist_cluster_draft()` then writes the forced value to `cluster.conf`.

### Fix

Only default empty `cl_connection` to mirror; never override an explicit user choice. Run `_apply_mode_connection` only on first wizard entry, or only when `cl_connection` is empty.

## Bug #907: TUI — TUI v2 hardcodes `mirror/` directory; named mirrors unsupported — BY DESIGN

**Severity:** N/A — BY DESIGN (confirmed by developer)
**Component:** `tui/v2/tui-mirror.sh` (30, 505–629), `tui/v2/tui-lib.sh` (768–769, 1082), `tui/v2/tui-cluster.sh` (1220–1222, 1585, 1984)
**Found:** 2026-06-26 (code review — confirmed by 2 independent reviews)
**Verified:** Code trace
**Status:** BY DESIGN — TUI v2 intentionally operates on the default `mirror/` directory only

### Description

TUI v2 always uses `$ABA_ROOT/mirror/mirror.conf`, checks `$ABA_ROOT/mirror/.available`, and runs `aba --dir mirror uninstall`. It never reads `mirror_name` from `cluster.conf`. Clusters pointing at `mirror_name=myreg` show wrong registry info, wrong mirror state, and wrong uninstall target.

## Bug #908: TUI — Empty cluster name input silently accepted

**Severity:** Low
**Component:** `tui/v2/tui-cluster.sh` (927–934)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** FIXED — empty cluster name rejected with feedback dialog

### Description

Pressing OK with an empty cluster name field skips validation and keeps the old name with no feedback to the user.

## Bug #909: TUI — `select_cluster()` uses weaker validation than core `_valid_cluster_name()`

**Severity:** Medium
**Component:** `tui/v2/tui-lib.sh` (1357–1360)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

`select_cluster()` regex allows names starting with a digit, has no 63-char limit, and no reserved-name check. A manually created invalid directory could appear selectable.

## Bug #910: TUI — Empty base domain allowed through cluster wizard

**Severity:** Medium
**Component:** `tui/v2/tui-cluster.sh` (959–964, 1562)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

Base domain only validates when non-empty. Review page falls back to `example.com` silently. User can proceed to install with an unintended domain.

## Bug #911: TUI — `aba.conf` values go stale for the session after external edit

**Severity:** Medium
**Component:** `tui/v2/abatui2.sh` (203–207)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

`aba.conf` is sourced once at startup. External edits to `ocp_version`, `platform`, etc. are invisible until "Rerun Wizard". Settings menu re-reads `mirror.conf` each iteration but not `aba.conf`.

## Bug #912: TUI — Wizard persist overwrites external `cluster.conf` edits

**Severity:** Medium
**Component:** `tui/v2/tui-cluster.sh` (134–165, 742–764)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

`_persist_cluster_draft()` is called after every wizard page, blindly writing in-memory state. External edits to `cluster.conf` made while the wizard is open are silently overwritten.

## Bug #913: TUI — DIRECT mode operator search does not persist basket

**Severity:** Medium
**Component:** `tui/v2/tui-direct.sh` (652–654)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

DIRECT action menu → Search Operator Names calls `_operator_search` directly instead of `mirror_select_operators`, skipping basket persistence. Selections are lost on TUI restart.

## Bug #914: TUI — Operator Sets menu exposes auto-generated custom sets

**Severity:** Medium
**Component:** `tui/v2/tui-mirror.sh` (1032–1039)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

`_operator_sets()` globs `templates/operator-set-*`, which includes internally created `operator-set-custom-*` files. Users see timestamped internal sets as normal selectable sets.

## Bug #915: TUI — Operator basket restore drops operators silently on OCP version change

**Severity:** Medium
**Component:** `tui/v2/abatui2.sh` (218–231, 251–253)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

On startup, operators from `aba.conf` are skipped if not found in catalog index for current `ocp_version`. No warning is shown; basket is silently smaller than `aba.conf` suggests.

## Bug #916: TUI — `--disco` bypasses offline payload validation

**Severity:** Medium
**Component:** `tui/v2/abatui2.sh` (387–397 vs 448–460)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

Auto-detected DISCO mode validates offline payload presence. Forced mode via `--disco` skips that check, entering DISCO menu even with no bundle, archives, or mirror.

## Bug #917: TUI — Mirror config review allows non-FQDN hostname on Continue

**Severity:** Medium
**Component:** `tui/v2/tui-mirror.sh` (54, 86, 194–229)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

FQDN validation only runs when the user edits the Hostname field. Pressing Continue without editing can persist and install with a short hostname that would fail FQDN validation.

## Bug #918: TUI — Advanced "Refresh Cluster" enabled for uninstalled clusters

**Severity:** Low
**Component:** `tui/v2/tui-lib.sh` (985–989), `tui/v2/tui-cluster.sh` (1887–1890)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

`_CLUSTER_DAY2_AVAIL` is true when any `cluster.conf` exists, not when a cluster is installed. Refresh Cluster for an uncreated cluster fails at CLI level.

## Bug #919: Core — `cluster-startup.sh` overrides externalized kubeconfig with stale local backup

**Severity:** High
**Component:** `scripts/cluster-startup.sh` (17–22)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace — needs live verification
**Status:** OPEN

### Description

After resolving kubeconfig via `cluster_kubeconfig()` (prefers externalized state), startup always repoints KUBECONFIG to local copy when `iso-agent-based/auth.backup/kubeconfig` exists. This contradicts the "prefer externalized state" logic. `cluster-graceful-shutdown.sh` keeps the externalized KUBECONFIG — inconsistent.

## Bug #920: Core — `create-cluster-conf.sh` writes invalid CIDR when prefix_length is empty

**Severity:** Medium
**Component:** `scripts/create-cluster-conf.sh` (77)
**Found:** 2026-06-26 (code review — confirmed by 3 independent reviews)
**Verified:** Code trace
**Status:** FIXED — prefix_length non-empty guard before CIDR composition

### Description

Writes `machine_network=10.0.0.0/` (invalid CIDR) when `aba.conf` has IP-only `machine_network` without `prefix_length`.

## Bug #921: Core — `cluster-version.sh` exits 0 when cluster API is unreachable

**Severity:** Medium
**Component:** `scripts/cluster-version.sh` (17)
**Found:** 2026-06-26 (code review — confirmed by 3 independent reviews)
**Verified:** Code trace
**Status:** OPEN

### Description

`cluster_api_reachable "$_kc" || exit 0` returns success with empty stdout. Callers treat this as "version unknown" rather than failure. TUI upgrade logic allows confusing prompts.

## Bug #922: Core — `reg-sync.sh` mirror-only pull secret blocked by new preflight

**Severity:** High
**Component:** `scripts/reg-sync.sh` (~31)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace — needs live verification
**Status:** OPEN

### Description

New `require_internet_and_pull_secret` checks global `pull_secret_file` from `aba.conf` first. Old code allowed sync when `pull-secret-mirror.json` existed even if global pull secret was missing. Now sync aborts before reaching mirror-specific check.

## Bug #923: Core — `day2.sh` stale `$KUBECONFIG` env prevents cluster resolution

**Severity:** High
**Component:** `scripts/day2.sh` (~39–46)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace — needs live verification
**Status:** OPEN

### Description

Kubeconfig resolved via `cluster_kubeconfig` only when `$KUBECONFIG` is unset. If environment has a stale/wrong `$KUBECONFIG`, script probes that path and aborts instead of falling back.

## Bug #924: Core — Removed `port0`/`port1` → `ports` backwards-compat migration

**Severity:** Medium
**Component:** `scripts/include_all.sh` (normalize-cluster-conf)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

Legacy `cluster.conf` files with only `port0=`/`port1=` and no `ports=` now get no `ports` export. `verify-cluster-conf` then fails with "ports value is missing". Regression for upgraded deployments.

## Bug #925: Core — `reg_vendor` dropped from mirror state immutability

**Severity:** Medium
**Component:** `scripts/include_all.sh` (_state_override_mirror)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

If user edits `reg_vendor` in `mirror.conf` after install (quay→docker), installed value in `state.sh` is no longer enforced. Can cause wrong password validation or wrong uninstall vendor selection.

## Bug #926: Core — Disk-space warnings reference Quay path for Docker registries

**Severity:** Low
**Component:** `scripts/reg-sync.sh` (95, 107–110), `scripts/reg-load.sh` (90, 107–109), `scripts/reg-save.sh` (108)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

All three scripts set `reg_root=$data_dir/quay-install` unconditionally. Docker registries use `$data_dir/docker-reg`. Misleading warnings, not operationally fatal.

## Bug #927: Core — `day2.sh` returns success despite custom manifest apply failures

**Severity:** Medium
**Component:** `scripts/day2.sh` (196–213)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

Custom manifest failures increment `failure_count` but function always returns 0. Callers miss partial failures.

## Bug #928: Core — `create-cluster-conf.sh` ask=true aborts before filling existing cluster.conf

**Severity:** Medium
**Component:** `scripts/create-cluster-conf.sh` (~54–87)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

When `ask=true` and aba.conf auto-detect fills values, script exits 1 before the block that fills empty fields in existing cluster.conf.

## Bug #929: Core — `aba.sh` uses directory basename instead of `cluster_name` for kubeconfig

**Severity:** Medium
**Component:** `scripts/aba.sh` (~1113–1115, ~1157–1166)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

`cluster_kubeconfig` called with `$(basename "$PWD")` instead of `cluster_name` from `cluster.conf`. Fails when directory name differs from `cluster_name`.

## Bug #930: Core — Drift warning deduplication broken (subshell PID mismatch)

**Severity:** Low
**Component:** `scripts/include_all.sh` (~944–946)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

Drift flag file uses `$$` inside process-substitution subshell. Each subshell gets new PID, so warning fires on every normalize call, not once per invocation.

## Bug #931: Core — `reg-uninstall.sh` cleanup can fail under set -e when regcreds_dir missing

**Severity:** Low
**Component:** `scripts/reg-uninstall.sh` (159–164)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

Else branch runs `rm -rf` on glob when directory doesn't exist. With nullglob off, may abort after successful uninstall.

## Bug #932: Core — `require_internet_and_pull_secret()` truncates error list to 2

**Severity:** Low
**Component:** `scripts/include_all.sh` (3882–3891)
**Found:** 2026-06-26 (code review)
**Verified:** Code trace
**Status:** OPEN

### Description

When 3+ issues exist, only two are shown in abort message.

---

## Documentation Bugs (README.md)

## Docbug #D01: `int_connection` empty = use mirror never explained

**Status:** OPEN — README only documents `direct` and `proxy` values; no mention that leaving `int_connection` empty routes through the mirror

**Severity:** High
**Component:** README.md — Connected Installation, Customizing Install Config
**Found:** 2026-06-26 (README review — confirmed by 2 independent reviews)

### Description

README documents `int_connection=direct` and `int_connection=proxy` but never explains that DISCO/CONNO clusters should leave `int_connection` empty to use the local mirror. Users in disconnected modes may set direct/proxy incorrectly.

## Docbug #D02: Misleading proxy guidance in Partially Disconnected Prerequisites

**Status:** OPEN — line 1206 still tells partially disconnected users to "set `int_connection=proxy`" which is misleading for CONNO

**Severity:** High
**Component:** README.md (lines 1204–1206)
**Found:** 2026-06-26 (README review)

### Description

Tells users to set `int_connection=proxy` in the partially disconnected section. CONNO clusters typically use the mirror (`int_connection` empty). Bastion proxy should be shell env vars only.

## Docbug #D03: `~/.vmware.conf` and `~/.kvm.conf` not documented

**Status:** OPEN — README has no mention of `~/.vmware.conf` or `~/.kvm.conf` persistent templates

**Severity:** High
**Component:** README.md — Common Requirements, Air-Gapped Prerequisites
**Found:** 2026-06-26 (README review — confirmed by 2 reviews)

### Description

README only documents ABA repo-level `vmware.conf`/`kvm.conf`. The `~/.vmware.conf`/`~/.kvm.conf` persistent templates (used by install scripts and TUI) and their role in bundles/air-gapped deploys are undocumented.

## Docbug #D04: FAQ uses wrong flag `-s cluster.conf`

**Status:** OPEN — line 1813 still shows `-s cluster.conf` where `-s` means `--step`, not a config path

**Severity:** Medium
**Component:** README.md (line 1813)
**Found:** 2026-06-26 (README review)

### Description

Recovery FAQ step uses `aba cluster -n sno -t sno -i 10.0.1.202 -s cluster.conf`. `-s` is `--step`, not a config path.

## Docbug #D05: `--monitor-timeout` documented but not implemented

**Status:** OPEN — `--monitor-timeout` listed on line 694 as a runtime flag but not implemented in any script

**Severity:** Medium
**Component:** README.md — Customizing Install Configuration
**Found:** 2026-06-26 (README review)

### Description

Listed as an upgrade flag but does not exist anywhere in the codebase.

## Docbug #D06: Command Reference missing ~10 important commands

**Status:** OPEN — `aba rescue` now in table but still missing: `aba vmw`, `aba kvm`, `aba install`, `aba iso`, `aba version`, `aba getco`, `aba cluster-version`

**Severity:** Medium
**Component:** README.md — Command Reference
**Found:** 2026-06-26 (README review)

### Description

Missing: `aba vmw`, `aba kvm`, `aba install`, `aba iso`, `aba -d mirror clean`, `aba mirror --name`, `aba rescue`, `aba getco`, `aba cluster-version`, `aba version`.

## Docbug #D07: CONNO/DISCO/DIRECT mode names not mapped to TUI flags

**Status:** FIXED — TUI section (lines 277-279) now maps `--direct`/`--disco`/`--conno` to their full mode names

**Severity:** Medium
**Component:** README.md — Choose Your Path
**Found:** 2026-06-26 (README review)

### Description

TUI flags `--conno`, `--disco`, `--direct` are documented but never mapped to README section names (Connected/Partially Disconnected/Air-Gapped).

## Docbug #D08: OSUS section thin on prerequisites and setup steps

**Status:** LOW RISK — OSUS section now has prerequisites and full upgrade workflow; minor gaps (graph-image details) unlikely to confuse users

**Severity:** Medium
**Component:** README.md — Cluster Updates (OSUS)
**Found:** 2026-06-26 (README review)

### Description

Missing: graph-image mirroring prereqs, UpdateService CR, policy engine URI, `aba day2` must run first, direct-mode clusters don't need OSUS.

## Docbug #D09: NTP documentation lacks Day-0 vs Day-2 distinction

**Status:** LOW RISK — NTP section is brief but `ntp_servers` documented in aba.conf table, pre-flight checks NTP, `aba day2-ntp` in command reference; info exists but scattered

**Severity:** Medium
**Component:** README.md — Synchronize NTP
**Found:** 2026-06-26 (README review)

### Description

Only ~3 lines. Missing: `ntp_servers` in `aba.conf` for install-time NTP, `aba day2-ntp` for Day-2 MachineConfig, preflight NTP reachability check.

## Docbug #D10: VLAN/bond configuration lacks concrete examples

**Status:** OPEN — FAQ explains the concept but provides no `ports=`/`vlan=` syntax examples or CLI flag usage

**Severity:** Medium
**Component:** README.md — FAQ
**Found:** 2026-06-26 (README review)

### Description

FAQ mentions bonds/VLAN possible but gives no example of `ports=ens1f0,ens2f0` or `vlan=100` or `aba cluster --vlan`.

## Docbug #D11: Bare-metal end-to-end workflow fragmented

**Status:** FEATURE REQUEST — all bare-metal info exists but spread across sections; a consolidated walkthrough would be a doc enhancement

**Severity:** Medium
**Component:** README.md — Installing a Cluster
**Found:** 2026-06-26 (README review)

### Description

`macs.conf`, ISO generation, and `aba mon` scattered across sections. No single bare-metal walkthrough.

## Docbug #D12: "ABA requires root access" contradicts Common Requirements

**Status:** NOT A BUG — line 213 says "requires root access, either directly or via passwordless sudo" which is consistent with line 1092's sudo explanation

**Severity:** Medium
**Component:** README.md (line 213 vs 1092)
**Found:** 2026-06-26 (README review)

### Description

Line 213 says "root access required"; Common Requirements correctly says "normal user with passwordless sudo."

