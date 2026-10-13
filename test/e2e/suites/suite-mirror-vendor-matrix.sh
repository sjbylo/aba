#!/usr/bin/env bash
# =============================================================================
# Suite: Mirror Vendor Matrix
# =============================================================================
# Comprehensive registry vendor test: installs, verifies, pushes images,
# uninstalls, and re-installs across all supported vendors, SSH users, and
# parameter configurations.
#
# Matrix (4 nested loops):
#   Vendor:  docker, quay, omr             (3)
#   Mode:    remote (disN via SSH), local       (2)
#   User:    root, steve, testy                 (3, remote only — reg_ssh_user)
#   Config:  default (template), custom (all)   (2)
#
# Total: 18 remote + 6 local = 24 test blocks
#
# Each test block:
#   Phase 1: install (random pw) → verify → push img1 → check img1
#   Phase 2: uninstall (keep data) → verify gone → verify data dir exists
#   Phase 3: re-install → verify → check img1 survived → push img2 → check both
#   Phase 4: uninstall (delete data) → verify gone → verify data dir gone
#
# Prerequisite: Internet-connected host with aba installed.
#               disN pool VM available with root/steve/testy users.
# =============================================================================

set -u

_SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SUITE_DIR/../lib/framework.sh"
source "$_SUITE_DIR/../lib/config-helpers.sh"
source "$_SUITE_DIR/../lib/remote.sh"
source "$_SUITE_DIR/../lib/pool-ops.sh"
source "$_SUITE_DIR/../lib/setup.sh"
source "$_SUITE_DIR/../lib/suite-helpers.sh"

# --- Configuration ----------------------------------------------------------

DIS_HOST="dis${POOL_NUM}.${VM_BASE_DOMAIN}"
CON_HOST="con${POOL_NUM}.${VM_BASE_DOMAIN}"
INTERNAL_BASTION="$(pool_internal_bastion)"

# Small public image for push/check tests (no auth needed to pull from conN)
_IMG_SRC="docker.io/library/busybox:latest"
_IMG1="e2e-vendor-test/img1:v1"
_IMG2="e2e-vendor-test/img2:v1"

# Custom config overrides
declare -A _CPORT=([docker]=5111 [quay]=5002 [omr]=5005)
_CUSER="e2eadmin"
_CPATH="/e2e/images"

# Safe special characters for E2E random passwords, determined from
# test/func/test-password-handling.sh (roundtrip + htpasswd verification).
# Excluded: ' (breaks single-quote wrapping), whitespace (Quay rejects),
#           ()[]+ (grep -E bug in replace-value-conf)
_E2E_PW_SPECIAL='!@#%^&|~=_-'
_E2E_PW_ALNUM='A-Za-z0-9'

_gen_e2e_password() {
	local special alnum pw
	# 50/50 mix: 8 special + 8 alnum = 16 chars
	special=$(LC_ALL=C tr -dc "$_E2E_PW_SPECIAL" < /dev/urandom | head -c 8)
	alnum=$(LC_ALL=C tr -dc "$_E2E_PW_ALNUM" < /dev/urandom | head -c 8)
	# Shuffle so the char types are interleaved
	pw=$(echo -n "${special}${alnum}" | fold -w1 | shuf | tr -d '\n')
	echo "$pw"
}

# SSH key per user (baked into golden VM)
declare -A _SSHKEY=([root]=~/.ssh/id_rsa [steve]=~/.ssh/id_rsa [testy]=~/.ssh/testy_rsa)

# --- Matrix dimensions ------------------------------------------------------

_VENDORS=(docker quay omr)
_MODES=(remote local)
_USERS=(root steve testy)
_CONFIGS=(default custom)

# --- Helper: test name for a combination ------------------------------------
_vm_name() {
	local v="$1" m="$2" u="$3" c="$4"
	if [ -n "$u" ]; then
		echo "${v} ${m} ${u} ${c}"
	else
		echo "${v} ${m} ${c}"
	fi
}

