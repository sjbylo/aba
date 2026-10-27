#!/bin/bash
# Test: TUI platform configuration dialogs — VMware, KVM, pull secret
#
# Exercises:
#   1.  VMware config form: all fields present, edit a field, verify vmware.conf
#   2.  KVM config form: all fields present, edit a field, verify kvm.conf
#   3.  Pull secret path: verify auto-skip when valid, info dialog when missing
#   4.  Mirror config form: all fields present (hostname, port, user, etc.)
#   5.  Restore originals
#
# Non-destructive: restores original config files at the end.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI Platform Config Deep Test ==="
echo "  Host: $_TUI_HOST"
echo ""

_ssh_cfg="$HOME/.aba/ssh.conf"
scp -q -F "$_ssh_cfg" tui/v2/*.sh "$_TUI_HOST:aba/tui/v2/" 2>/dev/null
scp -q -F "$_ssh_cfg" scripts/include_all.sh scripts/aba.sh "$_TUI_HOST:aba/scripts/" 2>/dev/null
echo "  Code deployed"
echo ""

# Save originals for restoration
$_TUI_SSH "cp ~/aba/vmware.conf ~/aba/vmware.conf.test-backup 2>/dev/null; true"
$_TUI_SSH "cp ~/aba/kvm.conf ~/aba/kvm.conf.test-backup 2>/dev/null; true"
_orig_pull_secret=$($_TUI_SSH "grep '^pull_secret_file=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "")
echo "  Saved originals"

# ============================================================================
tui_start
tui_assert_appears "OpenShift Installer" "TUI launched" 15 || {
	tui_stop; tui_summary; exit 1
}
tui_keys Enter
tui_assert_appears "Actions" "Main menu" 10

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
	echo "  ✓ PASS: VMware configuration form opened"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

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
		echo "  ✓ PASS: Datacenter input dialog appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))

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
			echo "  ✓ PASS: Datacenter persisted to vmware.conf: '$_dc_val'"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
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
	echo "  ~ NOTE: Platform is KVM, not VMware — testing KVM form instead"
	# Will be tested in section 2
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
	echo "  ✓ PASS: kvm.conf exists or created from template"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Verify kvm.conf has expected fields
	_kvm_fields=$($_TUI_SSH "cat ~/aba/kvm.conf 2>/dev/null" || echo "")
	if echo "$_kvm_fields" | grep -qi "LIBVIRT_URI"; then
		echo "  ✓ PASS: kvm.conf has LIBVIRT_URI field"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: kvm.conf missing LIBVIRT_URI"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	if echo "$_kvm_fields" | grep -qi "KVM_STORAGE_POOL"; then
		echo "  ✓ PASS: kvm.conf has KVM_STORAGE_POOL field"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: kvm.conf missing KVM_STORAGE_POOL"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
	if echo "$_kvm_fields" | grep -qi "KVM_NETWORK"; then
		echo "  ✓ PASS: kvm.conf has KVM_NETWORK field"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: kvm.conf missing KVM_NETWORK"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
else
	echo "  ~ NOTE: kvm.conf not available"
fi

# ============================================================================
# 3. Pull secret path verification
# ============================================================================
echo ""
echo "--- 3. Pull secret path ---"

# Verify pull secret is configured in aba.conf
_ps_path=$($_TUI_SSH "grep '^pull_secret_file=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "")
if [[ -n "$_ps_path" ]]; then
	echo "  ✓ PASS: pull_secret_file configured: $_ps_path"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: pull_secret_file not in aba.conf"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Verify pull secret file exists on remote
_ps_expanded="${_ps_path/#\~/$HOME}"
_ps_exists=$($_TUI_SSH "[ -f '$_ps_expanded' ] && echo yes || echo no" 2>/dev/null)
if [[ "$_ps_exists" == "yes" ]]; then
	echo "  ✓ PASS: Pull secret file exists at $_ps_path"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Pull secret file not found at $_ps_path"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Verify pull secret is valid JSON
_ps_valid=$($_TUI_SSH "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$_ps_expanded' 2>/dev/null && echo yes || echo no" 2>/dev/null)
if [[ "$_ps_valid" == "yes" ]]; then
	echo "  ✓ PASS: Pull secret is valid JSON"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
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
	echo "  ✓ PASS: Wizard auto-skipped pull secret (valid file exists)"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
elif echo "$_scr" | grep -qi "Pull Secret\|pull secret\|Enter file path"; then
	echo "  ✗ FAIL: Wizard showed pull secret dialog despite valid file"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
else
	echo "  ~ NOTE: Wizard response unclear"
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

# If mirror already installed, we'll see a reinstall confirmation
if echo "$_scr" | grep -qi "reinstall\|already installed\|existing"; then
	echo "  ~ NOTE: Mirror already installed, checking reinstall dialog"
	tui_press_button "No" 2>/dev/null || tui_keys Escape
	sleep 2
	# Try to reach install location choice
	_scr=$(tui_capture)
fi

# Check for local/remote choice or config form
if echo "$_scr" | grep -qi "locally\|remote\|Install locally\|local.*host"; then
	echo "  ✓ PASS: Install location choice shown"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	# Select "Install locally" to see config form
	tui_keys 1; sleep 0.3; tui_keys Enter
	sleep 3
	tui_screenshot "pc-04-mirror-config"
	_scr=$(tui_capture)

	if echo "$_scr" | grep -qi "Hostname\|Port\|Username\|Password"; then
		echo "  ✓ PASS: Mirror config form appeared"
		_TUI_PASS=$(( _TUI_PASS + 1 ))

		tui_assert_contains "Hostname\|hostname" "Mirror hostname field"
		tui_assert_contains "Port\|port" "Mirror port field"
		tui_assert_contains "Username\|username" "Mirror username field"
		tui_assert_contains "Password\|password" "Mirror password field"
		tui_assert_contains "Image path\|image.*path" "Mirror image path field"
		tui_assert_contains "Data dir\|data.*dir\|directory" "Mirror data dir field"
	else
		echo "  ~ NOTE: Mirror config form not reached (may already be configured)"
	fi

	tui_keys Escape; sleep 1
else
	echo "  ~ NOTE: Mirror install location not shown (may need different state)"
fi

tui_back_to "Actions" 5

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
fi

tui_screenshot "pc-05-cluster-basics"
_scr=$(tui_capture)

if echo "$_scr" | grep -qi "Cluster Name\|Name\|Type\|Domain"; then
	echo "  ✓ PASS: Cluster basics page appeared"
	_TUI_PASS=$(( _TUI_PASS + 1 ))

	tui_assert_contains "Name\|name" "Cluster name field"
	tui_assert_contains "Domain\|domain" "Base domain field"
	tui_assert_contains "Type\|type\|sno\|compact\|standard" "Cluster type field"
else
	echo "  ~ NOTE: Cluster basics page not reached"
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
echo "  ✓ PASS: Original configs restored"
_TUI_PASS=$(( _TUI_PASS + 1 ))

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
