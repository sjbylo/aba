#!/bin/bash
# test-linuxone.sh — Automated s390x (LinuxONE) regression tests for ABA
#
# Validates core ABA features on an s390x host:
#   CLI tools, mirror registry, image sync, ISC generation,
#   additional images, ISO generation, and (optionally) SNO install.
#
# Run from the ABA bastion/workspace host.
#
# Usage:
#   test/func/test-linuxone.sh [branch] [--reset] [--clean]
#   LINUXONE_HOST=user@host test/func/test-linuxone.sh [branch]
#
# Flags:
#   --reset  Wipe this test's cluster/registry/~/aba, then full run.
#            Without it, reuse the host: aba Make stamps skip install/iso/cluster;
#            sync is skipped if the release image is already in the registry.
#   --clean  After a PASS only, uninstall registry and delete the cluster.
#            Never wipes on FAIL (leave the crime scene).
#
# Environment:
#   LINUXONE_HOST  — SSH target (default: linux1@148.100.85.72)
#   SKIP_SNO       — set to 1 to skip the SNO install phase (saves ~60 min)

set -uo pipefail

# ── Configuration ────────────────────────────────────────────────
HOST="${LINUXONE_HOST:-linux1@148.100.85.72}"
GIT_REPO=$(cd "$(dirname "$0")/../.." && git remote get-url origin 2>/dev/null) \
	|| GIT_REPO="https://github.com/sjbylo/aba.git"

REG_FQDN="kvm.example.com"
VIRBR0_IP="192.168.122.1"
SNO_IP="192.168.122.200"
SNO_NAME="sno-test"
SNO_CPU=6
SNO_MEM=16
DISK_WARN_PCT=80
DISK_FAIL_PCT=90

DO_RESET=0
DO_CLEAN=0
BRANCH=dev
for _arg in "$@"; do
	case "$_arg" in
		--reset) DO_RESET=1 ;;
		--clean) DO_CLEAN=1 ;;
		-h|--help)
			sed -n '2,24p' "$0"
			exit 0
			;;
		-*)
			echo "Unknown option: $_arg (try --reset, --clean)" >&2
			exit 1
			;;
		*)
			BRANCH="$_arg"
			;;
	esac
done

# ── State ────────────────────────────────────────────────────────
PASS=0 FAIL=0 SKIP=0
ABORT=0
declare -a RESULTS=()
START=$(date +%s)

