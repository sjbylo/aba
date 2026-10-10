#!/usr/bin/env bash
# =============================================================================
# Standalone Mirror Vendor Matrix Test
# =============================================================================
# Same logic as the E2E suite but no framework dependency.
# Run from an ABA working directory on a connected host (e.g. conN, bastion).
#
# Usage:
#   ./test/func/test-mirror-vendor-matrix.sh                      # full matrix
#   ./test/func/test-mirror-vendor-matrix.sh --vendor docker      # one vendor
#   ./test/func/test-mirror-vendor-matrix.sh --vendor omr --mode local
#   ./test/func/test-mirror-vendor-matrix.sh --skip-extras        # matrix only
#   ./test/func/test-mirror-vendor-matrix.sh --extras-only        # extras only
#   ./test/func/test-mirror-vendor-matrix.sh --list               # show plan
#
# Prerequisites:
#   - ABA installed (./install done)
#   - aba.conf configured
#   - For remote tests: DIS_HOST reachable via SSH with root/steve/testy users
#   - SSH keys: ~/.ssh/id_rsa (root, steve), ~/.ssh/testy_rsa (testy)
# =============================================================================

set -u

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/aba")" || exit 1

# ---- Configuration ---------------------------------------------------------

# Override via env or flags
DIS_HOST="${DIS_HOST:-dis1.example.com}"
CON_HOST="${CON_HOST:-$(hostname -f)}"
SSH_CONF="${SSH_CONF:-$HOME/.aba/ssh.conf}"

# Small public image for push/check tests
_IMG_SRC="docker.io/library/busybox:latest"
_IMG1="e2e-vendor-test/img1:v1"
_IMG2="e2e-vendor-test/img2:v1"

# Port allocation: every test gets a unique port to avoid clobbering.
# "default" tests use 6100-range, "custom" tests use 6200-range.
declare -A _DPORT=([docker]=6101 [quay]=6102 [omr]=6103)
declare -A _CPORT=([docker]=6201 [quay]=6202 [omr]=6203)
_CUSER="e2eadmin"
_CPATH="/sa-images"

# SSH key per user
declare -A _SSHKEY=([root]=~/.ssh/id_rsa [steve]=~/.ssh/id_rsa [testy]=~/.ssh/testy_rsa)

# Safe special characters for random passwords
_E2E_PW_SPECIAL='!@#%^&|~=_-'
_E2E_PW_ALNUM='A-Za-z0-9'

# Matrix dimensions (overridable via flags)
# Order: most failure-prone first so we don't wait hours for the easy ones
_VENDORS=(omr quay docker)
_MODES=(remote local)
_USERS=(root steve testy)
_CONFIGS=(default custom)

# ---- Filters (set by CLI flags) -------------------------------------------
_FILTER_VENDOR=""
_FILTER_MODE=""
_FILTER_USER=""
_FILTER_CONFIG=""
_SKIP_EXTRAS=""
_EXTRAS_ONLY=""
_LIST_ONLY=""

# ---- Counters --------------------------------------------------------------
_PASS=0
_FAIL=0
_SKIP=0
_TOTAL=0

# ---- Colors ----------------------------------------------------------------
_green()  { printf "\033[32m%s\033[0m" "$*"; }
_red()    { printf "\033[31m%s\033[0m" "$*"; }
_yellow() { printf "\033[33m%s\033[0m" "$*"; }
_bold()   { printf "\033[1m%s\033[0m" "$*"; }
_dim()    { printf "\033[2m%s\033[0m" "$*"; }

# ---- Logging ---------------------------------------------------------------
_LOG_FILE="/tmp/test-mirror-vendor-matrix-$(date +%Y%m%d-%H%M%S).log"

_log() {
	echo "[$(date +%H:%M:%S)] $*" | tee -a "$_LOG_FILE"
}

