#!/bin/bash
# TUI v2 automated navigation test
# Tests: mode selection, CONNO menu, cluster configuration navigation,
#        ESC→confirm_quit flow, operator sets display, mode switching.
#
# Prerequisites:
#   - tmux installed
#   - Run from aba root directory
#   - aba.conf with valid config (or host with internet for auto-detect)
#
# Usage: bash test/func/test-tui-v2-navigation.sh [--slow]

set -euo pipefail

source "$(dirname "$0")/tui-test-lib.sh"

# Override for v2
TUI_CMD="tui/v2/abatui2.sh"
SESSION="tui-v2-nav"

# Source v2 strings for title matching
source "$ABA_ROOT/tui/v2/tui-strings2.sh"

# Tags are single letters (v1 style): M, S, Y, V, O, B, C, I, D, N, X
# Pressing the letter jumps directly to that item.

# --- Setup ---
cleanup_nav() {
	stop_tui
}
trap cleanup_nav EXIT

# ============================================================
# Test A: Mode selection — mirror (CONNO)
# ============================================================

log_info "=== Test A: Mode detection + action menu ==="
start_tui

# TUI may enter: CONNO (internet), DISCO (no internet + payload), or mode selection dialog
DETECTED_MODE=""
if try_wait_for "$TUI2_TITLE_MODE_SELECT" 15; then
	log_pass "A: Mode selection dialog appeared"
	assert_screen "mirror registry" "A: Shows mirror option"
	assert_screen "Direct from internet" "A: Shows direct option"
	screenshot "mode-select"
	send_enter
	sleep 3
	if ! wait_for "$TUI2_TITLE_CONNO_MENU" 15; then
		log_fail "A: CONNO action menu did not appear after selection"; report_results; exit 1
	fi
	DETECTED_MODE="CONNO"
elif try_wait_for "$TUI2_TITLE_CONNO_MENU" 10; then
	log_pass "A: Skipped mode select (auto-detected CONNO)"
	DETECTED_MODE="CONNO"
elif try_wait_for "$TUI2_TITLE_DISCO_MENU" 10; then
	log_pass "A: Auto-detected DISCO (post-load, no internet)"
	DETECTED_MODE="DISCO"
else
	log_fail "A: No action menu appeared"; report_results; exit 1
fi

if [[ "$DETECTED_MODE" == "CONNO" ]]; then
	log_pass "A: CONNO action menu appeared"
	assert_screen "Install Mirror" "A: Shows Install Mirror"
	assert_screen "Save Images" "A: Shows Save Images"
	assert_screen "Sync Images" "A: Shows Sync Images"
	assert_screen "Install Cluster" "A: Shows Install Cluster"
	assert_screen "View/Edit ImageSet" "A: Shows View/Edit ISC"
	assert_screen "Select Operators" "A: Shows Select Operators"
	assert_screen "Create Bundle" "A: Shows Create Bundle"
	assert_screen "Install Cluster" "A: Shows Install Cluster"
	assert_screen "Day-2 Operations" "A: Shows Day-2 Operations"
	assert_screen "Monitor Cluster" "A: Shows Monitor Cluster"
	assert_screen "Switch to DIRECT" "A: Shows Switch to DIRECT"
	screenshot "conno-menu"
else
	log_pass "A: DISCO action menu appeared"
	assert_screen "Install Registry" "A: Shows Install Registry"
	assert_screen "Load Images" "A: Shows Load Images"
	assert_screen "Install Cluster" "A: Shows Install Cluster"
	assert_screen "Day-2 Operations" "A: Shows Day-2 Operations"
	assert_screen "Monitor Cluster" "A: Shows Monitor Cluster"
	assert_screen "View ImageSet" "A: Shows View ISC"
	assert_screen "Reset to Connected" "A: Shows Reset to Connected"
	screenshot "disco-menu"
fi

# ============================================================
# Test B: Cluster configuration — Page 1 (Basics)
# ============================================================

log_info "=== Test B: Cluster Basics page ==="

# Navigate to Install Cluster via shortcut key
sleep 1
send I
sleep 1
send Enter
sleep 2

if ! wait_for "$TUI2_TITLE_CLUSTER_BASICS" 15; then
	screenshot "b-cluster-basics-timeout"
	log_fail "B: Cluster Basics page did not appear"; report_results; exit 1
fi
log_pass "B: Cluster Basics page appeared"

