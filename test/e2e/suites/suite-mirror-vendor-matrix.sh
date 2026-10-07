#!/usr/bin/env bash
# =============================================================================
# Suite: Mirror Vendor Matrix
# =============================================================================
# Comprehensive registry vendor test: installs, verifies, pushes images,
# uninstalls, and re-installs across all supported vendors, SSH users, and
# parameter configurations.
#
# Matrix (4 nested loops):
#   Vendor:  docker, quay, quay-ng             (3)
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
_IMG_SRC="registry.access.redhat.com/ubi9/ubi-micro:latest"
_IMG1="e2e-vendor-test/img1:v1"
_IMG2="e2e-vendor-test/img2:v1"

# Custom config overrides
declare -A _CPORT=([docker]=5111 [quay]=5002 [quay-ng]=5005)
_CUSER="e2eadmin"
_CPATH="/e2e/images"

# Safe special characters for E2E random passwords, determined from
# test/func/test-password-handling.sh (roundtrip + htpasswd verification).
# Excluded: ' (breaks single-quote wrapping), whitespace (Quay rejects),
#           ()[]+ (grep -E bug in replace-value-conf)
_E2E_PW_CHARS='A-Za-z0-9!@#%^&|~=_-'

_gen_e2e_password() {
	local pw
	while true; do
		pw=$(LC_ALL=C tr -dc "$_E2E_PW_CHARS" < /dev/urandom | head -c 16)
		# Ensure at least one special char and one alphanumeric
		[[ "$pw" =~ [^A-Za-z0-9] ]] && [[ "$pw" =~ [A-Za-z] ]] && break
	done
	echo "$pw"
}

# SSH key per user (baked into golden VM)
declare -A _SSHKEY=([root]=~/.ssh/id_rsa [steve]=~/.ssh/id_rsa [testy]=~/.ssh/testy_rsa)

# --- Matrix dimensions ------------------------------------------------------

_VENDORS=(docker quay quay-ng)
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
	[ "$c" = "custom" ] && p="${_CPORT[$v]}" || p="${POOL_REG_PORT}"
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
_vm_check_data_dir() {
	local v="$1" m="$2" u="$3" c="$4" dn="$5" assertion="$6"
	local test_op="test -d"
	[ "$assertion" = "gone" ] && test_op="! test -d"

	# reg_root suffix per vendor (mirrors reg_setup_data_dir in reg-common.sh)
	local suffix
	case "$v" in
		docker)  suffix="docker-reg" ;;
		quay)    suffix="quay-install" ;;
		quay-ng) suffix="quay-ng" ;;
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

	e2e_run "Install registry (pw=$_pw)" "aba -d $dn install $flags"
	e2e_run "Verify registry" "aba -d $dn verify"
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

_tnames+=("Cleanup: uninstall and verify")

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
	"sudo rm -rf /root/e2e-vm-data-* /home/*/e2e-vm-data-* /root/docker-reg /home/*/docker-reg /root/quay-install /home/*/quay-install /root/quay-ng /home/*/quay-ng"
e2e_run "Remove data dirs on conN" "rm -rf ~/e2e-vm-data-* ~/docker-reg ~/quay-install ~/quay-ng"
e2e_run "Remove regcreds" "rm -rf ~/.aba/mirror/e2e-vm-*"

test_end

# ============================================================================

suite_end; _rc=$?

exit $_rc
