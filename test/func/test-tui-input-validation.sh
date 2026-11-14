#!/bin/bash
# Input validation only. Standalone — not called from test-tui-all.sh.
# Types bad values into the cluster wizard and, when the install form is
# already on screen, the mirror form. A rejected value must show the error
# and leave the saved config unchanged. Nothing is installed.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

_IV_NAME=ivchk
_IV_CREATED=no

_iv_cleanup() {
	if [ "$_IV_CREATED" = yes ]; then
		$_TUI_SSH "test -f ~/aba/${_IV_NAME}/.install-complete && exit 0
			rm -rf ~/aba/${_IV_NAME}" >/dev/null 2>&1 || true
		_IV_CREATED=no
	fi
}
trap _iv_cleanup EXIT

# Replace the inputbox contents. Empty clears the field.
_iv_replace() {
	local value="$1"
	tui_keys C-u
	sleep 0.2
	if [ -n "$value" ]; then
		_tui_ssh_retry "tmux send-keys -t $_TUI_SESSION -l -- $(printf '%q' "$value")"
		sleep 0.2
	fi
}

# Open a menu field, submit a bad value, require the error, confirm the
# inputbox is still open, then Escape so the previous value is kept.
_iv_reject() {
	local key="$1" value="$2" pattern="$3" field_title="$4" desc="$5"
	echo "  -- $desc"
	tui_keys "$key"
	sleep 0.4
	tui_keys Enter
	sleep 0.6
	_iv_replace "$value"
	tui_keys Enter
	sleep 0.8
	tui_assert_contains "$pattern" "$desc"
	tui_keys Enter
	sleep 0.5
	tui_assert_title "$field_title" "$desc stays on the field"
	tui_keys Escape
	sleep 0.4
}

# Cluster name runs `aba cluster --validate` before the menu returns.
_iv_wait_title() {
	local pattern="$1" timeout="${2:-25}" i title
	for (( i=0; i<timeout*2; i++ )); do
		title=$(tui_dialog_title)
		if echo "$title" | grep -qi "$pattern"; then
			return 0
		fi
		sleep 0.5
	done
	return 1
}

# Submit a good value and require the parent menu back.
_iv_accept() {
	local key="$1" value="$2" parent_title="$3" desc="$4"
	echo "  -- $desc"
	tui_keys "$key"
	sleep 0.4
	tui_keys Enter
	sleep 0.6
	_iv_replace "$value"
	tui_keys Enter
	if _iv_wait_title "$parent_title"; then
		echo "  ✓ PASS: $desc"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: $desc (still on '$(tui_dialog_title)')"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_screenshot "iv-accept-$(date +%H%M%S)"
	fi
}

# Extra-button Next. Do not Tab+Enter: that can hit Exit and leave the wizard.
_iv_next() {
	if ! tui_press_button "Next"; then
		echo "  ✗ FAIL: Next button not found"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_screenshot "iv-no-next-$(date +%H%M%S)"
		return 1
	fi
}

_iv_goto() {
	local pattern="$1" desc="$2" timeout="${3:-20}"
	if tui_wait_for "$pattern" "$timeout"; then
		echo "  ✓ PASS: $desc"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
		return 0
	fi
	echo "  ✗ FAIL: $desc"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_screenshot "iv-missing-$(date +%H%M%S)"
	return 1
}

echo "=== TUI Input Validation ==="
echo "  Host: $_TUI_HOST"
echo ""

tui_deploy_code
echo ""
tui_ensure_mirror_installed || { tui_summary; exit 1; }
echo ""
tui_start_to_menu || { tui_summary; exit 1; }

# Port 8443 can be pasta while the registry is stopped. The TUI trusts
# reg_state, which is cached, so a listening socket is not enough.
_iv_mirror_state() {
	$_TUI_SSH 'cd ~/aba && source scripts/include_all.sh && aba_mirror_runtime_refresh && aba_mirror_runtime_wait && aba_mirror_runtime_read' \
		| sed -n 's/^reg_state=//p' | head -1
}

echo ""
echo "--- Enter the cluster wizard ---"
tui_select_item "Install Cluster"
sleep 3
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Mirror Stopped\|registry.*stopped"; then
	tui_keys Enter
	sleep 1
	_state=$(_iv_mirror_state)
	echo "  Mirror runtime state: ${_state:-unknown}"
	if [ "$_state" != "ready" ]; then
		echo "  Starting the mirror..."
		$_TUI_SSH 'cd ~/aba/mirror && aba start --yes' | tail -15
		_state=$(_iv_mirror_state)
		echo "  Mirror runtime state: ${_state:-unknown}"
	fi
	# This menu draw already cached reg_state. Help and back forces one
	# more read, after the refresh, before Install Cluster runs the gate.
	tui_press_button "Help" || true
	sleep 1
	tui_keys Enter
	sleep 1
	tui_select_item "Install Cluster"
	sleep 3
	_scr=$(tui_capture)
	if echo "$_scr" | grep -qi "Mirror Stopped\|registry.*stopped"; then
		tui_keys Enter
		sleep 1
		echo "  ✗ FAIL: mirror still stopped after refresh (${_state:-unknown})"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		tui_screenshot "iv-mirror-stopped"
		tui_cleanup
		tui_summary
		exit 1
	fi