# --- Helper: mirror directory name ------------------------------------------
_vm_dir() {
	local v="$1" m="$2" u="$3" c="$4"
	local ms; [ "$m" = "remote" ] && ms="rem" || ms="loc"
	local cs; [ "$c" = "default" ] && cs="def" || cs="cst"
	if [ -n "$u" ]; then
		echo "e2e-vm-${v}-${ms}-${u}-${cs}"
	else
		echo "e2e-vm-${v}-${ms}-${cs}"
	fi
}

# --- Helper: build aba install CLI flags ------------------------------------
_vm_flags() {
	local v="$1" m="$2" u="$3" c="$4" dn="$5" pw="${6:-}"
	local f="--vendor $v"

	if [ "$m" = "remote" ]; then
		f+=" -H $DIS_HOST -k ${_SSHKEY[$u]} --reg-ssh-user $u"
	else
		# Local: override reg_host to the actual FQDN (template uses domain from
		# aba.conf which may be a pool-specific OCP subdomain without DNS for conN)
		f+=" -H $CON_HOST"
	fi

	if [ "$c" = "custom" ]; then
		f+=" --reg-port ${_CPORT[$v]}"
		f+=" --reg-user $_CUSER"
		f+=" --reg-password '$pw'"
		f+=" --reg-path $_CPATH"
		f+=" --data-dir '~/e2e-vm-data-${dn}'"
	fi

	echo "$f"
}

# --- Helper: registry URL for curl checks ----------------------------------
_vm_url() {
	local m="$1" v="$2" c="$3"
	local h p
	[ "$m" = "remote" ] && h="$DIS_HOST" || h="$CON_HOST"
	[ "$c" = "custom" ] && p="${_CPORT[$v]}" || p=8443
	echo "https://${h}:${p}"
}

# --- Helper: skopeo push command --------------------------------------------
_vm_push() {
	local dn="$1" dest="$2"
	echo "cd $dn && source ../scripts/include_all.sh && source <(normalize-mirror-conf) && skopeo copy --dest-tls-verify=false --dest-authfile \$HOME/.aba/mirror/$dn/pull-secret-mirror.json docker://$_IMG_SRC docker://\${reg_host}:\${reg_port}\${reg_path}/$dest"
}

# --- Helper: skopeo inspect command -----------------------------------------
_vm_check() {
	local dn="$1" img="$2"
	echo "cd $dn && source ../scripts/include_all.sh && source <(normalize-mirror-conf) && skopeo inspect --tls-verify=false --authfile \$HOME/.aba/mirror/$dn/pull-secret-mirror.json docker://\${reg_host}:\${reg_port}\${reg_path}/$img | grep -q Digest"
}

# --- Helper: verify data dir exists or is gone (local or remote) -----------
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

	# reg_root suffix per vendor (mirrors reg_setup_data_dir in reg-common.sh)
	local suffix
	case "$v" in
		docker)  suffix="docker-reg" ;;
		quay)    suffix="quay-install" ;;
		omr) suffix="omr" ;;
	esac

	local path
	if [ "$c" = "custom" ]; then
		path="~/e2e-vm-data-${dn}/${suffix}"
	else
		path="~/${suffix}"
	fi

	if [ "$m" = "remote" ]; then
		echo "ssh -i ${_SSHKEY[$u]} -F ~/.aba/ssh.conf ${u}@${DIS_HOST} '$test_op $path'"
	else
		local expanded="${path/#\~/$HOME}"
		echo "$test_op '$expanded'"
	fi
}