# ---- Core run function with retry -----------------------------------------
run_step() {
	local desc="$1"; shift
	local cmd="$*"
	local attempt max_attempts=3

	_log "  STEP: $desc"
	_log "    CMD: $cmd"

	for (( attempt=1; attempt<=max_attempts; attempt++ )); do
		if (eval "$cmd") >> "$_LOG_FILE" 2>&1; then
			_log "    $(_green PASS) (attempt $attempt)"
			return 0
		fi
		if [ "$attempt" -lt "$max_attempts" ]; then
			_log "    $(_yellow "attempt $attempt failed, retrying in 10s ...")"
			sleep 10
		fi
	done

	_log "    $(_red "FAIL after $max_attempts attempts")"
	return 1
}

# ---- Test block wrapper ----------------------------------------------------
_current_test=""
_test_failed=""

test_begin() {
	_current_test="$1"
	_test_failed=""
	_TOTAL=$(( _TOTAL + 1 ))
	echo ""
	_log "$(_bold "═══ TEST [$_TOTAL]: $1 ═══")"
}

test_end() {
	if [ -n "$_test_failed" ]; then
		_FAIL=$(( _FAIL + 1 ))
		_log "$(_red "RESULT: FAIL — $_current_test")"
	else
		_PASS=$(( _PASS + 1 ))
		_log "$(_green "RESULT: PASS — $_current_test")"
	fi
	_current_test=""
}

# Like run_step but marks the test as failed on error (does not abort)
run() {
	if ! run_step "$@"; then
		_test_failed=1
		return 1
	fi
}

# ---- Password generator ----------------------------------------------------
_gen_password() {
	local special alnum pw
	# 50/50 mix: 8 special + 8 alnum = 16 chars
	special=$(LC_ALL=C tr -dc "$_E2E_PW_SPECIAL" < /dev/urandom | head -c 8)
	alnum=$(LC_ALL=C tr -dc "$_E2E_PW_ALNUM" < /dev/urandom | head -c 8)
	pw=$(echo -n "${special}${alnum}" | fold -w1 | shuf | tr -d '\n')
	echo "$pw"
}

# ---- Localhost detection ---------------------------------------------------
_is_local() {
	local h="$1"
	local my_fqdn; my_fqdn=$(hostname -f 2>/dev/null || hostname)
	local my_short; my_short=$(hostname -s 2>/dev/null || hostname)
	[[ "$h" == "localhost" || "$h" == "127.0.0.1" || "$h" == "$my_fqdn" || "$h" == "$my_short" ]]
}

# ---- Helpers (same logic as E2E suite) -------------------------------------

_vm_dir() {
	local v="$1" m="$2" u="$3" c="$4"
	local ms; [ "$m" = "remote" ] && ms="rem" || ms="loc"
	local cs; [ "$c" = "default" ] && cs="def" || cs="cst"
	if [ -n "$u" ]; then
		echo "sa-vm-${v}-${ms}-${u}-${cs}"
	else
		echo "sa-vm-${v}-${ms}-${cs}"
	fi
}

_vm_name() {
	local v="$1" m="$2" u="$3" c="$4"
	if [ -n "$u" ]; then
		echo "${v} ${m} ${u} ${c}"
	else
		echo "${v} ${m} ${c}"
	fi
}

_vm_flags() {
	local v="$1" m="$2" u="$3" c="$4" dn="$5" pw="${6:-}"
	local f="--vendor $v"

	if [ "$m" = "remote" ]; then
		f+=" -H $DIS_HOST -k ${_SSHKEY[$u]} --reg-ssh-user $u"
	else
		f+=" -H $CON_HOST"
		# If CON_HOST isn't localhost, it's effectively a remote install
		if ! _is_local "$CON_HOST"; then
			f+=" -k ~/.ssh/id_rsa --reg-ssh-user $USER"
		fi
	fi

	# Always use isolated ports and data dirs to avoid clobbering
	# anything else running on the host
	if [ "$c" = "custom" ]; then
		f+=" --reg-port ${_CPORT[$v]}"
		f+=" --reg-user $_CUSER"
		f+=" --reg-password '$pw'"
		f+=" --reg-path $_CPATH"
	else
		f+=" --reg-port ${_DPORT[$v]}"
		[ -n "$pw" ] && f+=" --reg-password '$pw'"
	fi
	f+=" --data-dir '~/sa-vm-data-${dn}'"

	echo "$f"
}

