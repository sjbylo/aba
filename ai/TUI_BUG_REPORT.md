# ABA TUI v2 Bug Report — Hackathon
**Date:** 2026-05-14
**Tester:** AI Agent
**Test Host:** registry4 (~/aba, dev branch)
**ABA Version:** 4.21.14 (stable channel)

---

## Re-verification Sweep (2026-06-22)

**Host:** conno (~/aba, dev branch @ e736eae)
**Method:** Live reproduction via tmux session "test" on conno

### REPRODUCED (confirmed still open):
| Bug | Summary | Method |
|-----|---------|--------|
| #23 | `_operator_menu` marks basket dirty without changes | Code: dirty flag set unconditionally after submenu visit |
| #27 | ~~NOT A BUG~~ `confirm_quit` ESC (255) treated as "yes, quit" | Intentional: ESC-ESC = quick exit shortcut |
| #35 | Metacharacter `\|` in cluster name causes shell injection | Live: `aba cluster --name "test\|bad"` → `/bin/sh: bad: command not found` |
| #67 | `_cluster_load_conf` strips `#` from values | Live: parser `${val%%#*}` truncates `pool.ntp.org#bad` to `pool.ntp.org` |
| #294 | `_apply_mode_connection` doesn't convert proxy→mirror in DISCO | Code: only handles `direct`→`mirror`, leaves `proxy` |
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
| #462 | `aba tui` exits silently (code 0) | Live: no output, no TUI, exit 0 |
| #467 | `aba --version 4.99.99` accepted without validation | Live: wrote to aba.conf without network check |
| #471 | Typo "reprecated" in verify-mirror-conf | Code: still at include_all.sh:628 |
| #472 | `aba --channel eus` accepted (invalid channel) | Live: wrote `ocp_channel=eus` to aba.conf |
| #474 | `aba --editor 'nano -w'` truncates at space | Live: saved only `editor=nano` |
| #475 | `aba --vmware /nonexistent` silently accepted | Live: exit 0, no error |
| #476 | `aba --platform bogus` accepted | Live: wrote `platform=bogus` to aba.conf |
| #477 | `aba cluster --starting-ip 999.999.999.999` accepted | Live: created cluster dir with invalid IP |
| #478 | `int_connection` regex accepts substring matches | Live: `directx` matches `direct\|proxy\|mirror` |
| #480 | `aba -d mirror install --help` shows wrong help | Live: shows general help, not mirror-specific |

### CANNOT REPRODUCE (likely fixed):
| Bug | Summary | Evidence |
|-----|---------|----------|
| #295 | No Day-2 prompt after sync/load | Code: `_offer_day2_after_mirror_update` IS called after both sync and load |
| #311 | Stale mirror cache after uninstall | Fixed by commit 4bffd928 (post-hook fires unconditionally) |
| #322 | Stale cache after version change via wizard | Fixed by commit 4bffd928 (_invalidate_mirror_cache after wizard) |
| #339 | Install gate trusts stale cache | Live: gate correctly showed "Mirror Not Synced" prompt |
| #340 | Advanced uninstall no cache invalidation | Code: all uninstall paths now have _invalidate_mirror_cache |
| #347 | Base domain rejects uppercase | Live: `_valid_fqdn 'Example.COM'` returned VALID |
| #409 | replace-value-conf regex escaping | Code: now uses `grep -F` first (fixed string) |
| #482 | RC→GA upgrade blocked | Code: old numeric comparison removed, uses graph lookup |