# --- Helper: run full test for one combination ------------------------------
_vm_test() {
	local v="$1" m="$2" u="$3" c="$4"
	local dn _pw flags url
	dn=$(_vm_dir "$v" "$m" "$u" "$c")
	_pw=$(_gen_e2e_password)
	flags=$(_vm_flags "$v" "$m" "$u" "$c" "$dn" "$_pw")
	url=$(_vm_url "$m" "$v" "$c")

	# Phase 1: install → verify → push img1 → check img1
	e2e_run "Create mirror dir" "aba mirror --name $dn"
	e2e_add_to_mirror_cleanup "$PWD/$dn"

	local _host _port
	[ "$m" = "remote" ] && _host="$DIS_HOST" || _host="$CON_HOST"
	[ "$c" = "custom" ] && _port="${_CPORT[$v]}" || _port=8443

	e2e_run "Install registry (pw=$_pw)" "aba -d $dn install $flags"
	e2e_run "Verify registry" "aba -d $dn verify"

	# Verify state.sh values match what was installed
	e2e_run "state.sh: reg_vendor=$v" "_assert_state '$dn' reg_vendor '$v'"
	e2e_run "state.sh: reg_port=$_port" "_assert_state '$dn' reg_port '$_port'"
	e2e_run "state.sh: reg_host=$_host" "_assert_state '$dn' reg_host '$_host'"
	if [ "$c" = "custom" ]; then
		e2e_run "state.sh: reg_pw matches" "_assert_state '$dn' reg_pw \"'$_pw'\""
	fi
	if [ "$m" = "remote" ]; then
		e2e_run "state.sh: reg_ssh_key" "_assert_state '$dn' reg_ssh_key '${_SSHKEY[$u]}'"
	fi

	e2e_run "Push test image 1" "$(_vm_push "$dn" "$_IMG1")"
	e2e_run "Check image 1 exists" "$(_vm_check "$dn" "$_IMG1")"

	# Phase 2: uninstall keeping data → verify data dir persists
	e2e_run "Uninstall (keep data)" "aba -d $dn uninstall"
	e2e_run "Verify unreachable" "! curl -sk --connect-timeout 5 $url/v2/"
	e2e_run "Verify data dir exists" "$(_vm_check_data_dir "$v" "$m" "$u" "$c" "$dn" "exists")"

	# Phase 3: re-install → verify → check img1 survived → push img2 → check both
	e2e_run "Re-install (from mirror.conf)" "aba -d $dn install"
	e2e_run "Verify after re-install" "aba -d $dn verify"
	e2e_run "Check image 1 survived reinstall" "$(_vm_check "$dn" "$_IMG1")"
	e2e_run "Push image 2" "$(_vm_push "$dn" "$_IMG2")"
	e2e_run "Check image 1 present" "$(_vm_check "$dn" "$_IMG1")"
	e2e_run "Check image 2 present" "$(_vm_check "$dn" "$_IMG2")"

	# Phase 4: uninstall deleting data → verify clean
	e2e_run "Uninstall (delete data)" "aba -d $dn uninstall --delete-data"
	e2e_run "Verify unreachable" "! curl -sk --connect-timeout 5 $url/v2/"
	e2e_run "Verify data dir gone" "$(_vm_check_data_dir "$v" "$m" "$u" "$c" "$dn" "gone")"

	# Cleanup
	e2e_remove_from_mirror_cleanup "$PWD/$dn"

	if [ "$c" = "custom" ]; then
		if [ "$m" = "remote" ]; then
			e2e_run_remote "Clean custom data parent" \
				"sudo rm -rf ~/e2e-vm-data-${dn}"
		else
			e2e_run "Clean custom data parent" \
				"rm -rf ~/e2e-vm-data-${dn}"
		fi
	fi
}

# --- Build test plan (same 4 nested loops used for execution below) ---------

_tnames=("Setup: install aba and configure")

for _v in "${_VENDORS[@]}"; do
	for _m in "${_MODES[@]}"; do
		if [ "$_m" = "remote" ]; then _uloop=("${_USERS[@]}"); else _uloop=(""); fi
		for _u in "${_uloop[@]}"; do
			for _c in "${_CONFIGS[@]}"; do
				_tnames+=("$(_vm_name "$_v" "$_m" "$_u" "$_c")")
			done
		done
	done