_vm_url() {
	local m="$1" v="$2" c="$3"
	local h p
	[ "$m" = "remote" ] && h="$DIS_HOST" || h="$CON_HOST"
	[ "$c" = "custom" ] && p="${_CPORT[$v]}" || p="${_DPORT[$v]}"
	echo "https://${h}:${p}"
}

_vm_push() {
	local dn="$1" dest="$2"
	echo "cd $dn && source ../scripts/include_all.sh && source <(normalize-mirror-conf) && skopeo copy --dest-tls-verify=false --dest-authfile \$HOME/.aba/mirror/$dn/pull-secret-mirror.json docker://$_IMG_SRC docker://\${reg_host}:\${reg_port}\${reg_path}/$dest"
}

_vm_check() {
	local dn="$1" img="$2"
	echo "cd $dn && source ../scripts/include_all.sh && source <(normalize-mirror-conf) && skopeo inspect --tls-verify=false --authfile \$HOME/.aba/mirror/$dn/pull-secret-mirror.json docker://\${reg_host}:\${reg_port}\${reg_path}/$img | grep -q Digest"
}

# Assert a value in state.sh for a given mirror dir
_assert_state() {
	local dn="$1" key="$2" expected="$3"
	local state_file="$HOME/.aba/mirror/$dn/state.sh"
	local actual
	actual=$(grep "^[[:space:]]*${key}=" "$state_file" 2>/dev/null | head -1 | sed 's/^[[:space:]]*//' | cut -d= -f2-) || true
	[ "$actual" = "$expected" ]
}

_vm_check_data_dir() {
	local v="$1" m="$2" u="$3" c="$4" dn="$5" assertion="$6"
	local test_op="test -d"
	[ "$assertion" = "gone" ] && test_op="! test -d"

	local suffix
	case "$v" in
		docker)  suffix="docker-reg" ;;
		quay)    suffix="quay-install" ;;
		omr) suffix="omr" ;;
	esac

	# Always under isolated data dir (never default ~/<suffix>)
	local path="~/sa-vm-data-${dn}/${suffix}"

	if [ "$m" = "remote" ]; then
		echo "ssh -i ${_SSHKEY[$u]} -F $SSH_CONF ${u}@${DIS_HOST} '$test_op $path'"
	elif ! _is_local "$CON_HOST"; then
		echo "ssh -F $SSH_CONF ${USER}@${CON_HOST} '$test_op $path'"
	else
		local expanded="${path/#\~/$HOME}"
		echo "$test_op '$expanded'"
	fi
}

# ---- Assert host port is free ----------------------------------------------
_assert_port_free() {
	local host="$1" port="$2"
	if curl -sk --connect-timeout 3 "https://${host}:${port}/v2/" &>/dev/null; then
		_log "$(_red "ABORT: Port $port on $host is already in use!")"
		_log "A prior test or run left a registry running. Fix and clean up manually."
		exit 1
	fi
}