fi
if echo "$_scr" | grep -qi "already installed\|Cluster Already"; then
	tui_press_button "New Cluster" 2>/dev/null || tui_keys Enter
	sleep 2
fi
if ! _iv_goto "Cluster Name\|Base domain\|Cluster – Basics" "Basics page"; then
	tui_cleanup
	tui_summary
	exit 1
fi

echo ""
echo "--- Cluster name ---"
_iv_reject N "" "cannot be empty" "Cluster Name" "empty cluster name"
_iv_reject N "Bad_Name" "invalid cluster name" "Cluster Name" "cluster name with uppercase"
_iv_accept N "$_IV_NAME" "Cluster – Basics" "valid cluster name returns to Basics"
tui_assert_contains "$_IV_NAME" "Basics shows $_IV_NAME"

echo ""
echo "--- Base domain ---"
_iv_reject D "10.0.0.1" "looks like an IP address" "Base Domain" "domain that is an IP"
_iv_reject D "not a domain" "Invalid base domain" "Base Domain" "domain with a space"
_iv_accept D "example.com" "Cluster – Basics" "valid domain returns to Basics"

echo ""
echo "--- Type and worker count ---"
_n=0
while [ "$_n" -lt 3 ]; do
	_scr=$(tui_capture)
	echo "$_scr" | grep -q "Type:.*standard" && break
	tui_keys T
	sleep 0.3
	tui_keys Enter
	sleep 0.5
	_n=$(( _n + 1 ))
done
if tui_capture | grep -q "Type:.*standard"; then
	echo "  ✓ PASS: type is standard"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: could not set type to standard"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi
_iv_reject W "abc" "Invalid worker count" "Worker Count" "worker count that is not a number"
_iv_reject W "0" "at least 1 worker" "Worker Count" "zero workers on standard"
_iv_accept W "2" "Cluster – Basics" "valid worker count returns to Basics"

echo ""
echo "--- Networking ---"
# Next writes a new cluster directory. Refuse to reuse a directory that is
# already on disk — that would overwrite somebody's cluster.conf.
if $_TUI_SSH "test -d ~/aba/${_IV_NAME}"; then
	echo "  ✗ FAIL: ~/aba/${_IV_NAME} already exists — not touching it"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_cleanup
	tui_summary
	exit 1
fi
_IV_CREATED=yes
_iv_next || { tui_cleanup; tui_summary; exit 1; }
# Next generates cluster.conf. That can take a while on a cold tree.
if ! _iv_goto "Cluster – Networking" "Networking page" 90; then
	tui_cleanup
	tui_summary
	exit 1
fi
# The directory now exists. Remove it at the end unless this name was already there.
if [ "$_IV_CREATED" = yes ] && $_TUI_SSH "test -f ~/aba/${_IV_NAME}/.install-complete"; then
	echo "  ✗ FAIL: $_IV_NAME is already installed — not deleting it"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	_IV_CREATED=no
fi

_iv_reject M "10.0.0.0" "Invalid CIDR" "Machine Network" "CIDR without a prefix"
_iv_accept M "10.0.0.0/20" "Cluster – Networking" "valid CIDR returns to Networking"
_iv_reject S "10.0.1" "Invalid IP address" "Starting IP" "starting IP with three octets"
_iv_reject A "10.0.1" "Invalid IP address" "API VIP" "API VIP with three octets"
_iv_reject I "10.0.1" "Invalid IP address" "Ingress VIP" "ingress VIP with three octets"
_iv_reject D "dns.lab" "Invalid DNS entry" "DNS Servers" "DNS hostname instead of an IP"
_iv_reject G "gateway" "Invalid IP address" "Gateway" "gateway that is not an IP"
_iv_reject N "!!!" "Invalid NTP entry" "NTP Servers" "NTP with punctuation"

echo ""
echo "--- Interfaces ---"
_iv_next || { tui_cleanup; tui_summary; exit 1; }
if ! _iv_goto "Cluster – Interfaces" "Interfaces page" 30; then
	tui_cleanup
	tui_summary
	exit 1
fi
# A space is a separator, same as a comma, so "ens 160" is two valid names.
_iv_reject P "ens/160" "Invalid port name" "Port Names" "port name with a slash"
_iv_reject V "4095" "Invalid VLAN tag" "VLAN Tag" "VLAN 4095"
_iv_reject V "0" "Invalid VLAN tag" "VLAN Tag" "VLAN 0"
# SSH rejects back to the Interfaces menu. Escape here would leave the wizard.
echo "  -- SSH key that is not an absolute path"
tui_keys K
sleep 0.4
tui_keys Enter
sleep 0.6
_iv_replace "id_rsa"
tui_keys Enter
sleep 0.8
tui_assert_contains "Invalid path" "SSH key that is not an absolute path"
tui_keys Enter
sleep 0.5
tui_assert_title "Cluster – Interfaces" "SSH error returns to Interfaces"