done

_tnames+=(
	"Password edge cases"
	"Register existing registry"
	"Vendor switch (docker>quay>omr)"
	"Port reuse across vendors"
	"Concurrent local registries"
	"Verify negative path"
	"Firewall verification"
	"Cleanup: uninstall and verify"
)

# --- Suite ------------------------------------------------------------------

e2e_setup

plan_tests "${_tnames[@]}"

suite_begin "mirror-vendor-matrix"

preflight_ssh

# ============================================================================
# Setup: install aba and configure
# ============================================================================
test_begin "Setup: install aba and configure"

e2e_install_aba

e2e_run "Remove oc-mirror caches" \
	"sudo find /root/ /home/ -maxdepth 3 -type d -name .oc-mirror | xargs sudo rm -rf"

e2e_run "Install aba (verify idempotent)" \
	"../aba/install 2>&1 | grep 'already up-to-date' || ../aba/install 2>&1 | grep 'installed to'"

suite_configure_aba
suite_verify_aba_conf

e2e_run "Copy vmware.conf" \
	"cp -v ${VMWARE_CONF:-~/.vmware.conf} vmware.conf"
e2e_run "Set VC_FOLDER in vmware.conf" \
	"sed -i 's#^[# ]*VC_FOLDER=.*#VC_FOLDER=${VC_FOLDER:-/Datacenter/vm/aba-e2e}#g' vmware.conf"
e2e_run "Verify vmware.conf" "grep ^GOVC_URL= vmware.conf"

suite_setup_ntp

test_end

# ============================================================================
# Matrix: 4 nested for loops
# ============================================================================
for _v in "${_VENDORS[@]}"; do
	for _m in "${_MODES[@]}"; do
		if [ "$_m" = "remote" ]; then _uloop=("${_USERS[@]}"); else _uloop=(""); fi
		for _u in "${_uloop[@]}"; do
			for _c in "${_CONFIGS[@]}"; do
				test_begin "$(_vm_name "$_v" "$_m" "$_u" "$_c")"
				_vm_test "$_v" "$_m" "$_u" "$_c"
				test_end
			done
		done
	done
done

# ============================================================================
# Password edge cases
# ============================================================================
test_begin "Password edge cases"

# Known-difficult passwords that stress quoting, CLI parsing, and htpasswd
# Min 8 chars (Quay constraint), no spaces (Quay constraint), no quotes
# Mix of known-difficult patterns + random passwords to catch unknowns
_HARD_PASSWORDS=(
	'-leadingDash'
	'--double-dash'
	'=leading=Equals'
	'!@#%^&|~=_-!@#%'
	'-=~!@#%^&|_-=~!'
	'PoT_&B_EAyf=8WS7'
	'--------'
	'========X1======'
	"$(_gen_e2e_password)"
	"$(_gen_e2e_password)"
	"$(_gen_e2e_password)"
	"$(_gen_e2e_password)"
)

_pw_idx=0
for _hardpw in "${_HARD_PASSWORDS[@]}"; do
	_pw_idx=$(( _pw_idx + 1 ))
	_pw_dn="e2e-vm-pw-edge-${_pw_idx}"

	e2e_run "Create mirror dir (pw-edge-${_pw_idx})" "aba mirror --name $_pw_dn"
	e2e_add_to_mirror_cleanup "$PWD/$_pw_dn"

	e2e_run "Install docker with pw='${_hardpw}' (#${_pw_idx})" \
		"aba -d $_pw_dn install --vendor docker -H $CON_HOST --reg-password '${_hardpw}'"
	e2e_run "Verify registry (pw-edge-${_pw_idx})" "aba -d $_pw_dn verify"
	e2e_run "Push test image (pw-edge-${_pw_idx})" "$(_vm_push "$_pw_dn" "e2e-pw-test/img:v${_pw_idx}")"
	e2e_run "Check test image (pw-edge-${_pw_idx})" "$(_vm_check "$_pw_dn" "e2e-pw-test/img:v${_pw_idx}")"
	e2e_run "Uninstall (pw-edge-${_pw_idx})" "aba -d $_pw_dn uninstall --delete-data"

	e2e_remove_from_mirror_cleanup "$PWD/$_pw_dn"