### NOT YET VERIFIED (require special infrastructure):
- DISCO-mode bugs (#16, #312, #333, #345, #352) — need disco host with payload
- Cluster-dependent bugs (#288, #289, #314, #317, #368, #465) — need installed cluster
- Mirror sync-dependent bugs (#285, #306, #426) — need synced mirror

---

## Bug #1: ~~FIXED~~ `cluster_monitor` uses `select_installed_cluster` — Cannot monitor installing clusters
**File:** `tui/v2/tui-cluster.sh` line 1713
**Severity:** HIGH — Functional breakage
**Status:** FIXED — Now uses `select_cluster` with `"installing"` filter.

**Expected:** User should see installing clusters in the "Finalize Installation" selector.
**Actual:** No clusters shown, user gets "No installed clusters found" message.
**Verified:** YES — via TUI on registry4 (no cluster has `.install-complete` marker, "Finalize Installation" is greyed out with "[install cluster first]")

---

## Bug #2: ~~INVALID~~ `_direct_operators` uses undefined `$_ver_short` variable (dead code)
**File:** `tui/v2/tui-direct.sh` line 438
**Severity:** LOW — Function is never called (dead code)
**Steps to reproduce:**
1. The function `_direct_operators()` is defined at line 415 but never called from anywhere in the code.
2. The DIRECT mode wizard steps do not include an "operators" step.
3. The DIRECT action menu does not have a "Select Operators" option.

**Root cause:** `_direct_operators()` was likely intended as a wizard step but was never wired into the step flow. If it were called, line 438's `_operator_search "$_ver_short"` would fail because `$_ver_short` is a local variable in `direct_wizard()`.

**Expected:** Either wire the function into the wizard/action menu, or remove the dead code.
**Actual:** Dead code that would fail if called.
**Verified:** YES — code search confirms no call sites exist.

---

## Bug #3: ~~FIXED~~ `_cluster_execute` doesn't pass `--platform bm` — Platform mismatch
**File:** `tui/v2/tui-cluster.sh` line 1352
**Severity:** CRITICAL — Creates wrong cluster type
**Status:** FIXED (2026-05-26 re-validation) — New two-step wizard generates `cluster.conf` with explicit `--platform $cl_platform` (line 184) before the install step runs. The install command reads platform from the generated `cluster.conf`.
**Steps to reproduce:**
1. Start TUI with `aba.conf` having `platform=vmw`
2. Go to Install Cluster wizard
3. On Basics page, toggle Platform to "bm" (bare-metal)
4. Complete wizard and press Install → press "Command" to view
5. The generated command does NOT include `--platform bm`
6. `aba.sh` reads `platform=vmw` from `aba.conf` → creates VMware VMs instead of bare-metal

**Root cause:** Line 1352: `[[ -n "$cl_platform" && "$cl_platform" != "bm" ]] && cmd="$cmd --platform $cl_platform"` — explicitly skips passing `--platform` when `bm` is selected, assuming it's the default. But `aba.conf` may have a different platform.

**Expected:** `--platform bm` should always be passed to ensure the correct platform.
**Actual:** Platform from aba.conf overrides the user's TUI selection for bare-metal.
**Verified:** YES — via TUI on registry4 (pressed "Command" button on execution dialog, confirmed missing `--platform bm`)

---

## Bug #4: ~~FIXED~~ VMware password shown in plaintext in inputbox
**File:** `tui/v2/tui-cluster.sh` line 373
**Severity:** MEDIUM — Security concern
**Status:** FIXED — Now uses `_tui_prompt_password()` which calls `--passwordbox` with hidden input.

---

## Bug #5: ~~FIXED~~ VMware password with single quotes causes config corruption
**File:** `tui/v2/tui-cluster.sh` line 375
**Severity:** MEDIUM — Data corruption for edge case
**Status:** FIXED — `_tui_prompt_password()` rejects single quotes; `_tui_reject_squote()` blocks them in all other fields.

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

## Bug #7: ~~INVALID~~ `_configure_vmw_form` always overwrites `~/.vmware.conf`
**File:** `tui/v2/tui-cluster.sh` line 349
**Severity:** LOW — Data loss potential
**Steps to reproduce:**
1. Have a valid `~/.vmware.conf` with correct password
2. Start TUI → go to VMware config form (triggered by missing vmware.conf)
3. Press Continue without changing anything
4. Template defaults overwrite cached `~/.vmware.conf`

**Root cause:** Line 349: `[[ -s "$conf_path" ]] && cp "$conf_path" "$HOME/.vmware.conf"` unconditionally copies the project vmware.conf to the home directory cache. If the user just opened the form and pressed Continue, template defaults overwrite the cached config.

**Expected:** Only overwrite cache if changes were actually made.
**Actual:** Cache overwritten on every Continue, even without changes.
**Verified:** YES — via TUI on registry4 (template defaults were saved to `~/.vmware.conf` after pressing Continue)

---

## Bug #8: ~~INVALID~~ CONNO menu `disco_switch_label` is confusing
**File:** `tui/v2/abatui2.sh` line 417
**Severity:** LOW — UX confusion
**Steps to reproduce:**
1. Start TUI in CONNO mode
2. Menu shows "Switch to Fully Disconnected" at bottom
3. No indication that this downloads prereqs and enters DISCO mode with the current repo

**Root cause:** The label "Switch to Fully Disconnected" doesn't clarify the implications.

**Verified:** YES — via TUI

---

## Bug #9: ~~NOT A BUG~~ `_cluster_page_iface` — Connection toggle includes "direct" in non-DIRECT modes
**File:** `tui/v2/tui-cluster.sh` lines 1284-1305
**Severity:** ~~MEDIUM~~ — N/A
**Status:** NOT A BUG — DISCO mode correctly locks to "mirror" only (lines 1291-1297). CONNO mode correctly allows all three (mirror/proxy/direct) per user clarification (Bug #24 discussion). DIRECT mode correctly allows only direct/proxy (lines 1285-1290).
**Steps to reproduce:**
1. Start TUI in CONNO mode
2. Install Cluster → Interfaces page
3. Toggle Connection: proxy → direct → mirror → proxy
4. "direct" is available even in CONNO/DISCO modes

**Root cause:** The toggle cycle in non-DIRECT modes is `mirror → proxy → direct → mirror`. In CONNO mode, "direct" is semantically wrong (nodes should use the mirror). In DISCO mode, "direct" is invalid (no internet).

**Expected:** In non-DIRECT modes, connection toggle should skip "direct".
**Actual:** User can select "direct" in CONNO and DISCO modes.
**Verified:** YES — via TUI on registry4 (toggled Connection to "direct" in CONNO mode)

---

## Bug #10: ~~FIXED~~ `tui_advanced_menu` ignores Help button (rc=2 fallthrough)
**File:** `tui/v2/tui-cluster.sh` lines 1644-1652
**Severity:** LOW — UI inconsistency
**Steps to reproduce:**
1. Open Advanced Options from any mode
2. Press Help button
3. Dialog returns rc=2 but no `case 2)` branch exists
4. Falls through to default handling — may cause unexpected behavior

**Root cause:** The Advanced menu dialog has no `--help-button` flag but also no `case 2)` handler. Other menus handle Help with `case 2: show_help; continue`.

**Expected:** Either add Help support or ensure no unhandled return codes.
**Actual:** rc=2 falls through to `[[ $rc -ne 0 ]] && return 0`, causing immediate return.
**Verified:** YES — code analysis confirmed (compare with other menus that have `case 2:` handlers)

---

## Bug #11: ~~FIXED~~ `_day2_ssh` masks SSH failures with `|| true`

**Status:** FIXED in commit fe5f8bde — captures exit code and displays error in red when SSH fails
**File:** `tui/v2/tui-cluster.sh` line 1860
**Severity:** LOW — Diagnostic loss
**Steps to reproduce:**
1. Install a cluster
2. Go to Day-2 → SSH into Rendezvous Server
3. SSH fails (wrong IP, unreachable host)
4. User only sees "Press ENTER to return to TUI" with no error indication

**Root cause:** `bash -c "aba -d $SELECTED_CLUSTER ssh" || true` masks the exit code. No error message is shown to the user.

**Expected:** Show SSH error message or exit code to the user.
**Actual:** Failure is silently swallowed.
**Verified:** YES — code analysis confirmed

---

## Bug #12: ~~FEATURE REQUEST~~ No proxy configuration fields in TUI cluster wizard
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

## Bug #15: ~~FIXED~~ `replace-value-conf` uses relative path `aba.conf` in operator persistence

**Status:** FIXED in commit e2122a11 — changed to `$ABA_ROOT/aba.conf` in all 4 operator persistence calls
**File:** `tui/v2/tui-mirror.sh` lines 538-539, 578-579
**Severity:** LOW — Works as long as cwd is `$ABA_ROOT`
**Steps to reproduce:**
1. If the shell's current working directory is ever changed from `$ABA_ROOT`
2. Operator set/search calls `replace-value-conf -f aba.conf`
3. Writes to wrong file or fails

**Root cause:** Uses `aba.conf` instead of `$ABA_ROOT/aba.conf`. The TUI sets `cd "$ABA_ROOT"` in `_exec_in_tui` but operator selection happens outside that function.

**Expected:** Use `$ABA_ROOT/aba.conf` for consistency and robustness.
**Actual:** Works in practice but fragile.
**Verified:** YES — code analysis confirmed

---

## Bug #16: ~~NOT A BUG~~ Mode switch CONNO→DISCO does not create `.bundle` flag

**Status:** NOT A BUG — `_disco_bundle_wizard_gate()` explicitly handles missing `.bundle` (line 22-25). The switch is a temporary nested call; creating `.bundle` would permanently alter startup detection.
**File:** `tui/v2/abatui2.sh` lines 658-664
**Severity:** LOW — Cosmetic / minor inconsistency
**Steps to reproduce:**
1. Start TUI in CONNO mode
2. "Switch to Fully Disconnected"
3. Enters DISCO mode but `.bundle` file is not created
4. Some DISCO operations check `is_bundle_mode()` which reads `.bundle`

**Root cause:** The CONNO→DISCO switch calls `disco_main` directly without setting `.bundle`. However, `disco_reset` (the reverse operation) does remove `.bundle`. The asymmetry means DISCO operations that depend on `.bundle` may behave differently when entered via "Switch" vs via actual bundle unpacking.

**Expected:** Either create `.bundle` on switch or make DISCO operations not depend on it.
**Actual:** Potential inconsistency in DISCO behavior depending on entry path.
**Verified:** YES — code analysis confirmed

---

## Bug #17: Forced `--conno`/`--disco`/`--direct` flags skip sanity checks
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

## Bug #18: TUI progressbox appears frozen during long waits (openshift-install wait-for)
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

## Bug #19: ~~FIXED~~ Interfaces help text mentions "mirror" in DIRECT mode

**Status:** FIXED in commit 0cb4a037 — help text now conditional on `$_TUI_MODE`
**File:** `tui/v2/tui-cluster.sh` lines 1115-1122
**Severity:** LOW — Misleading help text
**Steps to reproduce:**
1. Start TUI → switch to DIRECT mode (Fully Connected)
2. Install Cluster → Interfaces page
3. Press Help button
4. Help text lists "mirror: fully through the mirror registry" as a connection option
5. But in DIRECT mode, "mirror" is not available as a connection toggle option

**Root cause:** The help text in `_cluster_page_iface()` at lines 1115-1122 is hardcoded and always includes all three connection options (mirror, proxy, direct), regardless of the current mode. In DIRECT mode, the connection toggle only offers "proxy" and "direct".

**Expected:** Help text should only list connection options available in the current mode.
**Actual:** Help text shows "mirror" even in DIRECT mode where it's not available.
**Verified:** YES — via TUI on registry4 (opened Help in Interfaces page while in DIRECT mode)

---

## Bug #20: ~~NOT A BUG~~ DISCO mode `exit 0` terminates entire TUI when entered from CONNO
**File:** `tui/v2/tui-disco.sh` lines 224-230
**Severity:** N/A
**Status:** NOT A BUG — By design. ESC in any mode (regardless of how you got there) shows the exit confirmation dialog. If confirmed, the TUI exits. This is consistent and expected: the user explicitly chose to quit.

---

## Bug #21: ~~NOT A BUG~~ `disco_reset` return code 2 is swallowed when DISCO entered from CONNO
**File:** `tui/v2/tui-cluster.sh` line 1921
**Severity:** ~~HIGH~~ — N/A
**Status:** NOT A BUG — When DISCO is entered from CONNO (via "Switch to Fully Disconnected"), the user's starting point was CONNO. After `disco_reset`, returning to CONNO is correct behavior. The exit code 2 "re-detect" signal is only meaningful for top-level entry (bundle unpack), which is handled properly at `abatui2.sh` line 840. The `_TUI_DISCO_FROM_CONNO` flag exists for exactly this purpose.

---

## Bug #22: ~~FIXED~~ `_cluster_execute` unquoted variables in command string
**File:** `tui/v2/tui-cluster.sh` line 1493
**Severity:** MEDIUM — Command injection / breakage for special chars
**Status:** FIXED — Architecture changed. TUI no longer passes user fields as command flags. It generates cluster.conf first, then runs `aba cluster --name X --step install` which reads from the config file. No unquoted user input in command strings.

---

## Bug #23: ~~FIXED~~ `_operator_menu` marks basket dirty even when no changes made

**Status:** FIXED in commit b2a070c4 — only marks dirty when basket count actually changes
**File:** `tui/v2/tui-mirror.sh` lines 770-772
**Severity:** LOW — Unnecessary ISC regeneration
**Steps to reproduce:**
1. Open Select Operators → View/Edit Basket
2. Press Back/Cancel without making any changes
3. `_OP_BASKET_DIRTY=true` is set and `_persist_operator_basket` is called
4. ISC is regenerated unnecessarily

**Root cause:** After returning from `_operator_view_basket`, the code unconditionally sets `_OP_BASKET_DIRTY=true` and calls `_persist_operator_basket`, regardless of whether the user actually changed anything.

**Expected:** Only mark dirty and persist when actual changes were made.
**Actual:** Every view/edit of basket triggers a persist and potential ISC regen.
**Verified:** YES — code analysis confirmed

---

## Bug #24: ~~FIXED~~ Cluster wizard overwrites `int_connection` loaded from existing cluster.conf
**File:** `tui/v2/tui-cluster.sh` line 677
**Severity:** HIGH — Wrong install flags for re-edited clusters
**Status:** FIXED — `_apply_mode_connection` now only overrides in DIRECT and DISCO modes; CONNO preserves all three valid connection values (mirror/proxy/direct).

---

## Bug #25: ~~NOT A BUG~~ Changing cluster name skips network auto-detect
**File:** `tui/v2/tui-cluster.sh`
**Severity:** ~~MEDIUM~~ — N/A
**Status:** NOT A BUG — After page 1 completes, `_cluster_generate_defaults()` (line 717) runs `aba cluster --step cluster.conf` which generates a proper cluster.conf with all defaults (network, DNS, gateway, VIPs) using the NEW cluster name. The initial auto-detect (lines 644-674) is just a cosmetic pre-fill for the first menu display; `_is_reentry` logic no longer exists in the code.

---

## Bug #26: ~~LOW RISK~~ Stale worker count when switching cluster type after loading cluster.conf
**File:** `tui/v2/tui-cluster.sh` line 943
**Severity:** LOW — Minor cosmetic issue
**Status:** LOW RISK — The toggle (line 943) preserves `cl_workers` if non-zero, which is intentional UX (remembers user's previous setting). When creating a NEW cluster, `_cluster_generate_defaults` resets everything properly. Only manifests if user toggles types within the same session — and the "stale" value is their own previous choice. Acceptable behavior.

---

## Bug #27: ~~NOT A BUG~~ `confirm_quit` ESC (exit code 255) treated as "yes, quit"
**File:** `tui/v2/tui-lib.sh` — `confirm_quit()` function
**Severity:** N/A
**Status:** NOT A BUG — INTENTIONAL DESIGN

**Correct ESC behavior in ABA TUI:**
- ESC always means "go back one step" / "I want out"
- From submenu → parent menu
- From top-level menu → quit confirmation dialog
- From wizard → back to menu that started the wizard
- From the quit confirmation dialog itself → confirms quit (ESC-ESC = quick exit)

**Why this is correct:** ESC-ESC is a deliberate "force quit" shortcut. A single ESC shows the confirmation (safety net for accidental press). A second ESC on that confirmation means the user clearly wants out. This is good UX — fast exit for intentional users, safety for accidental presses.

**Code (correct as-is):**
```bash
case "$rc" in
    0)   return 0 ;;   # Yes button → quit
    255) return 0 ;;   # ESC again → quit (intentional: ESC-ESC = fast exit)
    *)   return 1 ;;   # No/Continue button → stay
esac
```

---

## Bug #28: ~~NOT A BUG~~ `mirror_save` has no "mirror not installed" guard (unlike sync/install)
**File:** `tui/v2/tui-mirror.sh`
**Severity:** ~~MEDIUM~~ — N/A
**Status:** NOT A BUG — `aba save` (m2d) downloads from internet to disk tar archives. It does NOT need a local mirror registry installed. Only `aba sync` (m2m) pushes to the mirror.
**Steps to reproduce:**
1. Start TUI in CONNO mode
2. Without installing a mirror, press "S" → Save Images (mirror2disk)
3. No mirror config review or "mirror not installed" check is shown
4. `aba save` runs against unconfigured mirror, fails with opaque errors

**Root cause:** The Sync flow (abatui2.sh 579-587) has a guard: if mirror not available, offers to install & sync first. The Save flow (572-577) has no equivalent guard — it just checks internet connectivity and runs `mirror_save` directly.

**Expected:** Save should check if mirror is configured and offer to set it up first (like Sync does).
**Actual:** Save runs against unconfigured mirror, leading to confusing failures.
**Verified:** YES — code analysis confirmed

---

## Bug #29: ~~FIXED~~ ISC "Reset to auto-generated" races with file regeneration
**File:** `tui/v2/tui-mirror.sh` lines 651-656
**Severity:** ~~MEDIUM~~ — N/A
**Status:** FIXED — The View/Edit paths (lines 651-656) now check `run_once -p -i "aba:isconf:generate"` before displaying the ISC file. If regeneration is in-flight, it shows an "ISC generating..." infobox and waits for completion via `run_once -q -w`. Race condition is handled.

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

## Bug #31: ~~NOT A BUG~~ DIRECT wizard `_direct_save_config` does not persist `pull_secret_file`
**File:** `tui/v2/tui-direct.sh`
**Severity:** ~~MEDIUM~~ — N/A
**Status:** NOT A BUG — The `aba.conf` template already sets `pull_secret_file=~/.pull-secret.json` (the same path the TUI uses). When `_direct_save_config` generates aba.conf from template (lines 660-668), the pull_secret_file value is already correct.
**Steps to reproduce:**
1. Start DIRECT wizard
2. Enter/select a pull secret (saved to default `~/.pull-secret.json`)
3. Finish wizard — `_direct_save_config` writes `ocp_channel`, `ocp_version`, `platform` to `aba.conf`
4. `pull_secret_file` is NOT written to `aba.conf`
5. On next TUI or CLI invocation, `pull_secret_file` from `aba.conf` may point elsewhere or be missing

**Root cause:** `_direct_save_config` only saves channel, version, and platform. The pull secret file path is only held in the in-memory variable `_direct_pull_secret` (defaults to `$HOME/.pull-secret.json`).

**Expected:** `pull_secret_file` should be saved to `aba.conf` by the wizard.
**Actual:** Pull secret path is ephemeral, not persisted.
**Verified:** YES — code analysis confirmed

---

## Bug #32: ~~NOT A BUG~~ DIRECT mode: cancelling wizard exits entire TUI
**File:** `tui/v2/tui-direct.sh`, `tui/v2/abatui2.sh`
**Severity:** ~~MEDIUM~~ — N/A
**Status:** NOT A BUG — Exiting the TUI on ESC/cancel from any mode is by design (same as Bug #20). The TUI shows `confirm_quit` dialog before exit. If user doesn't want to proceed with setup, exiting is the correct behavior.

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

## Bug #35: ~~FIXED~~ Metacharacter filter allows single `|` and `>` through
**File:** `tui/v2/tui-lib.sh` lines 451-456, 523-528
**Severity:** LOW — Defense-in-depth gap
**Steps to reproduce:**
1. If any code path passes a command with `| malicious` or `> /important/file`, the filter doesn't catch it
2. Only `||`, `>>`, `&&`, `<<`, `` ` ``, `$`, `;` are blocked
3. Single `|` (pipe) and single `>` (redirect) pass through

**Root cause:** The metacharacter regex was designed to block common shell injection patterns but doesn't cover all dangerous operators.

**Expected:** Filter should also block `|` and `>` (or use a whitelist approach).
**Actual:** Single pipe and redirect operators pass the filter.
**Verified:** YES — code analysis confirmed

---

## Bug #10 — ~~UPDATED: NOT A BUG~~
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

## Bug #37: ~~FIXED~~ `_cluster_load_conf` doesn't load `macs.conf` for bare-metal clusters
**File:** `tui/v2/tui-cluster.sh` line 642
**Severity:** MEDIUM — MACs empty when re-entering wizard for existing BM cluster
**Status:** FIXED — Added `macs.conf` loading after `_cluster_load_conf` in `cluster_install_flow()`. When re-entering the wizard for an existing BM cluster, MACs are now loaded from `$ABA_ROOT/$cl_name/macs.conf`.

**Expected:** When re-entering the wizard, MACs from `macs.conf` should be loaded and displayed.
**Actual:** MACs appear empty; user may re-enter them unnecessarily.
**Verified:** YES — code analysis confirmed

---

## Bug #38: ~~DEFERRED~~ `prefix_length` before `machine_network` in cluster.conf drops subnet prefix
**File:** `tui/v2/tui-cluster.sh` lines 86-120
**Severity:** MEDIUM — Wrong network configuration (theoretical)
**Status:** DEFERRED — Real fix is architectural: merge `prefix_length` into `machine_network` as a single CIDR value (per user). In practice, ABA always generates cluster.conf with `machine_network` before `prefix_length` so the ordering issue doesn't trigger.

---

## Bug #39: ~~INVALID~~ `mirror_install()` — empty choice returns success without installing
**File:** `tui/v2/tui-mirror.sh` lines 197-201
**Severity:** LOW — Edge case silent no-op
**Steps to reproduce:**
1. Open mirror install dialog (local vs remote chooser)
2. If dialog returns an empty or unexpected value for `choice`
3. `case "$choice" in 1) ... 2) ... esac` matches nothing
4. `return $?` returns 0 (success) without installing anything

**Root cause:** No default branch in the `case` statement; unexpected dialog output leads to silent success.

**Expected:** Default branch should return error or loop.
**Actual:** Silent success with no install.
**Verified:** YES — code analysis confirmed

---

---

## Bug #41: ~~NOT A BUG~~ `day2.sh` treats `int_connection=proxy` same as `direct` — skips all mirror integration
**File:** `scripts/day2.sh` lines 27-31
**Severity:** N/A
**Status:** NOT A BUG — `proxy` is another way (like `direct`) to reach Red Hat registries over the internet. Proxy does NOT enforce use of the mirror. Any non-empty `int_connection` (direct or proxy) means the cluster pulls from the internet and doesn't need mirror integration. The code is correct.

---

## Bug #42: Cannot delete a cluster during install via TUI (progressbox blocks all input)
**File:** `tui/v2/tui-lib.sh` line 615
**Severity:** LOW — UX issue (downgraded from HIGH after re-validation)
**Status:** **MOSTLY INVALID** — Ctrl+C works in progressbox mode; user can choose "Run in Terminal" mode for full control.

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

## Bug #43: ~~FIXED~~ KVM config has same bugs as VMware config (Bugs #5, #7, #14)
**File:** `tui/v2/tui-cluster.sh` lines 508-546
**Severity:** MEDIUM — Data corruption risk
**Status:** FIXED — All KVM fields now use `_tui_reject_squote()` for input validation. `KVM_GRAPHICS_ARGS` properly quoted. Same fixes as VMware.

---

**Total bugs found: 43** (Bug #10 invalidated, net 42 confirmed bugs)

## Bug #45: ~~FIXED~~ `replace-value-conf` corrupts values containing spaces (SYSTEMIC)
**File:** `scripts/include_all.sh` line 1708
**Severity:** CRITICAL — Data corruption
**Verified:** YES — Reproduced via CLI and TUI
**Steps to reproduce:**
1. Have a config file with a value containing spaces (e.g. `GOVC_PASSWORD='<my password here>'`, `GOVC_NETWORK='VM Network'`, `KVM_GRAPHICS_ARGS='vnc,listen=0.0.0.0 --video virtio'`)
2. Use the TUI form to change the value
3. The resulting file has corrupted values

**Root cause:** The sed pattern in `replace-value-conf` uses `[^ \t]*` to match the old value. This regex stops at the first space/tab character. So for `GOVC_PASSWORD='<my password here>'`, only `'<my` is matched as the value; ` password here>'` becomes part of `\(.*\)` (the trailing comment capture group). When the new value replaces only the `[^ \t]*` match, the old trailing fragment is appended.

**Example:**
- File contains: `GOVC_PASSWORD='<my password here>'`
- Command: `replace-value-conf -n GOVC_PASSWORD -v "'test123'" -f vmware.conf`
- Result: `GOVC_PASSWORD='test123' password here>'`  ← **CORRUPTED**

**Affected template values (spaces in default):**
- `GOVC_PASSWORD='<my password here>'` — password field
- `GOVC_NETWORK='VM Network'` — network field
- `KVM_GRAPHICS_ARGS='vnc,listen=0.0.0.0 --video virtio'` — graphics field
- Any other quoted value with spaces

**Impact:** First-time users going through the config form will ALWAYS get corrupted config files for these fields, causing govc/virsh to fail with cryptic errors. This makes the "from scratch" wizard flow fundamentally broken for most users.

---

## Bug #44: ~~DESIGN LIMITATION~~ `_exec_in_tui` can report "Success" when child process was externally killed
**File:** `tui/v2/tui-lib.sh`
**Severity:** ~~MEDIUM~~ — DESIGN LIMITATION
**Status:** DESIGN LIMITATION — This is an inherent limitation of `dialog --progressbox`. The exit code comes from `PIPESTATUS[0]` which reflects the bash pipe, not the external signal. Detecting external kills would require process monitoring beyond what dialog provides.
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

## Bug #46: ~~FIXED~~ KVM form field quoting inconsistency

**Status:** FIXED in commit d9a11daf — all KVM fields now quoted consistently with single quotes
**File:** `tui/v2/tui-cluster.sh` lines 427, 434, 441, 448, 455
**Severity:** LOW — Inconsistency (masked by Bug #45)
**Verified:** YES — Code review
**Details:** Most KVM fields are saved without quotes:
- `LIBVIRT_URI=qemu+ssh://steve@10.0.1.10/system` (no quotes)
- `KVM_STORAGE_POOL=/home/steve/libvirt/images` (no quotes)
- `KVM_NETWORK=br-lab` (no quotes)
- `KVM_BOOT_ARGS=uefi,hd,cdrom` (no quotes)
But `KVM_GRAPHICS_ARGS` is wrapped in single quotes (line 455): `replace-value-conf -q -n KVM_GRAPHICS_ARGS -v "'$k_graphics'" -f "$conf_path"`. This inconsistency means values containing spaces (URI with spaces, paths with spaces) would break for the unquoted fields.

---

## Bug #47: ~~FIXED~~ VMware Network value space corruption via TUI form
**File:** `tui/v2/tui-cluster.sh` line 309
**Severity:** CRITICAL — Data corruption (specific instance of Bug #45)
**Verified:** YES — Reproduced via CLI
**Steps to reproduce:**
1. Start with template `vmware.conf` (has `GOVC_NETWORK='VM Network'`)
2. Open VMware config form in TUI
3. Edit the Network field to `VM Network 2` (or any other value with spaces)
4. The file gets corrupted: `GOVC_NETWORK='VM Network 2' Network'`

**Test proof:**
```
$ echo "GOVC_NETWORK='VM Network'" > /tmp/test.txt
$ replace-value-conf -q -n GOVC_NETWORK -v "'VM Network 2'" -f /tmp/test.txt
$ cat /tmp/test.txt
GOVC_NETWORK='VM Network 2' Network'
```

---

## Bug #48: ~~FIXED~~ Machine Network prefix_length dropped in Networking form display
**File:** `tui/v2/tui-cluster.sh` (Networking page display)
**Severity:** MEDIUM — Confusing UX
**Status:** FIXED — Bug #64 fix recombines `prefix_length` with `cl_network` during initial load from `aba.conf` (line 648). The `_cluster_load_conf` parser (line 90) also recombines when loading from existing `cluster.conf`. Both paths now produce CIDR notation.

---

## Bug #49: ~~FIXED~~ Password entered through TUI form corrupts vmware.conf on first use
**File:** `tui/v2/tui-cluster.sh` line 375, `scripts/include_all.sh` line 1751
**Severity:** CRITICAL — Data corruption (specific instance of Bug #45)
**Status:** FIXED — `replace-value-conf` now properly matches single-quoted values with `'[^']*'` pattern. Password validation rejects chars that break quoting.

---

## Bug #50: ~~FIXED~~ `replace-value-conf` corrupts by cascading — each edit makes it worse
**File:** `scripts/include_all.sh` line 1751
**Severity:** CRITICAL — Data corruption cascading (subcase of Bug #45)
**Status:** FIXED — `replace-value-conf` now uses `'[^']*'` for quoted values (matches entire block). Auto-quoting wraps values with spaces in single quotes before writing.

---

## Bug #51: ~~FIXED~~ Mirror registry password loses quoting when saved via TUI form
**File:** `tui/v2/tui-mirror.sh` line 257
**Severity:** ~~MEDIUM~~ — FIXED
**Status:** FIXED — Line 257 now uses `replace-value-conf -q -n reg_pw -v "'$m_pw'"` which wraps the password in single quotes, preserving correct quoting in mirror.conf.
**Verified:** YES — Reproduced via CLI
**Steps to reproduce:**
1. mirror.conf has `reg_pw='p4ssw0rd'` (quoted in single quotes)
2. Change password via TUI form
3. `replace-value-conf -q -n reg_pw -v "newPassword"` writes `reg_pw=newPassword` (quotes dropped)
4. If the new password has spaces: `reg_pw=my password` — broken when sourced

**Root cause:** The TUI saves mirror passwords WITHOUT single-quote wrapping (`-v "$m_pw"`) unlike the VMware form which wraps in quotes (`-v "'$v_pass'"`). When the old value is quoted in the template, the quotes are part of the `[^ \t]*` match and get replaced, but the new value has no quotes.

---

## Bug #53: ~~FIXED~~ Mirror password entry has NO validation for restricted characters
**File:** `tui/v2/tui-lib.sh` lines 393-440 (`_tui_prompt_password`)
**Severity:** HIGH — Silent data corruption / install failure
**Status:** FIXED — `_tui_prompt_password()` now validates: min length, no whitespace, rejects `' " \` $`, has "Rules" help button, requires double-entry confirmation.

**Documented restrictions in `mirror.conf`:**
```
# Must be at least 8 characters with no whitespace and not include: "'\`$
```

**What's missing in `_prompt_password`:**
- No minimum length check (8 chars required)
- No check for forbidden characters: `"`, `'`, `` ` ``, `$`
- No check for whitespace/spaces
- No informative error message telling the user WHY their password was rejected

**Also affects:** VMware password in `tui-cluster.sh` line 292 uses `--inputbox` (not even `--passwordbox`) and has zero validation. While VMware/govc may accept more characters, the `replace-value-conf` bug (#45) means special chars in the password will corrupt `vmware.conf` anyway. At minimum, `'` (single quote) should be rejected since the value is stored as `GOVC_PASSWORD='...'`.

---

## Bug #54: ~~FIXED~~ CONNO "Install Cluster" with no mirror doesn't chain to cluster wizard after sync
**File:** `tui/v2/tui-lib.sh` `tui_install_cluster_gate()`
**Severity:** ~~MEDIUM~~ — FIXED
**Status:** FIXED — CONNO gate path now chains to `cluster_install_flow` after successful sync (matching DISCO behavior). Returns 3 to signal caller that flow was already invoked.
**Verified:** YES — Code review
**Steps to reproduce:**
1. Start TUI in CONNO mode with no mirror installed
2. Select "Install Cluster"
3. Dialog asks: "Install & Sync?" — click "Install & Sync"
4. Mirror config review → mirror sync runs successfully
5. User is returned to the CONNO main menu — NOT taken to the cluster wizard

**Root cause:** Line 615: `_mirror_config_review && mirror_sync` does not chain to `cluster_install_flow`. Compare with DISCO mode (tui-disco.sh line 174) which correctly does: `_mirror_config_review && disco_load_images && cluster_install_flow`.

**Expected:** After successful sync, the cluster installation wizard should open automatically (user clicked "Install Cluster", not "Sync Mirror").
**Actual:** User returns to the main menu and must click "Install Cluster" again.

---

## Bug #55: ~~FIXED~~ `aba_inet_check_cached` race condition — reads exit code before background check completes
**File:** `scripts/include_all.sh` line 3386 (`aba_inet_check_cached`)
**Severity:** HIGH — Causes intermittent "[no internet]" labels on all internet-dependent features
**Status:** FIXED — Now uses `run_once -p` (peek) to check if exit_file exists, and `run_once -w` (wait) if a check is in progress before reading the result.

---

## Bug #52: ~~FIXED~~ Deleting `~/.aba/` corrupts TUI's cached internet state
**File:** `scripts/include_all.sh` line 3391
**Severity:** ~~MEDIUM~~ — FIXED
**Status:** FIXED — `aba_inet_check_cached` (line 3391) now checks `run_once -p` and if no cached result exists, waits for the fresh check to complete. Deleting `~/.aba/` just means the first check runs fresh — no permanent corruption.
**Verified:** YES — Observed in TUI
**Steps to reproduce:**
1. Delete `~/.aba/` directory (as part of "from scratch" testing)
2. Start the TUI with `abatui --conno`
3. The TUI runs its background internet check, but the `run_once` cache for the check returns a failure (stale/missing cache)
4. All internet-dependent features are greyed out: "Switch to Fully Connected", "Sync Images", "Select Operators", "Create Bundle"
5. The error message says "This action requires internet access" even though the host HAS internet

**Root cause:** The `aba_inet_check_start` kick-off at TUI boot (line 96) writes results to `~/.aba/runner/`. When `~/.aba/` was deleted before the TUI started, the initial check's cache is in a corrupted/incomplete state. The TUI caches `_TUI_INET="no"` based on the first failed check and doesn't properly retry.

**Workaround:** Restart the TUI (exit and re-launch). The second launch usually picks up the correct internet state.

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
**Status:** Known limitation — duplicate of #77. Would require `exit 0` after reset (forcing TUI restart).
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

## Bug #58: ~~NOT A BUG~~ `_conno_main` does not re-detect mode after `disco_main` normal exit
**File:** `tui/v2/tui-cluster.sh` line 1921
**Severity:** ~~LOW~~ — N/A
**Status:** NOT A BUG — Same as Bug #21. When DISCO is entered from CONNO, returning to CONNO on exit is correct. Mode re-detect unnecessary since starting point was CONNO.
**Verified:** Code review
**Steps to reproduce:**
1. In CONNO mode, select "Switch to Fully Disconnected"
2. In DISCO mode, perform any actions, then exit normally (Exit → Confirm Quit)
3. `disco_main` calls `exit 0` (the whole TUI exits)
4. The `_TUI_MODE="CONNO"` at line 663 is never reached

**Root cause:** Unlike `direct_main` (which returns 0 when entered from CONNO via `_TUI_DIRECT_FROM_CONNO`), `disco_main` has no corresponding "from CONNO" guard. When `disco_main` exits normally, it calls `exit 0` (tui-disco.sh line 134), terminating the entire TUI process. Lines 663-664 (`_TUI_MODE="CONNO"`, log message) are dead code — they're never executed. The `|| true` at line 662 only handles non-zero returns, not `exit`. This is the same underlying issue as Bug #20 but manifests specifically in the code after the `disco_main || true` call.

**Expected:** Lines 663-664 should execute after returning from DISCO mode.
**Actual:** Lines 663-664 are dead code because `disco_main` always `exit`s instead of returning.

---

## Bug #59: ~~FIXED~~ Unchecking an operator set removes shared operators from still-checked sets
**File:** `tui/v2/tui-mirror.sh` lines 838-878 (`_operator_sets`)
**Severity:** HIGH — Silent data loss of operator selections
**Status:** FIXED (2026-05-26 re-validation) — Ref-counting now works correctly. Tested interactively: adding "ocp" + "gpu" (both contain `cincinnati-operator`), then removing "ocp" → `cincinnati-operator` survives with count=1. Removing "gpu" from 11 ops → 9 ops (correctly removes gpu-only `nfd` and `gpu-operator-certified`, keeps shared `cincinnati-operator`).
**Verified:** Code review (logic trace with concrete operator set data)
**Steps to reproduce:**
1. In operator selection, check both "ocp" set and "gpu" set
2. Both sets contain `cincinnati-operator` (shared operator)
3. `OP_SET_ADDED = {ocp: 1, gpu: 1}`, basket has operators from both
4. Re-enter operator sets and uncheck "ocp" (keep "gpu" checked)
5. Press "Apply"

**Root cause:** The removal loop (lines 838-856) removes ALL operators from unchecked sets, including shared ones. The re-add loop (lines 858-878) only processes NEWLY selected sets (`[[ -z "${OP_SET_ADDED[$new_set]:-}" ]]` at line 861). Since "gpu" was already in `OP_SET_ADDED` and wasn't removed by the removal loop, it's skipped by the add loop. Result: `cincinnati-operator` (and any other shared operators) are removed from the basket even though "gpu" set is still checked. Verified: `cincinnati-operator` exists in almost every operator set (ocp, odf, acm, ai, appdev, gpu, logging, mesh2, mesh3, odfdr). Other shared operators: `nfd`, `gpu-operator-certified`, `kiali-ossm`, `devworkspace-operator`.

**Expected:** Shared operators remain in the basket as long as at least one set containing them is still checked.
**Actual:** Shared operators are removed when ANY set containing them is unchecked, regardless of other still-checked sets.

---

## Bug #60: ~~FIXED~~ Operator search corrupts basket entries with grep file path prefix
**File:** `tui/v2/tui-mirror.sh` line 913 (`_operator_search`)
**Severity:** CRITICAL — Data corruption; operators saved as invalid paths, silently lost on restoration
**Verified:** Code review + confirmed by inspecting corrupted `templates/operator-set-custom-20260514-181224`
**Steps to reproduce:**
1. Open operator selection and choose "Search Operator Names"
2. Search for any operator (e.g. "mta")
3. Select the operator and add to basket
4. Persist basket (happens automatically on menu exit)

**Root cause:** The grep command at line 913 uses `grep -iF "$query" "$ABA_ROOT"/.index/*-index-v${version_short}` which searches across multiple index files (redhat-operator-index, certified-operator-index, community-operator-index). When grep matches multiple files, it prepends the filename to each output line: `.index/redhat-operator-index-v4.21:mta-operator  Migration Toolkit...`. The parsing at line 907 (`op_name="${line%%[[:space:]]*}"`) captures the full path+colon+opname as the operator name: `.index/redhat-operator-index-v4.21:mta-operator`. This corrupted key is stored in `OP_BASKET` and persisted to the custom set file. On next TUI launch, basket restoration (abatui2.sh line 174/197) validates against the index files, and the corrupted entries fail validation and are silently dropped.

**Evidence:** The file `templates/operator-set-custom-20260514-181224` contains lines:
```
/home/steve/aba/.index/certified-operator-index-v4.21:mto-dependencies-operator
/home/steve/aba/.index/redhat-operator-index-v4.21:mta-operator
```
These are corrupted entries from operator search. Fix: add `-h` flag to grep to suppress filenames.

**Expected:** `op_name` is just the operator name (e.g. `mta-operator`).
**Actual:** `op_name` includes the full grep filename prefix (e.g. `.index/redhat-operator-index-v4.21:mta-operator`).

---

## Bug #61: ~~NOT A BUG~~ DISCO mode never re-checks internet status in its menu loop
**File:** `tui/v2/tui-disco.sh`
**Severity:** ~~MEDIUM~~ — N/A
**Status:** NOT A BUG — "Switch to Connected Mode" (Advanced menu, line 1800 of tui-cluster.sh) is always available with no internet gating. When selected, `disco_reset()` removes `.bundle` and returns 2 (re-detect mode), which triggers a fresh internet check. User doesn't need to restart TUI.
**Verified:** Code review (compared with CONNO mode's `aba_inet_check_cached` at abatui2.sh line 401)
**Steps to reproduce:**
1. Start TUI without internet → enters DISCO mode
2. While TUI is running, restore internet connectivity
3. "Reset to Connected Mode" remains greyed out with "[no internet]"
4. Must restart TUI to pick up the connectivity change

**Root cause:** DISCO mode's menu loop (line 72-76) checks `_TUI_INET` which is set ONCE during `_detect_mode` at startup and never updated. The comment at line 72 says "Internet status set once at startup (_TUI_INET). No per-loop re-check." In contrast, CONNO mode re-checks every 30 seconds via `aba_inet_check_cached 30` (abatui2.sh line 401). This asymmetry means DISCO mode users who restore internet access are stuck until they restart the TUI.

**Expected:** DISCO mode should periodically re-check internet status (like CONNO does), enabling "Reset to Connected" when internet is restored.
**Actual:** `_TUI_INET` is stale in DISCO mode — never updated after startup.

---

## Bug #62: ~~FIXED~~ VM resource validation doesn't enforce documented minimums

**Status:** FIXED in commit d9a11daf — enforces min 4 CPU / 16 GB master, min 2 CPU / 8 GB worker
**File:** `tui/v2/tui-cluster.sh` lines 1270, 1285, 1300, 1315 (`_cluster_page_vm`)
**Severity:** LOW — OpenShift installer would reject invalid values later, but TUI should catch early
**Verified:** Code review
**Steps to reproduce:**
1. In cluster wizard, reach VM Resources page
2. Edit Master CPUs, enter "1"
3. TUI accepts it (validation only checks `>= 1`)
4. Help text says "min 4" for Master CPUs

**Root cause:** All VM resource input validation uses the same pattern: `[[ ! "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]]` — accepts any positive integer. But the help text (lines 1245-1248) documents specific minimums: Master CPU min 4, Master Memory min 16 GB, Worker CPU min 2, Worker Memory min 8 GB. These minimums are not enforced by the validation logic. Users can enter values below the minimums (e.g. 1 CPU for masters), which would be rejected by the OpenShift installer later with a less helpful error message.

**Expected:** Validation enforces minimum values matching the help text (4 CPU / 16 GB for masters, 2 CPU / 8 GB for workers).
**Actual:** Validation only enforces `>= 1` for all resource fields.

---

## Bug #63: ~~NOT A BUG~~ Operators silently dropped during basket restoration when version changes
**File:** `tui/v2/abatui2.sh` lines 224-226
**Severity:** ~~MEDIUM~~ — N/A
**Status:** NOT A BUG — During basket restoration, operators not in the current version's catalog index are correctly filtered out. The `ops=` config in aba.conf is NOT modified during restoration, so operators come back if the user reverts to the original version. This is correct behavior: the basket should only show operators valid for the active version.
**Verified:** Code review
**Steps to reproduce:**
1. Configure operators for OCP 4.21 (some operators added to basket)
2. Change OCP version to 4.20 in aba.conf
3. Restart TUI
4. Some operators may not exist in the 4.20 catalog index
5. Those operators are silently dropped from the basket

**Root cause:** During basket restoration at TUI startup, each operator is validated against the catalog index for the current OCP version. The check at line 174 (`if [[ -n "$_ver_short" ]] && ! grep -q "^${_op}[[:space:]]" "$ABA_ROOT"/.index/*-index-v${_ver_short}`) silently skips (drops) operators that aren't found in the current version's index. No warning or notification is shown to the user. The user discovers the missing operators only if they check the basket manually. This is compounded by Bug #60 (corrupted operator names that would never match the index, causing silent drops).

**Expected:** TUI should notify the user about dropped operators (e.g., "N operators from your previous selection are not available in OCP X.Y").
**Actual:** Operators are silently dropped with no notification.

---

## Bug #64: ~~FIXED~~ Machine network prefix length lost when pre-populating cluster wizard from aba.conf

**Severity:** HIGH
**File:** `tui/v2/tui-cluster.sh` line 646
**Status:** FIXED — Added prefix_length recombination after reading machine_network from aba.conf.

---

## Bug #65: ~~NOT A BUG~~ "Reset to Connected Mode" from DISCO-via-CONNO doesn't trigger mode re-detection
**Status:** NOT A BUG — Duplicate of Bug #21. When DISCO is entered from CONNO, returning to CONNO is correct behavior. Mode re-detection is unnecessary since the starting point was CONNO.

**Severity:** MEDIUM
**File:** `tui/v2/abatui2.sh` line 662
**Category:** Mode switching

**Description:** When the user enters DISCO mode from CONNO ("Switch to Fully Disconnected"), `disco_main` is called with `disco_main || true`. If the user then selects "Reset to Connected Mode" within DISCO, `disco_reset()` removes the `.bundle` flag, clears `_TUI_FORCE_MODE` and `_TUI_MODE`, and returns exit code 2 (signaling "re-detect mode"). However, `|| true` swallows this exit code, and line 663 immediately resets `_TUI_MODE="CONNO"`, so mode re-detection never happens.

**Steps to reproduce:**
1. Start TUI in CONNO mode
2. Select "Switch to Fully Disconnected"
3. In DISCO menu, select "Reset to Connected Mode"
4. Confirm the switch
5. Observe: TUI returns to CONNO mode instead of re-detecting

**Root cause:** Line 662: `disco_main || true` ignores all non-zero return codes. Compare with the main mode loop (line 704) where `disco_main || disco_rc=$?` properly captures the return code and triggers `_detect_mode` when `disco_rc == 2`.

**Expected:** "Reset to Connected Mode" should trigger mode re-detection (which could result in DIRECT mode if conditions warrant).
**Actual:** Always returns silently to CONNO mode; `.bundle` is removed but mode never re-evaluated.

---

## Bug #66: ~~FIXED~~ _prompt_password has no character or length validation

**Severity:** ~~MEDIUM~~ — FIXED
**File:** `tui/v2/tui-mirror.sh` line 18
**Status:** FIXED — `_prompt_password` now delegates to `_tui_prompt_password` which enforces minimum length (8 chars), no whitespace, and no dangerous characters (quotes/backtick/dollar).
**Category:** Input validation

**Description:** The `_prompt_password` function only validates that the two password entries match. It does not validate:
- Minimum length (Quay requires ≥8 characters, per `mirror.conf` comment)
- Disallowed characters (`"'\`$` cause downstream `replace-value-conf` corruption and shell injection risks)
- Whitespace (spaces cause Quay installer failure)
- Empty password is accepted (both entries empty → match → accepted)

**Steps to reproduce:**
1. Start TUI in CONNO or DISCO mode
2. Go to Install Mirror → Password field
3. Enter `my'pass` as password (or a 3-char password, or spaces)
4. Confirm → password accepted without validation

**Root cause:** The function at lines 25-27 only checks `[[ "$pw1" == "$pw2" ]]`. No further validation is performed. The `mirror.conf` template documents the restrictions but they aren't enforced in the TUI.

**Expected:** Password entry should reject: empty passwords, passwords under 8 chars, passwords containing `"'\`$` or whitespace.
**Actual:** Any string (including empty) is accepted if it matches the confirmation entry. Invalid passwords cause downstream failures: `replace-value-conf` corruption (Bug #45/#49), Quay installer failure, or shell expansion issues.

---

## Bug #67: ~~NOT A BUG~~ _cluster_load_conf parser strips # from legitimate values

**Status:** NOT A BUG — in practice, cluster.conf fields never contain `#`. The comment-stripping is adequate for its purpose.

**Severity:** LOW
**File:** `tui/v2/tui-cluster.sh` line 80
**Category:** Config parsing

**Description:** The `_cluster_load_conf` function uses `val="${val%%#*}"` to strip inline comments from config values. This also strips `#` characters that are part of legitimate values, even inside single quotes. Unlike the core `_normalize_export` helper (which uses a quote-aware regex `s/^(([^']*'[^']*')*[^']*)#.*$/\1/`), this custom parser doesn't understand quoting.

**Steps to reproduce:**
1. Manually set a value with `#` in `cluster.conf`, e.g., `ports='VM Network #2'` (or any value with `#`)
2. Enter cluster wizard for that cluster
3. Observe that the value is truncated at the `#`

**Root cause:** Line 80: `val="${val%%#*}"` — bash parameter expansion that strips from the first `#` to the end of the string. This is a simplified comment-stripping approach that doesn't account for quoted values. The core ABA code uses `_normalize_export` which handles this correctly.

**Expected:** Values containing `#` inside quotes are preserved (e.g., `'VM Network #2'` → `VM Network #2`).
**Actual:** Value is truncated at the first `#` (e.g., `'VM Network #2'` → `'VM Network `).

---

## Bug #68: ~~INVALID~~ MAC address inputbox prompt mentions "one per line" but widget is single-line

**Severity:** LOW
**File:** `tui/v2/tui-cluster.sh` line 1188
**Category:** UX/misleading text

**Description:** The MAC address entry dialog uses `--inputbox` (a single-line text input widget) but the prompt text says "Enter MAC addresses (one per line, or comma-separated)." The "one per line" option is impossible in a single-line inputbox — dialog's `--inputbox` doesn't support multiline input. Only the "comma-separated" option works.

**Steps to reproduce:**
1. Start cluster wizard with bare-metal platform
2. Navigate to Interfaces page
3. Select "MACs" field
4. Read the prompt — it mentions "one per line"
5. Attempt to enter multiple lines → impossible in single-line widget

**Root cause:** Line 1188: `--inputbox "Enter MAC addresses (one per line, or comma-separated)."` — the prompt text doesn't match the widget's capabilities. An `--editbox` or `--inputbox` with different instructions would be needed for multiline support.

**Expected:** Prompt text accurately describes input options for the widget type.
**Actual:** Prompt mentions "one per line" which is not supported by `--inputbox`. Users can only use comma-separated entry.

---

## Bug #69: ~~FIXED~~ ISC "Reset to auto-generated" doesn't actually regenerate the file

**Severity:** ~~MEDIUM~~ — FIXED
**Status:** FIXED — `tui_kick_isconf_regen()` resets the run_once task AND starts regeneration in background. Combined with wait-before-view logic (Bug #29 fix), the ISC is properly regenerated. Duplicate of #29.
**File:** `tui/v2/tui-mirror.sh` lines 670-675
**Category:** Logic error

**Description:** When the user clicks "Reset to auto-generated" in the ISC View/Edit menu, the code only does two things: (1) touches the `.created` flag file to make it newer than the ISC file, and (2) resets the `run_once` ISC generation task. However, it does NOT kick off a new ISC generation. The ISC file retains the manually edited content. The "Reset" button disappears from the menu (because `.created` is now newer), giving the false impression that the ISC was regenerated.

**Steps to reproduce:**
1. In CONNO mode, go to View/Edit ImageSet Config
2. Select "Edit" and make some manual changes, save
3. Return to the ISC menu — "Reset to auto-generated" option appears
4. Click "Reset to auto-generated"
5. Return to the ISC menu and select "View"
6. Observe: ISC still contains the manually edited content

**Root cause:** Line 672: `run_once -r -i "aba:isconf:generate"` only resets the task (marks it as "not done"). Compare with `_persist_operator_basket` (lines 584-586) which correctly does both: `run_once -r` (reset) followed by `run_once -i ... &` (restart in background). The Reset action is missing the restart step.

**Expected:** After clicking "Reset to auto-generated", the ISC file should be regenerated with the current operator basket and aba.conf settings.
**Actual:** ISC file retains manually edited content; only the "Reset" button is hidden. The ISC is not regenerated until some other action (e.g., operator basket change) triggers it.

---

## Bug #70: ~~FIXED~~ Temp file leak — `${_TUI_TMP}.edit` never cleaned up

**Status:** FIXED — added `${_TUI_TMP}.edit` to the EXIT trap rm in `tui-lib.sh`
**File:** `tui/v2/tui-direct.sh` line 160, `tui/v2/tui-lib.sh` line 110
**Severity:** LOW — File leak in /tmp
**Steps to reproduce:**
1. Start TUI, enter DIRECT mode
2. If pull secret is not found, the "paste pull secret" flow creates `${_TUI_TMP}.edit`
3. Exit TUI
4. Check /tmp for orphaned files

**Root cause:** `_direct_pull_secret()` line 160: `echo "" > "${_TUI_TMP}.edit"` creates a temp file for the editbox widget. The `_tui_cleanup` EXIT trap (tui-lib.sh line 110) only removes `$_TUI_TMP` and `$_TUI_DIALOGRC` — it does not remove `${_TUI_TMP}.edit`. The `.edit` file persists in `/tmp` after every TUI session that touches the pull secret form.

**Expected:** All temp files are cleaned up on TUI exit.
**Actual:** `${_TUI_TMP}.edit` file remains in /tmp.

---

## Bug #71: ~~FIXED~~ Bundle path with spaces causes broken command
**File:** `tui/v2/tui-mirror.sh` line 1231
**Severity:** ~~MEDIUM~~ — FIXED
**Status:** FIXED — Added escaped double quotes around `$bundle_path` in command string. Duplicate of #168.
**Steps to reproduce:**
1. Start TUI in CONNO mode
2. Select "Create Install Bundle"
3. Enter a path containing spaces: `/tmp/my bundle`
4. Observe the generated command

**Root cause:** Line 1124: `local cmd="aba bundle --out $bundle_path"` — `$bundle_path` is interpolated unquoted into the command string. When passed to `bash -c "$cmd"` in `_exec_in_tui`, the space splits the path into separate arguments. The resulting command is `aba bundle --out /tmp/my bundle -y`, where `bundle` becomes a separate arg and `aba` fails with "unknown command."

**Expected:** Path with spaces should be properly quoted in the command string.
**Actual:** Command breaks with argument splitting. Same issue applies to `$cl_ssh_key` in `_cluster_execute` (line 1353).

---

## Bug #72: ~~DUPLICATE~~ Metacharacter defense does not block single `|` or `>`
**File:** `tui/v2/tui-lib.sh`
**Severity:** ~~MEDIUM~~ — Duplicate of Bug #35
**Status:** Duplicate of Bug #35. Low risk since commands are internally constructed, not from raw user input.
**Steps to reproduce:**
1. Start TUI, go to "Create Install Bundle"
2. Enter path: `/tmp/test | echo pwned`
3. The command passes the metacharacter defense check
4. `bash -c "aba bundle --out /tmp/test | echo pwned -y"` executes a pipe

**Root cause:** Lines 451/523 check for `\``, `$`, `;`, `&&`, `||`, `>>`, `<<` — but NOT for single `|` (pipe), `>` (redirect), or `<` (input redirect). Since commands are executed via `bash -c "$cmd"`, any unblocked metacharacter is interpreted by the shell. The defense was designed to block common injection patterns but missed single-character operators.

**Expected:** All shell metacharacters that could alter command behavior should be blocked (or user-provided values should be properly quoted/escaped before embedding in command strings).
**Actual:** Single pipe and redirect operators pass through the defense.

---

## Bug #73: ~~DUPLICATE~~ `_OP_BASKET_DIRTY` unconditionally set after operator menu actions
**File:** `tui/v2/tui-mirror.sh`
**Severity:** LOW — Duplicate of Bug #23
**Status:** Duplicate of Bug #23. Minor performance issue, not a correctness bug.
**Steps to reproduce:**
1. Start TUI, go to "Select Operators"
2. Select "Operator Sets", view the checklist, press Back (no changes)
3. Return to operator menu
4. Observe that `_OP_BASKET_DIRTY` is already set to true and ISC regeneration triggered

**Root cause:** Lines 763, 767, 771: `_OP_BASKET_DIRTY=true` is set UNCONDITIONALLY after each sub-action (`_operator_sets`, `_operator_search`, `_operator_view_basket`), regardless of whether the user actually made any changes. Even pressing "Back" without modifying anything triggers `_persist_operator_basket`, which deletes old custom operator-set files and creates new ones, then kicks off background ISC regeneration.

**Expected:** `_OP_BASKET_DIRTY` should only be set to true when the basket actually changes.
**Actual:** Every visit to any operator sub-menu triggers unnecessary file I/O and background regeneration.

---

## ~~Bug #74~~ NOT A BUG — by design: double-ESC is intentional quick-exit
**File:** `tui/v2/tui-lib.sh` line 282
**Status:** NOT A BUG — by design. The code comment "ESC again — quitting" confirms the developer intended double-ESC as a quick-exit shortcut. If the user is hammering ESC, they clearly want to leave.

---

## Bug #75: ~~FIXED~~ No port validation in mirror config forms
**File:** `tui/v2/tui-mirror.sh` line 236
**Severity:** ~~MEDIUM~~ — FIXED
**Status:** FIXED — Line 236 validates port with `_valid_port "$m_port"` and shows "Invalid port. Must be a number between 1 and 65535" error message on failure.
**Steps to reproduce:**
1. Start TUI → Install Mirror (local)
2. Select "Port" field
3. Enter "abc" or "99999" or "-1"
4. Press OK — value accepted without error
5. Press Next → Install proceeds and fails later with unclear error

**Root cause:** The port inputbox accepts any string. No validation for: (a) numeric-only, (b) range 1–65535. The value is immediately written to `mirror.conf` via `replace-value-conf`. The same issue exists in all three mirror config forms (`_mirror_install_local`, `_mirror_install_remote`, `_mirror_config_review`).

**Expected:** Port input should reject non-numeric values and values outside 1–65535 range, showing a clear error message.

---

## Bug #76: ~~DUPLICATE~~ No MAC address format validation in cluster wizard

**Status:** DUPLICATE of Bug #329 — fixed in commit 31ca4a19
**File:** `tui/v2/tui-cluster.sh` lines 1191-1196
**Severity:** LOW — Invalid MACs accepted silently
**Steps to reproduce:**
1. Start cluster wizard → select platform bm → navigate to Interfaces page
2. Select "MACs" field
3. Enter "hello,world,foo" (invalid MAC format)
4. Press OK — values accepted and stored

**Root cause:** The MAC address normalization (line 1194: `tr ',; ' '\n' | sed '/^$/d' | tr -d ' \t'`) only converts separators and removes whitespace but does not validate the `aa:bb:cc:dd:ee:ff` format. Any string is accepted as a "MAC address". Invalid entries would cause failures during cluster install with unclear error messages.

**Expected:** Each MAC address should be validated against the `^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$` pattern. Invalid entries should be rejected with a clear error.

---

## Bug #77: ~~DUPLICATE~~ Stale in-memory config after `aba reset --force` from Advanced menu
**File:** `tui/v2/tui-cluster.sh`
**Severity:** LOW — Duplicate of Bug #57.
**Status:** Duplicate of Bug #57. Same root cause and resolution.
**Steps to reproduce:**
1. Start TUI in CONNO mode with configured environment
2. Go to Advanced Options → Reset ABA → Confirm
3. After reset completes, observe the TUI backtitle and menu
4. Backtitle still shows old version/channel (e.g., "stable 4.21.14")
5. Menu items still show old mirror state, cluster count, etc.

**Root cause:** `aba reset --force` (line 1664) deletes `aba.conf`, `mirror.conf`, cluster directories, and all configuration. But the TUI continues running with the in-memory variables (`ocp_version`, `ocp_channel`, `_TUI_MODE`, `OP_BASKET`, etc.) that were sourced at startup. These stale values are used by `ui_backtitle()`, menu item state checks (`mirror_available`, `list_cluster_dirs`, etc.), and the operator basket — until the TUI is manually restarted.

**Expected:** After `aba reset --force`, the TUI should either: (a) restart itself (re-exec), (b) clear all in-memory state and re-run mode detection, or (c) display a prominent warning that the TUI must be restarted.

---

## Bug #78: ~~NOT A BUG~~ Silent cluster config overwrite when entering existing cluster name
**File:** `tui/v2/tui-cluster.sh` line 919
**Severity:** ~~MEDIUM~~ — N/A
**Status:** NOT A BUG — Loading existing cluster config when user enters its name is by-design. If you type an existing cluster name, you're editing that cluster. Same logic as initial re-entry load at line 639. The alternative (blocking duplicate names) would prevent editing existing clusters via the wizard.
**Steps to reproduce:**
1. Start cluster wizard → change name to "ocp" (default)
2. Set type to "standard", configure network, set custom VIPs, ports, etc.
3. Change cluster name to "sno" (an existing cluster with cluster.conf)
4. All wizard fields silently replaced with values from sno/cluster.conf
5. No confirmation dialog, no "values loaded from existing cluster" notification

**Root cause:** When the user enters a cluster name that matches an existing directory with `cluster.conf` (line 815-817), `_cluster_load_conf` is called immediately without any confirmation. This silently replaces all `cl_*` variables (type, network, VIPs, ports, VM resources) with the values from the existing cluster's config. The user loses any values they had previously configured in the current wizard session.

**Expected:** Before loading an existing cluster config, show a confirmation dialog: "Cluster 'sno' already exists. Load its configuration? (Current wizard values will be replaced)" with options to Load or Keep Current values.

---

## Bug #79: ~~FIXED~~ Copy-paste error in `verify-cluster-conf` error messages
**File:** `scripts/include_all.sh` lines 969, 972
**Severity:** LOW — Misleading error messages
**Steps to reproduce:**
1. Set `master_mem=abc` or `worker_mem=xyz` in a cluster.conf
2. Run `aba cluster` or any command that triggers `verify-cluster-conf`
3. Error messages show the wrong variable name

**Root cause:** Copy-paste errors in validation:
- Line 969: `"Error: master_mem is invalid: [$master_cpu_count]"` — should be `[$master_mem]`
- Line 972: `"Error: worker_mem is invalid: [$worker_cpu_count]"` — should be `[$worker_mem]`

The validation logic itself is correct (checks `$master_mem` / `$worker_mem`), but the error messages display the wrong variable (`$master_cpu_count` / `$worker_cpu_count`), confusing users about which config field is actually invalid.

**Expected:** Error messages should reference the correct variable: `[$master_mem]` and `[$worker_mem]`.

---

### Summary by severity:
| Severity | Count | Bug IDs |
|----------|-------|---------|
| CRITICAL | 6 | #3, #45, #47, #49, #50, #60 |
| HIGH | 13 | #1, #9, #18, #20, #22, #24, #35, #41, #42, #53, #55, #59, #64 |
| MEDIUM | 34 | #5, #6, #7, #13, #14, #15, #16, #17, #21, #23, #25, #26, #29, #37, #38, #43, #44, #48, #51, #52, #54, #56, #57, #61, #63, #65, #66, #69, #71, #72, #74, #75, #77, #78 |
| LOW | 25 | #2, #4, #8, #11, #12, #19, #27, #28, #30, #31, #32, #33, #34, #36, #39, #40, #46, #58, #62, #67, #68, #70, #73, #76, #79 |

### Workflows tested via TUI:
1. **CONNO mode SNO install** — Full install from wizard to "Success" dialog. Cluster reached 4.21.14, all operators available.
2. **Day-2 Cluster Status** — Showed all cluster operators correctly. Both SNO and compact clusters showing all operators Available=True.
3. **Day-2 NTP** — NTP configuration applied, chrony synced on all nodes.
4. **Day-2 SSH** — Successfully SSHed into SNO cluster as core@10.0.1.201 and exited cleanly.
5. **Day-2 Resources** — `aba day2` ran successfully; identified Bug #41 (misleading proxy message).
6. **Cluster Delete via TUI** — Delete of sno3-ext cluster worked correctly (VMs destroyed, folder deleted). Delete dialog correctly uses `select_cluster` (shows all clusters, not just installed).
7. **Compact cluster install** — Started 3-node compact cluster install; VMs created, install progressing.
8. **VMware config from scratch** — Template defaults loaded, password shown in plaintext (Bug #4). Password corruption confirmed (Bug #49).
9. **Platform toggle in cluster wizard** — Cycled through vmw → kvm → bm successfully.
10. **Connection toggle** — Verified "direct" available in CONNO mode (Bug #9) and DISCO mode.
11. **Command preview** — Used "Command" button to verify missing `--platform bm` (Bug #3).
12. **DIRECT mode switch from CONNO** — Successfully switched; tested Connection toggle (only proxy/direct, correct).
13. **DISCO mode switch from CONNO** — Switched; tested Connection toggle (all 3 options, Bug #9 confirmed in DISCO too). Confirmed `.bundle` NOT created (Bug #16).
14. **DISCO mode exit** — Confirmed entire TUI exits instead of returning to CONNO (Bug #20). Live verified: pressed ESC→Exit from DISCO, TUI terminated completely.
15. **Finalize Installation** — Confirmed Bug #1: only shows already-installed clusters (sno, compact), not installing clusters (sno2delinst, sno3-ext, snosmoke1).
16. **VMware config form from scratch** — Full form test: URL, Username, Password (plaintext), Datastore, Network, Test Connection (success). Confirmed Bugs #4, #5, #45, #47, #49.
17. **KVM config form from scratch** — Full form test: URI, Storage Pool, Network, Boot/Graphics args, Test Connection (success). Values saved correctly when matching template defaults.
18. **Machine Network validation** — Invalid CIDR (/99) and missing prefix (no slash) both correctly rejected.
19. **Bare-metal wizard flow** — Toggled platform to bm, navigated through Basics→Networking→Interfaces (Ports empty, MACs entry visible). Entered 2 test MACs. Review page showed "bm (bare-metal)" and "2 addresses". Install action dialog showed "Full Install" and "Create ISO only" options. Bug #3 (missing `--platform bm`) visible in command preview.
20. **Internet state after ~/.aba/ deletion** — Discovered Bug #52: TUI incorrectly thinks no internet after deleting ~/.aba/. Required manual inet cache reset and TUI restart.
21. **DISCO mode exit behavior** — Code review AND live test confirmed Bug #20: `exit 0` in `disco_main` kills entire TUI when entered from CONNO. DIRECT mode has the fix (`_TUI_DIRECT_FROM_CONNO` guard) but DISCO mode does not.
22. **Bundle creation flow** — Path entry dialog appeared with `/tmp/ocp-bundle` default. Cancellation returned to main menu correctly.
23. **Upgrade cluster** — Version validation working correctly: "bad-version" rejected with clear error message, format x.y.z enforced. "List Available" button present.
24. **Advanced Options menu** — Reset ABA, Reconfigure Platform, Uninstall Mirror all present. Platform selection shows all 3 options.
25. **Internet check race condition** — Confirmed Bug #55: `aba_inet_check_cached` reads exit code before background check completes. Observed "[no internet]" labels flip on/off between menu iterations. Live verified with direct CLI testing showing `aba_inet_check_cached` returning false while exit file contains 0.
26. **ISC View** — ImageSet configuration displayed correctly in read-only textbox. Edit and Reset options available.
27. **Install Cluster with no mirror sync** — Confirmed Bug #54: "Install Cluster" → "Sync Now" dialog chains to `mirror_sync` only, doesn't chain to `cluster_install_flow` afterward.

28. **Operator Search (Bug #60 live verification)** — Searched for "amq" via Select Operators → Search. Results showed full file paths prepended: `/home/steve/aba/.index/redhat-operator-index-v4.21:amq-broker-rhel8` instead of just `amq-broker-rhel8`. CRITICAL: selecting any result would add the filepath+operator as the basket key, corrupting the entire operator system.
29. **ESC chain confirm_quit (Bug #74 live verification)** — Sent ESC keys via tmux from nested menus. The confirm_quit dialog appeared from buffered ESC keys. Pressing ESC on the confirm dialog exits the TUI (rc=255 treated as quit). Also tested: TUI exited completely from double-ESC from the Advanced→Platform selection stack.
30. **Operator search with regex metachar** — Searched for `[amq` (unclosed bracket). grep -F correctly treated it as literal string. "No operators matching '[amq' found." — safe, no crash. Confirms `grep -F` flag is properly set.
31. **Internet status flicker** — Observed "[no internet]" label appearing on "Switch to Fully Connected" menu item, then disappearing on next render. Confirms Bug #55 (internet check race condition) still manifests in live use.
32. **Install Cluster → Sync Now flow** — Confirmed Bug #54 live: "Mirror Not Synced" dialog offers "Sync Now" but does NOT chain to cluster install afterward. User must re-select "Install Cluster".
33. **Advanced Options menu** — Verified R (Reset), P (Reconfigure Platform), U (Uninstall Mirror) all present and accessible. Confirmed Bug #77 scenario: after Reset, TUI would continue with stale config.

### CLI commands used (not via TUI):
- `mv ~/aba/vmware.conf ~/aba/vmware.conf.testbug4` — rename vmware.conf to test "from scratch" config path
- `cp ~/aba/vmware.conf.bk ~/aba/vmware.conf` — restore correct vmware.conf after template defaults were applied
- `rm -f ~/.vmware.conf` — clean up incorrectly cached vmware.conf
- `tail ~/aba/sno/iso-agent-based/.openshift_install.log` — check install progress during frozen progressbox (diagnosis of Bug #18)
- `ps aux | grep openshift-install` — verify install process still running during frozen progressbox
- `rm -f ~/aba/vmware.conf ~/aba/kvm.conf ~/.vmware.conf ~/.kvm.conf && rm -rf ~/.aba/` — clean environment for "from scratch" test
- `cp ~/aba/vmware.conf.bk-scratch ~/aba/vmware.conf` — restore vmware.conf after password corruption test
- `replace-value-conf` CLI tests — verified Bug #45 root cause with multiple values containing spaces

---

# Session 2 — New Bugs Found (2026-05-15, 18:00+)

## Bug #79b: ~~FIXED~~ Internet check (aba_inet_check_cached) systematically fails after TTL expiry with `set -o pipefail`

> **Note:** Numbered #79b to avoid collision with Bug #79 above (copy-paste error in verify-cluster-conf). This is a DIFFERENT bug found in Session 2.

**Severity**: HIGH — blocks core TUI functionality

**Location**: `scripts/include_all.sh` — `aba_inet_check_cached()` function

**Root cause**: After the 30-second TTL expires, `run_once -t $ttl` starts a new background check. Immediately after, `run_once -E` tries to read the exit code file. But the new check hasn't completed yet, so `-E` either reads a stale/empty file or returns non-zero. With `set -o pipefail` active (set in `abatui2.sh` line 26), the pipeline `run_once -E ... | grep -q '^0$'` fails, causing `aba_inet_check_cached` to return 1 (no internet).

**Reproduction**: Launch TUI with proxy, wait >30 seconds, observe `[no internet]` tags appearing on menu items.

**Verified**: YES — via CLI test simulating the `run_once` flow and via TUI observation.

## Bug #80: ~~FIXED~~ Internet check failure blocks TUI operations (cascading from Bug #79b)

**Severity**: CRITICAL — makes CONNO workflow unusable

**Location**: `tui/v2/abatui2.sh` — CONNO main menu loop; `tui/v2/tui-mirror.sh` — sync/save/bundle operations

**Root cause**: When `aba_inet_check_cached` returns failure (Bug #79), the TUI marks items with `[no internet]` AND gates their execution. When user selects a gated item, a blocking dialog appears: "This action requires internet access. Restore internet connectivity to use this feature." The user cannot override this, even though internet IS available via proxy.

**Reproduction**: In CONNO mode, wait >30s, try "Sync Images" — blocked with "requires internet" dialog.

**Verified**: YES — observed in TUI.

## Bug #81: ~~FIXED~~ TUI flock file descriptor inherited by Docker registry container — prevents TUI restart

**Severity**: CRITICAL — TUI cannot be restarted after installing Docker mirror

**Location**: `tui/v2/abatui2.sh` lines 54-55

**Root cause**: The TUI opens `~/.aba/.tui.lock` with `exec {ABA_TUI_FLOCK_FD}>...` and acquires an flock. When the TUI runs `aba -d mirror install`, which starts a Docker registry container, the `conmon` process (container runtime monitor) inherits the open file descriptor. When the TUI exits, `conmon` still holds the FD (and the flock), preventing any new TUI instance from starting. The error message is "Another TUI instance is already running."

**Reproduction**: Install a Docker mirror via TUI → exit TUI → try to restart TUI → "Another TUI instance is already running" error.

**Verified**: YES — observed after mirror install. `fuser ~/.aba/.tui.lock` showed PID of the `conmon` process.

**Fix hint**: Set `FD_CLOEXEC` on the lock FD before spawning subprocesses, or close the FD explicitly in child processes.

## Bug #82: ~~DUPLICATE OF Bug #4~~ VMware password displayed in plaintext in configuration inputbox

**DUPLICATE** — Same issue as Bug #4. See Bug #4 for details.

## Bug #83: ~~DUPLICATE OF Bug #38~~ `_cluster_load_conf` — prefix_length/machine_network order dependency

**DUPLICATE** — Same issue as Bug #38. See Bug #38 for details.

## Bug #84: ~~NOT A BUG~~ VIP auto-detection uses default cluster name "ocp" instead of user's chosen name

**Severity**: ~~MEDIUM~~ — N/A
**Status:** NOT A BUG — Same resolution as Bug #25. After page 1, `_cluster_generate_defaults()` runs `aba cluster --step cluster.conf` with the correct name, which regenerates all defaults including VIPs from DNS. The initial auto-detect is just a cosmetic pre-fill overwritten by `_cluster_generate_defaults`.

**Location**: `tui/v2/tui-cluster.sh` lines 580-587

**Root cause**: The VIP auto-detection runs during wizard initialization (before the user changes the cluster name). It looks up `api.ocp.${domain}` and `*.apps.ocp.${domain}` instead of `api.${cl_name}.${domain}`. When the user changes the cluster name (e.g., to "sno"), the VIPs are NOT re-fetched from DNS. The user sees incorrect VIP values on the Network page.

**Reproduction**: Open cluster wizard → default name is "ocp" → change to "sno" → go to Network page → VIPs show values from api.ocp.example.com DNS lookup, not api.sno.example.com.

**Verified**: Code inspection confirmed. VIP auto-detect runs once at init time only.

## Bug #85: ~~DUPLICATE OF Bug #42~~ Ctrl+C silently ignored during `_exec_in_tui` command execution

**DUPLICATE** — Same issue as Bug #42 (and related Bug #18). See Bug #42 for details. **Note:** Re-validation (2026-05-26) found Ctrl+C actually works — see Bug #42 updated entry.

## Bug #86: ~~DUPLICATE OF Bug #3~~ Platform "bm" not passed as `--platform` flag

**DUPLICATE** — Same issue as Bug #3. See Bug #3 for details.

## Bug #87: ~~INVALID~~ Connection field truncated on Interfaces page

**Severity**: LOW — cosmetic

**Location**: `tui/v2/tui-cluster.sh` — `_cluster_page_iface()` function

**Root cause**: The dialog menu box width is too narrow for the "Connection: mirror (registry4.example.com:8443)" value. The display truncates to "mirror (registry4.example.com:844" — missing the closing "3)".

**Reproduction**: Open cluster wizard → go to Interfaces page → observe truncated Connection field.

**Verified**: YES — observed in TUI.

## Bug #88: ~~FIXED~~ ESC from VMware configuration silently continues wizard to next page

**Severity**: ~~MEDIUM~~ — FIXED
**Status:** FIXED — Added `|| return 1` after `_configure_platform_file` calls in `_gate_platform_config`. Cancelling the config form now returns to page 1.

**Location**: `tui/v2/tui-cluster.sh` lines 201-202, 213-219

**Root cause**: When the user selects "Configure Now" for VMware and then presses ESC inside the VMware config form, `_configure_vmw_form` returns 1. But `_configure_platform_file` doesn't check the return code, and `_gate_platform_config` returns 0 regardless. The wizard proceeds to the Network page as if VMware configuration was completed successfully.

**Reproduction**: Cluster wizard → Basics page → press Next → "Configure Now" → press ESC → wizard advances to Network page instead of returning to Basics.

**Verified**: YES — observed in TUI.

## Bug #89: ~~FIXED~~ Wizard defaults for VM resources don't match cluster.conf template defaults — misleading review page

**Severity**: HIGH — user installs cluster with different specs than shown
**Status:** FIXED (2026-05-26 re-validation) — New two-step wizard generates `cluster.conf` via `aba cluster --step cluster.conf` (gets real ABA defaults: CPU=10, Mem=20, Disk=500), then loads them into the form via `_cluster_load_conf`. Review page and actual install now match.

**Location**: `tui/v2/tui-cluster.sh` lines 517-521 (defaults) and lines 1375-1381 (command construction)

**Root cause**: The wizard initializes VM resource defaults as: CPU=8, Memory=32 GB, Disk=(none). These are shown on the VM Resources page and the review page. However, the command construction skips `--mcpu`, `--mmem`, and `--data-disk-gb` flags when values match these wizard defaults (line 1375: `"$cl_master_cpu" != "8"`). Since the flags are not passed, ABA core uses its own template defaults from cluster.conf, which are DIFFERENT:
- Template CPU = 10 (wizard shows 8)
- Template Memory = 20 GB (wizard shows 32 GB)
- Template Disk = 500 GB (wizard shows "none")

The review page displays: "Master CPU: 8, Master Mem: 32 GB" but the actual VM is created with 10 CPUs, 20 GB RAM, and a 500 GB data disk.

**Reproduction**: Create SNO cluster via wizard → leave VM Resources at defaults → review page shows 8 CPU/32GB → install → VM created with 10C/20G/500GB disk.

**Verified**: YES — observed in TUI install. `cluster.conf` confirmed: `master_cpu_count=10, master_mem=20, data_disk=500`.

## Bug #90: ~~DUPLICATE OF Bug #44~~ TUI shows "Success" when install process is killed externally

**DUPLICATE** — Same issue as Bug #44. This entry adds `set -o pipefail` interaction detail and live reproduction evidence. See Bug #44 for details.

## Bug #91: ~~DUPLICATE OF Bug #69~~ "Reset to auto-generated" ISC doesn't actually regenerate the file

**DUPLICATE** — Same issue as Bug #69. This entry adds the note that syncing immediately after reset uses the stale file. See Bug #69 for details.

## Bug #92: ~~DUPLICATE OF Bug #71~~ Bundle path with spaces breaks the command

**DUPLICATE** — Same issue as Bug #71. See Bug #71 for details.

## Bug #93: ~~DUPLICATE OF Bug #2~~ Dead code `_direct_operators()` with undefined variable

**DUPLICATE** — Same issue as Bug #2. See Bug #2 for details.

## Bug #94: Mirror config edits saved immediately even if user cancels

**Severity**: LOW — user expectation issue

**Location**: `tui/v2/tui-mirror.sh` lines 270-324 (local) and 416-483 (remote)

**Root cause**: When configuring the mirror (both local and remote), each field edit immediately calls `replace-value-conf` to write the change to `mirror.conf`. If the user edits a field (e.g., changes hostname) and then presses "Back" to cancel the configuration, the change is already persisted to `mirror.conf`. The user expects "Back" to discard changes, but partial edits remain.

**Verified**: YES — code review confirms `replace-value-conf` is called inside each field's case handler, before the user confirms with "Next".

---

## Bug #95: ~~DUPLICATE OF Bug #46~~ KVM `KVM_GRAPHICS_ARGS` wrapped in extra single quotes

**DUPLICATE** — Same issue as Bug #46 (KVM field quoting inconsistency). See Bug #46 for details.

---

## Bug #96: ~~FIXED~~ VMware config from template shows "Password: (set)" when actually placeholder

**Status:** FIXED in commit e2122a11 — angle-bracket placeholders treated as empty

**Severity**: LOW — misleading UX

**Location**: `tui/v2/tui-cluster.sh` line 255, `templates/vmware.conf` line 7

**Steps to reproduce**:
1. Remove `~/.vmware.conf` and `~/aba/vmware.conf` (simulate fresh install)
2. Start TUI → CONNO → Install Cluster → Enter cluster name → Next
3. "Configure Now" for VMware
4. VMware form shows "Password: (set)"

**Root cause**: When `vmware.conf` is created from the template (line 227-229), the template contains `GOVC_PASSWORD='<my password here>'`. The TUI displays `${v_pass:+(set)}` (line 255), which shows "(set)" whenever `v_pass` is non-empty. The template placeholder `<my password here>` is non-empty, so it displays "(set)" as if a real password is configured. Opening the password field reveals the plaintext placeholder. The user might skip editing the password, thinking it's already configured.

**Verified**: YES — reproduced in TUI on registry4. After renaming `~/.vmware.conf` and `~/aba/vmware.conf`, the VMware form showed "Password: (set)". Clicking on the field revealed the template placeholder `<my password here>` in plaintext.

---

## Bug #97: ~~FIXED~~ Optional fields (NTP, VIP) cannot be cleared once populated

**Severity**: LOW — prevents user from unsetting optional values

**Location**: `tui/v2/tui-cluster.sh` lines 1044-1059 (NTP), 976-1008 (VIPs)

**Root cause**: All Network page fields use the pattern:
```bash
[[ -n "$ntp_val" ]] && cl_ntp="$ntp_val"
```
If the user opens the inputbox, clears the content, and presses OK, the empty value is ignored and the old value persists. For required fields (machine_network, DNS, gateway), this is sensible. But NTP servers are documented as optional in the help text ("NTP servers: comma-separated NTP server addresses (optional)"). Once auto-populated (e.g., with `10.0.1.8,2.rhel.pool.ntp.org`), the user cannot remove NTP servers through the TUI. Similarly, API VIP and Ingress VIP cannot be cleared if auto-detected from DNS.

**Verified**: YES — code review confirms empty values are ignored for all Network page fields, including optional ones.

## Bug #98: ~~FIXED~~ Mirror state race — menu item label reads stale cache before verify completes

**Severity**: LOW (cosmetic, first-iteration only)

**Location**: `tui/v2/abatui2.sh` lines 464-472, `tui/v2/tui-disco.sh` lines 42-79

**Description**: In both CONNO and DISCO main menu loops, the "Install Cluster" label hint (`[sync mirror first]` / `[load mirror first]`) is computed BEFORE `aba_mirror_verify_wait` completes, while the menu title (e.g., `mirror ready`) is computed AFTER the wait. On the first loop iteration — when the background verify kicked off at startup hasn't finished yet — `_mirror_has_release_image()` returns stale/false because the cached exit code from `run_once` isn't written yet. After the wait, `mirror_state_label()` correctly reads the final result.

**Result**: On the very first menu display, the menu title can say "mirror ready" (green) while the Install Cluster item simultaneously says "[sync mirror first]" — contradictory information. Subsequent iterations are fine because the cache is populated.

**Fix**: Move `aba_mirror_verify_wait` before the `inst_label` hint logic (before line 464 in CONNO, before line 42 in DISCO).

**Verified**: YES — code review confirms the ordering issue in both modes.

## Bug #99: ~~CORE ABA BUG~~ `--ntp`/`--dns`/`--gateway` flags target wrong `cluster.conf` when used with `--name`

**Severity**: ~~MEDIUM~~ — CORE ABA BUG (not TUI)
**Status:** CORE ABA BUG — This is in `scripts/aba.sh` (CLI flag handling), not the TUI. Outside scope of TUI fixes.

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

## Bug #100: ~~DUPLICATE OF Bug #62~~ VM resource inputs accept values below OpenShift minimums

**DUPLICATE** — Same issue as Bug #62. See Bug #62 for details.

## Bug #101: ~~DUPLICATE OF Bug #73~~ Operator basket marked dirty even when user makes no changes

**DUPLICATE** — Same issue as Bug #73 (and related Bug #23). See Bug #73 for details.

## Bug #102: ~~DUPLICATE OF Bug #59~~ Removing an operator set deletes shared operators from other active sets

**DUPLICATE** — Same issue as Bug #59. See Bug #59 for details. (This entry adds a concrete A/B scenario example.)

## Bug #103: ~~FIXED~~ Upgrade version parser extracts current version and noise from dry-run output

**Severity**: ~~MEDIUM~~ — FIXED
**Status:** FIXED — Added filter to skip info/header lines (Current version, Target version, DRY RUN, etc.) before extracting semver patterns from `upgrade --dry-run` output. Only actual version list entries are now parsed.

**Location**: `tui/v2/tui-cluster.sh` lines 1884-1900 (`_day2_upgrade`)

**Description**: The version parser uses `grep -oE '[0-9]+\.[0-9]+\.[0-9]+'` on every line of `upgrade --dry-run` output, which includes info messages containing the CURRENT cluster version, not just upgrade targets. The `2>&1` merges stderr into stdout, and `|| true` masks failures.

The dry-run script (`scripts/cluster-upgrade.sh` lines 157-185) outputs structured info like:
- "Current version: 4.17.3" (info line)
- "Target version: 4.18.0" (info line)
- "Versions in mirror (higher than 4.17.3):" (info header)
- "  4.18.0 ← target" (actual upgrade target)

The parser blindly extracts ALL semver patterns, so `4.17.3` (the current version) appears alongside `4.18.0` (the actual upgrade target). After dedup/sort, the user sees both versions as selectable upgrade targets. Selecting the current version triggers a no-op ("already at version"), wasting time and confusing the user.

Additionally, if the dry-run fails (e.g., no `ocp_version_target` set, cluster unreachable, cluster unhealthy), `|| true` silences the error. The user sees "No available upgrade versions" with no indication of the actual problem (missing config, network issue, etc.).

**Fix**: Parse only the indented version lines from the "Versions in mirror" section (e.g., lines matching `^\[ABA\]   [0-9]+`). Or better: have the upgrade script output a machine-parseable section (e.g., `##VERSIONS## 4.18.0 4.18.1`). Also: don't use `|| true` — check the exit code and show the actual error to the user if dry-run fails.

**Verified**: YES — code review confirms the parser uses unstructured regex on the full output, and the dry-run output always includes the current version in info lines.

## Bug #104: ~~FEATURE REQUEST~~ EUS channel missing from TUI channel selection

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

## Bug #105: ~~DUPLICATE OF Bug #61~~ DISCO mode never re-checks internet status during session

**DUPLICATE** — Same issue as Bug #61. See Bug #61 for details.

---

## Bug #106: ~~INVALID~~ DISCO mode blocks on mirror verification every menu redraw

**Severity**: LOW (performance — menu may freeze for seconds after mirror operations)

**File:** `tui/v2/tui-disco.sh` line 79

**Root cause:** The DISCO menu loop calls `aba_mirror_verify_wait` (blocking) on every iteration:
```bash
# Wait for any in-flight mirror verify before reading state
aba_mirror_verify_wait
```

This blocks until the background `make -sC mirror check-image` completes (which runs `skopeo inspect` or similar). After operations that trigger `_invalidate_mirror_cache` (like load or install), the next menu render blocks for the duration of the verification (typically 2-10 seconds depending on registry responsiveness).

In contrast, CONNO mode uses `_mirror_has_release_image()` → `aba_mirror_verify_exit()` → `run_once -E` (non-blocking, reads cached exit code). CONNO's menu renders instantly and shows the last-known state.

**Expected:** DISCO menu should render immediately using cached mirror state (like CONNO does), with the state updating on the next render after the background check completes.
**Actual:** DISCO menu freezes for the duration of the mirror verification on every render cycle.

**Verified**: YES — code review confirms `aba_mirror_verify_wait` (blocking) on DISCO line 79, vs non-blocking `_mirror_has_release_image` pattern used by CONNO.

---

## Bug #107: Direct script invocations bypass make dependency tracking

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

## Bug #159: ~~INVALID~~ DISCO help text still references "Finalize Installation" (stale)

**Severity**: LOW — Misleading help text
**File:** `tui/v2/tui-disco.sh` line ~211
**Description:** The DISCO mode help text says "3. Install Cluster — configure and provision OpenShift / 4. Finalize Installation — wait for install to complete" but "Finalize Installation" was renamed to "Monitor Cluster Installation" and moved to the Advanced menu.

**Verified:** YES — confirmed stale reference (same class as Bug #112).

---

## Bug #161: ~~FIXED~~ TUI PID file (~/.tui.pid) not removed on exit — EXIT trap overwritten

**Severity**: ~~MEDIUM~~ — FIXED
**Status:** FIXED — Added `${_ABA_TUI_PID_FILE:-}` to `_tui_cleanup()` rm command in `tui-lib.sh`.
**File:** `tui/v2/abatui2.sh` line 93, `tui/v2/tui-lib.sh` line 113
**Description:** `abatui2.sh` sets `trap '_tui_exit_cleanup; exit 0' EXIT` which should remove `~/.tui.pid`. But `tui-lib.sh` later sets `trap '_tui_cleanup' EXIT`, overwriting the original trap. `_tui_cleanup` does NOT call `_tui_exit_cleanup` or remove the PID file.

**Verified:** YES — interactively confirmed PID file persists after TUI exit.

---

## Bug #162: ~~FIXED~~ VMware password displayed in cleartext in TUI input dialog

**Severity**: ~~HIGH~~ — N/A
**File:** `tui/v2/tui-cluster.sh` line 373
**Status:** FIXED — Line 373 now uses `_tui_prompt_password "Enter vSphere/ESXi password:"` which uses `--passwordbox` for secure input.

---

## Bug #163: ~~INVALID~~ DISCO reset dialog says user will be "asked to choose" mode, but mode is auto-detected

**Severity**: LOW — Misleading dialog text
**File:** `tui/v2/tui-strings2.sh` line ~346 (`TUI2_MSG_DISCO_RESET_CONFIRM`)
**Description:** The reset confirmation dialog states the user will be "asked to choose" between CONNO/DIRECT mode, but in reality the mode is auto-detected based on environment (internet connectivity, `.bundle` flag).

**Verified:** YES — code review confirms auto-detection, not user choice.

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
**Status:** CORE ABA BEHAVIOR — `aba cluster` auto-detects network settings and exits non-zero on first run to prompt user review. This is core ABA behavior, not a TUI bug. The TUI correctly shows the failure and lets the user retry.

**Verified:** YES — observed during interactive testing.

---

## Bug #166: ~~LOW RISK~~ Platform selection writes to aba.conf immediately, before user can cancel

**Severity**: ~~MEDIUM~~ — LOW RISK
**File:** `tui/v2/tui-cluster.sh`
**Status:** LOW RISK — Minor UX quirk. If user cancels the platform config form after selecting a platform, `aba.conf` retains the new platform value. Harmless: user can re-select the old platform from the same menu. No data loss.

**Verified:** YES — code review confirms `replace-value-conf` runs before form display.

---

## Bug #167: ~~INVALID~~ DIRECT/CONNO/DISCO help text references "Finalize Installation" — stale across all modes

**Severity**: LOW — Stale help text (confirmed variant of Bug #112)
**File:** `tui/v2/abatui2.sh` line ~608, `tui/v2/tui-direct.sh` line ~738, `tui/v2/tui-disco.sh` line ~211
**Description:** All three mode help texts reference "Finalize Installation" which was renamed to "Monitor Cluster Installation" and moved to the Advanced menu.

**Verified:** YES — confirmed across all three mode help text blocks.

---

## Bug #168: ~~FIXED~~ Bundle path not quoted in command string — breaks paths with spaces

**Severity**: ~~MEDIUM~~ — FIXED
**Status:** FIXED — Duplicate of Bug #71. Path now properly quoted in command string.
**File:** `tui/v2/tui-mirror.sh` line 1072
**Description:** `local cmd="aba bundle --out $bundle_path"` — `$bundle_path` is not quoted in the command string. Since this string is later passed to `confirm_and_execute` which uses `bash -c "$cmd"`, the unquoted path causes word splitting if the path contains spaces.

**Fix suggestion:** Quote the path: `local cmd="aba bundle --out '$bundle_path'"` or use `printf '%q'`.

**Verified:** YES — code review confirms unquoted variable in command string at line 1072.

---

## Bug #169: ~~FIXED~~ verify-config.sh treats missing DNS records as warning, not error — install proceeds and hangs

**Severity**: HIGH — Core ABA bug, install guaranteed to fail
**Status:** FIXED (2026-05-26 re-validation) — Commit `152220b1` ("fix: revert DNS checks to aba_abort") changed all DNS resolution failures from `aba_warning` to `aba_abort` (fatal). Install now stops immediately when DNS records don't resolve. User sees: "DNS record api.X does not resolve to the rendezvous ip" and the script exits non-zero.
**File:** `scripts/verify-config.sh` lines 136-171
**Description:** When DNS records for `api.<cluster>.<domain>` and `*.apps.<cluster>.<domain>` don't resolve, `verify-config.sh` emits `aba_warning` and sets `_dns_warn=1`, but then unconditionally falls through to `aba_info_ok "Cluster configuration is valid"` and `exit 0`. The install proceeds, the Agent comes alive, image writes to disk at 100%, then bootstrap hangs indefinitely because the API server can't be reached via DNS.

**Observed output:**
```
[ABA] Warning: DNS record api.ocp.example.com does not resolve to the rendezvous ip: 10.0.0.100, it resolves to <empty>!
[ABA] Warning: DNS record *.apps.ocp.example.com does not resolve to the rendezvous ip: 10.0.0.100, it resolves to <empty>!
[ABA] To skip network checks, run: aba --verify conf (see aba.conf)
[ABA] Cluster configuration is valid     ← THIS IS WRONG
```

**Root cause:** Lines 166-171: `_dns_warn` is checked only to print "To skip network checks" hint and `sleep 2`, then execution falls through to success. There is no `exit 1` or error path.

**Fix suggestion:** When `_dns_warn` is set, exit with error (or prompt interactively). The "skip network checks" option (`--verify conf`) should be the escape hatch, not the default behavior.

**Verified:** YES — observed in live DISCO install on registry host. Install hung at "cluster bootstrap did not complete" for 30+ minutes.

---

## Bug #170: ~~FIXED~~ trap - INT resets global INT handler — Ctrl-C stops working properly after Day-2 status

**Severity**: ~~MEDIUM~~ — FIXED
**Status:** FIXED — Replaced `trap - INT` with `trap 'exit 0' HUP TERM INT` in both `_exec_in_tui` and `_exec_in_terminal` to restore the global TUI signal handler.
**File:** `tui/v2/tui-cluster.sh` lines 2015-2026, `tui/v2/tui-lib.sh` lines 491-498
**Description:** `abatui2.sh` line 94 sets `trap 'exit 0' HUP TERM INT` as the global Ctrl-C handler. However, `_day2_status` (line 2015) temporarily overrides INT with `trap : INT` during `oc get` commands, then restores with `trap - INT` (line 2026). The `trap -` resets to **default** signal behavior, not the previously set handler. After `_day2_status` returns, Ctrl-C will terminate the process without triggering the EXIT trap (no cleanup).

Same pattern in `tui-lib.sh` lines 491/498 (`confirm_and_execute`).

**Expected:** After temporary INT override, restore the previous handler: `trap 'exit 0' HUP TERM INT` (or save/restore with a variable).

**Root cause:** `trap - SIGNAL` removes all handlers, including those set at the global level. It does not restore the previous handler.

**Fix suggestion:** Save and restore the handler, or use a wrapper function that saves/restores traps around the protected block.

**Verified:** YES — code review confirms `trap 'exit 0' INT` (line 94) is clobbered by `trap - INT` (line 2026).

---

## Bug #171: ~~FIXED~~ _exec_in_terminal always returns 0 — command failures not propagated

**Severity**: ~~MEDIUM~~ — FIXED
**Status:** FIXED — `_exec_in_terminal` now correctly returns 0 on success, 1 on failure/interrupt, and 2 for retry (lines 708-718). Matches `_exec_in_tui` semantics.
**File:** `tui/v2/tui-lib.sh` line 588
**Description:** `_exec_in_terminal()` always `return 0` at line 588, regardless of whether the executed command succeeded or failed. In contrast, `_exec_in_tui()` correctly returns 1 on failure and 2 for retry (lines 530-531). This means when "Run in Terminal" mode is used, a failed command (e.g. `aba cluster`, `aba delete`) is reported as success to `confirm_and_execute`, which prevents retry logic and hides the failure from the calling code.

**Expected:** `_exec_in_terminal` should return the command's exit code (or 1 for failure, 2 for retry, matching `_exec_in_tui` semantics).

**Root cause:** Line 588: unconditional `return 0` instead of propagating `$exit_code`.

**Fix suggestion:** Change `return 0` to `return $exit_code` (or add retry/fail logic matching TUI mode).

**Verified:** YES — code review confirms asymmetric return values between the two execution modes.

---

### Bug #172 — ~~FIXED~~ VMware password single-quote injection corrupts vmware.conf
**Severity:** Medium  
**File:** `tui/v2/tui-cluster.sh`, line 365  
**Description:** The VMware password field uses `replace-value-conf -q -n GOVC_PASSWORD -v "'$v_pass'" -f "$conf_path"` which wraps the password in single quotes. If the password contains a single quote character, the vmware.conf file is corrupted. The mirror registry password form (`tui-mirror.sh:31`) explicitly rejects single quotes, but the VMware password form has no such validation.

**Fix suggestion:** Add the same single-quote rejection as `_prompt_password` does, or escape single quotes properly.

**Verified:** YES — code review confirms no input validation on VMware password for special characters.

---

### Bug #173 — ~~NOT A BUG~~ Platform selection in Advanced menu persists before config form
**Severity:** Medium  
**File:** `tui/v2/tui-cluster.sh`, lines 1821, 1825, 1829  
**Description:** In the Advanced > Platform Settings menu, selecting a platform (VMware/KVM/BM) immediately writes to `aba.conf` via `replace-value-conf` BEFORE the platform configuration form opens. If the user cancels the config form, the platform is already changed. Same pattern as Bug #166.

**Example:** User is on `platform=bm`, selects "VMware vSphere" in Platform Settings, `aba.conf` changes to `platform=vmw`, user cancels the VMware config form — platform is now `vmw` but vmware.conf is unconfigured.

**Fix suggestion:** Only update the platform in `aba.conf` after the config form completes successfully.

**Verified:** YES — code review confirms `replace-value-conf` called before `_configure_platform_file`.

**Resolution:** By design. The platform must be persisted to `aba.conf` before the config form opens because `cluster.conf` is created up-front via `source aba.conf` and downstream scripts need `platform` set to generate the correct config. The config form edits the platform-specific file (`vmware.conf`/`kvm.conf`) which is a separate concern from the platform selection itself.
---

### Bug #174 — ~~FIXED~~ "Finalize Installation" referenced in all three mode help texts
**Severity:** Low (cosmetic)  
**File:** `tui/v2/abatui2.sh:608`, `tui/v2/tui-disco.sh:211`, `tui/v2/tui-direct.sh:738`  
**Description:** All three mode help texts (CONNO, DISCO, DIRECT) mention "Finalize Installation" as a workflow step. This was a v1 concept — TUI v2 has no separate "Finalize" step. The install flow now auto-monitors until completion.

**Fix suggestion:** Remove or replace "Finalize Installation" with "Monitor Cluster" or remove the step entirely since it's automatic.

**Verified:** YES — grep confirms all three instances.

---

### Bug #175 — ~~FIXED~~ GOVC_NETWORK and KVM_GRAPHICS_ARGS also have single-quote injection risk (extends Bug #172)
**Severity:** Low-Medium  
**File:** `tui/v2/tui-cluster.sh`, lines 379, 526  
**Description:** Same issue as Bug #172 (GOVC_PASSWORD), but affecting two additional fields:
- `GOVC_NETWORK` (line 379): `replace-value-conf -q -n GOVC_NETWORK -v "'$v_network'" ...`
- `KVM_GRAPHICS_ARGS` (line 526): `replace-value-conf -q -n KVM_GRAPHICS_ARGS -v "'$k_graphics'" ...`

Both fields wrap the value in extra single quotes before passing to `replace-value-conf`. If the value contains a literal single quote (e.g., a network name like `VM Network's Backup`), the resulting config line is corrupted:
```
GOVC_NETWORK='VM Network's Backup'
```
This would cause a bash syntax error when the config file is sourced.

**Inconsistency note:** Other VMware fields (GOVC_URL, GOVC_USERNAME, GOVC_DATASTORE, GOVC_DATACENTER, GOVC_CLUSTER, VC_FOLDER) do NOT use single-quote wrapping. Only GOVC_PASSWORD, GOVC_NETWORK, and KVM_GRAPHICS_ARGS have this pattern.

**Fix suggestion:** Either:
1. Remove the extra single-quote wrapping and let `replace-value-conf` handle quoting, or
2. Use double-quote wrapping with proper escaping, or
3. Add single-quote rejection/escaping for all three fields (as `_prompt_password` does for mirror registry password).

**Verified:** YES — code review confirms the pattern in both locations.

---

### Bug #176 — ~~FIXED~~ VMware password field also shows cleartext in "Continue" review  
**Severity:** Low  
**File:** `tui/v2/tui-cluster.sh`, line 325  
**Description:** The VMware config form shows `${v_pass:+(set)}` in the menu list — which correctly shows "(set)" rather than the actual password. However, when dialog's accessibility mode is on or when using screen readers, the raw value may be accessible. More importantly, the password is set via `--inputbox` (Bug #162), which means it's already visible during input. This bug documents a related UX concern: after entering the password in the cleartext `--inputbox`, it correctly shows "(set)" in the menu, which is inconsistent — if the password was just displayed in cleartext during input, why mask it in the menu?

**Note:** This is a minor UX inconsistency extension of Bug #162. The primary fix should be converting the `--inputbox` to `--passwordbox --insecure` (as mirror password already does).

**Verified:** YES — confirmed interactively and via code review.

---

### Interactively Confirmed Bugs (this session)

The following previously-reported bugs were confirmed through interactive TUI testing on `registry4` and `registry`:

- **Bug #131** (Settings summary shows irrelevant Quay/retry in DIRECT mode) — CONFIRMED: navigated to DIRECT mode via Advanced switch, DIRECT menu shows "(ask, Quay, retry=1)" for Configure item.
- **Bug #171** (fixed) — `_exec_in_terminal` now returns proper exit codes and offers retry; confirmed on `registry` where bootstrap failure showed the TUI retry dialog correctly.
- **Bug #174** ("Finalize Installation" in help texts) — CONFIRMED via code review of all three mode help texts.
- **Bug #173** (Platform persists before config form) — CONFIRMED via code review.
- **Bug #172** (GOVC_PASSWORD single-quote injection) — CONFIRMED, extended to Bug #175.

### Bug #177 — CONNO help text describes "Load" operation not available in CONNO mode
**Severity:** Low (cosmetic/confusing)  
**File:** `tui/v2/abatui2.sh`, line 633  
**Description:** The CONNO main menu help text lists four "Transfer" operations:
```
Transfer (uses oc-mirror):
  • Sync — mirror-to-mirror (m2m): push images directly to registry
  • Save — mirror-to-disk (m2d): download images to local archive
  • Load — disk-to-mirror (d2m): load saved images into registry
  • Install Bundle — create a portable bundle (tar) for USB transfer
```

However, the CONNO menu only has Sync, Save, and Bundle — there is no "Load" option. "Load" (disk-to-mirror) is a DISCO-only operation. The help text should not describe it.

**Fix suggestion:** Remove the "Load" bullet from the CONNO help text, or clarify it's only available in DISCO mode.

**Verified:** YES — confirmed by comparing the items list (lines 592-608) with the help text.

---

## Bug #280: ~~CORE ABA BUG~~ "Uninstall Mirror" option hidden from Advanced menu when `.available` marker is removed
**File:** `tui/v2/tui-cluster.sh` (menu gated by `.available`)
**Severity:** ~~HIGH~~ — CORE ABA BUG (downstream of #283)
**Status:** CORE ABA BUG — The TUI correctly shows "Uninstall" when `.available` exists. The root cause is Bug #283: `reg-uninstall.sh` falsely reports success, causing Makefile to remove `.available` prematurely. Fix belongs in core ABA uninstall scripts.
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

## Bug #281: ~~NOT A BUG~~ `reg-uninstall-quay.sh` false-fails when `reg_root` is `$HOME` (default `data_dir=~`)
**File:** `scripts/reg-uninstall-quay.sh`
**Severity:** ~~MEDIUM~~ N/A
**Status:** NOT A BUG — `reg_root` is ALWAYS `$data_dir/quay-install` (e.g. `~/quay-install`), never bare `$HOME`. The premise was wrong. The `[ -d "$reg_root" ]` check is correct — after successful uninstall, `~/quay-install` should be gone.
**Steps to reproduce:**
1. Install Quay with default `data_dir=~` (which sets `reg_root=$HOME`)
2. Uninstall via `aba -d mirror uninstall`
3. `mirror-registry uninstall` succeeds, containers removed
4. Post-uninstall check: "reg_root (/home/steve) still exists" → error exit
5. `.available` marker NOT removed due to error, leaving inconsistent state

**Root cause:** The post-uninstall validation checks if `$reg_root` directory still exists. When `data_dir=~` (default), `reg_root` resolves to `$HOME` which will ALWAYS exist. The check should verify the Quay-specific subdirectory (e.g., `quay-rootCA/`, `quay-config/`) or container state, not the root data directory.

**Expected:** Uninstall succeeds cleanly when `data_dir=~` and containers are removed.
**Actual:** False error "reg_root still exists" leaves `.available` marker and confuses subsequent operations.
**Verified:** YES — via CLI on registry4 (uninstall showed error about /home/steve still existing after containers were removed)

---

## Bug #282: ~~INVALID~~ Wizard "Confirm Configuration" dialog doesn't show platform selection
**File:** `tui/v2/tui-direct.sh` (wizard confirmation step)
**Severity:** LOW — UX gap, user cannot verify platform before committing
**Steps to reproduce:**
1. Start TUI wizard (CONNO initial setup)
2. Select channel=stable, version=4.21.15
3. Confirmation dialog shows: "Channel: stable\nVersion: 4.21.15\nProceed?"
4. Select platform=VMware, complete wizard
5. No confirmation shown that includes the platform selection

**Root cause:** The wizard's confirmation dialog (`_direct_confirm`) only shows channel and version. Platform is selected on a separate page after confirmation.

**Expected:** The final confirmation should include ALL wizard selections (channel, version, AND platform).
**Actual:** Platform is not shown in any confirmation; user must check `aba.conf` to verify.
**Verified:** YES — via TUI on registry4 (confirmation dialog showed only "Channel: stable, Version: 4.21.15")

---

## Bug #283: ~~CORE ABA BUG~~ TUI uninstall reports "Command completed successfully" when actual registry still running
**File:** `scripts/reg-uninstall.sh`
**Severity:** ~~HIGH~~ — CORE ABA BUG (not TUI)
**Status:** ADDRESSED (commits 193cd237, 0122cf8a, 43fa7131) — Multi-pronged fix: (1) reg_vendor=auto is resolved and written back to mirror.conf at install time (43fa7131), so config always matches state; (2) drift detection escalated to aba_warning (193cd237) so users see if they edit mirror.conf post-install; (3) fallback path (state.sh missing) correctly defaults to quay and probes containers+data dirs. The original scenario (mirror.conf wrong vendor) is now prevented at the source.
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
**Status:** ADDRESSED (commit 193cd237) — `_state_override_mirror()` now shows a visible `aba_warning` when state.sh and mirror.conf disagree, telling the user to uninstall first. If state.sh survives after uninstall, the user will see the drift warning on next operation. Uninstall scripts DO remove state.sh (`rm -rf "${regcreds_dir:?}/"*`); survival means uninstall didn't complete cleanly.
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

## Bug #286: ~~NOT A BUG~~ Bug #20 re-confirmed — DISCO `exit 0` terminates entire TUI when entered from CONNO
**File:** `tui/v2/tui-disco.sh` line 229
**Severity:** ~~HIGH~~ — N/A
**Status:** NOT A BUG — User confirmed that exiting the TUI on ESC/Exit from ANY mode is by design. The TUI shows a confirm_quit dialog before exit. Same resolution as Bug #20.
**Steps to reproduce:**
1. Start TUI in CONNO mode
2. Go to Advanced → "Z  Switch to Fully Disconnected"
3. TUI enters DISCO mode (called via `disco_main || true` from `tui_advanced_menu`)
4. In DISCO menu, press Exit
5. Confirm "Exit ABA TUI?" dialog
6. TUI terminates entirely (shows exit summary + shell prompt)
7. Expected: return to CONNO Advanced menu (since DISCO was a sub-call)

**Root cause:** `disco_main()` uses `exit 0` (process termination) instead of `return 0` when the user confirms exit. `exit 0` cannot be caught by `|| true` in the calling function.

**Expected:** `disco_main` should `return 0` when `_TUI_DISCO_FROM_CONNO` is true, returning control to the calling CONNO menu.
**Actual:** `exit 0` terminates the entire TUI process immediately.
**Verified:** YES — via TUI on registry4 (2026-05-24): pressed Exit in DISCO menu entered from CONNO, TUI terminated with "TUI v2 complete" message.

---

## Bug #287: ~~FIXED~~ Advanced Help text documents "E - Reset Execution Mode" but option is conditionally hidden

**Status:** FIXED in commit 31ca4a19 — help text now says "(only shown when set)"

**Severity:** Low (UX documentation inconsistency)
**Location:** `tui/v2/tui-cluster.sh` (Advanced menu Help text, ~line 1818)
**Commit range:** 896c6eef (input validation commit)

**Reproduction:**
1. Start TUI in CONNO mode
2. Go to Advanced (A)
3. Press Help
4. Observe "E - Reset Execution Mode: Clears your 'Always TUI' or 'Always Terminal' preference for this session."
5. Close Help, observe the menu — "E" is NOT listed

**Expected:** Help text should only describe items currently visible in the menu, or indicate "E" is conditional.
**Actual:** Help always mentions "E - Reset Execution Mode" but the option only appears in the menu when `$_TUI_EXEC_MODE` is set (i.e., after choosing "Always TUI" or "Always Terminal").

**Root cause:** The Help text is static (hardcoded in the `2)` case branch) but the menu items are dynamically added based on `if [[ -n "$_TUI_EXEC_MODE" ]]` (line 1778).

**Verified:** YES — via TUI on registry4 (2026-05-24): Help shows "E" but the menu does not list it in a fresh session.

---

## Bug #288: ~~FIXED~~ No "installing" status annotation for clusters in mid-install state

**Status:** FIXED in commit 0cb4a037 — shows "(installing)" when kubeconfig exists but no `.install-complete`

**Severity:** Low (UX improvement)
**Location:** `tui/v2/tui-lib.sh` `select_cluster()` function (~line 1212)
**Commit range:** db9d9ace (delete UX, cluster annotations)

**Reproduction:**
1. Start a cluster installation and interrupt it (Ctrl+C) before completion
2. Go to Day-2 → Delete cluster
3. Observe the cluster list — the cluster shows no status annotation

**Expected:** A cluster that has started installing but not completed should show "(installing)" annotation.
**Actual:** Only "(shut down)" and "(installed)" states are annotated. A cluster mid-install appears with no status indicator, indistinguishable from one that has never been installed.

**Root cause:** `select_cluster()` only checks for `.shutdown.log` and `.install-complete` markers. There's no check for an in-progress state (e.g., kubeconfig exists but no `.install-complete`).

**Verified:** YES — via TUI on registry4 (2026-05-24): started SNO install, interrupted with Ctrl+C, cluster appeared in list without any annotation.

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

## Bug #290: ~~FIXED~~ Retry button broken when using "Always TUI" or "Always Terminal" execution mode

**Severity:** ~~Medium~~ — FIXED
**Status:** FIXED — Added retry loop around remembered-mode execution path in `confirm_and_execute`. Previously, the `return $?` on lines 513-514 bypassed the retry loop when exec returned 2 (retry). Now the remembered-mode path has its own `while :; do` loop that handles return code 2.
**Location:** `tui/v2/tui-lib.sh` `confirm_and_execute()` (~line 510-516)
**Commit range:** c5d6598b (fix: _exec_in_terminal now returns failure and offers retry)

**Reproduction:**
1. Start TUI
2. Configure → set execution mode to "Always TUI" (option 3)
3. Run any command that will fail (e.g. OSUS on a cluster without cincinnati-operator)
4. In the FAILED dialog, click "Retry"
5. Observe: no retry happens; control returns to the parent menu

**Expected:** Clicking Retry should re-execute the command, just like it does when selecting "Run in TUI" from the picker each time.
**Actual:** When `_TUI_EXEC_MODE` is set ("always TUI" or "always terminal"), `confirm_and_execute()` calls `_exec_in_tui "$cmd" ...; return $?` (line 513/514), which directly returns the function's exit code (2 = retry). This bypasses the `while :; do` loop (line 519) that contains the retry logic `[[ $exec_rc -eq 2 ]] && continue` (line 581).

**Root cause:** The "remembered mode" fast-path (lines 510-516) uses `return $?` instead of going through the retry loop. It should instead loop on return code 2.

**Fix hint:**
```bash
if [[ -n "$_TUI_EXEC_MODE" ]]; then
    while :; do
        case "$_TUI_EXEC_MODE" in
            tui)      _exec_in_tui "$cmd" "$title" "$post_cmd_hook" ;;
            terminal) _exec_in_terminal "$cmd" "$title" "$post_cmd_hook" ;;
        esac
        local _rc=$?
        [[ $_rc -eq 2 ]] && continue
        return $_rc
    done
fi
```

**Verified:** YES — code analysis confirms the fast-path `return $?` skips the retry loop.

---

## Bug #291: ~~FIXED~~ Wizard "Reconfigure" channel change silently discarded — never reaches version selection

**Severity:** ~~High~~ — FIXED
**Status:** FIXED — Added `--default-button ok` to the channel selection dialog. Root cause: without explicit default button, Tab navigation focused on the Extra ("Back") button instead of OK ("Next"), causing users to inadvertently trigger "Back" → wizard exit.
**Location:** `tui/v2/tui-direct.sh` `direct_wizard()` (~line 86-150)
**Commit range:** 0313af41 (feat: menu performance, UX fixes)

**Reproduction:**
1. Start TUI in CONNO mode with existing stable 4.21.15 configuration
2. Select "W Rerun Wizard" → "Reconfigure"
3. In Channel menu, highlight "fast" (arrow down from "stable")
4. Tab to "Next" button, press Enter
5. Observe: TUI returns directly to main CONNO menu

**Expected:** After selecting "fast" and pressing Next:
1. Version selection screen should appear showing "Latest (4.21.16)", "Current (4.21.15)", "Previous (4.20.23)", "Manual entry"
2. After selecting a version, a confirmation dialog should show
3. The new channel/version should be saved to aba.conf

**Actual:** The wizard exits silently after the channel step. No version selection, no confirmation, no save. The `aba.conf` remains unchanged (still `ocp_channel=stable`, `ocp_version=4.21.15`).

**Root cause:** Unclear — the code path (pull_secret auto-skip → channel → version) should work. Possible causes:
1. `_direct_channel` dialog button interaction: Tab from highlighted "f" (fast) in menu may go to "Back" (extra button, rc=3) instead of "Next" (OK, rc=0), causing `DIALOG_RC="back"` → `return 1` exit
2. The `--extra-button --extra-label "Back"` button order may be confusing `dialog`'s tab navigation when `--no-cancel` is set
3. A timing issue where `run_once` tasks return empty, triggering the fallback path silently

**Verified:** YES — via TUI on registry4 (2026-05-24): reproduced 3 times. Channel change via Rerun Wizard always returns to main menu without saving.

---

## Bug #292: ~~FIXED~~ `trap - INT` in _exec_in_tui/_exec_in_terminal removes global INT handler permanently
**Status:** FIXED — Duplicate of Bug #170. Both `trap - INT` instances replaced with `trap 'exit 0' HUP TERM INT`.

**Severity:** Medium (cleanup skipped on Ctrl+C after first command execution)
**Location:** `tui/v2/tui-lib.sh` lines 615/622 (`_exec_in_tui`) and 688/694 (`_exec_in_terminal`); also `tui/v2/tui-cluster.sh` line 2054/2065 (`_day2_status`)
**Commit range:** c5d6598b (fix: _exec_in_terminal now returns failure and offers retry)

**Reproduction:**
1. Start TUI
2. Run any command (e.g. Day-2 → NTP) — this calls `_exec_in_tui` or `_exec_in_terminal`
3. Return to main menu
4. Press Ctrl+C

**Expected:** Ctrl+C should trigger the global handler (`trap 'exit 0' HUP TERM INT` at line 104 of abatui2.sh), which runs `_tui_exit_cleanup` via the EXIT trap, removing `$_ABA_TUI_PID_FILE` and cleaning up.
**Actual:** After the first `confirm_and_execute` call completes, `trap - INT` (line 622/694) removes the INT handler entirely. INT now has its DEFAULT disposition (terminate process immediately), bypassing the EXIT trap and `_tui_exit_cleanup`.

**Root cause:** `trap - INT` doesn't "restore" the previous trap — it removes all INT handling. The correct approach is to save and restore the previous trap:
```bash
local _prev_int_trap
_prev_int_trap=$(trap -p INT)
trap : INT
# ... execution ...
eval "$_prev_int_trap"  # restore previous handler
```
Or simply reset to the known global handler: `trap 'exit 0' INT`

**Impact:** After any command execution via TUI, Ctrl+C leaves stale PID file (`$_ABA_TUI_PID_FILE`). This could potentially prevent the TUI from starting next time if the PID file check is strict.

**Verified:** YES — code analysis confirms `trap - INT` removes the global handler set at line 104 of abatui2.sh.

---

## Bug #293: ~~FIXED~~ `select_cluster` "installing" filter checks wrong kubeconfig path — never matches

**Severity:** ~~High~~ — FIXED
**Status:** FIXED — Changed `$ABA_ROOT/$dir/kubeconfig` to `$ABA_ROOT/$dir/iso-agent-based/auth/kubeconfig` (matching the correct path used at line 812 in the same file).
**Location:** `tui/v2/tui-lib.sh` `select_cluster()` line 1208
**Commit range:** db9d9ace (cluster annotations)

**Reproduction:**
1. Start TUI in CONNO mode, install a cluster (e.g., "sno")
2. Interrupt/exit the TUI mid-install
3. Go to Advanced → "F" (Monitor/Finalize Installation)
4. Observe: no installing clusters found

**Expected:** The "installing" filter should find clusters that have a kubeconfig but no `.install-complete` marker.
**Actual:** The filter checks `$ABA_ROOT/$dir/kubeconfig` (does not exist) instead of the correct path `$ABA_ROOT/$dir/iso-agent-based/auth/kubeconfig`.

**Root cause:** Line 1208:
```bash
[[ ! -f "$ABA_ROOT/$dir/kubeconfig" ]] && continue
```
Should be:
```bash
[[ ! -f "$ABA_ROOT/$dir/iso-agent-based/auth/kubeconfig" ]] && continue
```

Compare with `list_undetected_clusters()` at line 812 which correctly uses the full path.

**Verified:** YES — confirmed on registry4 via TUI:
- `ls ~/aba/sno/kubeconfig` → "No such file or directory"
- `ls ~/aba/sno/iso-agent-based/auth/kubeconfig` → exists
- Advanced → "F" Monitor Installation → "No clusters are currently installing" (even though sno is mid-install)

---

## Bug #294: ~~FIXED~~ `_apply_mode_connection()` doesn't convert "proxy" to "mirror" in DISCO mode

**Status:** FIXED — changed condition to `[[ "$cl_connection" != "mirror" ]]` (any non-mirror value normalized in DISCO)

**Severity:** Low (edge case — only triggers when existing cluster.conf has int_connection=proxy)
**Location:** `tui/v2/tui-cluster.sh` `_apply_mode_connection()` lines 678-682
**Commit range:** N/A

**Description:** When loading an existing `cluster.conf` that has `int_connection=proxy`, the `_apply_mode_connection()` function in DISCO mode only converts "direct" → "mirror" but leaves "proxy" unchanged:
```bash
else
    [[ "$cl_connection" == "direct" ]] && cl_connection="mirror"
fi
```

In DISCO mode, "proxy" is invalid (no internet for proxy to reach public registries). The wizard correctly blocks the user from TOGGLING to proxy in DISCO mode (shows "only mirror is available"), but doesn't fix stale "proxy" values loaded from an existing config.

**Expected:** In DISCO mode, both "direct" AND "proxy" should be converted to "mirror".
**Actual:** Only "direct" is converted; "proxy" passes through unchanged.

**Note:** NOT a duplicate of Bug #286 (which is about `exit 0` killing the TUI). Also distinct from Bug #9 (which is about the toggle offering wrong options). This bug is specifically about stale config values not being corrected on load.

**Fix hint:** Change line 681 to: `[[ "$cl_connection" == "direct" || "$cl_connection" == "proxy" ]] && cl_connection="mirror"`

**Verified:** YES — code review confirms the logic only checks for "direct".

---

## Bug #295: ~~FIXED~~ No Day-2 prompt after `mirror sync` or `mirror load` — user may forget to apply IDMS/ITMS

**Severity:** Low (UX gap — operational step easily forgotten)
**Location:** `tui/v2/tui-mirror.sh` `mirror_sync()` line 490, `tui/v2/tui-disco.sh` `disco_load_images()` line 315
**Commit range:** N/A (missing feature)

**Reproduction:**
1. Start TUI with a running cluster and mirror
2. Sync images (S key in CONNO menu) — wait for completion
3. Observe: TUI returns to main menu with no prompt about Day-2

**Expected:** After a successful sync or load, the TUI should offer "Mirror updated. Run Day-2 to apply changes to running clusters? (Y/n)" — since the project rules explicitly state: "Always run `aba day2` after `mirror load` or `mirror sync` (applies IDMS/ITMS/CatalogSources)."
**Actual:** `mirror_sync()` and `disco_load_images()` return to the menu silently. The user must remember to manually go to Day-2 → Run Day-2, or their clusters won't see the updated images.

**Root cause:** Neither `mirror_sync()` nor `disco_load_images()` have a post-completion hook that prompts for Day-2 operations. The `_invalidate_mirror_cache` hook (line 493) only invalidates the status cache — it doesn't prompt.

**Verified:** YES — code analysis confirms no Day-2 prompt exists after sync/load completion.

---

## Bug #296: ~~NOT A BUG~~ Internet error dialog says "Exiting..." but TUI continues in DISCO mode when fallback succeeds

**Status:** NOT A BUG — current code shows "Exiting..." ONLY in the `else` branch that actually exits. DISCO fallback (line 449) runs BEFORE the error dialog and never shows the message.

**Severity:** Low (misleading message — cosmetic/UX)
**Location:** `tui/v2/abatui2.sh` `_detect_mode()` line 449
**Commit range:** N/A (likely present since initial implementation)

**Reproduction:**
1. Disconnect internet on a host with an existing `aba.conf` and valid mirror payload (ISC + archives)
2. Start the TUI
3. Observe: internet error dialog appears with message ending in "Exiting..."
4. Press OK
5. Observe: TUI does NOT exit — it falls back to DISCO mode and shows the DISCO menu

**Expected:** The error dialog should say something like "Falling back to Disconnected mode..." or not display the misleading "Exiting..." at all when DISCO fallback is available.
**Actual:** The msgbox at line 449 unconditionally includes "Exiting..." in its text. But lines 451-454 check if DISCO mode is possible and, if so, continue the TUI in DISCO mode instead of exiting.

**Root cause:** The error message text is hardcoded before the DISCO fallback check. The dialog is shown, THEN the code checks if it can fall back. The message should either:
1. Be conditional (don't show "Exiting..." if DISCO fallback is available), or
2. Show a different message explaining the fallback ("No internet - switching to Disconnected mode")

**Verified:** YES — code analysis confirms the flow: line 449 shows "Exiting..." → line 452 checks DISCO availability → line 453 sets DISCO mode (TUI continues).

---

## Bug #297: ~~DUPLICATE of Bug #177~~ — CONNO help text lists "Load" operation that doesn't exist in the menu

**DUPLICATE:** Same issue as Bug #177. Removed.

---

## Bug #298: ~~DUPLICATE of Bug #167~~ — DIRECT mode help text lists "Monitor Cluster" as a main workflow step but it's under Advanced

**DUPLICATE:** Same underlying issue as Bug #167 (all mode help texts reference Monitor/Finalize as a main step but it's under Advanced). Removed.

---

## Bug #299: ~~DUPLICATE OF Bug #398~~ Settings help text mentions "8" retries but actual toggle values are 0, 1, 2, 5

**Severity:** Low (help text inaccuracy)
**Location:** `tui/v2/tui-lib.sh` lines 1103-1105
**Commit range:** N/A
**DUPLICATE:** Same issue as Bug #398 (and #438). All report the Settings Help text showing wrong retry values.

**Description:** The Settings menu help text says:
```
Retry Count:
  How many times to retry failed oc-mirror operations.
  OFF = no retries, 2 or 8 = retry that many times.
```

But the actual toggle cycle (lines 1172-1178) is: `0 → 1 → 2 → 5 → 0`. The value "8" is never available through the UI toggle. Additionally, "1" and "5" are valid values that aren't mentioned.

**Expected:** Help text matches actual toggle values: "OFF (0), 1, 2, or 5 retries"
**Actual:** Help text says "2 or 8" — "8" doesn't exist in the toggle, "1" and "5" are missing

**Fix hint:** Change line 1105 to: `"  OFF = no retries, 1/2/5 = retry that many times."` (or update toggle to include 8 if intended)

**Verified:** YES — code review confirms toggle values `0, 1, 2, 5` don't include 8.

---

## Bug #300: ~~NOT A BUG~~ Cluster name validation regex rejects existing cluster directories containing dots

**Severity:** ~~MEDIUM~~ — N/A
**Status:** NOT A BUG — OpenShift cluster names must be valid DNS labels (RFC 1123): lowercase alphanumeric and hyphens only. Dots are NOT valid in cluster names. The regex validation is correct.
**Location:** `tui/v2/tui-lib.sh` lines 1245-1249 (in `select_cluster`) and line 1296 (in `select_installed_cluster`)
**Commit range:** N/A (present since these functions were written)

**Description:** Both `select_cluster()` and `select_installed_cluster()` use a post-selection validation regex:
```bash
if [[ ! "$SELECTED_CLUSTER" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    dlg --msgbox "Invalid cluster name..."
    return 1
fi
```

This regex only allows lowercase alphanumerics and hyphens. But `list_cluster_dirs()` (line 782) includes ANY directory with a `cluster.conf` file, regardless of naming. On the test host, `demo1.bk` exists with a valid `cluster.conf` and `.install-complete` marker.

**Reproduction:**
1. Have a cluster directory with a dot in the name (e.g. `demo1.bk/cluster.conf`)
2. Go to Day-2 → any operation that uses `select_installed_cluster`
3. Select the dotted cluster from the list
4. Error: "Invalid cluster name: 'demo1.bk' — Cluster directory names must be valid DNS labels."

**Expected:** Either:
- Don't show clusters that fail validation in the selection list (filter early), OR
- Relax the regex to allow dots (`.`) since OpenShift cluster names can contain dots, OR
- Accept any existing directory name that has a cluster.conf (it already exists, validation is moot)

**Root cause:** The validation is applied AFTER listing and AFTER user selection, making it a confusing rejection. The regex is DNS-label strict (`[a-z0-9-]`) but cluster directory names can be more permissive.

**Verified:** YES — `demo1.bk` exists on registry4 with `.install-complete` and would be shown then rejected.

---

## Bug #301: ~~FIXED~~ `offer_editor()` doesn't close flock FD before launching $EDITOR

**Status:** FIXED in commit 0cb4a037 — added `{ABA_TUI_FLOCK_FD}>&-` to editor launch

**Severity:** Low (minor FD leak — lock held by parent anyway)
**Location:** `tui/v2/tui-lib.sh` line 1329
**Commit range:** N/A

**Description:** The `offer_editor()` function launches the user's `$EDITOR` process without closing the TUI flock file descriptor:
```bash
${EDITOR:-vi} "$filepath"
```

Compare with `_exec_in_terminal` which correctly closes it:
```bash
bash -c "$cmd" {ABA_TUI_FLOCK_FD}>&-
```

And `_exec_in_tui`:
```bash
bash -c "$tui_cmd" {ABA_TUI_FLOCK_FD}>&- 2>&1
```

The editor process inherits the open flock FD. While the lock is already held by the parent TUI process (so no immediate deadlock), if the editor forks background processes (some editors do for language servers, etc.), those children could hold the FD open after the TUI exits, preventing future TUI launches until those processes terminate.

**Expected:** Close the flock FD before launching the editor: `${EDITOR:-vi} "$filepath" {ABA_TUI_FLOCK_FD}>&-`
**Actual:** Editor inherits the flock FD.

**Fix hint:** Change line 1329 to: `${EDITOR:-vi} "$filepath" {ABA_TUI_FLOCK_FD}>&-`

**Verified:** YES — code review confirms all other external process launches close the FD, but `offer_editor` does not.

---

## Bug #302: ~~DUPLICATE~~ `_operator_search` destroys ref-count — breaks set removal logic

**Severity:** ~~Medium~~ — DUPLICATE of Bug #308 (FIXED)
**Location:** `tui/v2/tui-mirror.sh` `_operator_search()` line 992
**Commit range:** Present since operator ref-counting was added

**Reproduction:**
1. Add operator set "ocp" (which contains `web-terminal`) — ref-count becomes 1
2. Add operator set "virt" (which also contains `web-terminal`) — ref-count becomes 2
3. Use "Search Operator Names", search "web-terminal"
4. Leave it checked, click OK → ref-count is RESET to 1 (line 992: `OP_BASKET["$op"]=1`)
5. Remove set "ocp" → ref-count drops to 0, `web-terminal` is removed from basket
6. But "virt" set still contains it! The operator should still be in the basket.

**Expected:** Search should either (a) not overwrite existing ref-counts for already-in-basket operators, or (b) not participate in the ref-counting system at all (use a separate "manual" flag).

**Actual:** Line 992 unconditionally assigns `OP_BASKET["$op"]=1`, overwriting any existing ref-count from sets.

**Root cause:** The search feature uses a flat `=1` assignment while the sets feature uses ref-counting. The two mechanisms are not coordinated.

**Fix hint:** Change line 992 to only set if not already in basket:
```bash
[[ -z "${OP_BASKET[$op]:-}" ]] && OP_BASKET["$op"]=1
```
Or increment: `OP_BASKET["$op"]=$(( ${OP_BASKET[$op]:-0} + 1 ))`
Neither is perfect — the design needs a decision on whether search-added operators participate in ref-counting.

**Additional finding:** The startup initialization at `abatui2.sh` line 250 ALSO uses `=1` (not incrementing) when loading operators from multiple sets. This means ref-counting is broken even WITHOUT using search — if two sets share an operator and one set is unchecked, the shared operator is incorrectly removed regardless.

**Verified:** YES — code analysis confirms the conflicting assignment patterns in both `_operator_search` and startup initialization.

---

## Bug #303: ~~DUPLICATE of Bug #13~~ `_operator_view_basket` removes operators without updating `OP_SET_ADDED` — set checklist becomes stale

**Severity:** Low (UX inconsistency — sets show "checked" but their operators are missing)
**Location:** `tui/v2/tui-mirror.sh` `_operator_view_basket()` lines 1042-1047
**Commit range:** Present since operator ref-counting was added

**Reproduction:**
1. Add operator set "ocp" (adds ~7 operators including `web-terminal`)
2. Go to "View/Edit Basket"
3. Uncheck `web-terminal` and other operators, click "Apply"
4. Operators are removed from `OP_BASKET` (correct)
5. Go to "Select Operator Sets" — "ocp" still shows as checked (wrong)
6. If user clicks OK without changing sets, nothing happens — the operators stay removed

**Expected:** Either (a) removing operators from the basket should also update `OP_SET_ADDED` to uncheck sets that have had members removed, or (b) removing operators in View/Edit should break the set association (clear `OP_SET_ADDED` for affected sets).

**Actual:** `OP_SET_ADDED` retains stale entries. The sets checklist is out of sync with the actual basket content.

**Root cause:** `_operator_view_basket()` only modifies `OP_BASKET` (line 1044 `unset 'OP_BASKET[$op]'`) but never touches `OP_SET_ADDED`. There's no reverse lookup from operator → set to determine which sets should be cleared.

**Fix hint:** After removing operators, iterate over `OP_SET_ADDED` and for each set that is still "1", check if any of its operators are still in `OP_BASKET`. If none remain, remove the set from `OP_SET_ADDED`. Alternatively, simply clear `OP_SET_ADDED` entirely in `_operator_view_basket` (treating manual edits as overriding sets).

**Verified:** YES — code analysis confirms `_operator_view_basket` never modifies `OP_SET_ADDED`.

---

## Bug #304: ~~FIXED~~ Platform change in Advanced menu not reflected in cluster wizard — stale `$platform` variable

**Severity:** ~~Medium~~ — FIXED
**Status:** FIXED — Added `platform=vmw/kvm/bm` after each `replace-value-conf` in the Advanced menu platform change logic. This keeps the in-memory `$platform` variable in sync with the disk write.
**Location:** `tui/v2/abatui2.sh` line 745 (CONNO main loop after `tui_advanced_menu` returns)
**Commit range:** Present since Advanced → Platform Settings was added

**Reproduction:**
1. Start TUI (platform=vmw in `aba.conf`)
2. Go to Advanced → Platform Settings → select "Bare Metal" → OK
3. `aba.conf` is correctly updated: `platform=bm`
4. Go back to main menu → select "Install Cluster"
5. Observe: wizard shows "Platform: vmw (VMware/ESXi)" — stale!

**Expected:** After changing platform in Advanced, the cluster wizard should reflect the new platform.
**Actual:** The main menu loop does not re-source `aba.conf` after `tui_advanced_menu` returns, so `$platform` stays "vmw" in memory.

**Root cause:** At `abatui2.sh` line 744-747:
```bash
"$TUI2_CONNO_TAG_ADVANCED")
    tui_advanced_menu
    _conno_need_recheck=true
    ;;
```
No `source <(normalize-aba-conf)` is done after `tui_advanced_menu` returns. Compare with line 751 which does re-source after the "Reconfigure" action.

Additionally, `cluster_install_flow` only initializes `_cl_platform="${platform:-bm}"` once (line 613, guarded by `_CL_STATE_INIT`). On second entry, it reuses the stale value.

**Fix hint:** Add `source <(cd "$ABA_ROOT" && normalize-aba-conf) 2>/dev/null || true` after `tui_advanced_menu` returns at line 747, similar to how it's done at line 751.

**Verified:** YES — live TUI testing on registry4: changed platform to "bm" via Advanced, then "Install Cluster" still showed "vmw".

---

## Bug #305: ~~DUPLICATE of Bug #165~~ First-time cluster creation fails with confusing error when network values are auto-detected

**Severity:** Medium (blocks first-time users — must dismiss error and retry)
**Location:** `tui/v2/tui-cluster.sh` `_cluster_generate_defaults()` lines 188-194
**Commit range:** Present since `_cluster_generate_defaults` was added

**Reproduction:**
1. Start TUI with `aba.conf` that has no `machine_network`, `dns_servers`, `next_hop_address`, or `ntp_servers` set
2. Go to Install Cluster → enter a new cluster name (e.g. "bmtest1") → press Next
3. Error: "Failed to generate cluster configuration (exit code 2)"
4. Dismiss error → press Next again → works fine (because values are now in `aba.conf`)

**Expected:** The TUI should either:
- Automatically retry after auto-detection writes the values, OR
- Check if `cluster.conf` was created despite the non-zero exit code and proceed, OR
- Show an informative message: "Network values auto-detected and saved. Retrying..."

**Actual:** Generic error "Failed to generate cluster configuration (exit code 2)" with "Check the TUI log for details" — no hint about what happened.

**Root cause:** `aba cluster --step cluster.conf` auto-detects network values, writes them to `aba.conf`, THEN exits non-zero with "Please review aba.conf and re-run the command." But it DOES successfully create `bmtest1/cluster.conf` before that exit. The TUI's `_cluster_generate_defaults` (line 190-194) treats any non-zero exit as failure without checking whether the config was actually created.

**Fix hint:** After detecting non-zero exit, check if `$_conf` exists. If so, load it and optionally show an info message about auto-detected values (or just silently proceed since the TUI provides review on pages 2-4):
```bash
if [[ $_gen_rc -ne 0 ]]; then
    if [[ -f "$_conf" ]]; then
        tui_log "WARN: Command exited $_gen_rc but cluster.conf was created (auto-detect)"
        # Proceed — user reviews values on pages 2-4
    else
        # Real failure
        dlg --msgbox "Failed to generate..." ...
        return 1
    fi
fi
```

**Verified:** YES — live reproduction on registry4 with `platform=bm`. First attempt fails, second succeeds.

---

## Bug #306: "Install Mirror" bypasses reinstall confirmation when mirror is installed but not verified

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

## Bug #307: ~~FIXED~~ Operator set files with inline comments silently skip operators

**Severity:** ~~Medium~~ — FIXED
**Location:** `tui/v2/tui-mirror.sh` lines 910-918 (add path) and lines 883-896 (remove path); also `tui/v2/abatui2.sh` lines 241-251 (restore path)
**Commit range:** Present since operator sets feature was added

**Reproduction:**
1. Ensure `templates/operator-set-ocp` contains a line like:
   `devworkspace-operator		# Required by web-terminal`
2. Start TUI → Select Operators → Operator Sets → check "ocp"
3. View Basket
4. Expected: `devworkspace-operator` appears in basket
5. Actual: `devworkspace-operator` is silently missing from basket

**Root cause:** The set file parser (lines 910-918) only strips full-line comments (lines starting with `#`) at line 911. It then attempts to trim whitespace with:
```bash
line="${line##[[:space:]]}"  # Removes ONE leading whitespace char
line="${line%%[[:space:]]}"  # Removes ONE trailing whitespace char
```
These bash parameter expansions WITHOUT `*` only remove a single character. For a line like `devworkspace-operator\t\t# Required by web-terminal`:
- No leading whitespace → first trim does nothing
- No trailing whitespace → second trim does nothing
- Result: `line` = `devworkspace-operator\t\t# Required by web-terminal`

Then the `grep -q "^$line[[:space:]]"` at line 915 searches for this entire string (including tabs and comment) at the start of index file lines. The index contains `devworkspace-operator  DevWorkspace Operator  fast` — no match. Operator is silently skipped.

**Fix hint:** Strip inline comments before trimming:
```bash
line="${line%%#*}"            # Strip inline comment (everything from first #)
line="${line%%[[:space:]]}"  # Trim trailing whitespace
line="${line##[[:space:]]}"  # Trim leading whitespace
```
Or better (handles multiple leading/trailing whitespace):
```bash
line="${line%%#*}"
line="${line%"${line##*[![:space:]]}"}"  # Trim trailing
line="${line#"${line%%[![:space:]]*}"}"  # Trim leading
```

**Impact:** Currently only `devworkspace-operator` in `operator-set-ocp` is affected (the only operator set line with an inline comment). This means:
- Users selecting the "ocp" set get 8 operators instead of 9
- `devworkspace-operator` (dependency of `web-terminal`) is silently omitted
- If `web-terminal` is mirrored without its dependency, it may fail to install on the cluster

**Verified:** YES — confirmed `devworkspace-operator` exists in `redhat-operator-index-v4.17` and would match if the inline comment were stripped. The grep pattern with the inline comment never matches any index line.

---

## Bug #308: ~~FIXED~~ `_operator_search` overwrites operator ref-counts, corrupting set-based tracking

**Severity:** ~~Medium~~ — FIXED
**Location:** `tui/v2/tui-mirror.sh` line 992 (search confirm logic)
**Commit range:** Present since operator search feature was added

**Reproduction:**
1. Select Operators → Operator Sets → check "ocp" (adds `cincinnati-operator` with ref=1)
2. Also check "gpu" (adds `cincinnati-operator` again → ref becomes 2)
3. Go to "Search" → type "cincinnati" → see it checked in results → press OK (confirm without changing)
4. Line 992 executes: `OP_BASKET["cincinnati-operator"]=1` — ref count drops from 2 to 1!
5. Go back to Operator Sets → uncheck "gpu" → removal loop decrements by 1 → count becomes 0
6. `cincinnati-operator` is removed from basket!
7. Expected: operator should remain (still in "ocp" set with ref=1)
8. Actual: operator is gone because search overwrote ref count from 2 to 1

**Root cause:** At line 992, the search function unconditionally sets:
```bash
OP_BASKET["$op"]=1
```
This overwrites whatever ref count the operator already had. For operators that appear in multiple sets (e.g., `cincinnati-operator` is in ocp, odf, acm, ai, appdev, gpu, logging, mesh2, mesh3, odfdr), confirming a search that includes them as "already checked" silently resets their ref count to 1.

**Fix hint:** Only add if not already present; don't overwrite:
```bash
if [[ -z "${OP_BASKET[$op]:-}" ]]; then
    OP_BASKET["$op"]=1
fi
```

**Note:** The removal side (`unset 'OP_BASKET[$op]'` when user explicitly unchecks in search/basket) is correct UX — an explicit user action to remove an operator should be definitive, regardless of set ref-counts.

**Related:** Bug #13 (same family — operations outside `_operator_sets` corrupting ref-count invariant)

**Impact:** Any user who uses Search after selecting multiple overlapping operator sets risks silent operator loss when they later modify set selections. The more sets selected, the worse the corruption (more operators have ref count > 1 that gets flattened to 1).

**Verified:** YES — code trace confirms line 996 unconditionally sets to 1 regardless of existing count. No guard exists for already-present operators.

---

## Bug #309: ~~DUPLICATE~~ Retry button broken when "Always TUI" or "Always Terminal" mode is active

**Severity:** ~~Medium~~ — DUPLICATE of Bug #290
**Location:** `tui/v2/tui-lib.sh` lines 510-516 (`confirm_and_execute` "remembered mode" bypass)
**Commit range:** Present since "Always" execution mode feature was added

**Reproduction:**
1. Start TUI → CONNO menu → Sync Images
2. At execution mode picker, choose "Always TUI (this session)"
3. Command runs and FAILS (e.g., mirror not available, network error)
4. Failure dialog shows "Back to Menu" and "Retry" buttons
5. Press "Retry"
6. Expected: command runs again
7. Actual: returns to main menu (retry is not performed)

**Root cause:** The "remembered mode" bypass at lines 510-516:
```bash
if [[ -n "$_TUI_EXEC_MODE" ]]; then
    case "$_TUI_EXEC_MODE" in
        tui)      _exec_in_tui "$cmd" "$title" "$post_cmd_hook"; return $? ;;
        terminal) _exec_in_terminal "$cmd" "$title" "$post_cmd_hook"; return $? ;;
    esac
fi
```
Uses `return $?` which passes ALL return codes directly to the caller. When the user presses Retry, `_exec_in_tui`/`_exec_in_terminal` returns 2 (retry signal). But `return $?` passes rc=2 to the CALLER of `confirm_and_execute` (e.g., `mirror_sync`), which doesn't understand rc=2 and simply returns it to the main menu.

Without "Always" mode active, the retry works correctly: `_exec_in_tui` returns 2 → line 581: `[[ $exec_rc -eq 2 ]] && continue` → loop re-shows mode picker → user picks mode → command retries.

**Fix hint:** Wrap the remembered-mode path in its own retry loop:
```bash
if [[ -n "$_TUI_EXEC_MODE" ]]; then
    while :; do
        local _rc=0
        case "$_TUI_EXEC_MODE" in
            tui)      _exec_in_tui "$cmd" "$title" "$post_cmd_hook"; _rc=$? ;;
            terminal) _exec_in_terminal "$cmd" "$title" "$post_cmd_hook"; _rc=$? ;;
        esac
        [[ $_rc -eq 2 ]] && continue  # Retry
        return $_rc
    done
fi
```

**Impact:** Any user who sets "Always TUI" or "Always Terminal" loses the ability to retry failed commands from the failure dialog. They must re-select the operation from the main menu to try again. This is particularly frustrating for long operations like mirror sync or image save that fail near the end.

**Verified:** YES — code trace confirms: `return $?` at line 513/514 passes rc=2 directly to caller without retry loop. The retry loop at lines 519-582 is only reached when `_TUI_EXEC_MODE` is empty.

---

## Bug #310: ~~FIXED~~ Community catalog display names shown instead of Red Hat/Certified

**Severity:** Low (cosmetic — wrong display name, correct operator)
**Location:** `tui/v2/tui-mirror.sh` — `_operator_view_basket()` (line 1016) and `_operator_search()` (line 963)
**Commit range:** Present since operator basket/search features were added

**Reproduction:**
1. Start TUI → Select Operators → Operator Sets → check "ocp"
2. View Basket
3. Expected: `node-healthcheck-operator  Node Health Check Operator`
4. Actual: `node-healthcheck-operator  Node Health Check Operator - Community Edition`

**Root cause:** Both `_operator_view_basket` and `_operator_search` use `grep -m1` with a `*` glob to search `.index/*-index-v*` files. Bash expands globs alphabetically: `certified` → `community` → `redhat`. So `grep -m1` finds the `community-operator-index` match first, even though the operator exists in `redhat-operator-index` with the official name.

Core ABA (`scripts/add-operators-to-imageset.sh` lines 211-219) correctly uses an if/elif chain checking redhat first, then certified, then community.

Additionally, `_operator_search` had no deduplication by operator name — if an operator appeared in multiple catalogs with different display names, it showed up multiple times in search results.

**Fix:** Replaced `*-index-v*` glob with explicit file list in priority order:
```bash
grep -m1 "^${op}[[:space:]]" \
    "$ABA_ROOT"/.index/redhat-operator-index-v${version_short} \
    "$ABA_ROOT"/.index/certified-operator-index-v${version_short} \
    "$ABA_ROOT"/.index/community-operator-index-v${version_short} \
    2>/dev/null
```
Search also now deduplicates by operator name (first match per operator wins).

**Verified:** YES — tested on registry4. `node-healthcheck-operator` and `node-maintenance-operator` now show Red Hat display names in the basket view.

---

## Bug #311: Stale "mirror ready"/"synced" status after mirror uninstall + reinstall

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

## Bug #312: ~~FIXED~~ DISCO mode exits TUI entirely when no mirror_*.tar archives found (even with synced mirror)

**Status:** FIXED (commit 74302da8 — added mirror-available bypass at lines 40-43 of tui-disco.sh)
**Severity:** HIGH
**File:** `tui/v2/tui-disco.sh` (lines ~73-82, `_disco_bundle_wizard_gate`)

**Description:** When the TUI detects DISCO mode (`.bundle` marker exists, no internet), it validates that `mirror_*.tar` files exist in `mirror/data/`. If none exist, it shows a "Cannot Proceed" message and then exits the entire TUI — returning the user to the shell prompt with no recourse.

**Root cause:** `_disco_bundle_wizard_gate` returns 1 when no archives found → `disco_main()` does `_disco_bundle_wizard_gate || return 1` → this propagates up to the main loop which exits the TUI.

**Steps to reproduce:**
1. Run in CONNO mode, sync images to mirror (mirror has images, no .tar files)
2. Take internet down: `int_down`
3. Create `.bundle` marker: `touch .bundle`
4. Launch TUI (auto-detects DISCO mode)
5. Press Continue past splash
6. See "ABA Install Bundle" summary showing "ISA archives: NONE"
7. Press OK
8. See "Cannot Proceed — No mirror archive files found"
9. Press OK → TUI exits entirely

**Expected:** If the mirror is already installed and has images (verified via `_mirror_has_release_image`), the DISCO menu should still be accessible (allowing cluster install without needing to load from `.tar`). Alternatively, offer to switch back to CONNO mode or show the DISCO menu with limited options.

**Actual:** TUI exits completely. User must restart TUI (after adding `.tar` files or removing `.bundle`).

**Impact:** A user who was working in CONNO mode, synced their mirror, then lost internet connectivity (or went to an air-gapped site with their system), cannot use the TUI to install clusters even though the mirror has all needed images.

**Verified:** YES — reproduced on registry4. TUI exited to shell prompt.

---

## Bug #313: ~~FIXED~~ Cluster type toggle silently ignored when re-editing existing cluster

**Status:** FIXED (commit fdcc119f — `--type` now uses `_set_cluster_conf()` in aba.sh + type mapping in setup-cluster.sh)
**Severity:** HIGH
**File:** `tui/v2/tui-cluster.sh` — `_cluster_generate_defaults()` lines 177-180, `_cluster_load_conf()` lines 112-121
**Affected:** Cluster wizard Basics page (Type toggle), Networking page (VIP fields missing)

**Description:** When re-entering the cluster wizard for an existing cluster (i.e., `cluster.conf` already exists), toggling the cluster type on the Basics page (e.g. sno → compact) has no effect. The type is silently reverted to the old value stored in the file.

**Root cause:** After page 1 (Basics) completes, `_cluster_generate_defaults()` is called (line 722). When the config file already exists (line 177), it unconditionally calls `_cluster_load_conf()` which derives `cl_type` from the file's `num_masters`/`num_workers` values (lines 112-121). This overwrites the in-memory `cl_type` that the user just toggled. Then `_persist_cluster_draft` (line 724) persists the now-reverted type back to the file.

**Flow:**
1. User opens wizard for existing "ocp" cluster (type=sno in cluster.conf)
2. User presses T → type toggles to "compact" (in-memory `cl_type="compact"`)
3. User presses Next → `_cluster_generate_defaults()` runs
4. Line 177: `cluster.conf` exists → `_cluster_load_conf()` reads num_masters=1, num_workers=0
5. Line 114-115: derives `cl_type="sno"` — **user's toggle is lost**
6. `_persist_cluster_draft()` writes num_masters=1 back to file (sno values)
7. Networking page: `cl_type` is "sno" → VIP fields (A, I) are hidden
8. Going Back: Basics page shows Type: sno — toggle was silently discarded

**Steps to reproduce:**
1. Have an existing cluster directory with cluster.conf (e.g. "ocp" as SNO)
2. TUI → Install Cluster (I) → Basics page shows Type: sno
3. Press T → Type changes to "compact" (visible on screen)
4. Press Tab → Next → Enter (advance to Networking)
5. Observe: Networking page shows only M, S, D, G, N — NO "A API VIP" or "I Ingress VIP"
6. Press Back → Basics page shows Type: sno (reverted)

**Expected:** Type toggle should persist — Networking page should show VIP fields for compact/standard. `_cluster_generate_defaults` should not overwrite user changes made on the Basics page.

**Actual:** Type toggle is silently discarded. VIP fields never appear for compact/standard when re-editing an existing cluster.

**Impact:** Users cannot change the cluster type of an existing cluster configuration via the TUI. They would have to delete the cluster directory and start fresh, or manually edit `cluster.conf`.

**Verified:** YES — reproduced on registry4. Toggled ocp from sno to compact, advanced to Networking, confirmed VIP fields missing and type reverted to sno on Back.

---

## Bug #314: ~~FIXED~~ "Monitor Cluster Installation" shows shut-down clusters

**Status:** FIXED in commit 31ca4a19 — added `.shutdown.log` check to "installing" filter

**Severity:** LOW
**File:** `tui/v2/tui-lib.sh` — `select_cluster()` lines 1211-1216
**Affected:** Advanced → Monitor Cluster Installation (F)

**Description:** The "installing" filter in `select_cluster()` does not exclude clusters that have been shut down (`.shutdown.log` exists). A cluster that was previously installing but was shut down before completion still appears in the Monitor list, even though it cannot be monitored.

**Root cause:** The filter only checks:
1. Skip if `.install-complete` exists (already fully installed)
2. Skip if no `kubeconfig` (never started installing)

It does NOT check for `.shutdown.log`. A cluster with kubeconfig + .shutdown.log (previously installing, then shut down) passes the filter and appears as a candidate for monitoring.

**Steps to reproduce:**
1. Start a cluster installation (creates kubeconfig)
2. Shut down the cluster before installation completes (creates `.shutdown.log`)
3. Go to Advanced → Monitor Cluster Installation
4. Observe: shut-down cluster appears in the list with "(shut down)" annotation

**Expected:** Shut-down clusters should not appear in the "installing" filter since they cannot be actively monitored.

**Actual:** `sno1-ext (shut down)` appears alongside actively-installing clusters.

**Verified:** YES — observed on registry4 in TUI.

---

## Bug #315: ~~FIXED~~ `_cluster_page_vm()` checks `macs.conf` in wrong directory (project root instead of cluster dir)

**Status:** NEW

**File:** `tui/v2/tui-cluster.sh` line 1353

**Steps to reproduce:**
1. Place a valid `macs.conf` in the cluster directory (e.g., `~/aba/sno/macs.conf`)
2. Open the cluster wizard → navigate to page 4 (VM Resources)
3. Look at the "MAC template" menu item

**Expected:** The annotation `(from macs.conf)` should appear next to the MAC template item when `macs.conf` exists in the **cluster directory** (`$ABA_ROOT/$cl_name/macs.conf`).

**Actual:** Line 1353 checks `$ABA_ROOT/macs.conf` (project root), NOT `$ABA_ROOT/$cl_name/macs.conf` (cluster dir). The annotation never appears for a correctly placed `macs.conf` file.

**Root cause:**
```bash
if [[ -f "$ABA_ROOT/macs.conf" ]] && grep -qE '^[^#]' "$ABA_ROOT/macs.conf" 2>/dev/null; then
    mac_info=" (from macs.conf)"
fi
```
Should be:
```bash
if [[ -f "$ABA_ROOT/$cl_name/macs.conf" ]] && grep -qE '^[^#]' "$ABA_ROOT/$cl_name/macs.conf" 2>/dev/null; then
    mac_info=" (from macs.conf)"
fi
```

**Evidence:**
- Line 643 correctly loads from `$ABA_ROOT/$cl_name/macs.conf`
- Line 1653 correctly writes to `$cluster_dir/macs.conf`
- Only line 1353 uses the wrong path

**Impact:** LOW — cosmetic only. The annotation "(from macs.conf)" doesn't appear when it should (or appears incorrectly if a stale macs.conf is in the project root).

**Verified:** YES — code analysis confirms the path mismatch. Compare line 643 (`$ABA_ROOT/$cl_name/macs.conf`) with line 1353 (`$ABA_ROOT/macs.conf`).

---

## Bug #316: ~~INVALID~~ DISCO upgrade hint references non-existent "main menu → S" shortcut

**Severity:** LOW (confusing help text)
**File:** `tui/v2/tui-cluster.sh`, line 2147
**Description:** In `_day2_upgrade()`, when no upgrade versions are available in DISCO mode, the hint text says:

```
To add newer versions to the mirror:
  1. Update the channel/version in ImageSet Config on the connected host
  2. Save images to disk (main menu → S)
  3. Transfer and Load images (main menu → L)
  4. Run Day-2 to apply changes (main menu → D)
  5. Then retry Upgrade here
```

Step 2 references "main menu → S" but in DISCO mode there is no "S" shortcut in the main menu. The DISCO menu has: R (Install Registry), L (Load), I (Install Cluster), D (Day-2), A (Advanced), V (View ISC). The "Save" operation is only available in CONNO mode on a connected host.

**Expected:** Step 2 should clarify that "Save images to disk" happens on the connected host (not via this TUI), e.g.: "Save images to disk (on the connected host)"

**Actual:** References a non-existent "S" shortcut in the current (DISCO) TUI menu.

**Impact:** LOW — The hint is merely confusing. The user would figure out that Save is done on the connected host, but the "main menu → S" is misleading.

**Verified:** YES — code analysis confirms DISCO menu tags are R, L, I, D, A, V (from `tui-strings2.sh` lines 144-152). No "S" exists.

---

## Bug #317: ~~FIXED~~ `aba delete` fails when cluster `.init` target fails (corrupted/stale cluster state)

**Status:** FIXED (commit 0ae85062 — repair symlinks + non-fatal make init for delete)
**Severity:** MEDIUM (prevents cleanup of broken clusters)
**File:** `scripts/aba.sh`, line 1186
**Description:** The `delete` operation starts with `make -s init` which must succeed before deletion proceeds. If the cluster directory is in a corrupted state (e.g., `./templates` is a real directory instead of a symlink, or `aba.conf` references a non-existent operator set), the `.init` target fails and the entire delete operation aborts.

**Steps to reproduce:**
1. Have a cluster directory in a broken state (e.g., `demo1` with `./templates` as a directory)
2. TUI → Day-2 → Delete cluster → select `demo1` → Confirm

**Expected:** `aba delete` should be able to clean up cluster state even when `.init` fails. Deletion is a cleanup operation that should be resilient to corruption.

**Actual:** Delete fails with:
```
ln: ./templates: cannot overwrite directory
make: *** [Makefile:67: .init] Error 1
Error: No such operator set [templates/operator-set-custom-20260526-191819]!
[ABA] Error: Invalid or incomplete aba.conf.
```

**Root cause:** `scripts/aba.sh` line 1186: `make -s init` is an unconditional prerequisite for `delete`. If `.init` fails, the delete is blocked. The `.init` target tries to create symlinks which can fail if directories exist.

**Impact:** MEDIUM — Users cannot clean up corrupted cluster directories through the TUI (or CLI). They must manually `rm -rf` the directory.

**Verified:** YES — Observed live via TUI on `registry4:~/aba` while attempting to delete the `demo1` cluster.

---

## Bug #318: ~~FIXED~~ Dead code — unused `tag` variable in `_day2_upgrade()`

**Severity:** LOW (cosmetic — dead code, no functional impact)
**File:** `tui/v2/tui-cluster.sh`, lines 2166-2167
**Description:** In the version selection loop of `_day2_upgrade()`, a `tag` variable is computed from the version (extracting major.minor) but never used:

```bash
local tag
tag=$(echo "${v}" | cut -d. -f1-2)
```

The loop uses `$v` directly for menu items and `$idx` for the "(newest)" annotation. The `tag` variable serves no purpose.

**Expected:** Either use `tag` for something (e.g., show minor version in the menu) or remove it.

**Actual:** Computed but never referenced — dead code.

**Impact:** LOW — No functional bug, just dead code that adds confusion.

**Verified:** YES — code analysis confirms `tag` is never referenced after assignment.

---

## Bug #319: ~~FIXED~~ Cluster name validation does not reject reserved directory names ("mirror", "templates", "cli", "scripts")

**Status:** FIXED in commits 89fae839 + pending (added `_valid_cluster_name()` in core with reserved name check, `--validate` flag, TUI uses `aba cluster --name X --validate`)

**Severity:** MEDIUM (can corrupt project structure)
**File:** `tui/v2/tui-cluster.sh`, line 911 (cluster name validation)
**File:** `tui/v2/tui-lib.sh`, line 793 (`list_cluster_dirs` exclusion list)
**Description:** The cluster name validator (`^[a-z]([a-z0-9-]*[a-z0-9])?$`) accepts names like "mirror", "templates", "cli", "scripts", etc. These names collide with ABA's internal directories. If a user names a cluster "mirror", `aba cluster --name mirror ...` would attempt to write cluster.conf and other files into the existing `mirror/` directory, corrupting the mirror configuration.

Additionally, `list_cluster_dirs()` at line 793 explicitly skips "mirror" and "templates" — so even if a user did create such a cluster, it would be invisible in selection dialogs.

**Steps to reproduce:**
1. Start TUI → Install Cluster
2. Enter cluster name: "mirror" or "templates"
3. The name passes validation (matches the regex)
4. Proceed with wizard — ABA would write into the existing directory

**Expected:** The TUI should reject reserved directory names (mirror, templates, cli, scripts, build, test, ai, tui, dev) with a message like "Name conflicts with an ABA internal directory."

**Actual:** Any valid DNS label is accepted, including names that collide with project directories.

**Impact:** MEDIUM — If the user creates a cluster named "mirror", it would overwrite `mirror/cluster.conf` which doesn't normally exist but `list_cluster_dirs` would never show it. The real risk is `aba cluster --name templates` which would try to write into `templates/`.

**Verified:** YES — code analysis confirms no reserved-name check exists in the validation logic.

---

## Bug #320: ~~INVALID~~ TUI "Upgrade cluster" always fails to list versions when `ocp_version_target` is not set

**Severity:** HIGH  
**Status:** OPEN  
**Location:** `tui/v2/tui-cluster.sh` line 2120, `scripts/cluster-upgrade.sh` lines 50-56

**Description:** The Day-2 "Upgrade cluster" feature calls `aba --dir $SELECTED_CLUSTER upgrade --dry-run` (line 2120) to discover available upgrade versions. However, `cluster-upgrade.sh` requires a target version (either `--to <version>` or `ocp_version_target` in mirror.conf) — it aborts at line 55 with "No target version specified" before reaching the version listing code at lines 170-181.

Since `ocp_version_target` is commented out by default in mirror.conf, and the TUI does not pass `--to`, the dry-run ALWAYS fails with an error message. The TUI captures this error via `|| true` (line 2120) and parses it for semver patterns (finding none), then shows "No available upgrade versions found" even when newer versions ARE available in the mirror.

**Steps to reproduce:**
1. Install a cluster via TUI (e.g., SNO at 4.21.15)
2. Sync newer version images into the mirror
3. Go to Day-2 → Upgrade cluster → Select the cluster
4. Observe "No available upgrade versions found" despite newer versions being in the mirror

**Expected:** The upgrade dialog should list all versions in the mirror that are higher than the current cluster version.

**Actual:** Always shows "No available upgrade versions" because `aba upgrade --dry-run` fails before reaching the version enumeration code.

**Impact:** HIGH — The upgrade feature is non-functional via TUI in the common case (no `ocp_version_target` set). Users must manually run `aba upgrade --to <version>` from the CLI.

**Verified:** YES — Tested on registry4 with cluster "sno" at version 4.21.15. TUI showed "No available upgrade versions found." CLI confirmed: `aba --dir sno upgrade --dry-run` returns "[ABA] Error: No target version specified."

---

## Bug #321: ~~FIXED~~ Version selection dialog missing `--default-button ok` (same class as Bug #291)

**Status:** FIXED — added `--default-button ok` to version selection dialog in `tui-direct.sh`

**Severity:** LOW  
**Status:** OPEN  
**Location:** `tui/v2/tui-direct.sh` lines 433-441 (`_direct_version`)

**Description:** The channel selection dialog (`_direct_channel`, line 268) was fixed in commit f22a3961 to include `--default-button ok` (Bug #291 fix). The version selection dialog in `_direct_version()` uses an identical button layout (--no-cancel --extra-button --help-button --ok-label) but does NOT include `--default-button ok`.

This means when the version selector appears, the default button focus may not be on "Next" (the OK button), depending on dialog's implementation of button focus with `--extra-button` present. If the user presses Enter expecting to confirm the selected version, they might instead trigger "Back" or "Help".

**Steps to reproduce:**
1. Start TUI in DIRECT or CONNO mode
2. Reach the version selection step in the wizard
3. Use arrow keys to select a version
4. Press Enter — observe which button is activated

**Expected:** "Next" button should be the default (same behavior as the channel dialog after Bug #291 fix).

**Actual:** Button focus may not default to "Next" due to missing `--default-button ok`.

**Impact:** LOW — In most dialog versions, OK is default anyway. Only affects environments where `--extra-button` shifts default focus.

**Verified:** YES — Code analysis confirms `_direct_channel` has `--default-button ok` (line 268) but `_direct_version` does not (lines 433-441). Same button layout used.

---

## Bug #322: ~~FIXED~~ CONNO menu shows stale "synced" status after OCP version change via "Rerun Wizard"

**Status:** FIXED in commit 4bffd928 — `_invalidate_mirror_cache` now fires unconditionally after wizard/rerun regardless of exit code

**Severity:** MEDIUM  
**Status:** OPEN  
**Location:** `tui/v2/abatui2.sh` lines 751-755

**Description:** After changing the OCP version via "Rerun Wizard" (W), the CONNO main menu continues showing `(synced)` next to the Sync option, even though the mirror does NOT have images for the NEW version. This happens because:

1. `_conno_need_recheck=false` is set after the wizard (line 755)
2. The mirror verify cache (`aba:mirror:check-image`) still has the result from the OLD version
3. No call to `_invalidate_mirror_cache()` or `aba_mirror_verify_refresh` is made after the version change

The comment at line 754 says "NO RECHECK: wizard only changes channel/version/platform in aba.conf" — but changing the version DOES invalidate the mirror's "ready" state because `_mirror_has_release_image` checks for the release image of the CURRENT ocp_version.

**Steps to reproduce:**
1. Start TUI in CONNO mode with mirror synced for version 4.21.15 (shows "synced")
2. Press W (Rerun Wizard)
3. Change version from 4.21.15 to a different version (e.g., 4.22.0)
4. Complete the wizard
5. Return to CONNO main menu
6. Observe: "Sync images to mirror (synced)" still shows — but mirror has NO images for the new version

**Expected:** After version change, the "synced" label should be cleared (or a recheck should be triggered), showing the user they need to re-sync.

**Actual:** Stale "synced" label persists until the next action that triggers `_conno_need_recheck=true` (e.g., entering Advanced menu).

**Impact:** MEDIUM — User may attempt to install a cluster for the new version, only to find the mirror doesn't have the right images. The install would fail with an image-not-found error.

**Fix direction:** After the wizard completes and version changed, either set `_conno_need_recheck=true` or call `_invalidate_mirror_cache`.

**Verified:** YES — Live-reproduced on registry4. Changed version from 4.21.15 to 4.20.22 via Rerun Wizard. After wizard completed, CONNO menu still showed "Sync images to mirror (synced)" and "Save images to disk (saved)". Root cause: (1) _conno_need_recheck=false after wizard (line 755) prevents state recheck, (2) cached check-image result from previous version not invalidated by aba_mirror_verify_refresh(), (3) tar file existence check does not validate version match.

---

## Bug #323: ~~FIXED~~ Image path validation (`_valid_abs_path`) accepts `~` which is semantically invalid for registry namespace paths

**Status:** FIXED — image path field now uses `[[ "$m_path" != /* ]]` directly instead of shared `_valid_abs_path` (which correctly accepts `~` for data_dir/ssh_key)

**Severity:** LOW  
**Status:** OPEN  
**Location:** `tui/v2/tui-mirror.sh` line 265, `tui/v2/tui-lib.sh` line 131

**Description:** The "Image path" field in the mirror configuration menu (e.g., `/ocp4/openshift4`) is validated using `_valid_abs_path()`, which accepts paths starting with `/` OR `~`. However, this field represents a container registry namespace path (not a filesystem path), so `~` is semantically meaningless and would cause the registry to create a namespace starting with a literal tilde character.

The error message at line 267 says "Must start with /" but the validator actually accepts `~`, creating an inconsistency between the message and the validation behavior.

**Steps to reproduce:**
1. Start TUI → CONNO mode → Install Mirror (M) → Local
2. Select "I" (Image path)
3. Enter `~/my-images`
4. Observe: validation passes (no error shown)
5. The path is saved to mirror.conf as `reg_path=~/my-images`

**Expected:** Only paths starting with `/` should be accepted for the registry namespace path. `~` should be rejected with the existing error message.

**Actual:** `~` is accepted, creating an invalid registry namespace.

**Impact:** LOW — In practice, users rarely enter `~` for a registry path. If they do, the registry install/sync would likely fail with an obscure error.

**Verified:** YES — Code analysis confirms `_valid_abs_path` (line 131: `[[ "$1" == /* || "$1" == ~* ]]`) accepts `~` and the mirror config code uses this validator for `reg_path`.

---

## Bug #324: ~~FIXED~~ Platform config forms save some field values without quotes — `$` in values silently corrupted on source

**Status:** FIXED in commits d9a11daf (KVM, Bug #46) and 756c40af (VMware) — all config fields now single-quoted

**Severity:** LOW  
**Status:** OPEN  
**Location:** `tui/v2/tui-cluster.sh` lines 383, 399, 407, 415 (VMware), lines 514, 522, 530, 538 (KVM)

**Description:** In `_configure_vmw_form()` and `_configure_kvm_form()`, some config fields are saved with pre-quoting (`'$value'`) and some without. Fields saved without explicit quotes rely on `replace-value-conf` auto-quoting (which only triggers for values containing spaces or `#`).

Pre-quoted (correct):
- `GOVC_PASSWORD` → `replace-value-conf -v "'$v_pass'"` (line 376)
- `GOVC_NETWORK` → `replace-value-conf -v "'$v_network'"` (line 391)
- `KVM_GRAPHICS_ARGS` → `replace-value-conf -v "'$k_graphics'"` (line 546)

NOT pre-quoted (inconsistent):
- `GOVC_URL`, `GOVC_USERNAME`, `GOVC_DATASTORE`, `GOVC_DATACENTER`, `GOVC_CLUSTER`, `VC_FOLDER`
- `LIBVIRT_URI`, `KVM_STORAGE_POOL`, `KVM_NETWORK`, `KVM_BOOT_ARGS`

If a user enters a value containing `$` (e.g., username `admin$lab`), it is saved unquoted:
```
GOVC_USERNAME=admin$lab
```
When this config file is later sourced by a script, bash expands `$lab` (likely to empty string), silently corrupting the value to `admin`.

**Steps to reproduce:**
1. TUI → Advanced → Platform → VMware
2. Set username to `admin$lab`
3. Press Continue
4. Inspect `vmware.conf`: shows `GOVC_USERNAME=admin$lab`
5. Run `source vmware.conf && echo $GOVC_USERNAME` → outputs `admin` (not `admin$lab`)

**Expected:** All config values should be saved with consistent quoting (single quotes) to prevent shell expansion when sourced.

**Actual:** Only PASSWORD, NETWORK, and GRAPHICS_ARGS are pre-quoted. All other fields are saved raw.

**Impact:** LOW — In practice, VMware/KVM usernames and paths rarely contain `$`. But the quoting is objectively inconsistent and would silently corrupt values in edge cases.

**Verified:** YES — Code analysis confirms the inconsistency across all config form fields.

---

## Bug #325: ~~FIXED~~ Wizard uses stale platform (`_cl_platform`) on re-entry after platform change via Advanced menu

**Status:** FIXED in commit e2122a11 — `_cl_platform` now refreshed from global `platform` on every wizard entry

**Severity:** MEDIUM  
**Status:** OPEN  
**Location:** `tui/v2/tui-cluster.sh` lines 592-616 (`cluster_install_flow` initialization guard)

**Description:** When the user first enters the cluster wizard, `_CL_STATE_INIT` is set to `true` (line 615) and `_cl_platform` is set from the global `platform` variable (line 614). On subsequent wizard entries, the initialization block is skipped (`_CL_STATE_INIT` is already `true`), so `_cl_platform` retains its old value even if the user changed the platform via Advanced → Platform Settings.

The Bug #304 fix correctly updates the global `platform` variable in the Advanced menu, but it does NOT update `_cl_platform` (the wizard's persisted state variable). The wizard reads `cl_platform` from `_cl_platform` at line 632, not from the global `platform`.

**Steps to reproduce:**
1. Start TUI in CONNO mode with `platform=vmw` in aba.conf
2. Go to Install Cluster (I) → enter a cluster name → confirm
3. Observe: Basics page shows "Platform: vmw (VMware/ESXi)" ✓
4. Press Back → Cancel out of wizard → return to main menu
5. Go to Advanced → Platform Settings → select "Bare Metal" → Continue
6. Confirm: `aba.conf` now has `platform=bm` ✓
7. Go to Install Cluster (I) → Basics page
8. **Observe: Platform still shows "vmw (VMware/ESXi)" — WRONG!**
9. Expected: "bm (bare-metal)"

**Root cause:** 
- Line 592: `if [[ "$_CL_STATE_INIT" != "true" ]]; then` — already true from step 2
- Line 614: `_cl_platform="${platform:-bm}"` — SKIPPED (inside the if block)
- Line 632: `local cl_platform="$_cl_platform"` — uses old "vmw" value

**Impact:** MEDIUM — If the user doesn't notice the stale platform indicator, they'll generate a cluster.conf with `--platform vmw`, causing VMware-specific operations (vmw-create.sh) to run instead of bare-metal flow.

**Fix hint:** Add `_cl_platform="${platform:-bm}"` at the beginning of `cluster_install_flow` OUTSIDE the `_CL_STATE_INIT` guard block (before line 618), so it's always refreshed from the current `aba.conf` value:
```bash
# Always refresh platform from aba.conf (may have changed via Advanced menu)
_cl_platform="${platform:-bm}"
```

**Verified:** YES — Code analysis confirms the initialization guard at line 592 prevents re-reading `platform` on subsequent wizard entries. The global `platform` is correctly updated by the Bug #304 fix, but `_cl_platform` is never refreshed.

---

## Bug #326: ~~DUPLICATE of #311~~ `mirror uninstall` does not invalidate the `run_once` mirror verify cache — causes stale "synced" label after reinstall

**Severity:** MEDIUM  
**Status:** OPEN  
**Location:** `tui/v2/tui-cluster.sh` line 1892, `tui/v2/abatui2.sh` line 668

**Description:** When uninstalling a mirror registry via the TUI (Advanced → Uninstall Mirror), the `confirm_and_execute` call does NOT include `_invalidate_mirror_cache` as a post-command hook. This means the `run_once` cached exit code for `aba:mirror:check-image` is NOT reset after uninstall.

Compare:
- `mirror install`: has `_invalidate_mirror_cache` callback ✓
- `mirror sync`: has `_invalidate_mirror_cache` callback ✓
- `mirror save`: has `_invalidate_mirror_cache` callback ✓
- `mirror load`: has `_invalidate_mirror_cache` callback ✓
- **`mirror uninstall`: NO callback** ✗

After uninstall, `_conno_need_recheck=true` is set, which re-checks `mirror_available()` (returns false since `.available` was removed). So the immediate menu rendering is correct. However, the `run_once` cache still holds the old "0" exit code from before uninstall.

If the user reinstalls a mirror and the `_invalidate_mirror_cache` from the install callback races or fails to properly reset, the stale "synced" status can reappear.

**Steps to reproduce:**
1. Have a working mirror with synced images (run_once cache: exit=0)
2. Advanced → Uninstall Mirror → confirm → success
3. Install Mirror → configure → install
4. Observe CONNO menu: status may briefly show "mirror ready" or "(synced)" before the new verify check completes

**Expected:** After uninstall, `_invalidate_mirror_cache` should be called (as it is for all other mirror operations) to immediately clear the stale cache.

**Actual:** No cache invalidation on uninstall. Related to Bug #311.

**Fix hint:** Add `_invalidate_mirror_cache` as the third argument to both uninstall calls:
```bash
# tui-cluster.sh line 1892:
confirm_and_execute "aba --dir mirror uninstall" "Uninstall Mirror Registry" _invalidate_mirror_cache
# abatui2.sh line 668:
confirm_and_execute "aba --dir mirror uninstall" "Uninstall Existing Mirror" _invalidate_mirror_cache && mirror_install
```

**Verified:** YES — Code analysis confirms no `_invalidate_mirror_cache` callback on either uninstall call path.

---

## Bug #327: ~~DUPLICATE of #294~~ DISCO mode `_apply_mode_connection()` only sanitizes `direct` to `mirror` — leaves `proxy` intact (invalid in DISCO)

**Severity:** MEDIUM  
**Status:** OPEN  
**Location:** `tui/v2/tui-cluster.sh` lines 688-690 (`_apply_mode_connection` inner function)

**Description:** The `_apply_mode_connection()` function correctly converts `cl_connection="direct"` to `"mirror"` in DISCO mode (no internet). However, it does NOT convert `cl_connection="proxy"` to `"mirror"`. The code comment at line 682 says `# DISCO: only "mirror" is valid (no internet)` — but the condition only checks for "direct":

```bash
elif [[ "$_TUI_MODE" == "DISCO" ]]; then
    [[ "$cl_connection" == "direct" ]] && cl_connection="mirror"
fi
```

If a user previously configured a cluster with `connection=proxy` in CONNO mode, then switches to DISCO mode, the wizard will load `cluster.conf` via `_cluster_load_conf` (which sets `cl_connection="proxy"`), and `_apply_mode_connection()` will NOT fix it.

**Steps to reproduce:**
1. In CONNO mode, create a cluster and set image source to "proxy" (toggle C on page 3)
2. Go through wizard to generate cluster.conf with `int_connection=proxy`
3. Switch to DISCO mode (Advanced → Switch to Disco, or restart with .bundle)
4. Go to Install Cluster (I) → enter the SAME cluster name
5. The wizard loads existing cluster.conf → `cl_connection="proxy"`
6. `_apply_mode_connection()` runs but only catches "direct", leaves "proxy" unchanged
7. Page 3 (Interfaces) shows "Image source: proxy (public registries)" — WRONG in DISCO!
8. If user proceeds without manually toggling, cluster generates with `proxy` mode

**Note:** The connection toggle UI (page 3, choice "C") at line 1296-1302 DOES correctly force `cl_connection="mirror"` if the user clicks it in DISCO mode. But if the user doesn't click "C" and just presses Next, the invalid "proxy" value persists.

**Fix hint:** Change line 689 from:
```bash
[[ "$cl_connection" == "direct" ]] && cl_connection="mirror"
```
to:
```bash
[[ "$cl_connection" != "mirror" ]] && cl_connection="mirror"
```

**Verified:** YES — Code analysis confirms line 689 only checks for "direct", not "proxy".

---

## Bug #328: ~~INVALID~~ Changing cluster name on Page 1 to an existing cluster does not load its `macs.conf`

**Severity:** LOW  
**Status:** FIXED  
**Location:** `tui/v2/tui-cluster.sh` `_cluster_load_conf()` (lines 112-124)

**Description:** When the user changes the cluster name on Page 1 (Basics) to a name that already has a `cluster.conf`, the code correctly calls `_cluster_load_conf` (line 920) and `_apply_mode_connection` (line 921). However, it does NOT load `macs.conf` for the newly selected cluster.

Compare with the Bug #37 fix at lines 642-645 which correctly loads `macs.conf` on wizard re-entry:
```bash
if [[ -f "$ABA_ROOT/$cl_name/macs.conf" ]]; then
    cl_macs=$(<"$ABA_ROOT/$cl_name/macs.conf")
fi
```

The name-change handler at line 919-923 is missing this macs.conf load:
```bash
[[ -n "$input" ]] && cl_name="$input"
# Silently load existing cluster.conf if present
if [[ -f "$ABA_ROOT/$cl_name/cluster.conf" ]]; then
    _cluster_load_conf "$ABA_ROOT/$cl_name/cluster.conf"
    _apply_mode_connection
    tui_log "Loaded existing cluster.conf for '$cl_name'"
fi
```

**Steps to reproduce:**
1. Create a bare-metal cluster "bm1" with 3 MAC addresses in macs.conf
2. Exit and re-enter the TUI
3. Go to Install Cluster (I) → on page 1, change cluster name to "bm1"
4. Observe: cluster.conf fields load correctly (type, network, etc.)
5. Navigate to Page 3 (Interfaces) → MAC row
6. **Observe: MACs are empty (or stale from previous session state)**
7. Expected: should show 3 MAC addresses loaded from `bm1/macs.conf`

**Root cause:** The name-change handler (lines 919-923) was not updated with the Bug #37 fix pattern. The fix exists for wizard re-entry but not for in-wizard name change.

**Fix applied:** Instead of adding macs.conf loading only in the name-change handler, moved the fix into `_cluster_load_conf()` itself — now reads `macs.conf` from the same directory as `cluster.conf` whenever it exists. This fixes ALL call sites (wizard re-entry, name change, etc.) in one place.

```bash
# At end of _cluster_load_conf(), after deriving cl_type:
local _macs_file="${conf%/*}/macs.conf"
if [[ -f "$_macs_file" ]]; then
    cl_macs="$(< "$_macs_file")"
fi
```

**Verified fix:** YES — on registry4. Created bmtest cluster with 1 MAC, restarted TUI, entered "bmtest" as name → Interfaces page shows "1 entered". macs.conf correctly reloaded.

**Verified:** YES — Code analysis confirms lines 919-923 load cluster.conf but NOT macs.conf. The fix pattern from Bug #37 (lines 642-645) is missing.

---

## Bug #329: ~~FIXED~~ MAC address input accepts invalid format without any validation

**Status:** FIXED in commit 31ca4a19 — validates each line against `XX:XX:XX:XX:XX:XX` regex, rejects invalid entries

**Location:** `tui/v2/tui-cluster.sh` lines 1322-1327 (MAC editbox handler in `_cluster_page_iface`)

**Description:** The MAC address entry dialog (`--editbox`) accepts any text without validating MAC format. The normalization at line 1325 (`tr ',; ' '\n' | sed '/^$/d' | tr -d ' \t'`) only strips whitespace and converts separators to newlines — it does NOT validate that entries are valid MAC addresses (format `XX:XX:XX:XX:XX:XX`). Invalid entries like "not-a-mac" are silently counted and stored. The user sees "3 entered" even though one entry is garbage that will be silently ignored at install time by `create-agent-config.sh` (which uses `grep -o -E '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'`).

**Expected:** After saving, the TUI should validate each line against the MAC pattern and reject invalid entries with an error message.

**Fix hint:** After the normalize step, add validation:
```bash
local invalid_lines
invalid_lines=$(echo "$cl_macs" | grep -vE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$')
if [[ -n "$invalid_lines" ]]; then
    dlg --msgbox "Invalid MAC address(es):\n$invalid_lines\n\nFormat: XX:XX:XX:XX:XX:XX" 0 0
    continue
fi
```

**Verified:** YES — Interactively tested on registry4. Entered "not-a-mac" in the MAC dialog, pressed Save, TUI accepted it and showed "3 entered" without error.

---

## Bug #330: ~~FIXED~~ MAC count not validated against cluster node count

**Status:** FIXED in commit 756c40af — warns when MAC count != expected nodes for cluster type

**Location:** `tui/v2/tui-cluster.sh` lines 1322-1327 (MAC editbox handler) and lines 1591-1594 (review summary)

**Description:** The TUI does not validate that the number of MAC addresses matches the expected node count for the cluster type. For example, an SNO cluster (1 node) was configured with 2 MAC addresses — the TUI displayed "2 addresses" on the review page without any warning. At install time, `create-agent-config.sh` only uses `head -n $expected_mac_count` (line 139), silently ignoring extra MACs. If too few MACs are entered, it only warns but continues. The TUI should provide early feedback: "SNO requires 1 MAC per port (you entered 2)".

**Expected:** The TUI should show a warning or error when MAC count doesn't match `num_nodes * num_ports` for the selected cluster type.

**Fix hint:** After saving MACs, calculate expected count based on `cl_type`:
```bash
local expected=1
case "$cl_type" in compact) expected=3 ;; standard) expected=$(( 3 + ${cl_workers:-2} )) ;; esac
local entered=$(echo "$cl_macs" | wc -l)
if [[ $entered -ne $expected ]]; then
    dlg --msgbox "Warning: $entered MAC(s) entered, but $cl_type needs $expected (1 per node)." 0 0
fi
```

**Verified:** YES — Interactively tested on registry4. Created bare-metal SNO cluster, entered 2 MACs, review page accepted them without any count validation warning.

---

## Bug #331: ~~FIXED~~ Install wizard allows full configuration of already-installed cluster — fails at execution

**Status:** FIXED  
**Location:** `tui/v2/tui-cluster.sh` `_cluster_page_basics()` (name-change handler)

**Description:** When selecting "Install Cluster" from the CONNO main menu and entering the name of a cluster that has already been successfully installed (has `.install-complete` marker), the TUI lets the user go through all 5 wizard pages (Basics, Network, Interfaces, VM Resources, Review) before failing at execution with: "This cluster has already been deployed successfully! Run 'aba clean; aba install' to re-install the cluster". The TUI should detect the `.install-complete` marker early (on page 1 when the cluster name is confirmed) and offer the user a choice.

**Expected:** Early detection of already-installed clusters, before the user spends time on the wizard.

**Fix applied:** Added `.install-complete` check in `_cluster_page_basics()` name-change handler. When an installed cluster name is entered, a warning dialog is shown:
```
Cluster 'sno' is already installed.

Use Day-2 menu for operations on installed clusters.
Continuing will overwrite the cluster configuration.

Continue anyway?
```
With "Continue" (override) and "Back" (return to name input) buttons.

**Verified fix:** YES — on registry4. Entered "sno" as cluster name → warning dialog appeared. "Back" returned to name input. "Continue" loaded the existing config normally.

---

## Bug #332: ~~INVALID~~ MAC addresses entered in TUI are lost on TUI restart — _persist_cluster_draft() does not write macs.conf

**Severity:** MEDIUM  
**Status:** FIXED  
**File:** `tui/v2/tui-cluster.sh` (`_persist_cluster_draft()`)

**Description:** MAC addresses entered in the TUI are only stored in memory (`cl_macs`/`_cl_macs`) and are written to `$cluster_dir/macs.conf` ONLY when the user clicks "Install" on the review page (via `_cluster_execute()` lines 1650-1655). The `_persist_cluster_draft()` function saves other `cluster.conf` values after each page but NOT `macs.conf`. If the user exits the wizard or the TUI process before clicking "Install", these MACs are lost.

**Steps to reproduce:**
1. Start TUI, go to Cluster Install wizard
2. Select bare-metal platform
3. Enter MAC addresses on the VM/Network page
4. Exit the TUI (ESC, or navigate away)
5. Restart TUI, re-enter wizard for same cluster name
6. MAC addresses are gone

**Root cause:** `_persist_cluster_draft()` saves `cluster.conf` values but has no logic for writing `macs.conf`. The `cl_macs` variable persists only in the shell process.

**Fix applied:** Added macs.conf writing at end of `_persist_cluster_draft()`:
```bash
# Persist macs.conf for bare-metal (not stored in cluster.conf)
if [[ "${cl_platform:-}" == "bm" && -n "${cl_macs:-}" ]]; then
    echo "$cl_macs" > "$ABA_ROOT/$cl_name/macs.conf"
    tui_log "Persisted macs.conf for '$cl_name'"
fi
```
Note: Uses `cl_platform` (caller's local via dynamic scoping), NOT `_cl_platform` (global, stale until `_cl_save_state()`).

**Verified fix:** YES — on registry4. Entered 1 MAC on Interfaces page, advanced to next page (triggers persist), confirmed `~/aba/bmtest/macs.conf` was written. Restarted TUI, re-entered same cluster → MACs loaded correctly ("1 entered").

---

## Bug #333: "Switch to Connected Mode" from DISCO is impossible when internet is unavailable — user loops back to DISCO

**Severity:** MEDIUM
**File:** `tui/v2/abatui2.sh` (lines 836-845, main loop) + `tui/v2/tui-disco.sh` (`disco_reset()`)

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

## Bug #334: ~~DUPLICATE of #296~~ Bug #296 live confirmation — "Exiting..." dialog shown but TUI continues into DISCO mode

**Severity:** LOW (UX confusion)
**File:** `tui/v2/abatui2.sh` (line 450)

**Description:** When the internet check fails during `_detect_mode`, the error dialog ends with the text "Exiting..." suggesting the TUI will terminate. However, if `_validate_payload` passes (mirror installed OR tar archives present), the TUI enters DISCO mode instead of exiting. The user sees "Exiting..." then finds themselves in DISCO mode — contradicting what they were just told.

**Steps to reproduce:**
1. Start TUI on a host where registry.redhat.io is unreachable but mirror is installed
2. See "ERROR: Internet access required... Exiting..." dialog
3. Press OK
4. TUI enters DISCO mode (splash screen appears) — it did NOT exit

**Verified:** YES — Live-reproduced on registry4. TUI showed "Exiting...", pressed OK, entered DISCO splash screen. Log confirms: "Payload validation passed → Mode detected: DISCO (offline, payload ready)".

---

## Bug #335: ~~NOT A BUG~~ Day-2 menu enabled when only *configured* (not installed) clusters exist

**Status:** NOT A BUG — intentional design. Day-2 access triggers `_probe_undetected_clusters()` which auto-detects background install completion via `auto_complete_install()`. Restricting to installed-only would prevent this auto-detection path.

**Severity:** MEDIUM
**Status:** OPEN
**Location:** `tui/v2/tui-lib.sh` lines 894-899 (`tui_cluster_menu_flags`)

**Description:** The `tui_cluster_menu_flags()` function computes `_CLUSTER_HAS_INSTALLED` (line 891) but never uses it for gating Day-2 menu availability. `_CLUSTER_DAY2_AVAIL` is set to `true` whenever *any* `cluster.conf` directory exists (via `_CLUSTER_HAS_ANY`), not when at least one cluster has `.install-complete`.

**Root cause:**
```bash
_CLUSTER_DAY2_AVAIL=true
_CLUSTER_MON_AVAIL=true
if [[ "$_CLUSTER_HAS_ANY" != "true" ]]; then
    _CLUSTER_DAY2_AVAIL=false
    _CLUSTER_MON_AVAIL=false
fi
```
The condition should check `_CLUSTER_HAS_INSTALLED`, not `_CLUSTER_HAS_ANY`.

**Steps to reproduce:**
1. Create a cluster config via the wizard but do NOT install it (exit before "Install")
2. Return to CONNO main menu
3. Day-2 / Cluster Management shows without `[install cluster first]` suffix
4. Enter Day-2 → select any operation → cluster selector shows "No installed clusters found."

**Expected:** Day-2 should be greyed out / show `[install cluster first]` when no clusters have `.install-complete`

**Actual:** Day-2 appears available, then dead-ends at cluster selection

**Impact:** Misleading menu state across all three modes; users enter a full Day-2 submenu only to hit a dead end.

**Fix hint:** Change line 896:
```bash
if [[ "$_CLUSTER_HAS_INSTALLED" != "true" ]]; then
    _CLUSTER_DAY2_AVAIL=false
fi
```

**Verified:** YES — code analysis confirms `_CLUSTER_HAS_INSTALLED` is computed but unused for gating Day-2. Interactively confirmed Day-2 menu appears in CONNO mode when configured (but not installed) clusters exist.

---

## Bug #336: ~~CLOSED~~ `_persist_cluster_draft()` writes CIDR into `machine_network` without updating `prefix_length`

**Severity:** ~~HIGH~~ — INVALID (won't happen)
**Status:** CLOSED (not a bug) — `cluster.conf` always stores combined CIDR (e.g. `10.0.0.0/20`). There is no separate `prefix_length` field in the file. `normalize-cluster-conf` splits the CIDR at runtime via sed. The TUI writing the combined form is correct.
**Location:** `tui/v2/tui-cluster.sh` line 140

**Description:** The Networking page stores CIDR in `cl_network` (e.g. `10.0.0.0/16`). `_persist_cluster_draft` writes that value directly to `machine_network` via `replace-value-conf`. However, if the cluster.conf has a separate `prefix_length` field (older format), the TUI never updates or clears it.

**Root cause:**
```bash
replace-value-conf -q -n machine_network  -v "$cl_network"     -f "$_conf"
```
No companion write of `prefix_length` and no removal of a stale `prefix_length` field.

**Steps to reproduce:**
1. Have a cluster.conf with split fields: `machine_network=10.0.0.0` and `prefix_length=24`
2. Open wizard for this cluster → Networking page → change Machine network to `10.0.0.0/16`
3. Advance through wizard (triggers `_persist_cluster_draft`)
4. Inspect `cluster.conf`: `machine_network=10.0.0.0/16` AND stale `prefix_length=24` present
5. At install time, `normalize-cluster-conf` may use **/24** from the `prefix_length` field instead of **/16** from the CIDR

**Expected:** Persist either (a) split `machine_network` + updated `prefix_length`, or (b) combined CIDR with `prefix_length` removed/cleared atomically

**Actual:** Stale `prefix_length` can conflict with the CIDR suffix in `machine_network`

**Impact:** Wrong subnet for installs — VIP/range validation failures or nodes on incorrect network

**Verified:** YES — code analysis confirms no `prefix_length` write in `_persist_cluster_draft()`. Note: current test configs use combined CIDR form, so not easily triggered with modern configs.

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

## Bug #338: ~~NOT A BUG~~ Cluster wizard platform toggle writes global `aba.conf` — affects all clusters

**Status:** NOT A BUG — platform is a global ABA setting by design. The Advanced menu does exactly the same thing. The wizard toggle is placed on the Basics page for convenience.

**Severity:** MEDIUM
**Status:** OPEN
**Location:** `tui/v2/tui-cluster.sh` line 994

**Description:** Toggling Platform on the Basics page (pressing T) immediately writes the new platform value to `$ABA_ROOT/aba.conf` — the global configuration file. This means changing the platform for one cluster wizard session affects ALL future cluster operations.

**Root cause:**
```bash
replace-value-conf -q -n platform -v "$cl_platform" -f "$ABA_ROOT/aba.conf"
```

**Steps to reproduce:**
1. Install cluster `sno1` with `platform=vmw`
2. Start Install Cluster for `compact1` → Basics → toggle Platform to `bm`
3. `grep platform aba.conf` → `platform=bm`
4. Return to main menu → Day-2 on `sno1` may use bare-metal code paths

**Expected:** Platform toggle in the cluster wizard should either (a) only write to the cluster-specific context, or (b) warn that the change affects all future cluster operations

**Actual:** Silent global platform change from within a per-cluster wizard

**Note:** This may be intentional design since ABA treats platform as a global setting. However, the UX is misleading — the toggle is on a per-cluster wizard page, implying it's a per-cluster setting.

**Verified:** YES — code analysis confirms line 994 writes to `$ABA_ROOT/aba.conf`. Interactively observed: changing platform via Advanced → Platform correctly shows as a global setting, but the wizard page doesn't indicate this.

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

## Bug #340: ~~FIXED~~ Advanced → Uninstall Mirror does not invalidate mirror verify cache

**Status:** FIXED — `confirm_and_execute` at line 1947 passes `_invalidate_mirror_cache` callback; commit 4bffd928 made it fire unconditionally regardless of exit code

**Severity:** MEDIUM
**Status:** OPEN
**Location:** `tui/v2/tui-cluster.sh` line 1911

**Description:** The Advanced menu's "Uninstall Mirror Registry" action calls `confirm_and_execute` without the `_invalidate_mirror_cache` post-command hook. All other mirror operations (install, sync, save, load) include this hook.

**Root cause:**
```bash
# Line 1911 — NO third argument:
confirm_and_execute "aba --dir mirror uninstall" "Uninstall Mirror Registry"

# Contrast with mirror sync at tui-mirror.sh line 481:
confirm_and_execute "aba --dir mirror sync..." "Sync Images" _invalidate_mirror_cache
```

**Steps to reproduce:**
1. Have a working mirror with synced images (run_once cache: exit=0)
2. Advanced → Uninstall Mirror → confirm → success
3. Install new mirror (empty)
4. Menu may show "mirror ready" / "(synced)" due to stale cache

**Expected:** `_invalidate_mirror_cache` should be called as post-hook for uninstall (same as install/sync/load)

**Actual:** No cache invalidation on uninstall. Related to Bug #326.

**Fix hint:** Change line 1911 to:
```bash
confirm_and_execute "aba --dir mirror uninstall" "Uninstall Mirror Registry" _invalidate_mirror_cache
```

**Verified:** YES — code analysis confirms no `_invalidate_mirror_cache` post-hook on uninstall at line 1911. Also confirmed DISCO uninstall at line 246 has the same issue.

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

## Bug #342: ~~DUPLICATE of #23~~ `_operator_menu` marks basket dirty on every submenu return, even with no edits

**Severity:** LOW
**Status:** OPEN
**Location:** `tui/v2/tui-mirror.sh` lines 798-810

**Description:** Opening Select Sets, Search, or View Basket always sets `_OP_BASKET_DIRTY=true` and calls `_persist_operator_basket`, even if the user only opened the screen and pressed Back without making changes.

**Steps to reproduce:**
1. Open Operators → Select Operator Sets → Back (no changes)
2. TUI log shows ISC regeneration kicked
3. Return to CONNO menu → menu still shows "(synced)" but ISC may have changed

**Root cause:** Unconditional `_OP_BASKET_DIRTY=true` after each submenu call (lines 799-809), with no comparison against prior basket state.

**Impact:** LOW — causes unnecessary ISC regeneration and potential cache invalidation. May cause "(synced)" status to become stale if ISC changed.

**Verified:** YES — code analysis confirms unconditional dirty flag on all three submenu returns.

---

## Bug #343: ~~FIXED~~ Duplicate menu tag `W` for MONITOR and RECONFIGURE in `tui-strings2.sh`

**Status:** FIXED — removed dead `TUI2_CONNO_TAG_MONITOR` and `TUI2_DIRECT_TAG_MONITOR` constants (DISCO still uses its own)

**Severity:** LOW
**Status:** OPEN
**Location:** `tui/v2/tui-strings2.sh` lines 171 and 174 (CONNO), lines 186 and 188 (DIRECT)

**Description:** Both `TUI2_CONNO_TAG_MONITOR` and `TUI2_CONNO_TAG_RECONFIGURE` are assigned the value `"W"`. Same for DIRECT mode: `TUI2_DIRECT_TAG_MONITOR` and `TUI2_DIRECT_TAG_RECONFIGURE` are both `"W"`.

**Root cause:** Copy-paste in string constants:
```bash
TUI2_CONNO_TAG_MONITOR="W"        # line 171
TUI2_CONNO_TAG_RECONFIGURE="W"    # line 174
```

**Impact:** LOW — MONITOR is currently only used in the Advanced submenu (`F` tag), not alongside RECONFIGURE in the main menu. If both were ever added to the same menu, pressing `W` would be ambiguous.

**Verified:** YES — code analysis confirms duplicate `W` tags in both CONNO and DIRECT menu tag definitions.

---

## Bug #344: ~~DUPLICATE of #337~~ `_operator_search` and `_operator_view_basket` bypass operator basket ref-counting

**Severity:** MEDIUM
**Status:** OPEN
**Location:** `tui/v2/tui-mirror.sh` lines 1000-1009 (`_operator_search`) and lines 1058-1064 (`_operator_view_basket`)

**Description:** The `_operator_sets` function correctly uses ref-counting: adding a set increments each operator's count, removing a set decrements it, and operators are only removed when their count reaches zero. However, `_operator_search` and `_operator_view_basket` bypass this entirely — they directly `unset` operators from `OP_BASKET` without checking ref-counts.

**Root cause:**
```bash
# _operator_search (line 1005-1006):
elif [[ -n "${OP_BASKET[$op]:-}" ]]; then
    unset 'OP_BASKET[$op]'    # ← ignores ref-count

# _operator_view_basket (lines 1059-1061):
for op in "${!OP_BASKET[@]}"; do
    if [[ -z "${_KEPT[$op]:-}" ]]; then
        unset 'OP_BASKET[$op]'  # ← ignores ref-count
```

**Steps to reproduce:**
1. In CONNO mode, open Operators → Select Operator Sets
2. Add set "security" (which includes operator A, B, C)
3. Go back, open Search, find operator A, uncheck it → A is removed entirely
4. Go back to Sets, uncheck "security" → B and C are removed, but A was already gone (should have survived with ref-count from the set)

**Expected:** Search/view basket should decrement ref-counts (like `_operator_sets` does), not directly remove operators

**Actual:** Unchecking an operator in search or basket view permanently removes it, even if it belongs to one or more active sets

**Impact:** Operators shared between sets can be prematurely removed, causing missing operators in the ISC and mirrored images

**Verified:** YES — code analysis confirms `unset` without ref-count check in both functions

---

## Bug #345: ~~FIXED~~ DISCO mode "Image source" toggle shows unnecessary msgbox every time

**Status:** FIXED in commit ea58e012 — msgbox moved inside `if` block, only shown when value changes

**Severity:** LOW
**Status:** OPEN
**Location:** `tui/v2/tui-cluster.sh` lines 1315-1321

**Description:** In the cluster wizard's Interface page (page 3), clicking "Image source" (C) in DISCO mode ALWAYS shows a msgbox stating "In disconnected mode only 'mirror' is available as an image source" — even when `cl_connection` is already set to "mirror". The message is shown unconditionally on every click.

**Root cause:**
```bash
elif [[ "$_TUI_MODE" == "DISCO" ]]; then
    if [[ "$cl_connection" != "mirror" ]]; then
        cl_connection="mirror"
    fi
    # ↓ This msgbox is OUTSIDE the if — runs every time
    dlg --backtitle "$(ui_backtitle)" --msgbox \
        "In disconnected mode only \"mirror\" is available as an image source." 0 0 || true
```

**Steps to reproduce:**
1. In DISCO mode, open cluster wizard, navigate to page 3 (Interfaces)
2. Click "Image source" (C) — msgbox appears (expected first time)
3. Click OK to dismiss
4. Click "Image source" (C) again — same msgbox appears again (unnecessary)

**Expected:** Either hide/disable the "Image source" option in DISCO mode, or only show the msgbox when `cl_connection` was actually changed

**Actual:** Msgbox is shown unconditionally every time the user clicks "C" in DISCO mode

**Impact:** Minor UX annoyance — creates confusion by presenting a toggle that does nothing

**Verified:** YES — code analysis confirms msgbox is outside the conditional `if` block

---

## Bug #346: ~~NOT A BUG~~ ESC/Exit in DISCO or DIRECT mode (entered from CONNO Advanced) exits entire TUI

**Severity:** N/A
**Status:** NOT A BUG — CORRECT BEHAVIOR

**Clarification:** The intended ESC behavior in the TUI is:
- ESC always moves "back one step"
- From a submenu → parent menu
- From a top-level menu → quit confirmation dialog
- From a wizard → back to the menu that started the wizard

When in DISCO/DIRECT mode (even if entered from CONNO), the DISCO/DIRECT menu IS the top-level menu of that mode. ESC correctly shows the quit confirmation (`confirm_quit`). If the user confirms, the TUI exits — this is correct. If they cancel, they stay in the menu.

The design is: once you "switch mode" via Advanced, you are IN that mode. ESC at its main menu → quit. This is consistent with the TUI's universal ESC-means-back-one-step behavior.

**Note:** The related Bug #27 (`confirm_quit` treating ESC as "yes, quit") is the real issue — if that is fixed, an accidental double-ESC won't cause unexpected exits.

---

## Bug #347: ~~FIXED~~ Base domain validation rejects uppercase letters

**Status:** FIXED — regex now accepts `[a-zA-Z0-9]`, value lowercased before storing (`${dom_input,,}`)

**Severity:** LOW
**Status:** OPEN
**Location:** `tui/v2/tui-cluster.sh` line 954

**Description:** The cluster wizard's base domain input validation uses a regex that only accepts lowercase letters (`a-z`), rejecting uppercase input. DNS names are case-insensitive per RFC 4343, so "Example.Com" should be accepted (and optionally lowercased).

**Root cause:**
```bash
# tui-cluster.sh line 954 — only [a-z0-9]
if [[ -n "$dom_input" && ! "$dom_input" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
```

Compare with `_valid_fqdn` (tui-lib.sh line 120) which accepts both cases:
```bash
[[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || return 1
```

**Steps to reproduce:**
1. Open cluster wizard, set base domain to "Example.Com"
2. Validation fails: "Invalid base domain"
3. Set to "example.com" — validation passes

**Expected:** Accept uppercase input (and optionally lowercase it before storing)

**Actual:** Rejects any uppercase characters in the base domain

**Impact:** Inconsistency between base domain validation (case-sensitive) and hostname validation elsewhere in the TUI (case-insensitive). Users who paste domains with mixed case get unexpected validation errors.

**Verified:** YES — code analysis confirms regex uses `[a-z]` only, while `_valid_fqdn` uses `[a-zA-Z]`

---

## Test Flow Status

### CONNO mode (Partially Disconnected) — registry4
| Flow | Status | Notes |
|------|--------|-------|
| TUI Launch (with proxy) | PASS | Requires `source ~/.proxy-set.sh` before launch |
| Platform change bm→vmw via Advanced | PASS | vmware.conf correctly loaded from ~/.vmware.conf |
| VMware connection test | PASS | Connection to vcenter.lan verified |
| Cluster wizard (page 1-5) for new SNO | PASS | All pages render correctly |
| Installed cluster warning (Bug #331 fix) | PASS | Warning dialog shown for installed clusters |
| Type toggle for existing cluster (Bug #313) | FAIL | Type silently reverted — VIP fields missing |
| Operator basket view | PASS | Shows cincinnati-operator and web-terminal |
| Settings help text (Bug #299) | FAIL | Help mentions "8" but toggle values are 0,1,2,5 |
| Settings retry toggle cycle | PASS | Cycles: 1→2→5→OFF→1 (correct values) |
| CONNO help text | PASS | Comprehensive and accurate |
| Switch CONNO→DISCO via Advanced | PASS | Enters DISCO mode correctly |
| DISCO help text | PASS | Comprehensive and accurate |

### Known bugs verified live
| Bug | Status | Verified |
|-----|--------|----------|
| #299 (retry help text mentions "8") | Already documented | YES — live |
| #300 (demo1.bk dotted name rejection) | Already documented | YES — live |
| #313 (type toggle silently ignored) | Already documented | YES — live |
| #331 (installed cluster warning - FIXED) | FIXED verified | YES — live |
| #334 ("Exiting..." enters DISCO) | Already documented | YES — live |

---

## Bug #348: ~~FIXED~~ "Auto-answer: ON" setting writes `ask=yes` but `ask()` doesn't auto-answer for `ask=yes`

**Status:** FIXED in commit 74302da8 — terminal mode now appends `--yes` when auto-answer is ON (line 694 of tui-lib.sh)

**Severity:** MEDIUM — misleading setting, user still sees prompts in terminal mode
**Status:** OPEN
**Location:** `tui/v2/tui-lib.sh` `_tui_settings_persist_ask_mode()` (line 976), `scripts/include_all.sh` `ask()` (lines 1116-1148), `normalize-aba-conf()` (lines 408-409)

**Description:** The TUI Settings "Auto-answer" toggle writes `ask=yes` to `aba.conf` when enabled (ON). However, the `ask()` function in `include_all.sh` only auto-answers when `$ask` is **empty** (line 1124: `[ ! "$ask" ] && ret_default="ask=false"`). The normalization in `normalize-aba-conf` only converts `ask=0`/`ask=false` to empty — `ask=yes` is NOT normalized and remains non-empty, so `ask()` shows prompts.

In **TUI mode** (`_exec_in_tui`), this is invisible because `ASK_OVERRIDE=1` is always set (line 622), which overrides `ask` via `normalize-aba-conf` line 424 (`export ask=`). So TUI mode always auto-answers regardless of the setting.

In **terminal mode** (`_exec_in_terminal`), `ASK_OVERRIDE` is NOT set. So `ask=yes` results in `$ask` being "yes" (non-empty) → `ask()` shows prompts. This means the "Auto-answer: ON" setting has **no effect** in terminal mode.

Additionally, the tip at `_exec_in_terminal` line 688 says "Enable auto-answer in TUI Settings to skip prompts" — which is misleading since the setting doesn't actually work in terminal mode.

**Steps to reproduce:**
1. TUI Settings → toggle Auto-answer to ON (writes `ask=yes` to `aba.conf`)
2. Run any ABA command in terminal execution mode (choose "Run in Terminal")
3. The command still shows prompts (e.g., "Do you want to continue?")

**Expected:** With "Auto-answer: ON", commands should not prompt for confirmation in terminal mode.
**Actual:** Commands still prompt because `ask=yes` is non-empty.

**Root cause:** Mismatch between TUI settings values and what `ask()` recognizes:
- TUI writes `ask=yes` for ON → `ask()` treats as non-empty → prompts shown
- TUI writes `ask=true` for OFF → `ask()` treats as non-empty → prompts shown
- Both ON and OFF result in identical behavior (prompts shown) in terminal mode

**Fix hint:** Either:
1. Change `_tui_settings_persist_ask_mode yes` to write `ask=` (empty) or `ask=false` instead of `ask=yes`
2. Or update `normalize-aba-conf` to normalize `ask=yes` like it normalizes `ask=0`/`ask=false`

**Verified:** YES — code review confirms the logic chain

---

### Bug #349 — `_cluster_page_vm` checks wrong path for `macs.conf` hint
**Severity:** LOW
**Status:** ACTIVE
**Component:** `tui/v2/tui-cluster.sh` — `_cluster_page_vm()` line 1372

**Description:** The VM resources page (page 4 of the cluster wizard) shows a "(from macs.conf)" hint next to the MAC template field when a `macs.conf` file exists. However, it checks `$ABA_ROOT/macs.conf` (the repo root) instead of `$ABA_ROOT/$cl_name/macs.conf` (the cluster directory). Since `macs.conf` is always stored in the cluster directory (see lines 176, 655, 1672), the hint will never display for cluster-specific `macs.conf` files.

**Steps to reproduce:**
1. Create a cluster with bare-metal platform and enter MAC addresses
2. Go Back and re-enter the VM resources page
3. The "(from macs.conf)" hint is missing even though `$cl_name/macs.conf` exists

**Expected:** Hint shows when `$ABA_ROOT/$cl_name/macs.conf` exists.
**Actual:** Hint checks `$ABA_ROOT/macs.conf` (wrong path) — always misses cluster-specific file.

**Fix hint:** Change line 1372 from:
  `if [[ -f "$ABA_ROOT/macs.conf" ]]`
to:
  `if [[ -f "$ABA_ROOT/$cl_name/macs.conf" ]]`

**Verified:** YES — code review confirms the path mismatch across all `macs.conf` references

---

### Bug #350 — VM resource validation doesn't enforce minimums stated in help text
**Severity:** LOW
**Status:** ACTIVE
**Component:** `tui/v2/tui-cluster.sh` — `_cluster_page_vm()` lines 1402-1508

**Description:** The help text for the VM resources page states specific minimums:
- Master CPUs: min 4
- Master Memory: min 16 GB
- Worker CPUs: min 2
- Worker Memory: min 8 GB

But the actual input validation for all four fields only checks `val -lt 1` (i.e., rejects values < 1). A user can enter Master CPUs = 2 or Master Memory = 4 without any warning, which will likely cause cluster installation failure or degraded performance.

**Steps to reproduce:**
1. Start cluster wizard for vmw/kvm platform
2. Reach VM Resources page (page 4)
3. Set Master CPUs to 2 (press Help to see it says "min 4")
4. Value 2 is accepted without warning

**Expected:** Validation should warn or reject values below the documented minimums.
**Actual:** Any positive integer >= 1 is accepted for all resource fields.

**Fix hint:** Update validation to match the help text minimums, or at minimum show a warning when values are below recommended minimums (e.g., "Warning: OpenShift requires at least 4 CPUs for control-plane nodes. Continue anyway?").

**Verified:** YES — code review confirms the mismatch between help text and validation logic

---

## Bug #351 — ~~FIXED~~ `_cluster_load_conf` doesn't normalize `int_connection=none` — connection toggle gets stuck

**Status:** FIXED in commit ea58e012 — normalizes legacy `none` to empty on load

**Severity:** LOW
**Status:** ACTIVE
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
**Status:** ACTIVE
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
**Severity:** NOT A BUG
**Category:** Testing error, not an ABA defect

**What happened:** During same-host DISCO simulation on registry4, the tester ran `aba save` then `aba load` in the SAME repo directory (with `int_down` to simulate disconnection), bypassing the bundle creation/unpack workflow entirely. The `.index/` digest was updated between save and load by a background catalog re-download, causing `aba load` to look for a catalog digest that wasn't in the tar.

**Why it's not a bug:** The proper DISCO workflow uses `aba bundle` → transfer → unpack → `aba load`. The bundle packages `.index/` alongside the tar, so the digest is self-consistent. On the disconnected host, `download_all_catalogs` fails (no internet), so `.index/` stays as-is from the bundle. The `catalogs-wait` Make target ensures catalogs are fully downloaded before ISC creation. The Make dependency chain (`save: ... data/imageset-config.yaml` → `catalogs-download catalogs-wait`) prevents race conditions.

**The README and test scripts are clear:** `test/basic-test-using-bundle.sh` shows the correct same-host simulation — create bundle, `int_down`, **unpack into a separate directory**, then load from the unpacked bundle. The tester skipped the bundle step entirely.

---

## Bug #354: ~~FIXED~~ "Next" button in cluster wizard pages is NOT keyboard-accessible (missing --tab-correct)

**Severity:** HIGH (critical usability)
**Status:** FIXED (2026-06-04) — Added `--tab-correct` to the `dialog` invocation in `dlg()` at line 288 of `tui/v2/tui-lib.sh`
**Location:** `tui/v2/tui-cluster.sh` — `_cluster_page_basics()`, `_cluster_page_network()`, `_cluster_page_iface()`, `_cluster_page_vm()`
**Category:** Dialog navigation / keyboard accessibility

**Description:** The 4-page cluster configuration wizard uses `--extra-button --extra-label "Next"` for page advancement. However, the `dlg()` wrapper function (line 288 in `tui-lib.sh`) invokes `dialog` WITHOUT the `--tab-correct` flag. On dialog 1.3-20210117 (as installed on RHEL 9/registry4), the Extra button is completely excluded from the keyboard Tab cycle:

- Tab cycle from menu items: Menu → OK(Select) → Cancel(Back) → Help → Menu (wraps)
- Arrow keys from OK button: Right goes OK → Cancel → Help → OK (wraps)
- The Extra/Next button is NOT in either cycle

**Verified behavior:**
- Tab×1 + Enter = OK (Select) — edits the highlighted menu item
- Tab×2 + Enter = Cancel (Back) — exits the wizard page
- Tab×3 + Enter = Help — shows help dialog
- Tab×4 + Enter = OK again (wraps back)
- Tab + Right + Enter = Cancel (Back)
- Tab + Right + Right + Enter = Help
- Tab + Left + Enter = OK (Select, no movement or wraps)

**Impact:** Users cannot advance through the 4-page cluster wizard using keyboard alone. The "Next" button is visible on screen but unreachable. The wizard is effectively broken for keyboard-only users.

**Root Cause:** Dialog 1.3's `--extra-button` places the button between OK and Cancel VISUALLY, but does NOT include it in the Tab/arrow key traversal order unless `--tab-correct` is explicitly passed.

**Fix suggestion:** Add `--tab-correct` to the `dialog` invocation in the `dlg()` function at line 288 of `tui/v2/tui-lib.sh`:
```
dialog --no-shadow --colors --no-collapse --tab-correct "${args[@]}" {ABA_TUI_FLOCK_FD}>&-
```
This makes Tab cycle through ALL buttons including Extra (Next).

**Verified:** YES — tested on registry4 (dialog 1.3-20210117, RHEL 9). Reproduced consistently across multiple attempts. The Extra button exit code (3) is never reached via keyboard.

---

## Bug #355: ~~DUPLICATE of #316 / INVALID~~ DISCO upgrade hint references "main menu → S" (Save) which doesn't exist in DISCO mode

**Severity:** LOW (UX/documentation)
**Location:** `tui/v2/tui-cluster.sh` line 2196 — `_day2_upgrade()` DISCO hint
**Category:** Misleading hint text

**Description:** When no upgrade versions are found in DISCO mode, the hint text says:
```
1. Update the channel/version in ImageSet Config on the connected host
2. Save images to disk (main menu → S)
3. Transfer and Load images (main menu → L)
4. Run Day-2 to apply changes (main menu → D)
5. Then retry Upgrade here
```

Step 2 references "main menu → S" (Save). In DISCO mode, there is NO "S" key in the menu — "S" is only available in CONNO mode. The hint is contextually confusing because the user is currently IN DISCO mode and references a shortcut key from a different menu on a different machine.

Steps 3-5 correctly reference DISCO-mode keys (L, D).

**Expected:** The hint should clearly distinguish which steps happen on the connected host vs the disconnected host, and avoid referencing menu shortcut keys from a different TUI mode. For example:
```
On the connected host:
  1. Update channel/version in ImageSet Config
  2. Save images to disk (use 'aba save' or the connected TUI's 'S' action)
  3. Transfer archives to this disconnected host
On this disconnected host:
  4. Load images (main menu → L)
  5. Run Day-2 (main menu → D)
  6. Then retry Upgrade here
```

**Verified:** Code review only (no functional failure — just misleading text). The DISCO tag definitions confirm no "S" key exists: R, L, I, D, W, K, C, A, V, X.

---

## Bug #356: ~~DUPLICATE of #318~~ Dead code in `_day2_upgrade` — unused `tag` variable (line 2216)

**Severity:** TRIVIAL (code quality)
**Location:** `tui/v2/tui-cluster.sh` line 2216
**Category:** Dead code

**Description:** In the `_day2_upgrade` function, a local variable `tag` is computed from the version string:
```bash
tag=$(echo "${v}" | cut -d. -f1-2)
```
This variable is never used — the menu items at lines 2218 and 2220 use `"$v"` directly as the tag. The `tag` variable was likely from an earlier design iteration and was left behind.

**Impact:** None (no functional effect). Minor code quality issue.

**Verified:** Code review only.

---

## Bug #357: `aba_wait_show` provides NO real-time progress in TUI progressbox mode

**Severity:** Medium (UX)
**File:** `scripts/include_all.sh` (lines 1328-1331), `tui/v2/tui-lib.sh` (line 626)
**Found:** 2026-06-03 (hackathon, Day-2 operations testing)
**Status:** NEW

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

## Bug #358: ~~FIXED~~ Inconsistent `_TUI_RETRY_COUNT` default values across settings code

**Severity:** Low (cosmetic)
**Status:** FIXED in commit 498cfeb2 — changed `:-2` fallbacks to `:-1` (matching init default)
**File:** `tui/v2/tui-lib.sh` (lines 1031, 1074, 1102, 1183)
**Found:** 2026-06-03 (hackathon, code review)
**Status:** NEW

**Description:**
The `_TUI_RETRY_COUNT` variable uses different default fallback values (`:-1` vs `:-2`) in different places:

| Location | Line | Default | Context |
|----------|------|---------|---------|
| `_tui_settings_summary()` | 1074 | `${_TUI_RETRY_COUNT:-1}` | Menu label |
| `_tui_settings_menu()` display | 1102 | `${_TUI_RETRY_COUNT:-2}` | Settings menu |
| `_tui_settings_menu()` toggle | 1183 | `${_TUI_RETRY_COUNT:-1}` | Toggle logic |
| `_tui_settings_menu_retry()` | 1031 | `${_TUI_RETRY_COUNT:-2}` | Input dialog |

The variable IS initialized at line 299: `_TUI_RETRY_COUNT="${_TUI_RETRY_COUNT:-1}"` — so in normal operation the fallback values are never reached (the variable is always "1" at startup). However, the inconsistency is misleading and would cause visible mismatch if the initialization were ever removed.

**Impact:** Practically none in current code (initialization covers it), but the dead defaults are misleading. If someone reads the code and assumes `:-2` is the default, they'll be wrong.

**Suggested fix:**
Change all fallback defaults to `:-1` to match the initialization at line 299, or better yet, remove the `:-` fallbacks entirely since the variable is always initialized.

**Verified:** Code review only — no functional impact observed in runtime testing.

---

## Bug #359: ~~INVALID~~ FAILED execution dialog shows "OK" instead of "Back to Menu" button label

**Severity:** Low (UX/cosmetic)
**File:** `tui/v2/tui-lib.sh` (lines 657-660)
**Found:** 2026-06-03 (hackathon, OSUS Day-2 failure observation)
**Status:** NEW

**Description:**
When a command fails in TUI mode (exit code != 0), the `_exec_in_tui` function shows a textbox with the output and two buttons:
- Expected: `< Back to Menu >` and `< Retry >`
- Actual: `< OK >` and `< Retry >`

The code uses:
```bash
dlg ... --exit-label "$TUI2_BTN_BACK_TO_MENU" \
    --extra-button --extra-label "$TUI2_BTN_RETRY" \
    --textbox "$review_file" 0 0
```

Where `$TUI2_BTN_BACK_TO_MENU` = "Back to Menu".

The `--exit-label` appears to be ignored (or overridden) by dialog 1.3-20210117 when `--extra-button` is also specified with `--textbox`. This causes the default "OK" label to appear instead of the intended "Back to Menu".

**Impact:** Minor UX confusion — user might not realize OK means "back to menu" vs a generic acknowledgment. Functionally, pressing OK still returns to the menu correctly.

**Suggested fix:**
Test whether `--ok-label` works instead of `--exit-label` when `--extra-button` is present. Alternatively, use a `--yesno` or `--menu` dialog instead of `--textbox` for the failure case.

**Verified:** Observed on registry4 when OSUS day2-osus failed (timed out waiting for operator). The failure dialog showed `< OK >` instead of `< Back to Menu >`.

---

## Bug #360: ~~DUPLICATE of #338~~ Platform selection immediately persists to aba.conf before form completion

**Severity:** Medium (data corruption/unexpected state change)
**File:** `tui/v2/tui-cluster.sh` (lines 1893-1910, within `tui_advanced_menu`)
**Found:** 2026-06-03 (hackathon, TUI testing Advanced menu)
**Status:** NEW

**Description:**
In Advanced > Platform Settings, selecting a platform type (VMware/KVM/BM) immediately writes the platform value to `aba.conf` BEFORE the configuration form is shown. If the user presses Back/ESC on the subsequent form (e.g., because they selected the wrong platform accidentally or just wanted to view settings), the platform has already been silently changed.

**Steps to reproduce:**
1. Start with `platform=vmw` in `aba.conf`
2. Go to Advanced > Platform Settings
3. Select "KVM/libvirt" (default is already VMware since `platform=vmw`)
4. See the KVM configuration form appear
5. Press ESC/Back without making changes
6. Result: `aba.conf` now has `platform=kvm` even though you cancelled

**Root cause:**
Lines 1899-1901:
```bash
K)
    replace-value-conf -q -n platform -v kvm -f "$ABA_ROOT/aba.conf"  # Persisted!
    platform=kvm
    _configure_platform_file "kvm.conf" "KVM/libvirt"  # Form shown AFTER persistence
    ;;
```

The `replace-value-conf` call is executed BEFORE `_configure_platform_file` (the form). If the user cancels the form, the platform has already been changed.

**Expected behavior:**
The platform should only be persisted to `aba.conf` AFTER the user completes and confirms the configuration form. If the user cancels, the previous platform value should be preserved.

**Suggested fix:**
Save the previous platform value, show the form first, and only persist if the form returns success:
```bash
K)
    _configure_platform_file "kvm.conf" "KVM/libvirt"
    if [[ $? -eq 0 ]]; then
        replace-value-conf -q -n platform -v kvm -f "$ABA_ROOT/aba.conf"
        platform=kvm
    fi
    ;;
```

**Impact:** Accidentally selecting the wrong platform changes `aba.conf` silently. The user may not notice until a subsequent cluster installation fails because it's trying to use the wrong hypervisor.

**Verified:** Observed on registry4 — selecting KVM from the VMware-default state, then pressing ESC, left `platform=kvm` in aba.conf. Had to re-select VMware to restore correct state.

---

## Bug #361: ~~NOT A BUG~~ ~~DUPLICATE of #346~~ ESC in DISCO/DIRECT mode (from CONNO) tries to EXIT entire TUI instead of returning to caller

**Severity:** N/A
**Status:** NOT A BUG — CORRECT BEHAVIOR (same as #346)

**Clarification:** Once you "switch mode" via Advanced menu, you are IN that mode. Its top-level menu is now YOUR top-level menu. ESC at a top-level menu → quit confirmation. This is the correct and consistent ESC-means-back-one-step behavior:
- From submenu → parent menu
- From top-level menu → quit confirmation
- The mode switch is a full transition, not a "nested submenu"

The only real ESC bug is Bug #27: ESC on the confirm_quit dialog itself should mean "cancel" (stay) not "yes, quit."

---

## Bug #362: ~~FIXED~~ Cluster summary shows "(not set) GB" when VM memory/disk values are empty

**Severity:** LOW (cosmetic)
**Status:** FIXED in commit 498cfeb2 — unit suffix now only shown when value is set
**Component:** tui/v2/tui-cluster.sh (lines 1602, 1605, 1607)
**Status:** NEW
**Found:** 2026-06-03 (hackathon)
**Commit range:** main..dev

**Description:**
In the cluster installation review/summary page, the Master Memory, Worker Memory, and Data Disk fields append the "GB" unit suffix unconditionally:
```bash
summary+="  Master Mem:   ${cl_master_mem:-(not set)} GB\n"
summary+="  Worker Mem:   ${cl_worker_mem:-(not set)} GB\n"
summary+="  Data disk:    ${cl_disk:-(not set)} GB\n"
```

When these values are empty, the display shows:
```
  Master Mem:   (not set) GB
  Worker Mem:   (not set) GB
  Data disk:    (not set) GB
```

**Expected behavior:**
The "GB" unit should only appear when a value is present:
```
  Master Mem:   (not set)
  Data disk:    (not set)
```
Or when set:
```
  Master Mem:   16 GB
  Data disk:    120 GB
```

**Suggested fix:**
```bash
summary+="  Master Mem:   ${cl_master_mem:-(not set)}${cl_master_mem:+ GB}\n"
summary+="  Data disk:    ${cl_disk:-(not set)}${cl_disk:+ GB}\n"
```
(The `${var:+ suffix}` pattern only outputs the suffix when `var` is non-empty.)

**Impact:** Cosmetic — confusing display but no functional impact.

---

## Bug #363: ~~FIXED~~ ISC Edit "Save" marks file as user-owned even when content is unchanged

**Status:** FIXED in commit 4abd48b6 — diff check before overwrite prevents accidental ownership

**Severity:** MEDIUM
**Component:** tui/v2/tui-mirror.sh (lines 662-671)
**Status:** NEW
**Found:** 2026-06-03 (hackathon)
**Commit range:** main..dev

**Description:**
When the user opens the ISC editor ("V > E" or "View/Edit > Edit") and presses Save
without making any changes, the TUI unconditionally copies `$_TUI_TMP` back to the ISC file:
```bash
dlg ... --editbox "$isconf_file" 0 0 2>"$_TUI_TMP"
if [[ $? -eq 0 ]]; then
    cp "$_TUI_TMP" "$isconf_file"    # ← Always overwrites
    tui_log "ISC saved by user"
    dlg ... --msgbox "$TUI2_MSG_ISC_SAVED" 0 0 || true
fi
```

This updates the file's mtime, which ABA's regeneration guard in
`scripts/reg-create-imageset-config.sh` uses to determine user ownership:
```bash
# Skip if: user edited the ISC after generation (ISC is strictly newer than .created).
```

**Impact:**
- Pressing Save without changes permanently disables auto-regeneration of the ISC
- The user sees "ABA will not overwrite your edits" even though no edits were made
- The user must manually use "Reset" to restore auto-management
- This is easily triggered accidentally since Tab→Enter hits Save (the first button)

**Expected behavior:**
The TUI should compare content before saving:
```bash
if [[ $? -eq 0 ]]; then
    if ! diff -q "$_TUI_TMP" "$isconf_file" >/dev/null 2>&1; then
        cp "$_TUI_TMP" "$isconf_file"
        tui_log "ISC saved by user"
        dlg ... --msgbox "$TUI2_MSG_ISC_SAVED" 0 0 || true
    else
        tui_log "ISC unchanged, skipping save"
    fi
fi
```

**Reproduction:**
1. CONNO main menu → V (View/Edit ISC) → E (Edit)
2. Don't change anything
3. Tab → Enter (hits Save)
4. Dialog shows "ImageSet configuration saved. ABA will not overwrite your edits."
5. From this point, `aba isconf` will skip regeneration even when channel/version changes

---

## Bug #364: ~~FIXED~~ Cluster selector lists directories with invalid DNS names then rejects them

**Status:** FIXED in commit 4abd48b6 — list_cluster_dirs() filters invalid DNS labels

**Severity:** LOW (UX inconsistency)
**Component:** tui/v2/tui-lib.sh (list_cluster_dirs + select_cluster validation)
**Status:** NEW — VERIFIED via TUI
**Found:** 2026-06-03 (hackathon)
**Commit range:** main..dev

**Description:**
The `list_cluster_dirs()` function (line 788) lists any subdirectory containing a
`cluster.conf` file, including directories with dots in their names (e.g., `demo1.bk`
which is a backup). These directories appear in the cluster selection menu.

However, `select_cluster()` (line 1256) validates the selected cluster name against
a DNS label regex after the user selects it:
```bash
if [[ ! "$SELECTED_CLUSTER" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    dlg ... --msgbox "Invalid cluster name: '$SELECTED_CLUSTER'\n\nCluster directory names must be valid DNS labels." 0 0
    return 1
fi
```

This creates a confusing UX: the TUI offers an item that it will refuse to operate on.

**Reproduction:**
1. Have a directory like `~/aba/demo1.bk/cluster.conf` (e.g., a renamed backup)
2. Day-2 → Delete → cluster list shows "demo1.bk  demo1.example.com (shut down)"
3. Select it → "Invalid cluster name: 'demo1.bk'"

**Expected behavior:**
Filter invalid directory names in `list_cluster_dirs()` before they reach the menu:
```bash
for dir in "$ABA_ROOT"/*/cluster.conf; do
    ...
    dir="${dir##*/}"
    # Filter out directories that aren't valid DNS labels
    [[ "$dir" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || continue
    ...
done
```

**Impact:** Confusing UX — user sees an option they can't use. Minor issue that only
occurs when backup/renamed cluster directories exist with non-DNS-label names.

---

## Bug #365: ~~DUPLICATE of #320 / INVALID~~ TUI upgrade flow fails to list available versions when ocp_version_target is unset

**Severity:** MEDIUM (functional — upgrade discovery broken in common case)
**Component:** tui/v2/tui-cluster.sh (`_day2_upgrade` ~line 2169) + scripts/cluster-upgrade.sh (line 53-59)
**Status:** NEW — VERIFIED via TUI
**Found:** 2026-06-03 (hackathon)
**Commit range:** main..dev

**Description:**
The TUI's `_day2_upgrade` function calls `aba --dir "$SELECTED_CLUSTER" upgrade --dry-run`
to discover available upgrade versions in the mirror. However, `cluster-upgrade.sh` requires
a target version — either via `--to <ver>` flag or from `ocp_version_target` in `mirror.conf`.

When `ocp_version_target` is not set (common case: fresh install, no prior upgrade configured),
the command aborts with "No target version specified" before reaching the version-listing code:
```bash
# In cluster-upgrade.sh line 53-59:
if [ ! "$target_ver" ]; then
    if [ "$ocp_version_target" ]; then
        target_ver="$ocp_version_target"
    else
        aba_abort "No target version specified. Use: aba -d <cluster> upgrade --to <version>"
    fi
fi
```

The TUI catches this with `|| true` and shows "No available upgrade versions found" with
a hint to update the ISC and sync. But the hint does not mention the actual root cause
(missing `ocp_version_target`), and the user cannot discover available versions even if
newer versions exist in the mirror.

**Reproduction:**
1. Ensure `ocp_version_target` is commented out in `mirror/mirror.conf` (default state)
2. Day-2 → Upgrade → select an installed cluster
3. TUI shows "No available upgrade versions found" immediately
4. Even if mirror has multiple versions, they cannot be discovered

**Expected behavior:**
The TUI should pass a dummy high version to `--dry-run` to force version listing:
```bash
_versions_raw=$(aba --dir "$SELECTED_CLUSTER" upgrade --to 99.99.99 --dry-run 2>&1) || true
```
Or better: `cluster-upgrade.sh` should allow `--dry-run` without a target version (just
list available versions in the mirror without requiring a specific target).

**Impact:**
- Upgrade discovery is completely broken unless user has previously run `aba upgrade --to`
- User must know to manually set `ocp_version_target` in `mirror.conf` — defeats TUI purpose
- The fallback hint is misleading (suggests ISC/sync issue when the real issue is missing config)

---

## Bug #366: ~~INVALID~~ `local` used at script top level in cluster-upgrade.sh crashes upgrade with OSUS

**Severity:** HIGH (crashes upgrade when OSUS is active and channel changes)
**Component:** scripts/cluster-upgrade.sh line 272
**Status:** FIXED — replaced `local` with plain variable assignment (2026-06-04)
**Found:** 2026-06-03 (hackathon)
**Commit range:** main..dev (introduced in commit 675b08fc)

**Description:**
Line 248 uses `local _graph_ok="" _try` at the script's top level (not inside a function).
The script runs with `#!/bin/bash -e`, so `local` at top level produces exit code 1 and
immediately terminates the script:
```
$ bash -e -c 'local x=1; echo $x'
bash: line 1: local: can only be used in a function
```

This code is inside a conditional block:
```bash
if [ "$_channel_changed" ] && [ "$osus_upstream" ]; then
    aba_info "Waiting for update graph to refresh after channel change ..."
    local _graph_ok="" _try    # ← CRASH: local at top level with set -e
    for _try in $(seq 1 12); do
```

The bug triggers when:
1. The cluster has OSUS active (update graph endpoint configured)
2. The upgrade requires a channel change (e.g., stable-4.20 → stable-4.21)

When both conditions are true, the script crashes before executing the upgrade.

**Reproduction:**
1. Install OSUS on a cluster
2. Attempt to upgrade from e.g., 4.20.x → 4.21.x (requires channel change)
3. `cluster-upgrade.sh` crashes at line 248 with "local: can only be used in a function"
4. Upgrade never executes

**Expected behavior:**
Replace `local` with plain variable assignment:
```bash
_graph_ok=""
_try=""
```

**Impact:**
- Cluster upgrades with OSUS + cross-minor version crash silently
- The user sees a cryptic bash error rather than an upgrade
- Affects the primary upgrade workflow for OSUS-enabled clusters (which the TUI encourages)

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

## Bug #371: ~~INVALID~~ add_ntp_ignition_to_iso.sh ignores ntp_servers from cluster.conf — only reads aba.conf

**Severity**: MEDIUM — CORE ABA BUG
**Status:** FIXED (2026-06-04)
**Found:** 2026-06-04 (TUI hackathon — live testing on registry4)

**Location**: `scripts/add_ntp_ignition_to_iso.sh` line 12-15

**Description**: The script `add_ntp_ignition_to_iso.sh` only sources `normalize-aba-conf` (line 12) but never sources `normalize-cluster-conf`. This means it only sees the `ntp_servers` variable from `aba.conf`, not from `cluster.conf`. If a user configures NTP servers via the TUI cluster wizard (which writes to `cluster.conf`) but leaves `aba.conf`'s `ntp_servers` empty, the early-bootstrap NTP ignition configuration is skipped entirely.

The message at line 15 is misleading: "Not configuring NTP in early bootstrap node because ntp_servers not defined in aba.conf or cluster.conf" — it claims to check both, but only checks aba.conf.

The parent script `generate-image.sh` sources both configs (lines 9-10), but since `add_ntp_ignition_to_iso.sh` is called as a subprocess (`#!/bin/bash -e`), it starts fresh and only reads aba.conf.

**Steps to Reproduce**:
1. Set `ntp_servers=10.0.1.8` in cluster.conf (via TUI wizard)
2. Leave `ntp_servers=` empty in aba.conf
3. Run cluster install
4. Observe: "Not configuring NTP in early bootstrap node" despite cluster.conf having NTP configured

**Expected**: NTP ignition should be added based on cluster.conf's ntp_servers value

**Actual**: NTP ignition is skipped; bootstrap node has no NTP configuration

**Fix**: Added `source <(normalize-cluster-conf)` after `source <(normalize-aba-conf)` in `add_ntp_ignition_to_iso.sh`

**Verified**: YES — observed during sno2 cluster installation on registry4. cluster.conf has `ntp_servers=10.0.1.8` but output showed "Not configuring NTP in early bootstrap node because ntp_servers not defined in aba.conf or cluster.conf"

---

## Bug #372: ~~INVALID~~ `_day2_status` refactored command blocked by metacharacter check in `confirm_and_execute`

**Status:** NEW (unverified — bastion uncommitted code only, not deployed to conno)

**Severity:** HIGH — Day-2 "Cluster status" will be completely broken when this code is deployed

**Location:** `tui/v2/tui-cluster.sh` lines 2095-2107 (bastion uncommitted diff)

**Description:** The bastion has an uncommitted refactor of `_day2_status()` that builds a compound shell command with `;`, `||`, and `2>&1` operators, then passes it to `confirm_and_execute()`. However, `confirm_and_execute` → `_exec_in_tui` (line 602) and `_exec_in_terminal` (line 677) both have a metacharacter defense check:
```bash
if [[ "$cmd" =~ [\`\$\;]|'&&'|'||'|'>>'|'<<' ]]; then
```
The compound command contains `;` (semicolons between echo/oc commands) and `||` (fallback echo on failure), which will always match this regex. Result: "Command blocked: contains invalid characters" — the Cluster Status function is unusable.

**Root cause:** The refactor to use `confirm_and_execute` doesn't account for the metacharacter filter that was added to prevent shell injection. Compound commands with shell operators are fundamentally incompatible with the current metacharacter defense.

**Suggested fix:** Either:
1. Keep the original approach (run commands directly, capture to file, show in textbox) — this is what conno's committed version does.
2. Or wrap the compound logic in a helper script/function that `confirm_and_execute` can call as a single simple command without metacharacters.

---

## Bug #373: ~~INVALIDATED~~ — VMware config form `VC_FOLDER` quoting is actually safe via auto-quoting

**Status:** INVALIDATED — `replace-value-conf` has auto-quoting logic that wraps values containing spaces or `#` in single quotes. The inconsistency in explicit pre-quoting (GOVC_PASSWORD, GOVC_NETWORK use `'...'` manually; other fields rely on auto-quoting) is a style issue but NOT a data corruption bug.

**Severity:** N/A (cosmetic inconsistency only)

---

## Bug #374: `reg-save.sh` instructs user to copy target-version CLIs before download completes

**Status:** NEW (unverified — code inspection only)

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

## Bug #375: ~~DUPLICATE of #294~~ `_apply_mode_connection` in DISCO mode does not reset "proxy" to "mirror"

**Status:** NEW (unverified — code inspection only)

**Severity:** LOW — Only triggers when cluster.conf has `int_connection=proxy` AND user enters DISCO mode (unusual scenario)

**Location:** `tui/v2/tui-cluster.sh` line 700-701

**Description:** The `_apply_mode_connection()` function sanitizes the image source for the current TUI mode:
```bash
elif [[ "$_TUI_MODE" == "DISCO" ]]; then
    [[ "$cl_connection" == "direct" ]] && cl_connection="mirror"
fi
```

This correctly converts "direct" to "mirror" in DISCO mode (no internet = can't pull directly). However, it does NOT convert "proxy" to "mirror". In a fully disconnected environment, proxy is also unavailable (there's no internet-facing proxy). If a user switches from CONNO (where they set `int_connection=proxy`) to DISCO mode, or if their cluster.conf was created in a CONNO session with proxy mode, the cluster would be configured to use a proxy that doesn't exist in the air-gapped environment.

**Root cause:** The guard only checks for `"direct"` but not `"proxy"`. Both should be reset to "mirror" in DISCO mode.

**Suggested fix:** Change line 701 to: `[[ "$cl_connection" != "mirror" && "$cl_connection" != "" ]] && cl_connection="mirror"`

---

## Bug #376: ~~DUPLICATE of #296~~ Internet error dialog says "Exiting..." but TUI may continue in DISCO mode

**Status:** NEW (unverified — code inspection only)

**Severity:** LOW — UX/wording issue, not functional breakage

**Location:** `tui/v2/abatui2.sh` lines 448-458

**Description:** When the internet check fails and there's no `.bundle` file, the TUI shows a detailed error dialog that ends with "Exiting..." (line 450). However, immediately after the dialog closes, the code checks if `aba.conf` exists and the payload is valid (line 453). If true, the TUI does NOT exit — it falls back to DISCO mode.

This is confusing UX: the user reads "Exiting..." but the TUI continues running in DISCO mode. The message should say something like "Attempting disconnected mode..." or the "Exiting..." text should be conditional on whether DISCO fallback is possible.

**Root cause:** The error dialog text was written before the DISCO fallback logic was added. The "Exiting..." text is now inaccurate when DISCO fallback succeeds.

**Suggested fix:** Remove "Exiting..." from the dialog, or split into two messages: one that says "checking for offline data..." and one that actually exits.

---

## Bug #377: ~~DUPLICATE of #335~~ Day-2 menu shows as available when clusters exist but none are installed

**Status:** NEW (unverified — code inspection only)

**Severity:** LOW — UX inconsistency, not functional breakage

**Location:** `tui/v2/tui-lib.sh` lines 903-907, `tui/v2/abatui2.sh` line 577

**Description:** The `tui_cluster_menu_flags` function sets `_CLUSTER_DAY2_AVAIL=true` when ANY cluster directory exists (`_CLUSTER_HAS_ANY=true`), regardless of whether any cluster is actually installed. This means the Day-2 menu item appears enabled (without a "install cluster first" hint) even when clusters are still being installed but not yet complete.

When the user selects Day-2, they're taken to `cluster_day2_menu()` → `select_installed_cluster()` which shows "No installed clusters found" — a confusing dead end since the menu suggested Day-2 was available.

**Expected behavior:** `_CLUSTER_DAY2_AVAIL` should check `_CLUSTER_HAS_INSTALLED` instead of `_CLUSTER_HAS_ANY`, or the Day-2 label should include a hint like "(waiting for install)" when no installed clusters exist.

**Root cause:** Lines 903-907 use `_CLUSTER_HAS_ANY` as the gate, but Day-2 operations require installed clusters. The `_CLUSTER_HAS_INSTALLED` variable is computed (line 900) but not used for the Day-2 gate.

**Suggested fix:** Change line 905 to: `if [[ "$_CLUSTER_HAS_INSTALLED" != "true" ]]; then` — or keep the current gate but annotate the Day-2 label when only installing clusters exist.

---

## Bug #378: ~~DUPLICATE of #338~~ Platform selection committed to aba.conf before user confirms configuration

**Status:** NEW (verified via code inspection on conno)

**Severity:** MEDIUM — Can leave aba.conf in an inconsistent state

**Location:** tui/v2/tui-cluster.sh lines 1895-1902 (Advanced Menu -> Platform Settings)

**Description:** In the Advanced Menu Platform Settings handler, when the user selects VMware or KVM, the code immediately writes platform=vmw (or platform=kvm) to aba.conf BEFORE calling _configure_platform_file() to configure the platform-specific file (vmware.conf or kvm.conf). If the user then cancels the configuration form (presses Back), aba.conf already has the new platform value but the platform config file may not be valid.

The code flow is: replace-value-conf writes platform=vmw immediately, then _configure_platform_file is called but its return code is not checked. Compare with the cluster wizard (lines 263, 285) which properly checks: _configure_platform_file ... || return 1.

**Impact:** After cancellation, aba.conf says platform=vmw but vmware.conf may be empty/invalid. Subsequent operations (cluster create, delete) will attempt to use VMware APIs with invalid credentials.

**Root cause:** The platform setting is persisted optimistically before the user completes configuration. The return code of _configure_platform_file is not checked in the advanced menu handler.

**Suggested fix:** Either move the replace-value-conf call to AFTER _configure_platform_file returns 0, or revert the platform on cancellation.

---

## Bug #379: TUI Upgrade shows versions from mirror but OSUS graph may not have a direct upgrade path

**Status:** NEW (verified via TUI on conno - upgrade from 4.20.20 to 4.20.23 failed)

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

**Status:** NEW (verified via TUI on conno - progress box shows no movement after "Upgrade command accepted")

**Severity:** LOW — Cosmetic/UX, upgrade continues correctly in background

**Location:** scripts/include_all.sh aba_wait_show() lines 1337-1339, interaction with _exec_in_tui (dialog --programbox)

**Description:** After the upgrade command is accepted by the cluster, the TUI progress box shows "[ABA] Upgrade command accepted by cluster" as the last visible line and then appears completely frozen for up to 10 minutes while aba_wait_show polls the cluster for upgrade completion.

The aba_wait_show function detects it is NOT on a TTY (because dialog --programbox captures stdout), so it uses the non-TTY path: it prints elapsed timestamps as space-separated values without newlines (e.g. "0:15 0:30 0:45"). However, dialog --programbox appears to buffer or not display incomplete lines, so the user sees nothing updating.

**Impact:** User sees a frozen progress box and cannot tell if the TUI has hung or is still working. They might kill it or think there is an error.

**Root cause:** aba_wait_show non-TTY path outputs progress without newlines (printf). dialog --programbox does not display partial lines (needs newline to scroll). The progress timestamps accumulate invisibly.

**Suggested fix:** In the non-TTY path of aba_wait_show, output each elapsed tick with a newline so that dialog --programbox shows each poll cycle as a new visible line.

---

## Bug #381: Upgrade to intermediate graph version (4.20.22) fails — signature not included by oc-mirror

**Status:** NEW (verified via TUI on conno - upgrade from 4.20.20 to 4.20.22 accepted but fails signature verification)

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

**Status:** NEW (verified via TUI on conno - upgrade 4.20.20 -> 4.20.22 shows wrong diagnosis)

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

**Status:** NEW (confirmed via code review - same pattern as Bug #94)

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

## Bug #384: ~~FIXED~~ VM Resources page checks wrong path for macs.conf indicator

**Status:** FIXED in commit 89fae839 (Bug #315 — changed to `$ABA_ROOT/$cl_name/macs.conf`)

**Status:** NEW (confirmed via code review)

**Severity:** LOW — cosmetic/misleading indicator

**Location:** tui/v2/tui-cluster.sh _cluster_page_vm() line 1372

**Description:** The VM Resources page (page 4) shows "(from macs.conf)" next to the MAC template field if a macs.conf file exists. However, the check looks at `$ABA_ROOT/macs.conf` (the global ABA root directory), NOT at `$ABA_ROOT/$cl_name/macs.conf` (the cluster-specific directory where the file is actually used).

Code at line 1372:
```
if [[ -f "$ABA_ROOT/macs.conf" ]] && grep -qE '^[^#]' "$ABA_ROOT/macs.conf" 2>/dev/null; then
    mac_info=" (from macs.conf)"
fi
```

The cluster-specific macs.conf is stored and read from the cluster directory (e.g., `sno/macs.conf`). The root-level `$ABA_ROOT/macs.conf` is not copied into cluster dirs by any ABA mechanism.

**Impact:** 
- If `$ABA_ROOT/macs.conf` exists (unlikely), the indicator shows even though the per-cluster file may be empty
- If only `$ABA_ROOT/sno/macs.conf` exists (the normal case after TUI edits), the indicator does NOT show

**Suggested fix:** Change the check to `$ABA_ROOT/$cl_name/macs.conf` to match the actual file location.

---

## Bug #384: ~~DUPLICATE of Bug #349~~ VM Resources page checks wrong path for macs.conf indicator

**Status:** DUPLICATE of Bug #349 — same issue, same line, same fix needed.

**Severity:** LOW — cosmetic/misleading indicator

**Location:** tui/v2/tui-cluster.sh _cluster_page_vm() line 1372

**Description:** The VM Resources page (page 4) shows "(from macs.conf)" next to the MAC template field if a macs.conf file exists. However, the check looks at `$ABA_ROOT/macs.conf` (the global ABA root directory), NOT at `$ABA_ROOT/$cl_name/macs.conf` (the cluster-specific directory where the file is actually used).

Code at line 1372:
```
if [[ -f "$ABA_ROOT/macs.conf" ]] && grep -qE '^[^#]' "$ABA_ROOT/macs.conf" 2>/dev/null; then
    mac_info=" (from macs.conf)"
fi
```

The cluster-specific macs.conf is stored and read from the cluster directory (e.g., `sno/macs.conf`). The root-level `$ABA_ROOT/macs.conf` is not copied into cluster dirs by any ABA mechanism.

**Impact:** 
- If `$ABA_ROOT/macs.conf` exists (unlikely), the indicator shows even though the per-cluster file may be empty
- If only `$ABA_ROOT/sno/macs.conf` exists (the normal case after TUI edits), the indicator does NOT show

**Suggested fix:** Change the check to `$ABA_ROOT/$cl_name/macs.conf` to match the actual file location.

---

## Bug #385: ~~INVALID~~ Cluster Status command blocked by metacharacter defense in confirm_and_execute

**Status:** NEW (confirmed via code review — HIGH severity)

**Severity:** HIGH — completely blocks a core Day-2 operation

**Location:** tui/v2/tui-cluster.sh _day2_status() lines 2094-2107, tui/v2/tui-lib.sh _exec_in_tui() line 602 / _exec_in_terminal() line 677

**Description:** The _day2_status() function constructs a multi-statement shell command using `;` separators and `||` conditionals, then passes it to confirm_and_execute(). However, both _exec_in_tui() and _exec_in_terminal() have a metacharacter defense regex that blocks any command containing `;`, `||`, `$`, etc:

```
if [[ "$cmd" =~ [\`\$\;]|'&&'|'||'|'>>'|'<<' ]]; then
```

The status command at lines 2095-2105 contains:
- `;` (statement separators between echo/oc commands)  
- `||` (fallback error messages)
- `$` (from escaped awk variables that become literal $3, $4 in the string)

This means when a cluster IS installed and the user selects "Cluster Status", the command will be blocked with "Command blocked: contains invalid characters" -- the status check cannot run.

**Why it was not caught sooner:** Without an installed cluster, select_installed_cluster() returns early with "No installed clusters found" BEFORE confirm_and_execute is ever called. The bug only manifests when a cluster is actually installed.

**Impact:** Cluster Status is completely non-functional for installed clusters. Users cannot check cluster operator status, node status, or upgrade status from the TUI.

**Suggested fix:** _day2_status() should bypass confirm_and_execute entirely and use a direct execution pattern (similar to _day2_ssh which uses clear + bash -c). Alternatively, restructure the status check as a proper aba CLI command (e.g., `aba --dir $cluster status`) that encapsulates the multi-command logic, so the TUI only passes a single simple command to confirm_and_execute.

---

### Bug #386: "Monitor Cluster Installation" shown in Advanced menu when no cluster is being installed

**Severity:** LOW (cosmetic/UX confusion)

**Location:** `tui/v2/tui-cluster.sh` lines 1802-1804 (in `tui_advanced_menu()`), root cause in `tui/v2/tui-lib.sh` lines 903-908 (`tui_cluster_menu_flags()`)

**Description:** The "Monitor Cluster Installation (re-attach)" option appears in the Advanced menu even when no cluster is currently being installed. The `_CLUSTER_MON_AVAIL` flag is set to `true` whenever *any* cluster directory with `cluster.conf` exists, regardless of whether a cluster installation is actively in progress.

**Root cause:** In `tui_cluster_menu_flags()`:
```bash
_CLUSTER_MON_AVAIL=true
if [[ "$_CLUSTER_HAS_ANY" != "true" ]]; then
    _CLUSTER_MON_AVAIL=false
fi
```

This only hides "Monitor" when there are zero cluster directories. It should additionally check whether any cluster is actively installing (has kubeconfig but no `.install-complete`).

**Reproduction:**
1. Have a configured cluster directory (e.g. `sno/cluster.conf`) that is NOT being installed
2. Open TUI → CONNO menu → Advanced
3. Observe "F Monitor Cluster Installation (re-attach)" is present
4. Select it → "No clusters are currently installing" message

**Expected behavior:** "Monitor Cluster Installation" should only appear in the Advanced menu when at least one cluster is actively being installed (i.e., has `iso-agent-based/auth/kubeconfig` but not `.install-complete`).

**Impact:** Minor UX confusion. Users see an option that is always non-functional unless a cluster happens to be mid-install. Selecting it always results in "No clusters are currently installing" message, wasting the user's time.

**Related:** Same root cause pattern as Bug #377 (Day-2 menu availability gated by `_CLUSTER_HAS_ANY` instead of actual state).

**Suggested fix:** Add a `_CLUSTER_HAS_INSTALLING` flag in `tui_cluster_menu_flags()` that checks for clusters with kubeconfig but no `.install-complete`, and use that for `_CLUSTER_MON_AVAIL` instead of `_CLUSTER_HAS_ANY`.

---

### Bug #60 Addendum: Search removal bypasses reference counting

**Severity:** MEDIUM (data corruption in operator basket)

**Additional detail for Bug #60:** The `_operator_search()` function's removal logic at lines 1080-1083 uses `unset 'OP_BASKET[$op]'` which completely removes the operator, bypassing the reference-counting system used by `_operator_sets_menu()` (lines 966-972). This means:

1. User adds operator set "ocp" → `cincinnati-operator` ref-count = 1
2. User adds operator set "monitoring" which also contains it → ref-count = 2
3. User searches for "cincinnati" and unchecks it → `unset` removes it entirely (ref-count gone)
4. The basket now appears to not contain `cincinnati-operator`, but both sets still believe they added it

The addition path (line 1079) is safe — it only sets `OP_BASKET[$op]=1` when the key is absent. But the removal path destructively removes regardless of ref-count. The fix should use the same decrement-to-zero pattern as the operator sets removal code.

---

### Bug #387: Pressing Exit in DISCO mode (entered from CONNO) exits the entire TUI

**Status: NOT A BUG (by design, per user feedback)**

**Location:** `tui/v2/tui-disco.sh` lines 246-254 (in `disco_main()`)

**Description:** When DISCO mode is entered from the CONNO advanced menu ("Switch to Fully Disconnected"), pressing the "Exit" button or ESC in the DISCO main menu exits the entire TUI process.

**Design rationale:** Exit from any main menu (CONNO, DISCO, DIRECT) is intended to exit the entire TUI. There is no concept of "going back to a previous mode." The code explicitly states: `"ESC or Exit button: always confirm quit, regardless of how we got here"`. ESC at a main menu level means EXIT (with confirmation). ESC inside wizards goes back one step.

---

### Bug #388: `_apply_mode_connection()` doesn't sanitize "proxy" in DISCO mode

**Severity:** MEDIUM (incorrect cluster configuration in disconnected environments)

**Location:** `tui/v2/tui-cluster.sh` lines 697-703 (in `_apply_mode_connection()`)

**Description:** When loading an existing `cluster.conf` that has `int_connection=proxy` into the TUI running in DISCO mode, the `_apply_mode_connection()` function fails to correct it to "mirror". Only "direct" is caught and converted.

**Root cause:**

```bash
_apply_mode_connection() {
    if [[ "$_TUI_MODE" == "DIRECT" ]]; then
        [[ "$cl_connection" != "proxy" ]] && cl_connection="direct"
    elif [[ "$_TUI_MODE" == "DISCO" ]]; then
        [[ "$cl_connection" == "direct" ]] && cl_connection="mirror"  # BUG: "proxy" not caught!
    fi
}
```

The condition only checks for `"direct"` but should check for anything other than `"mirror"`:
```bash
[[ "$cl_connection" != "mirror" ]] && cl_connection="mirror"
```

**Contrast with toggle handler:** The manual toggle at lines 1315-1321 gets this right:
```bash
elif [[ "$_TUI_MODE" == "DISCO" ]]; then
    if [[ "$cl_connection" != "mirror" ]]; then   # <-- correctly catches both "proxy" and "direct"
        cl_connection="mirror"
    fi
```

**Reproduction:**
1. On a connected host (CONNO), create a cluster with `int_connection=proxy` in `cluster.conf`
2. Start TUI in DISCO mode (or switch to DISCO from CONNO)
3. Use "Resume configuration" or load the existing cluster
4. Navigate to "Network & Interfaces" page
5. **Expected:** Image source shows "mirror" (auto-corrected for DISCO)
6. **Actual:** Image source shows "proxy (public registries)" — invalid for a disconnected environment

**Impact:** Users could proceed to install a cluster in a disconnected environment with `int_connection=proxy`, which would fail because there's no internet. The pre-install summary would also display a confusing "proxy" connection mode.

---

### Bug #389: Pressing Exit in DIRECT mode (entered from CONNO) exits the entire TUI

**Status: NOT A BUG (by design, per user feedback)**

**Location:** `tui/v2/tui-direct.sh` lines 753-760 (in `_direct_action_menu()`)

**Description:** When DIRECT mode is entered from the CONNO advanced menu ("Switch to Direct"), pressing the "Exit" button or ESC in the DIRECT action menu exits the entire TUI process.

**Design rationale:** Same as Bug #387 — Exit from any main menu is intended to exit the entire TUI. There is no concept of "going back to a previous mode." ESC at a main menu level means EXIT (with confirmation). ESC inside wizards goes back one step. The code comment at line 754 states: `"ESC or Exit button: always confirm quit, regardless of how we got here"`.

---

### Bug #390: Platform toggle port update lost by `_cluster_generate_defaults` reload

**Severity:** MEDIUM (user's port edit silently reverted; UI shows stale value)

**Location:** `tui/v2/tui-cluster.sh` line 734 (`_cluster_generate_defaults` call in page navigation)

**Description:** When the user toggles the platform on the Cluster Basics page (page 1) for an EXISTING cluster that already has a `cluster.conf` on disk, the port name update that accompanies the platform toggle is lost. The port value is correctly updated in memory by the toggle code (lines 986-993), but `_cluster_generate_defaults` (called when the user presses "Next") reloads the cluster.conf from disk, overwriting the in-memory port change with the old value.

**Root cause:** After page 1 completes (user presses Next), the navigation loop at line 734 calls `_cluster_generate_defaults`. For existing clusters, this function unconditionally reloads ALL values from `cluster.conf` via `_cluster_load_conf` (line 190):

```bash
if [[ -f "$_conf" ]]; then
    _cluster_load_conf "$_conf"  # Overwrites cl_ports, cl_type, etc.!
    return 0
fi
```

This overwrites the in-memory edits from page 1 (including the port name cleared by the platform toggle) with the OLD values from disk. `_persist_cluster_draft` (line 736) then writes these stale values back.

**Reproduction:**
1. Start TUI with an existing cluster `sno` (platform=vmw, ports=ens160 on disk)
2. Go to Install Cluster → Basics page loads with Platform: vmw, ports=ens160
3. Toggle Platform twice (P P): vmw → kvm → bm
   - Toggle code correctly updates cl_ports: ens160 → enp1s0 → ""
4. Press "Next" to go to page 2
5. **Expected:** Interface page shows Ports: (empty) — reflecting the bm platform
6. **Actual:** Interface page shows Ports: ens160 — the old value from disk

**LIVE VERIFIED (2026-06-13 on conno):** Confirmed that ALL page 1 edits are overwritten, not just ports. Test: toggled Type from "sno" to "compact" on page 1, pressed Next, then Back — Type reverted to "sno". The `_cluster_generate_defaults` reload affects every field that `_cluster_load_conf` sets (type, ports, network, DNS, gateway, NTP, VIPs, MAC template, connection mode, resources, disk).

**Suggested fix:** `_cluster_generate_defaults` should NOT reload the file when it already exists AND the user just finished editing page 1. Options:
1. Skip `_cluster_generate_defaults` entirely for existing clusters (it's only needed for NEW clusters to get defaults)
2. Call `_persist_cluster_draft` BEFORE `_cluster_generate_defaults` so the disk has the user's edits
3. Only call `_cluster_generate_defaults` on the FIRST page-1 completion (use a flag)

---

## Bug #391: ~~FIXED~~ Cluster Status blocked by metacharacter defense in `_exec_in_tui`
**File:** `tui/v2/tui-cluster.sh` `_day2_status()`
**Severity:** HIGH — Previously blocked all Cluster Status checks
**Status:** FIXED — `_day2_status()` has been rewritten to use direct `oc` commands with temp file output + `--textbox` display, completely bypassing `confirm_and_execute` and its metacharacter defense.

**Original problem (historical):** The `aba status` command contained pipe characters (`|`, `awk` filters, sort flags) that triggered the metacharacter safety regex in `_exec_in_tui`, blocking execution.

**LIVE VERIFIED (2026-06-13 on conno):** Cluster Status works correctly on installed SNO cluster (4.20.20). Shows all 34 cluster operators, nodes, pending pods, upgrade status, and cluster info in a scrollable textbox. No metacharacter issues.

---

## Bug #392: ~~FIXED~~ TUI Upgrade "Fetching versions" hangs when `ocp_version_target` set in mirror.conf AND cluster not healthy
**File:** `scripts/cluster-upgrade.sh` line 88 (condition), `scripts/include_all.sh` (new function)
**Severity:** HIGH — TUI appears frozen; user must kill the process manually
**Status:** FIXED (commit 8dd0aab1)

**Context:** The TUI's upgrade flow calls `aba --dir <cluster> upgrade --dry-run` to discover available versions. The script's dry-run-only code path (line 88) has this condition:
```bash
if [ "$opt_dry_run" ] && [ ! "$target_ver" ] && [ ! "$ocp_version_target" ]; then
```

**Root cause:** When `ocp_version_target` is set in `mirror.conf` (e.g. `ocp_version_target=4.20.23`), the third condition `[ ! "$ocp_version_target" ]` is FALSE. The script falls through to the actual upgrade logic path (lines 110+), which:
1. Resolves target from `ocp_version_target` (line 113)
2. Runs `cluster_is_ready` health check (line 133)
3. If cluster is NOT healthy → calls `ask "Continue with upgrade anyway"` (line 137)
4. The `ask` function reads from stdin (fd 0 = /dev/pts/N) but the TUI captured stdout/stderr into pipes — the interactive prompt is never displayed to the user
5. The TUI shows "Fetching available upgrade versions..." indefinitely

**Steps to reproduce:**
1. Set `ocp_version_target=<version>` in `mirror.conf`
2. Install a cluster
3. Immediately after install (while some operators are still settling), open TUI → Day-2 → Upgrade
4. Select the cluster
5. TUI shows "Fetching available upgrade versions..." forever

**LIVE VERIFIED (2026-06-13 on conno):** Reproduced exactly as described. Process tree showed `cluster-upgrade.sh --dry-run` blocked on `read` from `/dev/pts/4` with no children. Trace log confirmed: "The cluster is not fully healthy" → `ask` prompt → stdin block.

**Note:** When the cluster IS healthy, the flow works correctly — the script falls through the health check to lines 161-189 which outputs the dry-run summary. The bug only manifests with the unhealthy cluster + `ocp_version_target` set combination.

**Suggested fix:** Two changes needed:

1. **Primary fix — line 88 condition:** The condition should not check `ocp_version_target` when determining whether to enter the version-listing mode. Change to:
```bash
if [ "$opt_dry_run" ] && [ ! "$target_ver" ]; then
```
This ensures `--dry-run` (without explicit `--to`) ALWAYS enters the version-listing path, regardless of what's in `mirror.conf`. The TUI never passes `--to` when fetching versions — it relies on the dry-run output.

2. **Secondary fix — relax the health check for upgrade pre-checks:** The current `cluster_is_ready()` is too strict for determining if an upgrade can proceed. It checks:
   - ClusterVersion Available=True
   - ClusterVersion Progressing=False
   - Zero Degraded ClusterOperators

For **upgrade eligibility**, only `Available=True` matters — that means the API is reachable and the cluster is functional. A cluster with `Progressing=True` (update in flight) or a `Degraded` operator (e.g., monitoring flapping) is still perfectly capable of receiving upgrade commands.

**Proposed approach:** Add a relaxed `cluster_is_accessible()` function (or similar) that only checks `ClusterVersion Available=True`. Use it in the upgrade script's pre-check instead of `cluster_is_ready()`. Reserve the strict `cluster_is_ready()` for install-completion detection (where "truly complete" is the correct requirement).

---

## Bug #393: ~~FIXED~~ Upgrade from 4.20 to 4.21+ fails in disconnected environments — missing admin-ack

**File:** `scripts/cluster-upgrade.sh` (admin-ack guidance)
**Severity:** HIGH — Upgrade is silently blocked; cluster reports `Upgradeable=False`
**Status:** FIXED (commit pending — admin-ack ask + guidance added)

**Context:** Starting with OCP 4.21, Red Hat enforces Sigstore signature verification for release images via `ClusterImagePolicy`. Disconnected clusters upgrading from 4.20 → 4.21+ need an explicit admin acknowledgment.

### Signatures are NOT the problem (corrected 2026-06-13)

**oc-mirror v2 handles signatures correctly.** On conno, we confirmed:
- `working-dir/signatures/` contains Sigstore signature blobs for ALL mirrored releases (4.20.20, 4.20.22, 4.20.23, 4.21.18)
- oc-mirror v2 pushes these signatures **directly into the mirror registry as OCI referrer artifacts** during `sync`/`load`
- `cluster-resources/signature-configmap.json` IS produced by oc-mirror v2 (confirmed on con1) — `day2.sh` correctly applies it when present

**CORRECTION (2026-06-14):** The `day2.sh` code at lines 340-348 is NOT dead code. oc-mirror v2 DOES produce `signature-configmap.json` in `cluster-resources/`. The code correctly applies it when present and logs an informational message when absent. No change needed.

**Why the 4.20 cluster's `ClusterImagePolicy` is TechPreview-only:** The CIP shipped with 4.20 has `release.openshift.io/feature-set: TechPreviewNoUpgrade`, so Sigstore verification is NOT enforced on standard 4.20 clusters. In 4.21, this annotation is removed — Sigstore becomes GA and enforced.

### The actual requirement: Admin acknowledgment (4.20→4.21 only)

OCP 4.20 clusters with mirrors (`ImageDigestMirrorSets`) report:
```
Upgradeable=False
Reason: AdminAckRequired
Message: This cluster has mirrors configured. 4.21 will require Sigstore signatures...
```

The user must follow the instructions in the `oc adm upgrade` output, which tells them exactly what ack is needed and how to apply it.

**ABA must NEVER automatically apply admin-acks.** The gate/ack is different for every version transition — the patch command changes, and sometimes no ack is needed at all. ABA cannot predict or hardcode these. The ONLY correct action is to clearly surface the `oc adm upgrade` output to the user so they can follow the instructions.

### Suggested fix for ABA

**APPLIED — `scripts/cluster-upgrade.sh`**: When `Upgradeable=False` is detected, displays the full output of `oc adm upgrade`, warns about potential admin-ack requirement, and asks the user to confirm before proceeding. ABA does NOT attempt to parse or auto-resolve the gate.

**`scripts/day2.sh`**: No change needed — `signature-configmap.json` code is NOT dead (confirmed oc-mirror v2 produces it on con1).

### Reference

- [OCP 4.20 Sigstore docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/nodes/nodes-sigstore-using.html#nodes-sigstore-prepare-for-4.21_nodes-sigstore-using)
- [OCP 4.22 oc-mirror v2 signature mirroring](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/disconnected_environments/about-installing-oc-mirror-v2) §5.10
- [MCO PR #5558](https://github.com/openshift/machine-config-operator/pull/5558) (admin-ack implementation)

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

**Status:** NEW  
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

**Status:** NEW  
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

**Status:** NEW  
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

**Status:** NEW  
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

**Status:** NEW  
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

**Status:** NEW  
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

## Bug #405 — `_tui_reject_squote` insufficient: allows backtick/dollar/backslash injection in config fields

**Status:** NEW  
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

**Status:** NEW  
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

**Status:** NEW  
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

## Bug #413 — Bundle path input not validated (no `_tui_reject_squote`, no path check)

**Status:** NEW  
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

**Status:** NEW  
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

**Status:** NEW  
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

**Status:** NEW  
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

**Status:** VERIFIED (live test 2026-06-14)  
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

**Status:** VERIFIED (live TUI test 2026-06-14)  
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

**Status:** NEW (code review)  
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

**Status:** VERIFIED (live TUI test)  
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

**Status:** NEW (code review)  
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

**Status:** NEW (code review)  
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

**Status:** NEW (code review)  
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

**Status:** NEW (code review)  
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

**Status:** DOWNGRADED TO UX QUIRK — removed from active bug count.

---

## Bug #435 — Cluster wizard allows empty `ports` field on vmw/kvm platforms

**Status:** NEW (code review)  
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

**Status:** NEW (code review + live observation)  
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

**Status:** NEW (code review)  
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

**Status:** LIVE VERIFIED on conno — `oc-mirror version 2>&1 | grep 'environment version:'` produces empty output  
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

**Status:** NEW — Code analysis (unverified — requires candidate channel with RC as latest)  
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

**Status:** LIVE VERIFIED on conno — `fetch_all_versions candidate 5.0` returns `4.22.0, 4.22.1` (wrong minor, no pre-release)  
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

**Status:** LIVE VERIFIED on conno — `fetch_all_versions candidate 5.0` returns `4.22.0, 4.22.1` (wrong minor!)  
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

**Status:** NEW — LIVE VERIFIED in TUI on conno  
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

**Status:** LIVE VERIFIED on conno  
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

**Status:** NEW — LIVE VERIFIED on conno  
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

**Status:** NEW — VERIFIED via code analysis  
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

**Status:** CONFIRMED via code analysis  
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

**Status:** LIVE VERIFIED on conno  
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

**Status:** LIVE VERIFIED on conno  
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

**Status:** LIVE VERIFIED on conno  
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

**Status:** LIVE VERIFIED on conno  
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

**Status:** LIVE VERIFIED on conno  
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

**Status:** LIVE VERIFIED on conno  
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

**Status:** LIVE VERIFIED on conno  
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

**Status:** LIVE VERIFIED on conno  
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

## Bug #474: ~~FIXED~~ `aba --editor 'nano -w'` silently truncates value at first space (CLI)

**Status**: NEW  
**Severity**: Medium (data loss — user settings silently truncated)  
**Component**: CLI (`scripts/aba.sh`)  
**Discovered**: 2026-06-19  
**Verified**: Yes (live on conno)

### Reproduction

```
aba --editor 'nano -w'
grep editor= aba.conf
# Shows: editor=nano   (the '-w' flag is lost!)
```

### Expected behavior

`editor=nano -w` should be written (or auto-quoted: `editor='nano -w'`).

### Root cause

Line 807 in `aba.sh`:
```
replace-value-conf -n editor -v $editor -f $ABA_ROOT/aba.conf
```
`$editor` is **unquoted**, causing word-splitting. The function receives `-v nano -w -f /path` — interprets only `nano` as the value, and `-w` falls into the file list or unknown arg handling.

### Suggested fix

Quote the variable:
```
replace-value-conf -n editor -v "$editor" -f "$ABA_ROOT/aba.conf"
```

---

## Bug #475: ~~FIXED~~ `aba --vmware` / `aba --kvm` silently ignores non-existent file (CLI)

**Status**: NEW  
**Severity**: Medium (silent failure — user thinks config was applied)  
**Component**: CLI (`scripts/aba.sh`)  
**Discovered**: 2026-06-19  
**Verified**: Yes (live on conno)

### Reproduction

```
aba --vmware /tmp/this-file-does-not-exist.conf
# Exit code 0, no output, no error — vmware.conf NOT updated
```

### Expected behavior

Should error: "File '/tmp/this-file-does-not-exist.conf' not found" and exit non-zero.

### Root cause

Lines 814-815 in `aba.sh`:
```
[ -s "$2" ] && cp "$2" vmware.conf
shift 2
```
If the file doesn't exist, `[ -s "$2" ]` is false, `cp` never runs, but the command continues silently with exit code 0. Same pattern for `--kvm` (lines 817-818).

### Suggested fix

Add an explicit check:
```
if [ ! -s "$2" ]; then
    aba_abort "File '$2' not found or empty"
fi
cp "$2" vmware.conf
```

---

## Bug #476: ~~FIXED~~ `aba --platform bogus` accepts invalid platform values without validation (CLI)

**Status**: FIXED in commit 498cfeb2 — added `case` validation (vmw|kvm|bm only)
**Severity**: Medium (garbage-in, confusing downstream failures)  
**Component**: CLI (`scripts/aba.sh`)  
**Discovered**: 2026-06-19  
**Verified**: Yes (live on conno — wrote `platform=bogus` to aba.conf)

### Reproduction

```
aba --platform bogus
grep platform= aba.conf
# Shows: platform=bogus
```

### Expected behavior

Should reject with: "Invalid platform 'bogus'. Valid values: vmw, kvm, bm (or empty for bare-metal)."

### Root cause

Lines 747-750 in `aba.sh`:
```
elif [ "$1" = "--platform" -o "$1" = "-p" ]; then
    [[ "$2" =~ ^- || -z "$2" ]] && aba_abort "missing argument after option $1"
    replace-value-conf -n platform -v "$2" -f $ABA_ROOT/aba.conf
    shift 2
```
No validation against valid values (vmw, kvm, bm, or empty).

### Suggested fix

Add validation:
```
case "$2" in
    vmw|kvm|bm) replace-value-conf -n platform -v "$2" -f "$ABA_ROOT/aba.conf" ;;
    *) aba_abort "invalid platform '$2' (valid: vmw, kvm, bm)" ;;
esac
```

---

## Bug #477: `aba cluster --starting-ip 999.999.999.999` accepted (invalid octets, CLI)

**Status**: NEW  
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

## Bug #478: ~~FIXED~~ `int_connection` validation regex accepts substring matches (include_all.sh)

**Status:** FIXED — added `-x` (whole-line match) and quoted `$int_connection`

**Status**: NEW  
**Severity**: Very Low (unlikely to hit in practice, but technically incorrect validation)  
**Component**: `scripts/include_all.sh` (verify-cluster-conf)  
**Discovered**: 2026-06-19  
**Verified**: Yes (`echo indirect | grep -q -E "none|proxy|direct"` → matches)

### Reproduction

```
# In cluster.conf: int_connection=indirect
# verify-cluster-conf would NOT flag this as invalid because:
echo "indirect" | grep -q -E "none|proxy|direct"  # Returns 0 ("direct" is a substring)
```

### Expected behavior

Should reject any value that isn't exactly `none`, `proxy`, or `direct`.

### Root cause

Line 1018 in `include_all.sh`:
```
echo $int_connection | grep -q -E "none|proxy|direct"
```
Uses unanchored grep alternation — matches substrings. `indirect` contains `direct`, `nonevent` contains `none`.

### Suggested fix

Anchor the regex:
```
echo "$int_connection" | grep -qxE "none|proxy|direct"
```
(The `-x` flag matches whole line only.)

---

## Bug #479: ~~FIXED~~ `aba register` port parsing breaks when pull secret has hostname without port

**Status**: FIXED (commit 7707f582 — check for colon before splitting, default port 443)  
**Severity**: Medium (corrupts mirror.conf — sets reg_port to the hostname string)  
**Component**: `scripts/reg-register.sh`  
**Discovered**: 2026-06-19  
**Verified**: Yes (live on conno — registered with `registry.example.com`, got `reg_port=registry.example.com`)

### Reproduction

```
echo '{"auths":{"registry.example.com":{"auth":"dGVzdDp0ZXN0"}}}' > /tmp/ps.json
echo 'FAKE CA' > /tmp/ca.pem
aba -d mirror register --pull-secret-mirror /tmp/ps.json --ca-cert /tmp/ca.pem
# Output: "Existing registry registered: registry.example.com:registry.example.com"
```

### Expected behavior

When the pull secret hostname has no port, `reg_port` should default to 443 (HTTPS default) or prompt the user.

### Root cause

Lines 50 and 62 in `reg-register.sh`:
```
_inferred_port="${_ps_keys##*:}"
reg_port="${_ps_keys##*:}"
```
Bash parameter expansion `${var##*:}` removes everything up to and including the last `:`. When there IS no `:` in the string, NOTHING is removed — the entire string is returned. So if `_ps_keys=registry.example.com` (no port), `_inferred_port` gets `registry.example.com`.

### Suggested fix

Check if the key contains a colon before splitting:
```
if [[ "$_ps_keys" == *:* ]]; then
    _inferred_host="${_ps_keys%%:*}"
    _inferred_port="${_ps_keys##*:}"
else
    _inferred_host="$_ps_keys"
    _inferred_port="443"
fi
```

---

## Bug #480: ~~FIXED~~ `aba -d mirror install/uninstall/verify --help` shows wrong help page

**Status**: NEW  
**Severity**: Low (UX confusion — shows general aba help instead of mirror-specific help)  
**Component**: CLI (`scripts/aba.sh`) help routing  
**Discovered**: 2026-06-19  
**Verified**: Yes (live on conno)

### Reproduction

```
aba -d mirror install --help   # Shows GENERAL aba help (wrong)
aba -d mirror uninstall --help # Shows GENERAL aba help (wrong)
aba -d mirror verify --help    # Shows GENERAL aba help (wrong)
aba -d mirror load --help      # Shows MIRROR help (correct)
aba -d mirror sync --help      # Shows MIRROR help (correct)
aba -d mirror register --help  # Shows MIRROR help (correct)
```

### Expected behavior

All should show the mirror-specific help text starting with "Install 'Mirror Registry for Red Hat OpenShift'".

### Root cause

`install`, `uninstall`, and `verify` are also recognized as TOP-LEVEL aba commands (e.g., `aba install` installs ABA itself, `aba verify` verifies the mirror). When the CLI parser encounters `--help` after these keywords, it triggers the general help display because the keyword is matched at the global level before the `-d mirror` context is fully applied.

`load`, `sync`, `save`, and `register` are mirror-only commands (no top-level equivalent), so they correctly fall through to the mirror-specific help handler.

### Suggested fix

When `--help` is present and `-d mirror` was specified, force the mirror help display regardless of the subcommand.

---

## Bug #481: ~~FIXED~~ "Prepare Upgrade for Transfer" dialog shows misleading hardcoded example version (TUI)

**Status:** FIXED — current code uses dynamic version list from mirror; no hardcoded example remains

**Status**: NEW  
**Severity**: Low (UX confusion — example version can be lower than current)  
**Component**: TUI (`tui/v2/tui-mirror.sh`)  
**Discovered**: 2026-06-19  
**Verified**: Yes (live TUI on conno — showed "e.g. 4.21.16" when current was 4.21.19)

### Reproduction

1. Launch TUI in CONNO mode with `ocp_version=4.21.19`
2. Select "Prepare Upgrade for Transfer" (U)
3. Dialog shows: "Current installed version: 4.21.19" and example "(e.g. 4.21.16)"

### Expected behavior

Example version should always be HIGHER than the current version to avoid confusion. For example, if current is 4.21.19, example should show "4.22.0" or "4.21.20".

### Root cause

Lines 510 and 524 in `tui-mirror.sh` have hardcoded `4.21.16`:
```
--inputbox "\nCurrent installed version: ${_current_ver}\n\nEnter target upgrade version:\n(e.g. 4.21.16)" \
```
The example doesn't adapt to the current version.

### Suggested fix

Compute a dynamic example (next minor version):
```
local _example_ver="$((${_current_ver%%.*} )).$(( ${_current_ver#*.} + 1 )).0"
# Or simpler: always use next .0 minor
```

---

## Bug #482: ~~DUPLICATE OF Bug #446~~ TUI upgrade prep blocks RC→GA upgrades (numeric comparison strips suffix)

**Status**: DUPLICATE of Bug #446 (same root cause: version comparison strips suffix)  
**Severity**: Medium (blocks legitimate upgrade path from RC/EC to GA in TUI)  
**Component**: TUI (`tui/v2/tui-mirror.sh`)  
**Discovered**: 2026-06-19  
**Verified**: By code analysis (lines 530-543)

### Reproduction

1. Set `ocp_version=4.21.0-rc.1` in aba.conf
2. Launch TUI, select "Prepare Upgrade for Transfer"
3. Enter target version: `4.21.0`
4. Error: "Target version '4.21.0' must be higher than current version '4.21.0-rc.1'"

### Expected behavior

`4.21.0` (GA) IS a valid upgrade from `4.21.0-rc.1` (pre-release). The dialog should accept it.

### Root cause

Lines 532-538 in `tui-mirror.sh`:
```
local _cur_clean="${_current_ver%%-*}"   # 4.21.0-rc.1 → 4.21.0
local _tgt_clean="${_target_ver%%-*}"     # 4.21.0 → 4.21.0
IFS='.' read -r ... <<< "$_cur_clean"
IFS='.' read -r ... <<< "$_tgt_clean"
local _cur_num=$(( ... ))                 # Both = 4021000
local _tgt_num=$(( ... ))                 # Both = 4021000
if [[ $_tgt_num -le $_cur_num ]]; then    # 4021000 <= 4021000 → BLOCKED!
```
By stripping the pre-release suffix, RC and GA versions become numerically equal. The `<=` comparison then rejects the upgrade.

### Suggested fix

When versions are numerically equal, check if current has a pre-release suffix and target does not (meaning RC→GA upgrade):
```
if [[ $_tgt_num -lt $_cur_num ]]; then
    # Definite downgrade
    ...reject...
elif [[ $_tgt_num -eq $_cur_num ]]; then
    # Same base version — allow if upgrading from pre-release to GA
    if [[ "$_current_ver" == *-* && "$_target_ver" != *-* ]]; then
        break  # RC→GA is a valid upgrade
    fi
    ...reject...
fi
```

---

## Bug #483: ~~DUPLICATE~~ Cluster wizard platform toggle immediately persists to aba.conf (TUI side-effect on cancel)

**Status:** DUPLICATE of Bug #338 — platform is a global setting, written immediately by design (required for `aba cluster --step cluster.conf` to generate correct defaults)

**Status**: NEW  
**Severity**: Medium (global config mutation occurs even if user cancels the wizard)  
**Component**: TUI (`tui/v2/tui-cluster.sh`, line ~991)  
**Discovered**: 2026-06-19  
**Verified**: By code analysis (line 991 in `_cluster_page_basics`)

### Reproduction

1. Launch TUI, enter cluster wizard (Install Cluster → configure new cluster)
2. On the "Basics" page, toggle Platform from `bm` to `vmw`
3. Press ESC or Back to cancel the wizard

### Expected behavior

Cancelling the wizard should discard all changes. `aba.conf` should remain unchanged.

### Observed behavior

`aba.conf` now has `platform=vmw` even though the wizard was cancelled. This happens because the platform toggle at line 991 immediately calls:
```
replace-value-conf -q -n platform -v "$cl_platform" -f "$ABA_ROOT/aba.conf"
```
Every toggle press writes to `aba.conf` immediately.

### Impact

- Global config (`aba.conf`) is mutated even when the user cancels
- The platform setting affects OTHER operations (e.g., ISC generation, cluster creation)
- Confusing: user cancels but their environment has changed

### Root cause

The cluster wizard's platform toggle (line 991 of `tui-cluster.sh`) writes to `aba.conf` on every toggle press. In contrast, the DIRECT wizard's platform selection (line 680 of `tui-direct.sh`) correctly defers the write until the wizard completes.

### Suggested fix

Remove the immediate write at line 991. Let the platform change be persisted only when:
1. The user advances past page 1 (Next button), OR
2. At `_persist_cluster_draft()` time (line 196) where the wizard's final state is saved

```bash
# REMOVE this line from the T case:
# replace-value-conf -q -n platform -v "$cl_platform" -f "$ABA_ROOT/aba.conf"
```

The platform will be persisted later by `_cluster_generate_defaults()` / `_persist_cluster_draft()` which already runs `aba cluster --platform $cl_platform`.

---

## Bug #484: ~~FIXED~~ CONNO Help text describes non-existent "Load" operation and omits "Prepare Upgrade" (TUI)

**Status:** FIXED in commit 7312797d (Bug #469 — same fix as Bug #424)

**Status**: NEW (extends Bug #469)  
**Severity**: Low (Help text inaccuracy — confusing but not harmful)  
**Component**: TUI (`tui/v2/abatui2.sh`, CONNO Help text)  
**Discovered**: 2026-06-19  
**Verified**: Yes (live TUI test and code review)

### Reproduction

1. Launch TUI in CONNO mode
2. Press "Help" on the main menu
3. Compare Help text with actual menu items

### Discrepancies found

**Help says "Load — disk-to-mirror (d2m)" — but CONNO menu has NO "Load" item!**
"Load" is exclusive to DISCO mode. CONNO mode uses "Sync" (m2m) instead.

**Help omits "Prepare Upgrade for Transfer" (U) — which IS in the menu!**
This is an important operation for preparing upgrade bundles, completely undocumented in Help.

### Root cause

Help text hardcodes the operation list without matching the actual menu items. Lines in `abatui2.sh`:
```
Transfer (uses oc-mirror):
  • Sync — mirror-to-mirror (m2m): push images directly to registry
  • Save — mirror-to-disk (m2d): download images to local archive
  • Load — disk-to-mirror (d2m): load saved images into registry    ← WRONG for CONNO
  • Install Bundle — create a portable bundle (tar) for USB transfer
```

### Suggested fix

Remove "Load" from CONNO Help (it belongs only in DISCO Help). Add "Prepare Upgrade for Transfer" to the Transfer section.

---

## Bug #485: ~~FIXED~~ Settings Help missing "Retry Count" documentation and has stale "2 or 8" values (TUI)

**Status**: NEW (extends Bug #398)  
**Severity**: Low (Help text incomplete/stale)  
**Component**: TUI (`tui/v2/tui-lib.sh`, lines 1185-1189)  
**Discovered**: 2026-06-19  
**Verified**: Yes (live TUI test confirmed help shows incomplete info, and code analysis confirms cycle is OFF/1/2/5 not "2 or 8")

### Reproduction

1. Launch TUI → Configure → Help button
2. Note the Help text for "Retry Count"

### Expected Help content

Should describe the actual toggle cycle: OFF → 1 → 2 → 5 → OFF

### Observed Help text

```
Retry Count:
  How many times to retry failed oc-mirror operations.
  OFF = no retries, 2 or 8 = retry that many times.
```

### Issues

1. Says "2 or 8" but cycle is OFF/1/2/5 — value `8` doesn't exist, `5` is not mentioned, `1` is not mentioned
2. Doesn't explain the toggle behavior (cycle through predefined values)
3. Dead code: `_tui_settings_menu_retry()` (line 1102) exists but is never called — leftover from input-box design

### Root cause

Help text at line 1189 was written for an earlier implementation and never updated when the toggle cycle was changed from `0, 2, 8` to `0, 1, 2, 5`.

---

## Bug #486: TUI mirror verify cache not invalidated when `ocp_version` changes via CLI

**Status**: NEW  
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

## Bug #487: `is_version_greater()` incorrectly handles RC/pre-release versions

**Status**: FIXED (commit a8b0e76 — "feat: semver-aware version resolution with pre-release support")  
**Severity**: MEDIUM — Incorrect version comparison for pre-release  
**Component**: Core (`scripts/include_all.sh`, line ~1397)  
**Discovered**: 2026-06-23  
**Fixed**: 2026-06-23 — `is_version_greater '4.21.0-rc.2' '4.21.0'` now correctly returns FALSE (rc < GA)  
**Verified**: Yes (live test on conno: `is_version_greater '4.21.0-rc.2' '4.21.0'` returns TRUE)

### Reproduction

```bash
source scripts/include_all.sh
is_version_greater '4.21.0-rc.2' '4.21.0' && echo "BUG: thinks rc.2 > GA"
```

Output: `BUG: thinks rc.2 > GA`

### Root cause

`is_version_greater` uses `sort -V` which treats `-rc.2` as a later version suffix (standard version sort considers hyphenated suffixes as extensions). Semantically, `4.21.0-rc.2` is a **pre-release** of `4.21.0` and should be LESS than the GA version.

### Impact

In the TUI upgrade dialog (`_day2_upgrade`, uncommitted code), the downgrade check at line 2369 uses `is_version_greater`. A user could "upgrade" from GA `4.21.0` to RC `4.21.0-rc.2` without being blocked, which is actually a downgrade.

### Suggested fix

Add pre-release awareness: strip the pre-release suffix for base comparison, and if base versions are equal, treat the one WITH a suffix as LESS than the one WITHOUT.

---

## Bug #488: `_upgrade_preflight_check` uses non-existent `./kubeconfig` path (uncommitted code)

**Status**: CONFIRMED (committed in 9e024a6)  
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

**Status**: NEW  
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

**Status**: NEW  
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

**Status**: NEW  
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

**Status**: CONFIRMED STILL OPEN (re-verifying Bug #472)  
**Severity**: LOW  
**Component**: CLI (`scripts/aba.sh`)  
**Discovered**: 2026-06-23  
**Verified**: Yes (live test on conno: `aba --channel eus` → accepted, wrote to aba.conf)

### Note

Bug #472 was reported previously. Re-verified on 2026-06-23 that it's still open on the dev branch. The `--channel` handler accepts `eus` (and presumably any string that matches the case statement), but `eus` is later silently converted to `stable` at line 1463 (`[ "$ocp_channel" = "eus" ] && ocp_channel=stable`). This silent conversion is confusing — better to reject at the CLI handler level.

---

## Bug #493: `_day2_status()` uses hardcoded `iso-agent-based/auth/kubeconfig` path (TUI)

**Status**: NEW  
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

## Bug #494: CRITICAL — TUI Install Cluster overwrites SNO type with standard (3 masters, 2 workers)

**Status**: FIXED in local HEAD (93e73336) — `setup-cluster.sh` line 13 now has `type=` (empty)  
**Severity**: CRITICAL — Creates wrong number of VMs (5 instead of 1 for SNO)  
**Component**: TUI + Core (`tui/v2/tui-cluster.sh` + `scripts/setup-cluster.sh`)  
**Discovered**: 2026-06-23  
**Verified**: Yes (RE-CONFIRMED at commit a8b0e76 on deployed conno code: `type=standard` default caused overwrite)  
**Fix confirmed**: Local HEAD (93e73336) has `type=` (empty) on line 13, so `if [ "$type" ]` guard on line 65 is FALSE → no overwrite.  
**Note**: Bug was introduced by commit fdcc119, fixed by a later commit before 93e73336. Deployed code on conno STILL has the old `type=standard` (needs `run.sh deploy` to push fix).

### Reproduction

1. Launch TUI → Install Cluster
2. Set cluster name: "sno", type: "sno"
3. Complete wizard → Press "Install"
4. Observe output: `[ABA] Updated sno/cluster.conf: num_masters=3 num_workers=2`

### Root cause

The TUI runs `aba cluster --name sno --step install` WITHOUT passing `--type sno`. In `scripts/setup-cluster.sh`:

1. Line 13: `type=standard` (default)
2. Line 15: `process_args` receives `name=sno step=install` — no `type` override
3. Line 65: `if [ "$type" ] && [ -z "$num_masters" ]` → TRUE (type=standard, num_masters empty)
4. Line 69: Maps standard → `num_masters=3; num_workers=2`
5. Lines 88-89: Writes these values to cluster.conf, OVERWRITING the TUI's correct `num_masters=1 num_workers=0`

### Impact

- SNO clusters get 5 VMs (3 masters + 2 workers) instead of 1
- Compact clusters get 5 VMs instead of 3
- Only "standard" type works correctly (it's the default!)
- Wastes compute resources and may fail due to insufficient capacity

### Suggested fix

The TUI should pass `--type` to the install command:
```bash
# In tui/v2/tui-cluster.sh, when building the install command:
local _cmd="aba cluster --name $cl_name --type $cl_type --step install"
```

OR fix `setup-cluster.sh` to NOT override existing cluster.conf values when they're already set:
```bash
# Line 65: Only map type if cluster.conf doesn't already have num_masters set
if [ "$type" ] && [ -z "$num_masters" ]; then
    # Also check if cluster.conf already has the value
    existing_nm=$(grep '^num_masters=' cluster.conf 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ')
    [ "$existing_nm" ] && num_masters="" || ...
fi
```

---

## Bug #495: Bundle+internet dialog ESC/Help destructively removes .bundle marker

**Status**: NEW (code analysis confirmed)  
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

**Status**: NEW (code analysis confirmed)  
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

**Status**: NEW  
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

**Status**: NEW (code confirmed)  
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

**Status**: NEW (code confirmed)  
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

**Status**: NEW (live reproduced)  
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

**Status**: NEW (live reproduced)  
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

**Status**: NEW (live reproduced)  
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

**Status**: NEW (code analysis confirmed)  
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

## Bug #497: DIRECT "Use existing" pull secret skips JSON validation

**Status**: NEW (code analysis confirmed)  
**Severity**: LOW — Corrupt pull secret causes late failure at install time  
**Component**: TUI (`tui/v2/tui-direct.sh`, line ~220)  
**Discovered**: 2026-06-23  
**Verified**: Code confirmed

### Description

In `_direct_pull_secret()`, when the pull secret file already exists, the dialog offers
"Use existing" vs "Enter new". Selecting "Use existing" does `return 0` immediately
without validating the JSON content.

If the file was manually edited or corrupted, the TUI proceeds with invalid pull secret.
The error only surfaces later at cluster install time with a confusing error.

### Impact

Low — rare scenario (file must exist but be corrupt). However, the "Enter new" path
validates JSON, creating inconsistency.

### Suggested fix

Add `jq empty "$ps_file" 2>/dev/null || { show error; prompt for new }` before `return 0`.

---

## Bugs confirmed FIXED on dev branch (2026-06-23)

| Bug # | Description | Status |
|-------|-------------|--------|
| #462 | `aba tui` exits silently | **FIXED** — now launches TUI correctly |
| #474 | `aba --editor 'nano -w'` drops space-containing values | **FIXED** — correctly saves `editor='nano -w'` |
| #475 | `aba --vmware /nonexistent` accepted | **FIXED** — rejects with "file not found or empty" |
| #476 | `aba --platform bogus` accepted | **FIXED** — rejects with "invalid platform" |
| #480 | `aba -d mirror install --help` shows generic help | **FIXED** — shows mirror install-specific help |

---

## Test Flows Attempted (2026-06-23)

| Flow | Status | Notes |
|------|--------|-------|
| TUI CONNO mode - splash → main menu | PASS | Correctly shows mode and version |
| TUI CONNO mode - mirror state display | FAIL (Bug #486) | Showed "synced" with stale cache |
| TUI CONNO mode - Install Cluster gate | PASS | Correctly detected missing release images |
| TUI CONNO mode - Advanced → Platform Settings (VMware) | PASS | VMware config loaded from project file |
| TUI CONNO mode - VMware Test Connection | PASS | ESXi 7.0.3 connected successfully |
| TUI CONNO mode - VMware config from scratch (no ~/.vmware.conf) | PARTIAL (Bug #7) | Values loaded from project file, ~/.vmware.conf recreated on Continue |
| TUI CONNO mode - Sync confirmation dialog | FAIL (Bug #490) | Misleading version range from stale ISC |
| TUI CONNO mode - Rerun Wizard → Channel → Candidate → Manual RC | PASS | Correctly accepted 4.21.0-rc.2 |
| CLI - `aba --version 4.21.0-rc.2` | FAIL (Bug #489) | Channel not auto-set to candidate |
| CLI - `aba --channel eus` | FAIL (Bug #492) | Invalid channel accepted |
| CLI - `aba --platform bogus` | PASS (FIXED since Bug #476) | Now correctly rejects invalid platform |
| CLI - `aba --type sno cluster --name X` | FAIL (Bug #491) | Arg order dependency |
| CLI - `is_version_greater` with RC versions | PASS (Bug #487 FIXED) | RC < GA comparison now correct |
| Code review - `_upgrade_preflight_check` | FAIL (Bug #488) | Wrong kubeconfig path |
| TUI CONNO mode - Install Cluster wizard (4 pages) | FAIL (Bug #494) | Created correctly via wizard, corrupted on execution |
| TUI CONNO mode - Delete Cluster (sno.example.com) | PASS | Deleted successfully (no VMs to remove) |
| TUI CONNO mode - Day-2 menu | PASS | All options displayed correctly |
| TUI CONNO mode - Cluster Status (no clusters) | PASS | Shows "No installed clusters found" |
| TUI CONNO mode - Save Images confirmation | PASS | Shows correct version and operator list |
| TUI CONNO mode - Create Bundle (full) | PASS but Bug #498 | ESC on light/full dialog triggers full bundle |
| TUI CONNO mode - Bundle execution | PASS | 56GB bundle created successfully |
| TUI CONNO mode - Advanced menu + Help | PASS | All items and help text correct |
| TUI CONNO mode - VMware Test Connection | PASS | ESXi 7.0.3 verified |
| Code review - `_day2_status()` kubeconfig | FAIL (Bug #493) | Hardcoded iso-agent-based/auth/kubeconfig |
| Code review - Bundle ESC handling | FAIL (Bug #495, #498) | ESC treated as No on yesno dialogs |
| Code review - DISCO light-bundle first-run | FAIL (Bug #496) | Exits TUI instead of retry |
| Code review - archive detection mismatch | FAIL (Bug #499) | Different globs in validate vs has_archives |
| Code review - DIRECT help accuracy | FAIL (Bug #500) | Mentions Monitor not in menu |
| Code review - CONNO wizard cancel | FAIL (Bug #501) | Silent exit on first-run cancel |
| CLI - Bug #494 reproduced | FAIL (CRITICAL) | aba cluster --name sno --step install overwrites SNO to standard |
| TUI CONNO mode - Bug #494 LIVE reproduction | FAIL (CRITICAL) | TUI shows "sno (1 master, 0 workers)" then runs `aba cluster --name sno --step install` which outputs "num_masters=3 num_workers=2" |
| TUI CONNO mode - Title bar stale version | FAIL (Bug #502) | External aba.conf change (candidate 4.22.2 → stable 4.20.20) not reflected until Rerun Wizard |
| TUI CONNO mode - Wizard version picker cross-channel | FAIL (Bug #503) | Shows "Current (4.22.2)" in stable channel where it doesn't exist (latest stable is 4.22.1) |
| TUI CONNO mode - Platform ✓ false positive | FAIL (Bug #504) | KVM shows ✓ with template values (kvm-user@kvmhost.lan) because check is file-exists-only |
| TUI CONNO mode - Cluster status vs Delete inconsistency | PASS | Correct: status=running clusters, delete=all dirs |
| TUI CONNO mode - Operator search + basket | PASS | Search, add, remove all work correctly |
| TUI CONNO mode - Configure settings toggle | PASS | Registry cycles Docker→Auto→Quay correctly |
| TUI CONNO mode - Prepare Upgrade (4.20.20→4.20.23) | PASS | Clear summary, proper version picker |
| TUI CONNO mode - SNO install via CLI (workaround) | IN PROGRESS | Bootstrap complete, cluster initializing (69%+) |
| TUI CONNO mode - Prepare Upgrade save complete | PASS | 45GB tar created, upgrade images ready dialog shown |
| TUI CONNO mode - Day-2 menu (no clusters yet) | PASS | "No installed clusters found" correctly shown |
| Code review - `filter_disco_values()` dead code | FAIL (Bug #505) | Defined but never called — DISCO mode doesn't filter public DNS/NTP |
| Code review - page 1 edits overwritten | FAIL (Bug #506) | `_cluster_generate_defaults` silently overwrites domain and worker count |

---

## Bug #506: Cluster wizard page 1 edits (domain, worker count) silently overwritten — FIXED

**Status**: FIXED (2026-06-24)  
**Severity**: MEDIUM — User-entered values are lost without warning  
**Component**: TUI (`tui/v2/tui-cluster.sh`, `_cluster_generate_defaults()`, lines 185-212)  
**Discovered**: 2026-06-23  

### Description

When the user edits `base_domain` or `worker count` on page 1 of the cluster wizard and presses
"Next", the function `_cluster_generate_defaults()` (line 727) runs which:

1. Calls `aba cluster --name $cl_name --type $cl_type --platform $cl_platform --step cluster.conf --yes`
2. Then calls `_cluster_load_conf()` to load the generated/existing file back into local variables

The problem: `_cluster_load_conf` overwrites ALL `cl_*` variables from the file, including
`cl_domain` and `cl_workers`. Since the TUI command doesn't pass `--domain` or `--workers`,
the file retains its old/default values, and the user's edits are silently discarded.

### Reproduction

1. Start TUI → CONNO → Install Cluster
2. On page 1 (Basics), change "Base domain" from `example.com` to `custom.lab`
3. Press "Next"
4. Navigate forward to the review page (page 5)
5. **Expected**: Review shows `sno.custom.lab`
6. **Actual**: Review shows `sno.example.com` — user's domain edit was silently lost

Same bug for worker count:
1. Set type to "standard", change worker count to 6
2. Press "Next"
3. Review page shows 2 workers (the default)

### Root cause

Lines 725-729 of `tui-cluster.sh`:
```bash
_gate_platform_config || continue
_cluster_generate_defaults || continue   # <--- overwrites cl_domain, cl_workers
_apply_mode_connection
_persist_cluster_draft                    # <--- writes the overwritten values!
```

Inside `_cluster_generate_defaults` (lines 185-209):
```bash
_cluster_generate_defaults() {
    local _conf="$ABA_ROOT/$cl_name/cluster.conf"
    local _cmd="aba cluster --name $cl_name --type $cl_type --platform $cl_platform --step cluster.conf --yes"
    # ... runs the command ...
    if [[ -f "$_conf" ]]; then
        _cluster_load_conf "$_conf"   # <--- THIS overwrites cl_domain and cl_workers!
    fi
}
```

### Affected fields

Only fields NOT passed as CLI args to `_cluster_generate_defaults`:
- `cl_domain` (base_domain) — always affected
- `cl_workers` (num_workers) — affected when type=standard

Fields that ARE preserved (passed via CLI):
- `cl_name` (--name)
- `cl_type` (--type)
- `cl_platform` (--platform)

### Suggested fix

Option A: Persist user changes BEFORE calling `_cluster_generate_defaults`:
```bash
_gate_platform_config || continue
_persist_cluster_draft               # <--- save user edits to file FIRST
_cluster_generate_defaults || continue
_apply_mode_connection
```

Option B: Only call `_cluster_load_conf` for NEWLY created files:
```bash
_cluster_generate_defaults() {
    local _conf="$ABA_ROOT/$cl_name/cluster.conf"
    local _was_new=false
    [[ ! -f "$_conf" ]] && _was_new=true
    # ... run aba cluster ...
    if [[ "$_was_new" == "true" && -f "$_conf" ]]; then
        _cluster_load_conf "$_conf"
    fi
}
```

Option C: Pass --domain and --workers to the command:
```bash
local _cmd="aba cluster --name $cl_name --type $cl_type --platform $cl_platform"
_cmd+=" --domain $cl_domain"
[[ "$cl_type" == "standard" ]] && _cmd+=" --workers $cl_workers"
_cmd+=" --step cluster.conf --yes"
```

### Fix applied (hybrid of B + C)

1. Track whether file is new: `local _was_new=false; [[ ! -f "$_conf" ]] && _was_new=true`
2. Pass domain via CLI: `[[ -n "$cl_domain" ]] && _cmd+=" --domain $cl_domain"`
3. Only reload for NEW files: `if [[ "$_was_new" == "true" && -f "$_conf" ]]; then`

Verification:
- Unit tests: 6/6 pass (existing cluster domain/type/workers preserved, new cluster with custom domain, new cluster with default, file integrity)
- Live TUI test on conno: changed domain from `example.com` → `bugtest.lab`, pressed Next (triggers generate), went Back — domain correctly shows `bugtest.lab`. Confirmed persisted to `cluster.conf`.

---

## Bug #505: `filter_disco_values()` is dead code — DISCO mode NTP/DNS never filtered

**Status**: NEW (code analysis confirmed)  
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

## Bug #507: "Prepare Upgrade for Transfer" missing [No internet] label in CONNO menu

**Status**: NEW (code confirmed, live verified)  
**Severity**: LOW — UX inconsistency, handler correctly blocks the action  
**Component**: TUI (`tui/v2/abatui2.sh`, lines 513-522, 577)  
**Discovered**: 2026-06-23  
**Verified**: Live on conno — menu item shows plain label when Internet is down

### Description

In the CONNO main menu, when Internet connectivity is unavailable, the following items
correctly receive the `$TUI2_STATUS_NO_INTERNET` suffix (e.g. "[No internet]"):
- Save images to disk
- Sync images to mirror
- Select Operators
- Create Install Bundle

However, "Prepare Upgrade for Transfer" does NOT receive this suffix. Its label is
hardcoded at line 577:
```bash
"$TUI2_CONNO_TAG_PREP_UPGRADE"   "Prepare Upgrade for Transfer"
```

The handler at lines 664-669 correctly checks `_TUI_INET` and shows a msgbox when
the user selects it without Internet, so functionality is correct. But the label
is inconsistent with other internet-dependent items — the user sees a clean label
that implies the item is available.

### Root cause

When building the no-internet label overrides (lines 513-522), `TUI2_CONNO_TAG_PREP_UPGRADE`
was not included in the list:
```bash
if [[ "$_TUI_INET" == "no" ]]; then
    save_avail=false; save_label="..."
    sync_avail=false; sync_label="..."
    ops_avail=false; ops_label="..."
    bndl_avail=false; bndl_label="..."
    # MISSING: prep_upgrade_avail=false; prep_upgrade_label="..."
fi
```

### Suggested fix

Add a `prep_upgrade_label` variable alongside the others:
```bash
local prep_upgrade_label="Prepare Upgrade for Transfer"
if [[ "$_TUI_INET" == "no" ]]; then
    ...
    prep_upgrade_label="Prepare Upgrade for Transfer $TUI2_STATUS_NO_INTERNET"
fi
# ... later in items array:
"$TUI2_CONNO_TAG_PREP_UPGRADE"   "$prep_upgrade_label"
```

---

## Bug #508: `_day2_upgrade` dry-run hides errors — empty version list with no diagnostics

**Status**: NEW (code analysis)  
**Severity**: MEDIUM — User gets "No available upgrade versions" with no clue why  
**Component**: TUI (`tui/v2/tui-cluster.sh`, line 2257)  
**Discovered**: 2026-06-23

### Description

In `_day2_upgrade()`, the available upgrade versions are fetched via:
```bash
_versions_raw=$(aba --dir "$SELECTED_CLUSTER" upgrade --dry-run 2>&1) || true
```

The `|| true` swallows any non-zero exit code (e.g., cluster unreachable, kubeconfig invalid,
registry down). The parser then tries to find "Versions in mirror" in the output. If the
command fails entirely (e.g., "error: no configuration found"), no versions are parsed,
and the user sees a generic "No available upgrade versions found" message.

The `2>&1` merges stderr into `_versions_raw` which is good for the Help button ("show raw
output"). But the `|| true` means the function doesn't distinguish between "no newer
versions exist" (correct) and "command failed catastrophically" (actionable error).

### Impact

When `aba upgrade --dry-run` fails (cluster down, auth error, mirror unreachable), the user
sees a misleading "No available upgrade versions" dialog with mode-specific hints about
syncing/loading — none of which address the actual problem (connectivity/auth).

### Suggested fix

Check exit code and show a distinct error dialog when the command fails:
```bash
local _dry_run_rc=0
_versions_raw=$(aba --dir "$SELECTED_CLUSTER" upgrade --dry-run 2>&1) || _dry_run_rc=$?

if [[ $_dry_run_rc -ne 0 && ${#_versions[@]} -eq 0 ]]; then
    dlg --backtitle "$(ui_backtitle)" --title "Upgrade Check Failed" \
        --msgbox "Failed to query available versions (exit $dry_run_rc).\n\n...\n\n$_versions_raw" 0 0
    return 1
fi
```

---

## Bug #509: Operator set swap (same basket size) bypasses dirty detection — ISC not regenerated

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

## Bug #511: Upgrade manual version entry — Cancel after invalid input shows spurious "not found" error

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

## Bug #512: `mirror_prep_upgrade` persists target version BEFORE user confirms save

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

## Bug #514: MAC address validation error clears ALL previously valid addresses

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

## Bug #515: Day-2 "Startup" dialog says "power on VMs" for bare-metal clusters

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

## Bug #516: Settings menu shows stale registry vendor after mirror config change

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
**Status:** Partially fixed — works for subsequent `confirm_and_execute` calls, but retry within the SAME call still shows the dialog

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

## Bug #529: TUI NTP/DNS dialogs accept space-separated input without normalizing to commas — FIXED

**Status**: FIXED (2026-06-24, commit `07f6ec18`)  
**Severity**: MEDIUM — Causes install failure: "ntp_servers is invalid [10.0.1.8 ntp.example.com]"  
**Component**: TUI (`tui/v2/tui-cluster.sh`, network page DNS/NTP inputs)

### Description

When a user enters space-separated NTP or DNS values (e.g. `10.0.1.8 ntp.example.com`), the TUI stores the value as-is. The validator `_valid_ip_or_host_list` uses `tr -d ' '` which merges entries into one string that passes the hostname regex. The resulting value with spaces gets auto-quoted by `replace-value-conf` → `ntp_servers='10.0.1.8 ntp.example.com'` in cluster.conf. Later, `aba cluster --step install` fails: "ntp_servers is invalid".

### Fix

Added normalization (`tr -s ' ,' ',' | sed 's/^,//; s/,$//'`) after reading from dialog, before validation, for both DNS and NTP inputs. Spaces are converted to commas, duplicates collapsed, leading/trailing commas trimmed.

### Verification

- 10/10 unit tests pass (space-separated, comma+space, multiple spaces, single value, empty, invalid)
- Live TUI test on conno: entered "10.0.1.8 ntp.example.com" → displayed as "10.0.1.8,ntp.example.com" in menu