# ---- Full test for one vendor/mode/user/config combination ----------------
_vm_test() {
	local v="$1" m="$2" u="$3" c="$4"
	local dn _pw flags url
	dn=$(_vm_dir "$v" "$m" "$u" "$c")
	_pw=$(_gen_password)
	flags=$(_vm_flags "$v" "$m" "$u" "$c" "$dn" "$_pw")
	url=$(_vm_url "$m" "$v" "$c")
	local _host
	[ "$m" = "remote" ] && _host="$DIS_HOST" || _host="$CON_HOST"
	local _port
	[ "$c" = "custom" ] && _port="${_CPORT[$v]}" || _port="${_DPORT[$v]}"

	# Assert: port must be free before we start
	_assert_port_free "$_host" "$_port"

	# Assert: no leftover mirror dir
	[ -d "$dn" ] && { _log "$(_red "ABORT: leftover dir $dn from prior run")"; exit 1; }

	# Phase 1: install → verify → push img1 → check img1
	run "Create mirror dir" "aba mirror --name $dn"

	run "Install registry (pw=$_pw)" "aba -d $dn install $flags"
	run "Verify registry" "aba -d $dn verify"

	# Verify state.sh values match what was installed
	run "state.sh: reg_vendor=$v" "_assert_state '$dn' reg_vendor '$v'"
	run "state.sh: reg_port=$_port" "_assert_state '$dn' reg_port '$_port'"
	run "state.sh: reg_host=$_host" "_assert_state '$dn' reg_host '$_host'"
	run "state.sh: reg_pw matches" "_assert_state '$dn' reg_pw \"'$_pw'\""
	if [ "$m" = "remote" ]; then
		run "state.sh: reg_ssh_key" "_assert_state '$dn' reg_ssh_key '${_SSHKEY[$u]}'"
	fi

	run "Push test image 1" "$(_vm_push "$dn" "$_IMG1")"
	run "Check image 1 exists" "$(_vm_check "$dn" "$_IMG1")"

	# Phase 2: uninstall keeping data → assert port free, data preserved
	run "Uninstall (keep data)" "aba -d $dn uninstall"
	run "Assert port free after uninstall" "! curl -sk --connect-timeout 5 $url/v2/"
	run "Assert data dir preserved" "$(_vm_check_data_dir "$v" "$m" "$u" "$c" "$dn" "exists")"

	# Phase 3: re-install → verify → check img1 survived → push img2 → check both
	run "Re-install (from mirror.conf)" "aba -d $dn install"
	run "Verify after re-install" "aba -d $dn verify"
	run "Assert image 1 survived reinstall" "$(_vm_check "$dn" "$_IMG1")"
	run "Push image 2" "$(_vm_push "$dn" "$_IMG2")"
	run "Assert image 1 present" "$(_vm_check "$dn" "$_IMG1")"
	run "Assert image 2 present" "$(_vm_check "$dn" "$_IMG2")"

	# Phase 4: uninstall deleting data → assert fully clean
	run "Uninstall (delete data)" "aba -d $dn uninstall --delete-data"
	run "Assert port free after delete" "! curl -sk --connect-timeout 5 $url/v2/"
	run "Assert data dir removed" "$(_vm_check_data_dir "$v" "$m" "$u" "$c" "$dn" "gone")"
	run "Assert mirror dir removable" "rm -rf $dn $HOME/.aba/mirror/$dn"
}

# ---- Filter check ----------------------------------------------------------
_should_run() {
	local v="$1" m="$2" u="${3:-}" c="${4:-}"
	[ -n "$_FILTER_VENDOR" ] && [ "$v" != "$_FILTER_VENDOR" ] && return 1
	[ -n "$_FILTER_MODE" ]   && [ "$m" != "$_FILTER_MODE" ]   && return 1
	[ -n "$_FILTER_USER" ]   && [ "$u" != "$_FILTER_USER" ]   && return 1
	[ -n "$_FILTER_CONFIG" ] && [ "$c" != "$_FILTER_CONFIG" ] && return 1
	return 0
}

# ---- Parse CLI flags -------------------------------------------------------
while [ $# -gt 0 ]; do
	case "$1" in
		--vendor)       _FILTER_VENDOR="$2"; shift 2 ;;
		--mode)         _FILTER_MODE="$2"; shift 2 ;;
		--user)         _FILTER_USER="$2"; shift 2 ;;
		--config)       _FILTER_CONFIG="$2"; shift 2 ;;
		--dis-host)     DIS_HOST="$2"; shift 2 ;;
		--con-host)     CON_HOST="$2"; shift 2 ;;
		--skip-extras)  _SKIP_EXTRAS=1; shift ;;
		--extras-only)  _EXTRAS_ONLY=1; shift ;;
		--list)         _LIST_ONLY=1; shift ;;
		-h|--help)
			echo "Usage: $0 [OPTIONS]"
			echo ""
			echo "Filters:"
			echo "  --vendor docker|quay|omr   Run only one vendor"
			echo "  --mode remote|local            Run only one mode"
			echo "  --user root|steve|testy         Run only one user (remote only)"
			echo "  --config default|custom         Run only one config"
			echo "  --skip-extras                   Skip extra tests (pw edge, port reuse, etc.)"
			echo "  --extras-only                   Run only extra tests"
			echo ""
			echo "Hosts:"
			echo "  --dis-host HOST                 Disconnected host (default: $DIS_HOST)"
			echo "  --con-host HOST                 Connected host (default: $CON_HOST)"
			echo ""
			echo "Other:"
			echo "  --list                          Show test plan and exit"
			exit 0
			;;
		*) echo "Unknown flag: $1"; exit 1 ;;
	esac