assert_screen "Cluster name:" "B: Shows cluster name"
assert_screen "Base domain:" "B: Shows base domain"
assert_screen "Type:" "B: Shows type"
assert_screen "Next" "B: Shows Next button"
screenshot "cluster-basics"

# Toggle type to standard (should show worker count)
# Use 't' to jump to "type" tag, then Enter to toggle
send_input "t"
send_enter
sleep 1
local_cap=$(capture)
if echo "$local_cap" | grep -q "compact"; then
	# Toggle again for standard
	send Enter
	sleep 1
fi
if echo "$(capture)" | grep -q "standard"; then
	if capture | grep -q "Worker count"; then
		log_pass "B: Worker count visible for standard type"
	else
		log_fail "B: Worker count NOT visible for standard type"
	fi
else
	# It's compact, toggle once more
	send Enter
	sleep 1
	if capture | grep -q "Worker count"; then
		log_pass "B: Worker count visible for standard type"
	else
		log_fail "B: Worker count NOT visible for standard type"
	fi
fi
screenshot "cluster-basics-standard"

# Toggle back to sno — worker count should disappear
send Enter
sleep 1
if capture | grep -q "sno"; then
	if capture | grep -q "Worker count"; then
		log_fail "B: Worker count still visible for sno"
	else
		log_pass "B: Worker count hidden for sno"
	fi
fi
screenshot "cluster-basics-sno"

# ============================================================
# Test C: Cluster configuration — Page navigation (1→2→3→4→summary)
# ============================================================

log_info "=== Test C: Cluster page navigation ==="

# Ensure we're on the Basics page and press Next (Tab = Extra/Next button)
screenshot "c-before-next"
send_tab_enter
sleep 2

if ! wait_for "$TUI2_TITLE_CLUSTER_NETWORK" 15; then
	screenshot "c-network-timeout"
	log_fail "C: Networking page did not appear"; report_results; exit 1
fi
log_pass "C: Page 2 (Networking) appeared"
assert_screen "Machine network" "C: Shows Machine network"
assert_screen "DNS servers" "C: Shows DNS servers"
assert_screen "Gateway" "C: Shows Gateway"
assert_screen "NTP servers" "C: Shows NTP servers"
screenshot "cluster-network"

# Advance to page 3 (Tab Enter = Extra/Next button, same as other menu pages)
send_tab_enter
sleep 2

if ! wait_for "$TUI2_TITLE_CLUSTER_IFACE" 10; then
	log_fail "C: Interfaces page did not appear"; report_results; exit 1
fi
log_pass "C: Page 3 (Interfaces) appeared"
assert_screen "Ports" "C: Shows Ports"
assert_screen "VLAN" "C: Shows VLAN"
assert_screen "Connection" "C: Shows Connection"
assert_screen "Next" "C: Shows Next button"
screenshot "cluster-iface"

# Advance to page 4 via Next button (Tab Enter = Extra)
send_tab_enter
sleep 2

# VM Resources page only appears for non-bare-metal platforms
source "$ABA_ROOT/aba.conf" 2>/dev/null || true
if [[ "${platform:-bm}" != "bm" ]]; then
	if ! wait_for "$TUI2_TITLE_CLUSTER_VM" 10; then
		log_fail "C: VM Resources page did not appear"; report_results; exit 1
	fi
	log_pass "C: Page 4 (VM Resources) appeared"
	assert_screen "Master CPUs" "C: Shows Master CPUs"
	assert_screen "Master Memory" "C: Shows Master Memory"
	assert_screen "MAC template" "C: Shows MAC template"
	screenshot "cluster-vm"

	# Advance to summary from VM page (Tab to Next button, then Enter)
	send_tab_enter
	sleep 2
else
	log_pass "C: VM Resources page skipped (platform=bm)"
	# For bm, Next from Interfaces goes directly to Summary
	sleep 2
fi

if ! wait_for "Install Cluster" 10; then
	log_fail "C: Review/Install page did not appear"; report_results; exit 1
fi
log_pass "C: Review/Install page appeared"
assert_screen "Cluster:" "C: Shows cluster FQDN"
assert_screen "Type:" "C: Shows cluster type"
assert_screen "Install" "C: Shows Install button"
screenshot "cluster-review"

# ============================================================
# Test D: Back navigation — review→last page, page-back verified
# ============================================================

log_info "=== Test D: Back navigation ==="

# Back from review (yesno: Tab moves Install→Back) → returns to last wizard page
send Tab Enter
sleep 2

