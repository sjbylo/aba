#!/bin/bash
# Test: TUI settings — verify toggles persist to config files
#
# Exercises:
#   1.  Registry vendor toggle: auto → quay → docker → omr → auto (full cycle)
#       Verify each value is written to mirror/mirror.conf
#   2.  Retry count toggle: 1 → 2 → 5 → OFF → 1 (full cycle)
#       Verify each value is written to ~/.aba/config
#   3.  Main menu label reflects current settings (vendor, retry)
#   4.  Settings survive TUI restart (persistence check)
#   5.  Mirror install label reflects vendor: "Install auto/Quay/Docker Mirror"
#
# Non-destructive: restores original values at the end.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Settings Deep Test ==="
echo "  Host: $_TUI_HOST"
echo ""

_ssh_cfg="$HOME/.aba/ssh.conf"
scp -q -F "$_ssh_cfg" tui/v2/*.sh "$_TUI_HOST:aba/tui/v2/" 2>/dev/null
scp -q -F "$_ssh_cfg" scripts/include_all.sh scripts/aba.sh "$_TUI_HOST:aba/scripts/" 2>/dev/null
echo "  Code deployed"
echo ""

# Save originals for restoration
_orig_vendor=$($_TUI_SSH "grep '^reg_vendor=' ~/aba/mirror/mirror.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "auto")
_orig_retry=$($_TUI_SSH "grep '^TUI_OC_MIRROR_RETRY_COUNT=' ~/.aba/config 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "1")
echo "  Saved originals: vendor='$_orig_vendor' retry='$_orig_retry'"

# ============================================================================
tui_start
tui_assert_appears "OpenShift Installer" "TUI launched" 15 || {
	tui_stop; tui_summary; exit 1
}
tui_keys Enter
tui_assert_appears "Actions" "Main menu" 10

# Helper: open Settings menu
_goto_settings() {
	if tui_capture | grep -qi "Registry Type\|Retry Count"; then
		return 0
	fi
	tui_back_to "Actions" 5
	tui_select_item "Configure"
	tui_wait_for "Registry Type\|Retry Count" 10
}

# Helper: read vendor from config file on remote host
_read_vendor() {
	$_TUI_SSH "grep '^reg_vendor=' ~/aba/mirror/mirror.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo ""
}

# Helper: read retry from config file on remote host
_read_retry() {
	$_TUI_SSH "grep '^TUI_OC_MIRROR_RETRY_COUNT=' ~/.aba/config 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo ""
}

# ============================================================================
# 1. Registry vendor: full toggle cycle
# ============================================================================
echo ""
echo "--- 1. Registry vendor toggle cycle ---"

# Cycle: auto → quay → docker → omr → auto
# Build expected sequence from current starting vendor
declare -A _NEXT_VENDOR=([auto]=quay [quay]=docker [docker]=omr [omr]=auto)
declare -A _DISP_NAME=([auto]=Auto [quay]=Quay [docker]=Docker [omr]=OMR)

_cur_vendor=$(_read_vendor)
[[ -z "$_cur_vendor" ]] && _cur_vendor="auto"

_goto_settings
sleep 1
tui_screenshot "sd-01-initial"

for _step in 1 2 3 4; do
	_exp="${_NEXT_VENDOR[$_cur_vendor]}"
	_disp="${_DISP_NAME[$_exp]}"

	# Select item 1 (Registry Type) and press Toggle
	_goto_settings
	tui_keys 1; sleep 0.3; tui_keys Enter
	sleep 1.5

	# Read the display value from screen
	_goto_settings
	sleep 1
	_scr=$(tui_capture)
	tui_screenshot "sd-01-vendor-${_exp}"

	if echo "$_scr" | grep -qi "Registry Type.*$_disp"; then
		echo "  ✓ PASS: Vendor toggled to '$_disp' (display)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Expected '$_disp' in settings display"
		echo "    Screen: $(echo "$_scr" | grep -i 'Registry Type')"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi

	# Verify config file was updated
	_file_val=$(_read_vendor)
	if [[ "$_file_val" == "$_exp" ]]; then
		echo "  ✓ PASS: mirror.conf updated to reg_vendor=$_exp"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Expected reg_vendor=$_exp in mirror.conf, got '$_file_val'"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	_cur_vendor="$_exp"
done

# ============================================================================
# 2. Retry count: full toggle cycle
# ============================================================================
echo ""
echo "--- 2. Retry count toggle cycle ---"

# Toggle sequence from current (should be 1 after reset): 1→2, 2→5, 5→0, 0→1
# First set to 1 as starting point (toggle from auto back)
_expected_retries=("2" "5" "0" "1")
_display_retries=("2" "5" "OFF" "1")

_goto_settings
sleep 1

for idx in "${!_expected_retries[@]}"; do
	_exp="${_expected_retries[$idx]}"
	_disp="${_display_retries[$idx]}"

	# Select item 2 (Retry Count) and press Toggle
	_goto_settings
	tui_keys 2; sleep 0.3; tui_keys Enter
	sleep 1.5

	# Read the display value from screen
	_goto_settings
	sleep 1
	_scr=$(tui_capture)
	tui_screenshot "sd-02-retry-${_exp}"

	if echo "$_scr" | grep -qi "Retry Count.*$_disp\|Retry.*$_disp"; then
		echo "  ✓ PASS: Retry toggled to '$_disp' (display)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Expected '$_disp' in retry display"
		echo "    Screen: $(echo "$_scr" | grep -i 'Retry')"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi

	# Verify config file was updated
	_file_val=$(_read_retry)
	if [[ "$_file_val" == "$_exp" ]]; then
		echo "  ✓ PASS: ~/.aba/config updated to TUI_OC_MIRROR_RETRY_COUNT=$_exp"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Expected retry=$_exp in ~/.aba/config, got '$_file_val'"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
done

# ============================================================================
# 3. Main menu label reflects settings
# ============================================================================
echo ""
echo "--- 3. Main menu settings label ---"

# Read current state — whatever the cycle left us at
_label_vendor=$(_read_vendor)
[[ -z "$_label_vendor" ]] && _label_vendor="auto"
_label_retry=$(_read_retry)
[[ -z "$_label_retry" ]] && _label_retry="1"

# Toggle retry once so label changes from the default
_goto_settings
tui_keys 2; sleep 0.3; tui_keys Enter; sleep 1
_goto_settings
sleep 1
_label_retry=$(_read_retry)
tui_screenshot "sd-03-settings"

# Construct expected label fragments
_label_v_disp="${_DISP_NAME[$_label_vendor]}"
[[ "$_label_retry" == "0" ]] && _label_r_disp="OFF" || _label_r_disp="$_label_retry"

# Go back to main menu and check Configure label
tui_back_to "Actions" 3
sleep 2
_scr=$(tui_capture)
tui_screenshot "sd-03-main-label"

if echo "$_scr" | grep -qi "Configure.*$_label_v_disp.*retry=$_label_r_disp"; then
	echo "  ✓ PASS: Main menu shows '$_label_v_disp, retry=$_label_r_disp'"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Main menu label doesn't reflect $_label_v_disp/retry=$_label_r_disp"
	echo "    Configure line: $(echo "$_scr" | grep -i 'Configure')"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 3b. Verify retry value flows into actual command strings
# ============================================================================
echo ""
echo "--- 3b. Verify retry value is used in commands ---"

# The retry suffix function uses _TUI_RETRY_COUNT which is loaded from
# TUI_OC_MIRROR_RETRY_COUNT in ~/.aba/config.  Verify the mapping:
#   TUI_OC_MIRROR_RETRY_COUNT=N → command gets " --retry N"
_cur_retry=$(_read_retry)
if [[ "$_cur_retry" -gt 0 ]]; then
	_expected_suffix="--retry $_cur_retry"
	echo "  Retry=$_cur_retry → commands should include '$_expected_suffix'"
else
	_expected_suffix=""
	echo "  Retry=0 (OFF) → commands should NOT include --retry"
fi

# Source the TUI and call the suffix function to verify it returns the right value
_actual_suffix=$($_TUI_SSH "cd ~/aba && source scripts/include_all.sh 2>/dev/null && \
	export TUI_OC_MIRROR_RETRY_COUNT=$_cur_retry && \
	_TUI_RETRY_COUNT=\"\${TUI_OC_MIRROR_RETRY_COUNT:-1}\" && \
	source tui/v2/tui-lib.sh 2>/dev/null && \
	_tui_oc_mirror_retry_suffix" 2>/dev/null || echo "ERR")

if [[ "$_actual_suffix" == *"$_expected_suffix"* ]] || \
   { [[ "$_cur_retry" -eq 0 ]] && [[ -z "$_actual_suffix" || "$_actual_suffix" == "" ]]; }; then
	echo "  ✓ PASS: _tui_oc_mirror_retry_suffix returns correct value"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Expected suffix '$_expected_suffix', got '$_actual_suffix'"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Verify the sync command would include the retry flag by checking the
# command template directly (aba --dir mirror sync --retry N)
_sync_cmd=$($_TUI_SSH "cd ~/aba && source scripts/include_all.sh 2>/dev/null && \
	export TUI_OC_MIRROR_RETRY_COUNT=$_cur_retry && \
	_TUI_RETRY_COUNT=\"\${TUI_OC_MIRROR_RETRY_COUNT:-1}\" && \
	source tui/v2/tui-lib.sh 2>/dev/null && \
	echo \"aba --dir mirror sync\$(_tui_oc_mirror_retry_suffix)\"" 2>/dev/null || echo "ERR")

if [[ "$_cur_retry" -gt 0 ]]; then
	if echo "$_sync_cmd" | grep -q -- "--retry $_cur_retry"; then
		echo "  ✓ PASS: Sync command includes '--retry $_cur_retry': $_sync_cmd"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Sync command missing retry: $_sync_cmd"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
else
	if ! echo "$_sync_cmd" | grep -q -- "--retry"; then
		echo "  ✓ PASS: Sync command has no --retry when OFF: $_sync_cmd"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Sync command has --retry when retry=0: $_sync_cmd"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
fi

# Also verify vendor is loaded from mirror.conf into the install label
_cur_vendor=$(_read_vendor)
_install_label=$($_TUI_SSH "cd ~/aba && source scripts/include_all.sh 2>/dev/null && \
	source <(cd mirror && normalize-mirror-conf) 2>/dev/null && \
	echo \"Install \${reg_vendor:-auto} Mirror\"" 2>/dev/null || echo "ERR")

if echo "$_install_label" | grep -qi "$_cur_vendor"; then
	echo "  ✓ PASS: Install label uses vendor from mirror.conf: $_install_label"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Install label doesn't match vendor '$_cur_vendor': $_install_label"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 4. Settings persist across TUI restart
# ============================================================================
echo ""
echo "--- 4. Settings persistence across restart ---"

# Record current state (after step 3 changes)
_set_vendor=$(_read_vendor)
_set_retry=$(_read_retry)
echo "  Before restart: vendor=$_set_vendor, retry=$_set_retry"

# Kill and restart TUI
tui_stop
sleep 2
tui_start
tui_assert_appears "OpenShift Installer" "TUI launched (restart)" 15
tui_keys Enter
tui_assert_appears "Actions" "Main menu (restart)" 10

# Open settings and verify values are preserved
_goto_settings
sleep 1
tui_screenshot "sd-04-after-restart"
_scr=$(tui_capture)

# Check vendor survived
_post_vendor=$(_read_vendor)
if [[ "$_post_vendor" == "$_set_vendor" ]]; then
	echo "  ✓ PASS: Vendor persisted across restart: $_post_vendor"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Vendor changed after restart: $_set_vendor → $_post_vendor"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Check retry survived
_post_retry=$(_read_retry)
if [[ "$_post_retry" == "$_set_retry" ]]; then
	echo "  ✓ PASS: Retry persisted across restart: $_post_retry"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Retry changed after restart: $_set_retry → $_post_retry"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Verify screen display matches files
if echo "$_scr" | grep -qi "Registry Type"; then
	echo "  ✓ PASS: Settings menu shows Registry Type after restart"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
fi

# ============================================================================
# 5. Settings help text contains all options
# ============================================================================
echo ""
echo "--- 5. Settings help completeness ---"
_goto_settings
tui_press_button "Help"
sleep 2
tui_screenshot "sd-05-help"
_scr=$(tui_capture)

tui_assert_contains "Auto" "Help mentions Auto"
tui_assert_contains "Quay" "Help mentions Quay"
tui_assert_contains "Docker" "Help mentions Docker"
tui_assert_contains "OMR" "Help mentions OMR"
tui_assert_contains "Retry" "Help mentions Retry"
tui_assert_contains "oc-mirror" "Help mentions oc-mirror"
tui_keys Enter; sleep 1

# ============================================================================
# 6. Restore original values
# ============================================================================
echo ""
echo "--- 6. Restore original values ---"
$_TUI_SSH "cd ~/aba && sed -i 's/^reg_vendor=.*/reg_vendor=$_orig_vendor/' mirror/mirror.conf" 2>/dev/null
$_TUI_SSH "sed -i 's/^TUI_OC_MIRROR_RETRY_COUNT=.*/TUI_OC_MIRROR_RETRY_COUNT=$_orig_retry/' ~/.aba/config" 2>/dev/null
echo "  Restored: vendor='$_orig_vendor' retry='$_orig_retry'"

# Verify restoration
_final_vendor=$(_read_vendor)
_final_retry=$(_read_retry)
if [[ "$_final_vendor" == "$_orig_vendor" && "$_final_retry" == "$_orig_retry" ]]; then
	echo "  ✓ PASS: Original values restored"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Restoration incomplete: vendor=$_final_vendor, retry=$_final_retry"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 7. Cleanup
# ============================================================================
echo ""
echo "--- 7. Cleanup ---"
tui_back_to "Actions" 5
for i in 1 2 3 4 5; do tui_keys Escape; sleep 0.5; done
sleep 2
if tui_session_alive; then
	tui_keys Enter; sleep 1; tui_keys Escape; sleep 1; tui_keys Enter; sleep 2
fi
_strays=$($_TUI_SSH "ps -eo pid,ppid,args | grep -E '\bdialog\b|abatui' | grep -v grep" 2>/dev/null || true)
if [ -z "$_strays" ]; then
	echo "  ✓ PASS: No stray processes"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Stray processes"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	$_TUI_SSH "pkill -f abatui 2>/dev/null; pkill -f 'dialog --' 2>/dev/null; true"
fi

tui_stop 2>/dev/null
tui_summary