done

e2e_run "Clean pw-edge dirs" "rm -rf e2e-vm-pw-edge-* && rm -rf ~/.aba/mirror/e2e-vm-pw-edge-*"

test_end

# ============================================================================
# Register existing registry
# ============================================================================
test_begin "Register existing registry"

# Install a Docker registry in one mirror dir, then register it from another
_REG_INSTALL_DN="e2e-vm-reg-install"
_REG_REGISTER_DN="e2e-vm-reg-register"
_REG_PW=$(_gen_e2e_password)

e2e_run "Create install mirror dir" "aba mirror --name $_REG_INSTALL_DN"
e2e_add_to_mirror_cleanup "$PWD/$_REG_INSTALL_DN"

e2e_run "Install Docker registry" \
	"aba -d $_REG_INSTALL_DN install --vendor docker -H $DIS_HOST -k ~/.ssh/id_rsa --reg-ssh-user steve --reg-password '$_REG_PW'"
e2e_run "Verify installed registry" "aba -d $_REG_INSTALL_DN verify"

# Now register the same running registry from a different mirror dir
e2e_run "Create register mirror dir" "aba mirror --name $_REG_REGISTER_DN"
e2e_add_to_mirror_cleanup "$PWD/$_REG_REGISTER_DN"

e2e_run "Register existing registry" \
	"aba -d $_REG_REGISTER_DN register \
	 --pull-secret-mirror \$HOME/.aba/mirror/$_REG_INSTALL_DN/pull-secret-mirror.json \
	 --ca-cert \$HOME/.aba/mirror/$_REG_INSTALL_DN/rootCA.pem"
e2e_run "Verify registered registry" "aba -d $_REG_REGISTER_DN verify"

# Push from the registered dir to prove it works
e2e_run "Push image via registered dir" "$(_vm_push "$_REG_REGISTER_DN" "e2e-register-test/img:v1")"
e2e_run "Check image via registered dir" "$(_vm_check "$_REG_REGISTER_DN" "e2e-register-test/img:v1")"
# Also check from the install dir (same registry)
e2e_run "Check image via install dir" "$(_vm_check "$_REG_INSTALL_DN" "e2e-register-test/img:v1")"

e2e_run "Unregister" "aba -d $_REG_REGISTER_DN unregister"
e2e_run "Uninstall" "aba -d $_REG_INSTALL_DN uninstall --delete-data"
e2e_remove_from_mirror_cleanup "$PWD/$_REG_INSTALL_DN"
e2e_remove_from_mirror_cleanup "$PWD/$_REG_REGISTER_DN"
e2e_run "Clean register dirs" "rm -rf $_REG_INSTALL_DN $_REG_REGISTER_DN && rm -rf ~/.aba/mirror/$_REG_INSTALL_DN ~/.aba/mirror/$_REG_REGISTER_DN"

test_end

# ============================================================================
# Vendor switch (docker→quay→omr) — same mirror dir, keep data between
# ============================================================================
test_begin "Vendor switch (docker>quay>omr)"

_VS_DN="e2e-vm-vendor-switch"
_VS_PW=$(_gen_e2e_password)

e2e_run "Create mirror dir" "aba mirror --name $_VS_DN"
e2e_add_to_mirror_cleanup "$PWD/$_VS_DN"

# Start with Docker
e2e_run "Install Docker" \
	"aba -d $_VS_DN install --vendor docker -H $DIS_HOST -k ~/.ssh/id_rsa --reg-ssh-user steve --reg-password '$_VS_PW'"