# ── Helpers ──────────────────────────────────────────────────────
log()   { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
_pass() { log "  ✓ PASS: $1"; RESULTS+=("PASS  $1"); PASS=$((PASS + 1)); }
_fail() { log "  ✗ FAIL: $1"; RESULTS+=("FAIL  $1  ($2)"); FAIL=$((FAIL + 1)); }
_skip() { log "  - SKIP: $1"; RESULTS+=("SKIP  $1"); SKIP=$((SKIP + 1)); }
_abort() { log "  ✗ ABORT: $1 — $2"; RESULTS+=("ABORT $1  ($2)"); FAIL=$((FAIL + 1)); ABORT=1; }

r() {
	# Run a command on the remote host. Args are joined as a single string.
	# -n: do not read local stdin (would steal the operator's TTY / hang ask prompts).
	ssh -n -o BatchMode=yes -o ServerAliveInterval=30 -o ConnectTimeout=15 \
		-o StrictHostKeyChecking=no -o LogLevel=ERROR "$HOST" "$*" 2>&1
}

# run_test <name> <remote-command>
#   Returns 0 on pass, 1 on fail. Records result.
#   Captures remote stdout — do not use for commands that prompt or run for minutes.
run_test() {
	local name="$1"; shift
	local out rc=0
	out=$(r "$@") || rc=$?
	if [ $rc -eq 0 ]; then
		_pass "$name"
	else
		local reason
		reason=$(echo "$out" | grep -v '^$' | tail -2 | tr '\n' ' ')
		_fail "$name" "${reason:-(exit $rc)}"
		log "  --- output (last 30 lines) ---"
		echo "$out" | tail -30 | while IFS= read -r line; do log "  | $line"; done
		log "  --- end ---"
	fi
	return $rc
}

# Stream remote output to this terminal (install/sync/iso). Still records PASS/FAIL.
run_stream() {
	local name="$1"; shift
	local rc=0
	r "$@" || rc=$?
	if [ $rc -eq 0 ]; then
		_pass "$name"
	else
		_fail "$name" "(exit $rc)"
	fi
	return $rc
}

# run_critical <name> <remote-command>
#   Like run_test but sets ABORT=1 on failure (later phases will skip).
run_critical() {
	if ! run_test "$@"; then
		ABORT=1
	fi
}

run_critical_stream() {
	if ! run_stream "$@"; then
		ABORT=1
	fi
}

_keep_hint() {
	log "  Host state kept. Inspect with:"
	log "    ssh $HOST"
	log "    ssh $HOST 'cd ~/aba && aba -d $SNO_NAME run'"
	log "  Full wipe next time: $0 --reset $BRANCH"
}

# Fail the run if host (or the SNO guest, when reachable) is at DISK_FAIL_PCT.
# Guest /run/ephemeral is the live-ISO overlay — it fills during bootstrap.
check_disks() {
	local out mp pct avail rc=0
	log "  Disk space:"
	out=$(r "df -P / /home /home/libvirt/images 2>/dev/null | awk 'NR>1 {gsub(/%/,\"\",\$5); print \$6, \$5, \$4}'") || true
	while read -r mp pct avail; do
		[ -n "$mp" ] || continue
		log "    host $mp ${pct}% used (${avail} avail)"
		if [ "$pct" -ge "$DISK_FAIL_PCT" ] 2>/dev/null; then
			_fail "Disk space $mp" "${pct}% used (limit ${DISK_FAIL_PCT}%)"
			ABORT=1
			rc=1
		elif [ "$pct" -ge "$DISK_WARN_PCT" ] 2>/dev/null; then
			log "    WARNING: host $mp at ${pct}%"
		fi
	done <<< "$out"

	if r "timeout 2 bash -c 'echo >/dev/tcp/${SNO_IP}/22'" >/dev/null 2>&1; then
		out=$(r "ssh -n -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null core@${SNO_IP} \"df -P /run/ephemeral 2>/dev/null | awk 'NR>1 {gsub(/%/,\\\"\\\",\\\$5); print \\\$6, \\\$5, \\\$4}'\"") || true
		while read -r mp pct avail; do
			[ -n "$mp" ] || continue
			log "    guest $mp ${pct}% used (${avail} avail)"
			if [ "$pct" -ge "$DISK_FAIL_PCT" ] 2>/dev/null; then
				_fail "Guest disk $mp" "${pct}% used (limit ${DISK_FAIL_PCT}%)"
				ABORT=1
				rc=1
			elif [ "$pct" -ge "$DISK_WARN_PCT" ] 2>/dev/null; then
				log "    WARNING: guest $mp at ${pct}%"
			fi
		done <<< "$out"
	fi
	return $rc
}

# ── --reset: wipe this test's trees only ────────────────────────
phase_reset() {
	if [ "$DO_RESET" -ne 1 ]; then
		log "=== No --reset: reusing host state (ABA Make stamps skip done work) ==="
		return
	fi
	log "=== --reset: wiping test cluster, registry, and ~/aba ==="

	r "cd ~/aba 2>/dev/null && aba -d $SNO_NAME delete --yes; true"
	r "cd ~/aba 2>/dev/null && aba -d sno-kvm delete --yes; true"
	r "cd ~/aba 2>/dev/null && aba -d mirror uninstall --yes; true"

	# Only VMs this test (or the old skill name) creates — not every libvirt guest.
	r "for vm in $SNO_NAME sno-kvm; do
		sudo virsh destroy \"\$vm\" 2>/dev/null || true
		sudo virsh undefine \"\$vm\" --remove-all-storage 2>/dev/null || true
	done"

	r "rm -rf ~/aba ~/.aba"
	r "sudo rm -f /etc/dnsmasq.d/aba-registry-fqdn.conf /etc/dnsmasq.d/aba-${SNO_NAME}.conf /etc/dnsmasq.d/aba-sno-kvm.conf; sudo systemctl restart dnsmasq 2>/dev/null; true"

	_pass "Reset"
}

# ── Phase 1: Infrastructure prerequisites ────────────────────────
phase_prereqs() {
	log "=== Phase 1: Infrastructure prerequisites ==="

	r "sudo virsh net-start default 2>/dev/null || true"

	r "sudo iptables -C INPUT -d $VIRBR0_IP -j ACCEPT 2>/dev/null || sudo iptables -I INPUT 1 -d $VIRBR0_IP -j ACCEPT"
	r "sudo iptables -C INPUT -i virbr0 -j ACCEPT 2>/dev/null || sudo iptables -I INPUT 1 -i virbr0 -j ACCEPT"

	r "[ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa -q"
	r "grep -q \"\$(cat ~/.ssh/id_rsa.pub)\" ~/.ssh/authorized_keys 2>/dev/null || { cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; }"

	run_critical "virbr0 active" \
		"ip addr show virbr0 | grep -q $VIRBR0_IP"
}

# ── Phase 2: Setup (clone or update, install, platform=kvm) ─────
phase_setup() {
	log "=== Phase 2: Setup ==="
	[ "$ABORT" -eq 1 ] && { _skip "Setup (prereqs failed)"; return; }

	run_critical "Pull secret present" \
		"test -f ~/.pull-secret.json"

	if r "test -d ~/aba/.git" >/dev/null; then
		log "  Updating existing clone to '$BRANCH' ..."
		run_critical "Git update" \
			"cd ~/aba && git fetch origin && git checkout $BRANCH && git reset --hard origin/$BRANCH"
	elif r "test -e ~/aba" >/dev/null; then
		_abort "Git clone" "~/aba exists but is not a git clone; re-run with --reset"
		return
	else
		log "  Cloning branch '$BRANCH' ..."
		run_critical "Git clone" \
			"git clone --branch $BRANCH --single-branch $GIT_REPO ~/aba"
	fi
	[ "$ABORT" -eq 1 ] && return

	log "  Running ./install ..."
	run_critical "ABA install" \
		"cd ~/aba && ./install"

	run_critical "Architecture = s390x" \
		"cd ~/aba && uname -m | grep -q s390x"

	log "  Configuring aba.conf ..."
	r "cd ~/aba && aba < /dev/null 2>/dev/null || true"
	run_critical "Configure aba.conf" \
		"cd ~/aba && aba --channel stable --version latest --platform kvm"

	# ask=true + captured SSH stdout = hung y/n prompt the operator never sees.
	r "cd ~/aba && aba --noask"

	# kvm-upload.sh scp's via KVM_HOST parsed from LIBVIRT_URI.
	# qemu:///system becomes hostname "qemu" and scp fails; use qemu+ssh to self.
	r "cat > ~/aba/kvm.conf << 'KVMEOF'
LIBVIRT_URI=qemu+ssh://linux1@kvm.example.com/system
KVM_STORAGE_POOL=/home/libvirt/images
KVM_NETWORK=virbr0
KVM_BOOT_ARGS=hd,cdrom
KVM_GRAPHICS_ARGS=none
KVMEOF
cp ~/aba/kvm.conf ~/.kvm.conf"

	log "  Setting up DNS (dnsmasq) via ABA ..."
	run_critical "Setup DNS" \
		"cd ~/aba && aba setup dns -y --bastion-ip $VIRBR0_IP"

	r "echo 'address=/${REG_FQDN}/${VIRBR0_IP}' | sudo tee /etc/dnsmasq.d/aba-registry-fqdn.conf >/dev/null && sudo systemctl restart dnsmasq"
	run_test "DNS resolves registry FQDN" \
		"dig +short @127.0.0.1 ${REG_FQDN} | grep -q $VIRBR0_IP"

	log "  Setting up NTP (chrony) via ABA ..."
	run_critical "Setup NTP" \
		"cd ~/aba && aba setup ntp -y --bastion-ip $VIRBR0_IP --allow-network 192.168.122.0/24"

	run_critical "Self-SSH via FQDN" \
		"ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 linux1@${REG_FQDN} 'echo ok'"
}

# ── Phase 3: CLI tools ──────────────────────────────────────────
phase_cli() {
	log "=== Phase 3: CLI tools ==="
	[ "$ABORT" -eq 1 ] && { _skip "CLI tools (setup failed)"; return; }

	run_test "CLI download" \
		"cd ~/aba && aba cli"

	run_test "oc binary is s390x" \
		"file \$(which oc) | grep -qi 'S/390'"

	run_test "openshift-install is s390x" \
		"file \$(which openshift-install) | grep -qi 'S/390'"

	run_test "oc-mirror is s390x" \
		"file \$(which oc-mirror) | grep -qi 'S/390'"
}

# ── Phase 4: Mirror registry ────────────────────────────────────
phase_mirror() {
	log "=== Phase 4: Mirror registry ==="
	[ "$ABORT" -eq 1 ] && { _skip "Mirror registry (prior failure)"; return; }

	r "cd ~/aba && aba mirror --name mirror >/dev/null 2>&1 || true"

	# docker: classic Quay is too heavy for 24GB; quay-ng image is amd64-only.
	r "cd ~/aba && aba -d mirror --reg-host ${REG_FQDN} --vendor docker"

	r "cd ~/aba && aba mirror --name mirror"

	# .available stamp: no-op if the registry is already installed.
	log "  Installing registry (skipped by Make if .available) ..."
	run_critical_stream "Registry install" \
		"cd ~/aba && aba -y -d mirror install"

	# Docker /v2/_catalog is 401 without auth; curl -f treats that as exit 22.
	# ABA's own probe accepts 200 or 401 on /v2/.
	run_test "Registry health check" \
		"code=\$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 https://${REG_FQDN}:8443/v2/); echo HTTP_\$code; echo \$code | grep -qE '^(200|401)\$'"
}

# ── Phase 5: Image sync ─────────────────────────────────────────
phase_sync() {
	log "=== Phase 5: Image sync ==="
	[ "$ABORT" -eq 1 ] && { _skip "Image sync (prior failure)"; return; }

	# sync has no Make stamp; skip when the release image is already there.
	if r "cd ~/aba && aba -d mirror check-image" >/dev/null; then
		_pass "Image sync (already in registry)"
	else
		log "  Syncing images (may take 10-15 min) ..."
		run_critical_stream "Image sync" \
			"cd ~/aba && aba -y -d mirror sync"
	fi
	[ "$ABORT" -eq 1 ] && return

	run_test "Release image in registry" \
		"cd ~/aba && aba -d mirror verify"
}

# ── Phase 6: ISC generation ─────────────────────────────────────
phase_isc() {
	log "=== Phase 6: ISC generation ==="
	[ "$ABORT" -eq 1 ] && { _skip "ISC generation (prior failure)"; return; }

	run_test "ISC generated" \
		"cd ~/aba && aba -d mirror imagesetconf"

	run_test "ISC contains s390x" \
		"grep -q 's390x' ~/aba/mirror/data/imageset-config.yaml"
}

# ── Phase 7: Additional images (always run; cheap and must execute) ─
phase_images() {
	log "=== Phase 7: Additional images ==="
	[ "$ABORT" -eq 1 ] && { _skip "Additional images (prior failure)"; return; }

	run_test "aba image add" \
		"cd ~/aba && aba image add registry.redhat.io/ubi9/ubi:latest"

	run_test "aba image list shows image" \
		"cd ~/aba && aba image list | grep '/'"

	run_test "aba image remove" \
		"cd ~/aba && aba image remove registry.redhat.io/ubi9/ubi:latest"

	run_test "aba image list empty" \
		"cd ~/aba && aba image list 2>&1 | grep -q 'No additional images'"
}

# ── Phase 8: ISO generation ─────────────────────────────────────
phase_iso() {
	log "=== Phase 8: ISO generation ==="
	[ "$ABORT" -eq 1 ] && { _skip "ISO generation (prior failure)"; return; }

	r "cd ~/aba && aba --machine-network 192.168.122.0/24 --dns $VIRBR0_IP --gateway $VIRBR0_IP --ntp $VIRBR0_IP"

	r "cd ~/aba && aba cluster --name $SNO_NAME --type sno >/dev/null 2>&1 || true"
	r "cd ~/aba && aba cluster --name $SNO_NAME --type sno"
	r "cp ~/aba/kvm.conf ~/aba/$SNO_NAME/kvm.conf"
	# Node IP / size last so a later aba cluster cannot rewrite them.
	# 6 vCPUs: 8-on-8 starved the z/VM host; 4-on-8 left kube-apiserver unable to pass livez.
	# data_disk= (empty) — do not use 0; kvm-create treats any non-empty value as "add a disk".
	r "cd ~/aba && aba -d $SNO_NAME --starting-ip $SNO_IP --master-cpu $SNO_CPU --master-memory $SNO_MEM --ports enc0"
	r "sed -i 's/^#*data_disk=.*/data_disk=/' ~/aba/$SNO_NAME/cluster.conf"
	check_disks || true

	log "  Generating ISO (Make skips if agent.s390x.iso exists) ..."
	run_stream "ISO generated" \
		"cd ~/aba && aba -y -d $SNO_NAME iso"

	run_test "ISO file is s390x" \
		"ls ~/aba/$SNO_NAME/iso-agent-based/agent.s390x.iso"
}

# ── Phase 9: SNO install on KVM (optional) ──────────────────────
phase_sno() {
	log "=== Phase 9: SNO install on KVM ==="
	if [ "${SKIP_SNO:-0}" = "1" ]; then
		_skip "SNO install (SKIP_SNO=1)"
		return
	fi
	[ "$ABORT" -eq 1 ] && { _skip "SNO install (prior failure)"; return; }

	log "  WARNING: SNO install needs ~16 GB RAM and may take hours on this s390x host"
	log "  Set SKIP_SNO=1 to skip this phase"
	check_disks || return

	log "  Installing (Make skips only if .install-complete AND cluster is up) ..."
	# aba install is a no-op when .install-complete exists, even if no VM was created
	# (e.g. 'aba mon' after a failed upload stamps it because wait-for exit 8 = interrupted).
	if r "test -f ~/aba/$SNO_NAME/.install-complete"; then
		if r "cd ~/aba && aba -d $SNO_NAME run" >/dev/null; then
			_pass "SNO install (already complete)"
			_pass "SNO cluster healthy"
			return
		fi
		log "  Stale .install-complete (API not reachable); installing for real ..."
		r "rm -f ~/aba/$SNO_NAME/.install-complete"
	fi

	# Make skips .autoupload/.autorefresh even when the guest is gone (interrupt
	# can virsh-destroy the domain). Drop those stamps so aba install recreates it.
	if ! r "sudo virsh list --all --name | grep -qx $SNO_NAME"; then
		log "  No KVM guest named $SNO_NAME — clearing upload/refresh stamps so ABA recreates the VM"
		r "rm -f ~/aba/$SNO_NAME/.autopoweroff ~/aba/$SNO_NAME/.autoupload ~/aba/$SNO_NAME/.autorefresh ~/aba/$SNO_NAME/.auto-agent-up ~/aba/$SNO_NAME/.install-complete"
	fi

	run_stream "SNO install" \
		"cd ~/aba && aba -y -d $SNO_NAME install"
	_inst_rc=$?

	if [ "$_inst_rc" -ne 0 ]; then
		if r "sudo virsh list --all --name | grep -qx $SNO_NAME"; then
			log "  Install did not complete; VM exists, resuming monitoring ..."
			run_stream "SNO install (resumed)" \
				"cd ~/aba && aba -d $SNO_NAME mon"
		else
			log "  No KVM guest named $SNO_NAME — not running 'aba mon' (that would stamp .install-complete)"
		fi
	fi

	run_stream "SNO cluster healthy" \
		"cd ~/aba && aba -d $SNO_NAME run"
	check_disks || true
}

# ── Teardown: --clean after PASS only ────────────────────────────
phase_final_cleanup() {
	if [ "$FAIL" -gt 0 ]; then
		log "=== Keeping host state (tests failed) ==="
		_keep_hint
		return
	fi
	if [ "$DO_CLEAN" -ne 1 ]; then
		log "=== Keeping host state (no --clean) ==="
		_keep_hint
		return
	fi
	log "=== --clean after PASS ==="

	r "cd ~/aba 2>/dev/null && aba -d $SNO_NAME delete --yes; true"
	r "cd ~/aba 2>/dev/null && aba -d mirror uninstall --yes; true"
	r "rm -rf ~/aba ~/.aba"
	r "sudo rm -f /etc/dnsmasq.d/aba-registry-fqdn.conf /etc/dnsmasq.d/aba-${SNO_NAME}.conf; sudo systemctl restart dnsmasq 2>/dev/null; true"

	_pass "Final cleanup"
}

# ── Report ───────────────────────────────────────────────────────
report() {
	local e=$(( $(date +%s) - START ))
	echo
	echo "═══════════════════════════════════════════════════════════"
	echo "  ABA s390x Test Report — $(date '+%Y-%m-%d %H:%M')"
	echo "  Branch: $BRANCH  Host: $HOST  Duration: $((e/60))m$((e%60))s"
	echo "  Flags:  reset=$DO_RESET  clean=$DO_CLEAN  skip_sno=${SKIP_SNO:-0}"
	echo "═══════════════════════════════════════════════════════════"
	for r in "${RESULTS[@]}"; do printf '  %s\n' "$r"; done
	echo "───────────────────────────────────────────────────────────"
	printf '  PASS: %d  FAIL: %d  SKIP: %d\n' "$PASS" "$FAIL" "$SKIP"
	echo "═══════════════════════════════════════════════════════════"
	if [ "$FAIL" -eq 0 ]; then
		echo "  ✓ ALL TESTS PASSED"
	else
		echo "  ✗ SOME TESTS FAILED"
	fi
	echo
}

# ── Main ─────────────────────────────────────────────────────────
main() {
	log "ABA s390x test run — branch=$BRANCH host=$HOST reset=$DO_RESET clean=$DO_CLEAN"
	log ""

	local arch
	arch=$(r "uname -m") || { echo "ERROR: Cannot SSH to $HOST" >&2; exit 1; }
	echo "$arch" | grep -q s390x || { echo "ERROR: Host $HOST is $arch, not s390x" >&2; exit 1; }
	log "Connected to $HOST (arch=$arch)"

	phase_reset
	check_disks || true
	phase_prereqs
	phase_setup
	phase_cli
	phase_mirror
	phase_sync
	phase_isc
	phase_images
	phase_iso
	phase_sno
	phase_final_cleanup
	report

	[ "$FAIL" -gt 0 ] && exit 1
	exit 0
}

main