echo ""
echo "--- VM resources ---"
_iv_next || { tui_cleanup; tui_summary; exit 1; }
sleep 2
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "Review\|Install anyway\|Begin install"; then
	echo "  ✗ FAIL: review page opened before VM checks — backing out"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_press_button "Back" 2>/dev/null || tui_keys Escape
	sleep 1
elif _iv_goto "Cluster – VM Resources" "VM resources page" 20; then
	_iv_reject C "1" "Must be at least 4" "Master CPUs" "master CPU below 4"
	_iv_reject R "8" "Must be at least 16" "Master Memory" "master memory below 16 GB"
	_iv_reject W "1" "Must be at least 2" "Worker CPUs" "worker CPU below 2"
	_iv_reject E "4" "Must be at least 8" "Worker Memory" "worker memory below 8 GB"
	_iv_reject D "disk" "non-negative number" "Data disk" "data disk that is not a number"
	# MAC rejects back to the VM menu. Escape here would leave the wizard.
	echo "  -- MAC prefix 00:11"
	tui_keys A
	sleep 0.4
	tui_keys Enter
	sleep 0.6
	_iv_replace "00:11"
	tui_keys Enter
	sleep 0.8
	tui_assert_contains "Invalid MAC prefix" "MAC prefix 00:11"
	tui_keys Enter
	sleep 0.5
	tui_assert_title "Cluster – VM Resources" "MAC error returns to VM resources"
	_iv_accept A "00:50:56:1a:2b:" "Cluster – VM Resources" "valid MAC prefix returns to VM resources"
fi

echo ""
echo "--- Leave the wizard without installing ---"
# One Escape leaves the wizard. More Escapes reach Confirm Exit, and
# Escape on that dialog quits the TUI. tui_back_to stops on Actions
# and chooses Continue if the exit dialog is up.
tui_back_to "Actions" 8
tui_assert_contains "Actions" "back at the main menu"
if $_TUI_SSH "test -d ~/aba/${_IV_NAME} && test ! -f ~/aba/${_IV_NAME}/.install-complete"; then
	echo "  ✓ PASS: $_IV_NAME was not installed"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: $_IV_NAME is missing or was installed"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

echo ""
echo "--- Mirror form ---"
# Install Mirror on a host that already has a registry offers to uninstall it.
# This suite must not do that. The form is tested only when it is already open.
tui_select_item "Install Mirror" 2>/dev/null || tui_select_item "Install Registry" 2>/dev/null || true
sleep 2
_scr=$(tui_capture)
if echo "$_scr" | grep -qi "already installed\|Reinstall"; then
	echo "  ✓ PASS: mirror form is behind reinstall — left it alone"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
	tui_press_button "No" 2>/dev/null || tui_keys Escape
	sleep 1
elif echo "$_scr" | grep -qi "Install locally\|remote host"; then
	tui_keys Enter
	sleep 2
	if _iv_goto "Hostname\|Mirror Configuration\|Install Mirror" "mirror config form" 15; then
		_before=$($_TUI_SSH "grep -E '^(reg_host|reg_port|reg_user|reg_path|data_dir)=' ~/aba/mirror/mirror.conf 2>/dev/null" || true)
		# Mirror rejects back to the menu. The file must stay unchanged.
		_iv_mirror_reject() {
			local key="$1" value="$2" pattern="$3" desc="$4"
			echo "  -- $desc"
			tui_keys "$key"
			sleep 0.4
			tui_keys Enter
			sleep 0.6
			_iv_replace "$value"
			tui_keys Enter
			sleep 0.8
			tui_assert_contains "$pattern" "$desc"
			tui_keys Enter
			sleep 0.5
		}
		_iv_mirror_reject H "10.0.0.10" "Invalid hostname" "mirror hostname that is an IP"
		_iv_mirror_reject P "0" "Invalid port" "mirror port 0"
		_iv_mirror_reject U "1bad" "Invalid username" "mirror username starting with a digit"
		_iv_mirror_reject I "quay" "Invalid image path" "mirror image path without a leading slash"
		_iv_mirror_reject D "quay-data" "Invalid directory path" "mirror data dir that is not absolute"
		_after=$($_TUI_SSH "grep -E '^(reg_host|reg_port|reg_user|reg_path|data_dir)=' ~/aba/mirror/mirror.conf 2>/dev/null" || true)
		if [ "$_before" = "$_after" ]; then
			echo "  ✓ PASS: mirror.conf unchanged after rejected values"
			_TUI_PASS=$(( _TUI_PASS + 1 ))
		else
			echo "  ✗ FAIL: mirror.conf changed after rejected values"
			_TUI_FAIL=$(( _TUI_FAIL + 1 ))
		fi
		tui_keys Escape
		sleep 0.5
		tui_keys Escape
		sleep 0.5
	fi
else
	echo "  ✗ FAIL: mirror install screen not recognized"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	tui_screenshot "iv-mirror-unknown"
	tui_keys Escape
	sleep 0.5
fi

echo ""
_iv_cleanup
tui_cleanup
tui_summary