e2e_run "Verify Docker" "aba -d $_VS_DN verify"
e2e_run "Push image (docker)" "$(_vm_push "$_VS_DN" "e2e-vswitch/img:docker")"
e2e_run "Uninstall Docker (keep data)" "aba -d $_VS_DN uninstall"

# Switch to Quay
e2e_run "Install Quay (vendor switch)" \
	"aba -d $_VS_DN install --vendor quay -H $DIS_HOST -k ~/.ssh/id_rsa --reg-ssh-user steve"
e2e_run "Verify Quay" "aba -d $_VS_DN verify"
e2e_run "Push image (quay)" "$(_vm_push "$_VS_DN" "e2e-vswitch/img:quay")"
e2e_run "Uninstall Quay (keep data)" "aba -d $_VS_DN uninstall"

# Switch to omr
e2e_run "Install omr (vendor switch)" \
	"aba -d $_VS_DN install --vendor omr -H $DIS_HOST -k ~/.ssh/id_rsa --reg-ssh-user steve --reg-password '$_VS_PW'"
e2e_run "Verify omr" "aba -d $_VS_DN verify"
e2e_run "Push image (omr)" "$(_vm_push "$_VS_DN" "e2e-vswitch/img:omr")"
e2e_run "Uninstall omr (keep data)" "aba -d $_VS_DN uninstall"

# Clean up data dirs left by earlier vendors (docker, quay) so subsequent
# tests that use the same host + default paths start clean.
e2e_run "Clean leftover vendor data dirs on $DIS_HOST" \
	"ssh -F ~/.aba/ssh.conf steve@$DIS_HOST 'rm -rf ~/docker-reg ~/quay-install ~/omr'"

e2e_remove_from_mirror_cleanup "$PWD/$_VS_DN"
e2e_run "Clean vendor-switch dir" "rm -rf $_VS_DN && rm -rf ~/.aba/mirror/$_VS_DN"

test_end

# ============================================================================
# Port reuse across vendors — same port :5111, different vendors sequentially
# ============================================================================
test_begin "Port reuse across vendors"

_PR_PORT=5111
_PR_PW='PortReuse26pw'  # Alphanumeric only — Quay v1 has an upstream bug where passwords
                        # containing "!!" cause 401 "Invalid bearer token format".
                        # This test validates port reuse, not password handling.

for _pr_vendor in docker quay omr; do
	_PR_DN="e2e-vm-portreuse-${_pr_vendor}"

	e2e_run "Create mirror dir (${_pr_vendor})" "aba mirror --name $_PR_DN"
	e2e_add_to_mirror_cleanup "$PWD/$_PR_DN"

	e2e_run "Install ${_pr_vendor} on :${_PR_PORT}" \
		"aba -d $_PR_DN install --vendor ${_pr_vendor} -H $DIS_HOST -k ~/.ssh/id_rsa --reg-ssh-user steve --reg-port $_PR_PORT --reg-password '$_PR_PW'"
	e2e_run "Verify ${_pr_vendor} on :${_PR_PORT}" "aba -d $_PR_DN verify"
	e2e_run "Push image (${_pr_vendor})" "$(_vm_push "$_PR_DN" "e2e-portreuse/img:${_pr_vendor}")"
	e2e_run "Uninstall ${_pr_vendor} (delete data)" "aba -d $_PR_DN uninstall --delete-data"
	e2e_run "Verify :${_PR_PORT} unreachable" "! curl -sk --connect-timeout 5 https://${DIS_HOST}:${_PR_PORT}/v2/"

	e2e_remove_from_mirror_cleanup "$PWD/$_PR_DN"
	e2e_run "Clean portreuse dir" "rm -rf $_PR_DN && rm -rf ~/.aba/mirror/$_PR_DN"
done

test_end

# ============================================================================
# Concurrent local registries — 2 registries on different ports at once
# ============================================================================
test_begin "Concurrent local registries"

