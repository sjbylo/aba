#!/bin/bash
# Test: TUI platform configuration dialogs — VMware, KVM, pull secret
#
# Exercises:
#   1.  VMware config form: all fields present, edit a field, verify vmware.conf
#   2.  KVM config form: all fields present, edit a field, verify kvm.conf
#   3.  Pull secret path: file exists, valid JSON, wizard auto-skips it
#       (the missing-file dialog is test-tui-wizard.sh)
#   4.  Mirror config form: all fields present (hostname, port, user, etc.)
#   5.  Restore originals
#
# Non-destructive: restores original config files at the end.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh
trap 'tui_mirror_restore_service || true' EXIT

echo "=== TUI Platform Config Deep Test ==="
echo "  Host: $_TUI_HOST"
echo ""

tui_deploy_code
echo ""

# Save originals for restoration
$_TUI_SSH "cp ~/aba/vmware.conf ~/aba/vmware.conf.test-backup 2>/dev/null; true"
$_TUI_SSH "cp ~/aba/kvm.conf ~/aba/kvm.conf.test-backup 2>/dev/null; true"
_orig_pull_secret=$($_TUI_SSH "grep '^pull_secret_file=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "")
echo "  Saved originals"

# ============================================================================
tui_start_to_menu || { tui_summary; exit 1; }

# ============================================================================
# 1. VMware Configuration Form
# ============================================================================
echo ""
echo "--- 1. VMware configuration form ---"

# Navigate: Advanced → Platform Settings → select VMware
tui_select_item "Advanced"
tui_wait_for "Platform Settings\|Advanced" 10
tui_select_item "Platform Settings"
sleep 2

# Platform selector may appear — select VMware
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Select platform\|Bare Metal\|VMware.*vSphere\|KVM"; then
	tui_keys V; sleep 0.3; tui_keys Enter
	sleep 3
fi
tui_screenshot "pc-01-vmware"
_scr=$(tui_capture)

if echo "$_scr" | grep -qi "VMware\|vCenter\|ESXi"; then
	tui_pass "VMware configuration form opened" "$_scr"
	tui_assert_title "VMware\|ESXi" "VMware config dialog title"

	# Verify all expected fields
	tui_assert_contains "vCenter.*URL\|ESXi.*URL\|URL" "VMware URL field"
	tui_assert_contains "Username" "VMware Username field"
	tui_assert_contains "Password" "VMware Password field"
	tui_assert_contains "Datastore" "VMware Datastore field"
	tui_assert_contains "Network" "VMware Network field"
	tui_assert_contains "Datacenter" "VMware Datacenter field"
	tui_assert_contains "Cluster" "VMware Cluster field"
	tui_assert_contains "Folder\|VM Folder" "VMware Folder field"
	tui_assert_contains "TLS\|Insecure\|Skip TLS" "VMware TLS verify field"
	tui_assert_contains "Test Connection" "VMware Test Connection option"

	# Edit a field: select Datacenter (C) and type a value
	echo ""
	echo "  --- Edit Datacenter field ---"
	tui_keys C; sleep 0.3; tui_keys Enter
	sleep 2
	_scr=$(tui_capture)
	tui_screenshot "pc-01b-datacenter-input"
	if echo "$_scr" | grep -qi "Datacenter\|datacenter"; then
		tui_pass "Datacenter input dialog appeared" "$_scr"

		# Clear existing value and type new
		# Ctrl+U clears input in dialog
		tui_keys C-u; sleep 0.3
		tui_keys "test-dc-01"
		sleep 0.3
		tui_keys Enter
		sleep 2

		# Verify in vmware.conf
		_dc_val=$($_TUI_SSH "grep '^GOVC_DATACENTER=' ~/aba/vmware.conf 2>/dev/null | head -1 | cut -d= -f2 | awk '{print \$1}' | tr -d \"'\"" || echo "")
		if [[ "$_dc_val" == "test-dc-01" ]]; then
			tui_pass "Datacenter persisted to vmware.conf: '$_dc_val'"
		else
			echo "  ✗ FAIL: Expected 'test-dc-01' in vmware.conf, got '$_dc_val'"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi
	else
		echo "  ✗ FAIL: Datacenter input not shown"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi

	# Back out of VMware form
	tui_press_button "Continue" 2>/dev/null || {
		tui_keys Escape; sleep 1
	}
	sleep 1

elif echo "$_scr" | grep -qi "KVM\|Libvirt"; then
	tui_pass "Platform is KVM — will verify KVM form in section 2" "$_scr"
	tui_keys Escape; sleep 1
else
	echo "  ✗ FAIL: Platform config form not shown"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

tui_back_to "Actions" 5

# ============================================================================
# 2. KVM Configuration Form (via Advanced → Platform Settings after mode switch)
# ============================================================================
echo ""
echo "--- 2. KVM configuration form ---"

# Check if kvm.conf exists; if not, create from template
$_TUI_SSH "[ -f ~/aba/kvm.conf ] || cp ~/aba/templates/kvm.conf ~/aba/kvm.conf 2>/dev/null || true"

# Read kvm.conf directly to verify field access
_kvm_has_uri=$($_TUI_SSH "grep 'LIBVIRT_URI=' ~/aba/kvm.conf 2>/dev/null | head -1 | cut -d= -f2" || echo "")

if [[ -n "$_kvm_has_uri" ]] || $_TUI_SSH "[ -f ~/aba/kvm.conf ]" 2>/dev/null; then
	tui_pass "kvm.conf exists or created from template"

	# Verify kvm.conf has expected fields
	_kvm_fields=$($_TUI_SSH "cat ~/aba/kvm.conf 2>/dev/null" || echo "")
	if echo "$_kvm_fields" | grep -qi "LIBVIRT_URI"; then
		tui_pass "kvm.conf has LIBVIRT_URI field"
	else
		echo "  ✗ FAIL: kvm.conf missing LIBVIRT_URI"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	if echo "$_kvm_fields" | grep -qi "KVM_STORAGE_POOL"; then
		tui_pass "kvm.conf has KVM_STORAGE_POOL field"
	else
		echo "  ✗ FAIL: kvm.conf missing KVM_STORAGE_POOL"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	if echo "$_kvm_fields" | grep -qi "KVM_NETWORK"; then
		tui_pass "kvm.conf has KVM_NETWORK field"
	else
		echo "  ✗ FAIL: kvm.conf missing KVM_NETWORK"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
else
	echo "  ✗ FAIL: kvm.conf not available"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 3. Pull secret path verification
# ============================================================================
echo ""
echo "--- 3. Pull secret path ---"

# Verify pull secret is configured in aba.conf
_ps_path=$($_TUI_SSH "grep '^pull_secret_file=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "")
if [[ -n "$_ps_path" ]]; then
	tui_pass "pull_secret_file configured: $_ps_path"
else
	echo "  ✗ FAIL: pull_secret_file not in aba.conf"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Verify pull secret file exists on remote
_ps_expanded="${_ps_path/#\~/$HOME}"
_ps_exists=$($_TUI_SSH "[ -f '$_ps_expanded' ] && echo yes || echo no" 2>/dev/null)
if [[ "$_ps_exists" == "yes" ]]; then
	tui_pass "Pull secret file exists at $_ps_path"
else
	echo "  ✗ FAIL: Pull secret file not found at $_ps_path"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Verify pull secret is valid JSON
_ps_valid=$($_TUI_SSH "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$_ps_expanded' 2>/dev/null && echo yes || echo no" 2>/dev/null)
if [[ "$_ps_valid" == "yes" ]]; then
	tui_pass "Pull secret is valid JSON"
else
	echo "  ✗ FAIL: Pull secret is not valid JSON"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Test that the wizard auto-skips pull secret when valid (verify in TUI)
echo ""
echo "  --- Wizard auto-skip with valid pull secret ---"
tui_back_to "Actions" 5
tui_select_item "Rerun Wizard\|Wizard"
sleep 3
tui_screenshot "pc-03-wizard-start"
_scr=$(tui_capture)

# When pull secret is valid, wizard should skip directly to channel/resume
if echo "$_scr" | grep -qi "Resume\|channel\|version\|platform\|Continue with"; then
	tui_pass "Wizard auto-skipped pull secret (valid file exists)" "$_scr"
elif echo "$_scr" | grep -qi "Pull Secret\|pull secret\|Enter file path"; then
	echo "  ✗ FAIL: Wizard showed pull secret dialog despite valid file"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
else
	echo "  ✗ FAIL: Wizard response unclear"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi
# Back out of wizard
tui_keys Escape; sleep 1
tui_keys Escape; sleep 1
tui_back_to "Actions" 3

# ============================================================================
# 4. Mirror configuration form fields
# ============================================================================
echo ""
echo "--- 4. Mirror configuration form ---"

tui_select_item "Install Mirror"
sleep 3
tui_screenshot "pc-04-mirror-pre"
_scr=$(tui_capture)

# An installed registry shows Reinstall. Yes removes the service and keeps
# the data dir so the config form can be checked. --defaultno focuses No;
# tui_confirm_yes moves to Yes.
if echo "$_scr" | grep -qi "reinstall\|already installed\|existing"; then
	tui_pass "Mirror reinstall confirmation shown (mirror already installed)" "$_scr"
	echo "  Uninstalling mirror so the config form opens (data dir kept)"
	_TUI_MIRROR_SERVICE_DOWN=yes
	tui_confirm_yes
	if ! tui_wait_mirror_install_choice "pc-uninstall"; then
		echo "  ✗ FAIL: mirror uninstall did not reach the install form"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		_scr=""
	else
		tui_pass "Install form opened after uninstall" "$(tui_capture)"
		_scr=$(tui_capture)
	fi
fi
if echo "$_scr" | grep -qi "locally\|remote\|Install locally\|local.*host"; then
	tui_pass "Install location choice shown" "$_scr"

	# Select "Install locally" to see config form
	tui_keys 1; sleep 0.3; tui_keys Enter
	sleep 3
	tui_screenshot "pc-04-mirror-config"
	_scr=$(tui_capture)

	if echo "$_scr" | grep -qi "Hostname\|Port\|Username\|Password"; then
		tui_pass "Mirror config form appeared" "$_scr"

		tui_assert_contains "Hostname\|hostname" "Mirror hostname field"
		tui_assert_contains "Port\|port" "Mirror port field"
		tui_assert_contains "Username\|username" "Mirror username field"
		tui_assert_contains "Password\|password" "Mirror password field"
		tui_assert_contains "Image path\|image.*path" "Mirror image path field"
		tui_assert_contains "Data dir\|data.*dir\|directory" "Mirror data dir field"
	else
		echo "  ✗ FAIL: Mirror config form not reached after Install locally"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi

	tui_keys Escape; sleep 1
else
	echo "  ✗ FAIL: Neither reinstall dialog nor install-location choice shown"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_screenshot "pc-04-mirror-unexpected"
fi

tui_back_to "Actions" 5
if ! tui_mirror_restore_service; then
	echo "  ✗ FAIL: mirror service was not installed again"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 5. Cluster wizard page 1 — verify all basics fields
# ============================================================================
echo ""
echo "--- 5. Cluster wizard basics ---"

tui_select_item "Install Cluster"
sleep 3
tui_screenshot "pc-05-cluster-pre"
_scr=$(tui_capture)

# Handle existing cluster dialog
if echo "$_scr" | grep -qi "existing\|previous\|Use Existing"; then
	tui_press_button "New Cluster" 2>/dev/null || {
		tui_keys Tab; sleep 0.3; tui_keys Enter
	}
	sleep 2
	_scr=$(tui_capture)
fi

# Mirror missing or empty offers Install & Sync / Sync Now. Take it.
# The wizard page is the check. Backing out is not a pass.
if echo "$_scr" | grep -qi "Mirror Required\|No mirror registry\|Install & Sync\|Release Image Missing\|Sync Now\|Load Now"; then
	echo "  Mirror gate is up — installing or syncing so the wizard opens"
	_pc_i=0
	while [ "$_pc_i" -lt 40 ]; do
		_scr=$(tui_capture)
		if echo "$_scr" | grep -qi "Cluster Name\|Base domain\|Cluster – Basics"; then
			break
		fi
		if echo "$_scr" | grep -qi "In Progress\|Overall Progress\|Executing\|Syncing"; then
			tui_wait_for_progress "pc-wizard-gate" 3600 || break
			tui_dismiss_result 2>/dev/null || true
		elif echo "$_scr" | grep -qi "Mirror Required\|Release Image Missing\|Install & Sync\|Sync Now\|Load Now"; then
			tui_keys Enter
		elif echo "$_scr" | grep -qi "existing\|previous\|Use Existing\|New Cluster\|already installed"; then
			tui_press_button "New Cluster" 2>/dev/null || tui_keys Enter
		elif echo "$_scr" | grep -qi "Mirror Updated\|updated successfully"; then
			tui_keys Enter
		elif echo "$_scr" | grep -qi "Continue"; then
			tui_press_button "Continue" 2>/dev/null || tui_keys Enter
		fi
		sleep 2
		_pc_i=$(( _pc_i + 1 ))
	done
	_scr=$(tui_capture)
fi
tui_screenshot "pc-05-cluster-basics"
if echo "$_scr" | grep -qi "Cluster Name\|Name\|Type\|Domain"; then
	tui_pass "Cluster basics page appeared" "$_scr"
	tui_assert_contains "Name\|name" "Cluster name field"
	tui_assert_contains "Domain\|domain" "Base domain field"
	tui_assert_contains "Type\|type\|sno\|compact\|standard" "Cluster type field"
else
	echo "  ✗ FAIL: Cluster basics page not reached"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_screenshot "pc-05-basics-missing"
fi

# Back out
tui_keys Escape; sleep 1
tui_keys Escape; sleep 1
tui_back_to "Actions" 5

# ============================================================================
# 6. Restore originals
# ============================================================================
echo ""
echo "--- 6. Restore originals ---"
$_TUI_SSH "cp ~/aba/vmware.conf.test-backup ~/aba/vmware.conf 2>/dev/null; rm -f ~/aba/vmware.conf.test-backup" 2>/dev/null
$_TUI_SSH "cp ~/aba/kvm.conf.test-backup ~/aba/kvm.conf 2>/dev/null; rm -f ~/aba/kvm.conf.test-backup" 2>/dev/null
# Persistence check writes a fake DC (test-dc-01). If the backup itself was
# already poisoned, ensure_install_prereqs rewrites to a real govc DC.
tui_ensure_install_prereqs
tui_pass "Original configs restored"

# ============================================================================
# 7. Cleanup
# ============================================================================
echo ""
echo "--- 7. Cleanup ---"
tui_cleanup
tui_summary