done

# ---- Build test plan -------------------------------------------------------
_plan=()

if [ -z "$_EXTRAS_ONLY" ]; then
	for _v in "${_VENDORS[@]}"; do
		for _m in "${_MODES[@]}"; do
			if [ "$_m" = "remote" ]; then _uloop=("${_USERS[@]}"); else _uloop=(""); fi
			for _u in "${_uloop[@]}"; do
				for _c in "${_CONFIGS[@]}"; do
					_should_run "$_v" "$_m" "$_u" "$_c" || continue
					_plan+=("$(_vm_name "$_v" "$_m" "$_u" "$_c")")
				done
			done
		done
	done
fi

if [ -z "$_SKIP_EXTRAS" ]; then
	_plan+=(
		"Password edge cases"
		"Register existing registry"
		"Vendor switch (docker→quay→omr)"
		"Port reuse across vendors"
		"Concurrent local registries"
	)
fi

if [ -n "$_LIST_ONLY" ]; then
	echo "Test plan (${#_plan[@]} tests):"
	for _t in "${_plan[@]}"; do
		echo "  $_t"
	done
	exit 0
fi

# ---- Banner ----------------------------------------------------------------
echo ""
_log "$(_bold "════════════════════════════════════════════════════════════")"
_log "$(_bold "  Standalone Mirror Vendor Matrix Test")"
_log "$(_bold "════════════════════════════════════════════════════════════")"
_log "  DIS_HOST: $DIS_HOST"
_log "  CON_HOST: $CON_HOST"
_log "  Tests:    ${#_plan[@]}"
_log "  Log:      $_LOG_FILE"
_log "$(_bold "════════════════════════════════════════════════════════════")"
echo ""

# ---- Preflight check: abort if leftovers from a prior run exist ------------
_log "Preflight check ..."
_leftovers=""
for _leftover in sa-vm-*/mirror.conf; do
	[ -f "$_leftover" ] || continue
	_leftovers+="  $(dirname "$_leftover")"$'\n'
done
if [ -n "$_leftovers" ]; then
	_log "$(_red "ERROR: Leftover mirror dirs from a prior run:")"
	_log "$_leftovers"
	_log "Clean up manually before re-running (aba -d <dir> uninstall --delete-data)."
	exit 1
fi
_log "Preflight check passed."

# ============================================================================
# Matrix tests
# ============================================================================
if [ -z "$_EXTRAS_ONLY" ]; then
	for _v in "${_VENDORS[@]}"; do
		for _m in "${_MODES[@]}"; do
			if [ "$_m" = "remote" ]; then _uloop=("${_USERS[@]}"); else _uloop=(""); fi
			for _u in "${_uloop[@]}"; do
				for _c in "${_CONFIGS[@]}"; do
					_should_run "$_v" "$_m" "$_u" "$_c" || continue
					test_begin "$(_vm_name "$_v" "$_m" "$_u" "$_c")"
					_vm_test "$_v" "$_m" "$_u" "$_c"
					test_end
				done
			done
		done
	done
fi

# ============================================================================
# Extra tests (only when no vendor/mode/user/config filter active)
# ============================================================================
if [ -z "$_SKIP_EXTRAS" ]; then

# ---- Password edge cases --------------------------------------------------
test_begin "Password edge cases"

_HARD_PASSWORDS=(
	'-leadingDash'
	'--double-dash'
	'=leading=Equals'
	'!@#%^&|~=_-!@#%'
	'-=~!@#%^&|_-=~!'
	'PoT_&B_EAyf=8WS7'
	'--------'
	'========X1======'
	"$(_gen_password)"
	"$(_gen_password)"
	"$(_gen_password)"
	"$(_gen_password)"
)