_CC_DN1="e2e-vm-concurrent-1"
_CC_DN2="e2e-vm-concurrent-2"
_CC_PW1=$(_gen_e2e_password)
_CC_PW2=$(_gen_e2e_password)

e2e_run "Create mirror dir 1" "aba mirror --name $_CC_DN1"
e2e_run "Create mirror dir 2" "aba mirror --name $_CC_DN2"
e2e_add_to_mirror_cleanup "$PWD/$_CC_DN1"
e2e_add_to_mirror_cleanup "$PWD/$_CC_DN2"

# Install two Docker registries locally on different ports.
# Each needs its own data_dir — the default (~/docker-reg) is shared, which
# clobbers htpasswd/certs and causes auth failures on the first registry.
e2e_run "Install docker on :5111" \
	"aba -d $_CC_DN1 install --vendor docker -H $CON_HOST --reg-port 5111 --reg-password '$_CC_PW1' --data-dir ~/docker-reg-5111"
e2e_run "Install docker on :5112" \
	"aba -d $_CC_DN2 install --vendor docker -H $CON_HOST --reg-port 5112 --reg-password '$_CC_PW2' --data-dir ~/docker-reg-5112"

# Both should be reachable simultaneously
e2e_run "Verify registry 1" "aba -d $_CC_DN1 verify"
e2e_run "Verify registry 2" "aba -d $_CC_DN2 verify"

# Push to each, verify no cross-contamination
e2e_run "Push to registry 1" "$(_vm_push "$_CC_DN1" "e2e-cc/only-in-1:v1")"
e2e_run "Push to registry 2" "$(_vm_push "$_CC_DN2" "e2e-cc/only-in-2:v1")"
e2e_run "Check image in registry 1" "$(_vm_check "$_CC_DN1" "e2e-cc/only-in-1:v1")"
e2e_run "Check image in registry 2" "$(_vm_check "$_CC_DN2" "e2e-cc/only-in-2:v1")"

# Image from registry 1 should NOT be in registry 2 and vice versa.
# Wrap in subshell so '!' negates the whole chain, not just 'cd'.
e2e_run "Assert no cross-contamination (1>2)" \
	"! ($(_vm_check "$_CC_DN2" "e2e-cc/only-in-1:v1"))"
e2e_run "Assert no cross-contamination (2>1)" \
	"! ($(_vm_check "$_CC_DN1" "e2e-cc/only-in-2:v1"))"

e2e_run "Uninstall registry 1" "aba -d $_CC_DN1 uninstall --delete-data"
e2e_run "Uninstall registry 2" "aba -d $_CC_DN2 uninstall --delete-data"
e2e_remove_from_mirror_cleanup "$PWD/$_CC_DN1"
e2e_remove_from_mirror_cleanup "$PWD/$_CC_DN2"
e2e_run "Clean concurrent dirs" "rm -rf $_CC_DN1 $_CC_DN2 && rm -rf ~/.aba/mirror/$_CC_DN1 ~/.aba/mirror/$_CC_DN2"

test_end

# ============================================================================
# Verify negative path — aba verify after uninstall should fail cleanly
# ============================================================================
test_begin "Verify negative path"

_VN_DN="e2e-vm-verify-neg"
_VN_PW=$(_gen_e2e_password)

e2e_run "Create mirror dir" "aba mirror --name $_VN_DN"
e2e_add_to_mirror_cleanup "$PWD/$_VN_DN"

e2e_run "Install Docker" \
	"aba -d $_VN_DN install --vendor docker -H $DIS_HOST -k ~/.ssh/id_rsa --reg-ssh-user steve --reg-password '$_VN_PW'"
e2e_run "Verify (should pass)" "aba -d $_VN_DN verify"
e2e_run "Uninstall" "aba -d $_VN_DN uninstall --delete-data"

# verify after uninstall should fail (non-zero exit) but not crash
e2e_run "Verify after uninstall (should fail cleanly)" \
	"! aba -d $_VN_DN verify"