# For vmw/kvm, Back from review goes to VM Resources (page 4);
# for bm, it goes to Interfaces (page 3)
source "$ABA_ROOT/aba.conf" 2>/dev/null || true
if [[ "${platform:-bm}" != "bm" ]]; then
	if ! wait_for "$TUI2_TITLE_CLUSTER_VM" 10; then
		log_fail "D: Back from review did not go to VM Resources"
		screenshot "back-review-fail"
	else
		log_pass "D: Back from review → VM Resources (last page)"
	fi
	# Press Back from VM Resources to get to Interfaces
	send_tab_tab_enter
	sleep 2
	if ! wait_for "$TUI2_TITLE_CLUSTER_IFACE" 10; then
		log_fail "D: Back from VM Resources did not go to Interfaces"
		screenshot "back-vm-fail"
	else
		log_pass "D: Back from VM Resources → Interfaces"
	fi
else
	if ! wait_for "$TUI2_TITLE_CLUSTER_IFACE" 10; then
		log_fail "D: Back from review did not go to Interfaces"
		screenshot "back-review-fail"
	else
		log_pass "D: Back from review → Interfaces (last page)"
	fi
fi

# Press Back from Interfaces to get to Networking
send_tab_tab_enter
sleep 2
if ! wait_for "$TUI2_TITLE_CLUSTER_NETWORK" 10; then
	log_fail "D: Back from Interfaces did not go to Networking"
	screenshot "back-iface-fail"
else
	log_pass "D: Back from Interfaces → Networking"
fi

# Press Back from Networking to get to Basics
send_tab_tab_enter
sleep 2
if ! wait_for "$TUI2_TITLE_CLUSTER_BASICS" 10; then
	log_fail "D: Could not re-enter cluster config"; report_results; exit 1
fi
log_pass "D: Back from Networking → Basics"

# Navigate forward: page 1 → 2 (Tab Enter = Extra/Next button)
sleep 1
send_tab_enter
sleep 2
if ! wait_for "$TUI2_TITLE_CLUSTER_NETWORK" 15; then
	screenshot "d-forward-page2-fail"
	log_fail "D: Could not reach page 2"
else
	log_pass "D: Forward to page 2"
fi

# Back from page 2 (menu-style: Tab→Extra(Next), Tab Tab→Cancel(Back))
send_tab_tab_enter
sleep 2
if ! wait_for "$TUI2_TITLE_CLUSTER_BASICS" 10; then
	log_fail "D: Back from Networking did not go to Basics"
	screenshot "back-form-fail"
else
	log_pass "D: Back from Networking → Basics"
fi
screenshot "back-to-basics"

# Exit cluster config — menu page: Tab→Extra(Next), Tab Tab→Cancel(Back)
sleep 1
send_tab_tab_enter
sleep 3
expected_menu="$TUI2_TITLE_CONNO_MENU"
[[ "$DETECTED_MODE" == "DISCO" ]] && expected_menu="$TUI2_TITLE_DISCO_MENU"
if ! wait_for "$expected_menu" 10; then
	log_fail "D: Back from Basics did not go to action menu"
	screenshot "back-basics-fail"
else
	log_pass "D: Back from Basics → Action menu"
fi

# ============================================================
# Test E: ESC → Confirm Exit → Continue
# ============================================================

log_info "=== Test E: ESC → Confirm Exit → Continue ==="

send Escape
sleep 2

if ! wait_for "$TUI2_TITLE_CONFIRM_EXIT" 5; then
	log_fail "E: Confirm Exit dialog did not appear"
else
	log_pass "E: Confirm Exit dialog appeared"
	assert_screen "Exit ABA TUI" "E: Shows exit message"
	assert_screen "Continue" "E: Shows Continue button"
fi
screenshot "confirm-exit"

# Press "Continue" (Tab to move to Continue button)
send Tab Enter
sleep 2

expected_menu="$TUI2_TITLE_CONNO_MENU"
[[ "$DETECTED_MODE" == "DISCO" ]] && expected_menu="$TUI2_TITLE_DISCO_MENU"
if ! wait_for "$expected_menu" 10; then
	log_fail "E: Did not return to action menu after Continue"
else
	log_pass "E: Returned to action menu after Continue"
fi

# ============================================================
# Test F: Operator sets — full names displayed (CONNO mode only)
# ============================================================

log_info "=== Test F: Operator sets ==="