_pw_idx=0
_pw_base_port=6300
for _hardpw in "${_HARD_PASSWORDS[@]}"; do
	_pw_idx=$(( _pw_idx + 1 ))
	_pw_port=$(( _pw_base_port + _pw_idx ))
	_pw_dn="sa-vm-pw-edge-${_pw_idx}"

	_assert_port_free "$CON_HOST" "$_pw_port"
	run "Create mirror dir (pw-edge-${_pw_idx})" "aba mirror --name $_pw_dn"
	run "Install docker with pw='${_hardpw}' (#${_pw_idx})" \
		"aba -d $_pw_dn install --vendor docker -H $CON_HOST --reg-port $_pw_port --reg-password '${_hardpw}' --data-dir '~/sa-vm-data-${_pw_dn}'"
	run "Verify registry (pw-edge-${_pw_idx})" "aba -d $_pw_dn verify"
	run "Push test image (pw-edge-${_pw_idx})" "$(_vm_push "$_pw_dn" "sa-pw-test/img:v${_pw_idx}")"
	run "Assert test image (pw-edge-${_pw_idx})" "$(_vm_check "$_pw_dn" "sa-pw-test/img:v${_pw_idx}")"
	run "Uninstall (pw-edge-${_pw_idx})" "aba -d $_pw_dn uninstall --delete-data"
	run "Assert port free (pw-edge-${_pw_idx})" "! curl -sk --connect-timeout 3 https://${CON_HOST}:${_pw_port}/v2/"
	run "Assert dir removable (pw-edge-${_pw_idx})" "rm -rf $_pw_dn $HOME/.aba/mirror/$_pw_dn"
done

test_end

# ---- Register existing registry -------------------------------------------
test_begin "Register existing registry"

_REG_INSTALL_DN="sa-vm-reg-install"
_REG_REGISTER_DN="sa-vm-reg-register"
_REG_PW=$(_gen_password)

run "Create install mirror dir" "aba mirror --name $_REG_INSTALL_DN"
run "Install Docker registry" \
	"aba -d $_REG_INSTALL_DN install --vendor docker -H $DIS_HOST -k ~/.ssh/id_rsa --reg-ssh-user steve --reg-port 6401 --reg-password '$_REG_PW' --data-dir '~/sa-vm-data-${_REG_INSTALL_DN}'"
run "Verify installed registry" "aba -d $_REG_INSTALL_DN verify"

run "Create register mirror dir" "aba mirror --name $_REG_REGISTER_DN"
run "Register existing registry" \
	"aba -d $_REG_REGISTER_DN register \
	 --pull-secret-mirror \$HOME/.aba/mirror/$_REG_INSTALL_DN/pull-secret-mirror.json \
	 --ca-cert \$HOME/.aba/mirror/$_REG_INSTALL_DN/rootCA.pem"
run "Verify registered registry" "aba -d $_REG_REGISTER_DN verify"

run "Push image via registered dir" "$(_vm_push "$_REG_REGISTER_DN" "sa-register-test/img:v1")"
run "Check image via registered dir" "$(_vm_check "$_REG_REGISTER_DN" "sa-register-test/img:v1")"
run "Check image via install dir" "$(_vm_check "$_REG_INSTALL_DN" "sa-register-test/img:v1")"

run "Unregister" "aba -d $_REG_REGISTER_DN unregister"
run "Uninstall" "aba -d $_REG_INSTALL_DN uninstall --delete-data"
run "Assert port free" "! curl -sk --connect-timeout 3 https://${DIS_HOST}:6401/v2/"
run "Assert dirs removable" "rm -rf $_REG_INSTALL_DN $_REG_REGISTER_DN $HOME/.aba/mirror/$_REG_INSTALL_DN $HOME/.aba/mirror/$_REG_REGISTER_DN"

test_end

# ---- Vendor switch ---------------------------------------------------------
test_begin "Vendor switch (docker→quay→omr)"