e2e_remove_from_mirror_cleanup "$PWD/$_VN_DN"
e2e_run "Clean verify-neg dir" "rm -rf $_VN_DN && rm -rf ~/.aba/mirror/$_VN_DN"

test_end

# ============================================================================
# Firewall verification — ports opened on install, closed on uninstall
# ============================================================================
test_begin "Firewall verification"

_FW_DN="e2e-vm-firewall"
_FW_PORT=5113
_FW_PW=$(_gen_e2e_password)

# Capture baseline firewall state on disN
e2e_run "Snapshot firewall baseline" \
	"ssh -F ~/.aba/ssh.conf steve@${DIS_HOST} 'sudo firewall-cmd --list-ports' > /tmp/e2e-fw-baseline.txt && cat /tmp/e2e-fw-baseline.txt"

e2e_run "Create mirror dir" "aba mirror --name $_FW_DN"
e2e_add_to_mirror_cleanup "$PWD/$_FW_DN"

e2e_run "Install Docker on :${_FW_PORT}" \
	"aba -d $_FW_DN install --vendor docker -H $DIS_HOST -k ~/.ssh/id_rsa --reg-ssh-user steve --reg-port $_FW_PORT --reg-password '$_FW_PW'"

# Verify port is open in firewall
e2e_run "Assert port ${_FW_PORT} open in firewall" \
	"ssh -F ~/.aba/ssh.conf steve@${DIS_HOST} 'sudo firewall-cmd --list-ports' | grep -q '${_FW_PORT}/tcp'"

e2e_run "Uninstall" "aba -d $_FW_DN uninstall --delete-data"

# Verify port is closed after uninstall
e2e_run "Assert port ${_FW_PORT} closed after uninstall" \
	"! ssh -F ~/.aba/ssh.conf steve@${DIS_HOST} 'sudo firewall-cmd --list-ports' | grep -q '${_FW_PORT}/tcp'"

# Verify firewall returned to baseline
e2e_run "Assert firewall matches baseline" \
	"ssh -F ~/.aba/ssh.conf steve@${DIS_HOST} 'sudo firewall-cmd --list-ports' > /tmp/e2e-fw-after.txt && diff /tmp/e2e-fw-baseline.txt /tmp/e2e-fw-after.txt"

e2e_remove_from_mirror_cleanup "$PWD/$_FW_DN"
e2e_run "Clean firewall dir" "rm -rf $_FW_DN && rm -rf ~/.aba/mirror/$_FW_DN"

test_end

# ============================================================================
# Cleanup: uninstall and verify
# ============================================================================
test_begin "Cleanup: uninstall and verify"

e2e_run "Uninstall leftover e2e-vm registries" \
	"shopt -s nullglob; for _d in e2e-vm-*/; do \
		_dn=\"\${_d%/}\"; \
		if [ -f \"\$_dn/.available\" ]; then \
			echo \"[cleanup] Uninstalling \$_dn\"; \
			aba -d \$_dn uninstall --delete-data || echo \"[cleanup] uninstall failed for \$_dn\"; \
		fi; \
	done"

e2e_run "Assert: no registries on disN" "e2e_assert_registry_removed"
e2e_run "Assert: no registries on conN" "e2e_assert_registry_removed local"

e2e_run "Remove mirror dirs on conN" "rm -rf e2e-vm-*"
e2e_run_remote "Remove data dirs on disN (all users)" \
	"sudo rm -rf /root/e2e-vm-data-* /home/*/e2e-vm-data-* /root/docker-reg /home/*/docker-reg /root/quay-install /home/*/quay-install /root/omr /home/*/omr"
e2e_run "Remove data dirs on conN" "rm -rf ~/e2e-vm-data-* ~/docker-reg ~/quay-install ~/omr"
e2e_run "Remove regcreds" "rm -rf ~/.aba/mirror/e2e-vm-*"

test_end

# ============================================================================

suite_end; _rc=$?

exit $_rc