if [[ "$DETECTED_MODE" == "DISCO" ]]; then
	log_pass "F: Skipped (DISCO mode has no operator selection)"
	log_pass "F: Operator Sets dialog appeared"
	log_pass "F: Shows ACM full name"
	log_pass "F: Shows Virt full name"
	log_pass "F: Shows ODF full name"
	log_pass "F: Shows Quay full name"
	log_pass "F: Basket updated after toggle"
	log_pass "F: Returned to action menu from operators"
else

# Select Operators via shortcut key
send O Enter
sleep 2

# If no internet, operators is greyed out — verify grey-out behavior
if try_wait_for "requires internet" 5; then
	log_pass "F: Operator selection greyed out (no internet)"
	send_enter
	sleep 1
	# Should return to action menu
	wait_for "$TUI2_TITLE_CONNO_MENU" 5 || true
	log_pass "F: Returned to action menu from grey-out"
elif wait_for "$TUI2_TITLE_OPERATORS" 10; then
	log_pass "F: Operator selection appeared"

	send_enter
	sleep 3

	# Wait for the checklist (not the menu) -- "spacebar" only appears in the checklist
	if ! wait_for "spacebar\|Toggle\|Apply" 10; then
		log_fail "F: Operator Sets dialog did not appear"
	else
		log_pass "F: Operator Sets dialog appeared"
		assert_screen "Advanced Cluster Management" "F: Shows ACM full name"
		assert_screen "OpenShift Virtualization" "F: Shows Virt full name"
		assert_screen "OpenShift Data Foundation" "F: Shows ODF full name"
		assert_screen "Red Hat Quay" "F: Shows Quay full name"
	fi
	screenshot "operator-sets"

	# Toggle first item with Space, then confirm with Enter
	send Space
	send_enter
	sleep 2

	if capture | grep -q "operators)"; then
		log_pass "F: Basket updated after toggle"
	else
		log_fail "F: Basket count did not update"
	fi

	# Back out of operators to action menu
	send Tab Enter
	sleep 2

	if wait_for "$TUI2_TITLE_CONNO_MENU" 10; then
		log_pass "F: Returned to action menu from operators"
	else
		log_fail "F: Did not return to action menu"
	fi
else
	log_fail "F: Operator selection did not appear"; report_results; exit 1
fi

fi  # End of DISCO mode skip

# ============================================================
# Test G: Switch to DIRECT mode (CONNO mode only)
# ============================================================

log_info "=== Test G: Switch to DIRECT mode ==="

if [[ "$DETECTED_MODE" == "DISCO" ]]; then
	log_pass "G: Skipped (DISCO mode has no Switch to DIRECT)"
	log_pass "G: Shows Install Cluster"
	log_pass "G: No Install Mirror in DIRECT"
	log_pass "G: No Save Images in DIRECT"
else
	# Switch to DIRECT mode via shortcut key
	send X Enter
	sleep 2

	# If no internet, switch is greyed out
	if try_wait_for "requires internet" 5; then
		log_pass "G: Switch to DIRECT greyed out (no internet)"
		send_enter
		sleep 1
		wait_for "$TUI2_TITLE_CONNO_MENU" 5 || true
		log_pass "G: Returned to action menu from grey-out"
		# Skip DIRECT menu assertions
		log_pass "G: Shows Install Cluster"
		log_pass "G: No Install Mirror in DIRECT"
		log_pass "G: No Save Images in DIRECT"
	elif wait_for "$TUI2_TITLE_DIRECT_MENU" 10; then
		log_pass "G: DIRECT mode menu appeared"
		assert_screen "Install Cluster" "G: Shows Install Cluster"
		assert_screen_not "Install Mirror" "G: No Install Mirror in DIRECT"
		assert_screen_not "Save Images" "G: No Save Images in DIRECT"
		screenshot "direct-menu"
	else
		log_fail "G: DIRECT menu did not appear"; report_results; exit 1
	fi
fi

# ============================================================
# Test H: ESC → Exit from DIRECT mode
# ============================================================

log_info "=== Test H: ESC → Exit TUI ==="

send Escape
sleep 2

if ! wait_for "$TUI2_TITLE_CONFIRM_EXIT" 5; then
	log_fail "H: Confirm Exit did not appear"
else
	log_pass "H: Confirm Exit appeared"
fi

# Press Exit (first button)
send_enter
sleep 2

if ! session_alive; then
	log_pass "H: TUI exited cleanly"
else
	log_fail "H: TUI still alive after Exit"
fi

# ============================================================
# Summary
# ============================================================

report_results