_VS_DN="sa-vm-vendor-switch"
_VS_PW=$(_gen_password)

run "Create mirror dir" "aba mirror --name $_VS_DN"

run "Install Docker" \
	"aba -d $_VS_DN install --vendor docker -H $DIS_HOST -k ~/.ssh/id_rsa --reg-ssh-user steve --reg-port 6501 --reg-password '$_VS_PW' --data-dir '~/sa-vm-data-${_VS_DN}'"
run "Verify Docker" "aba -d $_VS_DN verify"
run "Push image (docker)" "$(_vm_push "$_VS_DN" "sa-vswitch/img:docker")"
run "Uninstall Docker (keep data)" "aba -d $_VS_DN uninstall"

run "Install Quay (vendor switch)" \
	"aba -d $_VS_DN install --vendor quay -H $DIS_HOST -k ~/.ssh/id_rsa --reg-ssh-user steve --reg-port 6501 --data-dir '~/sa-vm-data-${_VS_DN}'"
run "Verify Quay" "aba -d $_VS_DN verify"
run "Push image (quay)" "$(_vm_push "$_VS_DN" "sa-vswitch/img:quay")"
run "Uninstall Quay (keep data)" "aba -d $_VS_DN uninstall"

run "Install omr (vendor switch)" \
	"aba -d $_VS_DN install --vendor omr -H $DIS_HOST -k ~/.ssh/id_rsa --reg-ssh-user steve --reg-port 6501 --reg-password '$_VS_PW' --data-dir '~/sa-vm-data-${_VS_DN}'"
run "Verify omr" "aba -d $_VS_DN verify"
run "Push image (omr)" "$(_vm_push "$_VS_DN" "sa-vswitch/img:omr")"
run "Uninstall omr (delete data)" "aba -d $_VS_DN uninstall --delete-data"
run "Assert port free" "! curl -sk --connect-timeout 3 https://${DIS_HOST}:6501/v2/"
run "Assert dir removable" "rm -rf $_VS_DN $HOME/.aba/mirror/$_VS_DN"

test_end

# ---- Port reuse across vendors --------------------------------------------
test_begin "Port reuse across vendors"

_PR_PORT=6601
_PR_PW='PortReuse26pw'  # Alphanumeric only — Quay v1 has an upstream bug where passwords
                        # containing "!!" cause 401 "Invalid bearer token format".
                        # This test validates port reuse, not password handling.

for _pr_vendor in docker quay omr; do
	_PR_DN="sa-vm-portreuse-${_pr_vendor}"

	run "Create mirror dir (${_pr_vendor})" "aba mirror --name $_PR_DN"
	run "Install ${_pr_vendor} on :${_PR_PORT}" \
		"aba -d $_PR_DN install --vendor ${_pr_vendor} -H $DIS_HOST -k ~/.ssh/id_rsa --reg-ssh-user steve --reg-port $_PR_PORT --reg-password '$_PR_PW' --data-dir '~/sa-vm-data-${_PR_DN}'"
	run "Verify ${_pr_vendor} on :${_PR_PORT}" "aba -d $_PR_DN verify"
	run "Push image (${_pr_vendor})" "$(_vm_push "$_PR_DN" "sa-portreuse/img:${_pr_vendor}")"
	run "Uninstall ${_pr_vendor} (delete data)" "aba -d $_PR_DN uninstall --delete-data"
	run "Assert :${_PR_PORT} free" "! curl -sk --connect-timeout 5 https://${DIS_HOST}:${_PR_PORT}/v2/"
	run "Assert dir removable (${_pr_vendor})" "rm -rf $_PR_DN $HOME/.aba/mirror/$_PR_DN"
done

test_end

# ---- Concurrent local registries ------------------------------------------
test_begin "Concurrent local registries"

_CC_DN1="sa-vm-concurrent-1"
_CC_DN2="sa-vm-concurrent-2"
_CC_PW1=$(_gen_password)
_CC_PW2=$(_gen_password)

run "Create mirror dir 1" "aba mirror --name $_CC_DN1"
run "Create mirror dir 2" "aba mirror --name $_CC_DN2"

run "Install docker on :6701" \
	"aba -d $_CC_DN1 install --vendor docker -H $CON_HOST --reg-port 6701 --reg-password '$_CC_PW1' --data-dir '~/sa-vm-data-${_CC_DN1}'"
run "Install docker on :6702" \
	"aba -d $_CC_DN2 install --vendor docker -H $CON_HOST --reg-port 6702 --reg-password '$_CC_PW2' --data-dir '~/sa-vm-data-${_CC_DN2}'"

run "Verify registry 1" "aba -d $_CC_DN1 verify"
run "Verify registry 2" "aba -d $_CC_DN2 verify"

run "Push to registry 1" "$(_vm_push "$_CC_DN1" "sa-cc/only-in-1:v1")"
run "Push to registry 2" "$(_vm_push "$_CC_DN2" "sa-cc/only-in-2:v1")"
run "Check image in registry 1" "$(_vm_check "$_CC_DN1" "sa-cc/only-in-1:v1")"
run "Check image in registry 2" "$(_vm_check "$_CC_DN2" "sa-cc/only-in-2:v1")"

run "Assert no cross-contamination (1→2)" "! $(_vm_check "$_CC_DN2" "sa-cc/only-in-1:v1")"
run "Assert no cross-contamination (2→1)" "! $(_vm_check "$_CC_DN1" "sa-cc/only-in-2:v1")"

run "Uninstall registry 1" "aba -d $_CC_DN1 uninstall --delete-data"
run "Uninstall registry 2" "aba -d $_CC_DN2 uninstall --delete-data"
run "Assert port 6701 free" "! curl -sk --connect-timeout 3 https://${CON_HOST}:6701/v2/"
run "Assert port 6702 free" "! curl -sk --connect-timeout 3 https://${CON_HOST}:6702/v2/"
run "Assert dirs removable" "rm -rf $_CC_DN1 $_CC_DN2 $HOME/.aba/mirror/$_CC_DN1 $HOME/.aba/mirror/$_CC_DN2"

test_end

fi  # end extras

# ============================================================================
# Final assertions: nothing should be left behind
# ============================================================================
_log ""
_log "Final assertions ..."
_final_fail=""

# Assert: no leftover mirror dirs
_leftover_dirs=$(ls -d sa-vm-*/mirror.conf 2>/dev/null)
if [ -n "$_leftover_dirs" ]; then
	_log "$(_red "FAIL: leftover mirror dirs found:")"
	_log "$_leftover_dirs"
	_final_fail=1
fi

# Assert: no leftover local data dirs
_leftover_data=$(ls -d ~/sa-vm-data-sa-vm-* 2>/dev/null)
if [ -n "$_leftover_data" ]; then
	_log "$(_red "FAIL: leftover local data dirs found:")"
	_log "$_leftover_data"
	_final_fail=1
fi

# Assert: no leftover remote data dirs
for _fau in root steve testy; do
	_remote_leftover=$(ssh -F "$SSH_CONF" "$_fau@$DIS_HOST" "ls -d ~/sa-vm-data-sa-vm-* 2>/dev/null" 2>/dev/null)
	if [ -n "$_remote_leftover" ]; then
		_log "$(_red "FAIL: leftover data dirs on $DIS_HOST as $_fau:")"
		_log "$_remote_leftover"
		_final_fail=1
	fi
done

if [ -n "$_final_fail" ]; then
	_log "$(_red "Final assertions FAILED — aba uninstall --delete-data did not fully clean up!")"
	_FAIL=$(( _FAIL + 1 ))
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
_log "$(_bold "════════════════════════════════════════════════════════════")"
_log "$(_bold "  RESULTS")"
_log "$(_bold "════════════════════════════════════════════════════════════")"
_log "  $(_green "PASS: $_PASS")  $(_red "FAIL: $_FAIL")  Total: $(( _PASS + _FAIL ))"
_log "  Log: $_LOG_FILE"
_log "$(_bold "════════════════════════════════════════════════════════════")"
echo ""

if [ "$_FAIL" -gt 0 ]; then
	exit 1
fi
exit 0
