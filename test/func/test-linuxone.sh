#!/bin/bash
# test-linuxone.sh — Automated s390x (LinuxONE) regression tests for ABA
#
# Validates core ABA features on an s390x host:
#   CLI tools, mirror registry, image sync, ISC generation,
#   additional images, and ISO generation.
#
# Run from the ABA bastion/workspace host.
#
# Usage:
#   test/func/test-linuxone.sh [branch] [--reset] [--clean]
#   LINUXONE_HOST=user@host test/func/test-linuxone.sh [branch]
#
# Flags:
#   --reset  Wipe this test's cluster/registry/~/aba, then full run.
#            Without it, reuse the host: aba Make stamps skip install/iso;
#            sync is skipped if the release image is already in the registry.
#   --clean  After a PASS only, uninstall registry and delete the cluster dir.
#            Never wipes on FAIL (leave the crime scene).
#
# Environment:
#   LINUXONE_HOST  — SSH target (default: linux1@148.100.85.72)

set -uo pipefail

# ── Configuration ────────────────────────────────────────────────
HOST="${LINUXONE_HOST:-linux1@148.100.85.72}"
GIT_REPO=$(cd "$(dirname "$0")/../.." && git remote get-url origin 2>/dev/null) \
	|| GIT_REPO="https://github.com/sjbylo/aba.git"

REG_FQDN="kvm.example.com"
SNO_NAME="sno-test"
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
			sed -n '2,23p' "$0"
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
	# z/VM networking has intermittent pauses; retry once on SSH failure.
	local _out _rc=0
	_out=$(ssh -n -o BatchMode=yes -o ServerAliveInterval=30 -o ConnectTimeout=30 \
		-o StrictHostKeyChecking=no -o LogLevel=ERROR "$HOST" "$*" 2>&1) || _rc=$?
	if [ $_rc -eq 255 ]; then
		log "  (SSH retry after transient failure)"
		sleep 3
		_rc=0
		_out=$(ssh -n -o BatchMode=yes -o ServerAliveInterval=30 -o ConnectTimeout=30 \
			-o StrictHostKeyChecking=no -o LogLevel=ERROR "$HOST" "$*" 2>&1) || _rc=$?
	fi
	echo "$_out"
	return $_rc
}

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
	log "  Full wipe next time: $0 --reset $BRANCH"
}

check_disks() {
	local out mp pct avail rc=0
	log "  Disk space:"
	out=$(r "df -P / /home 2>/dev/null | awk 'NR>1 {gsub(/%/,\"\",\$5); print \$6, \$5, \$4}'") || true
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
	return $rc
}

# ── --reset: wipe this test's trees only ────────────────────────
phase_reset() {
	if [ "$DO_RESET" -ne 1 ]; then
		log "=== No --reset: reusing host state (ABA Make stamps skip done work) ==="
		return
	fi
	log "=== --reset: wiping test trees, registry, and ~/aba ==="

	r "cd ~/aba 2>/dev/null && aba -d mirror uninstall --yes --delete-data; true"

	r "rm -rf ~/aba ~/.aba"
	r "sudo sed -i '/${REG_FQDN}/d' /etc/hosts; true"
	# Wipe ALL dnsmasq confs (not just aba-*) to clear stale listen-address
	# directives and other leftovers from prior manual setups.
	r "sudo rm -f /etc/dnsmasq.d/*.conf; sudo systemctl restart dnsmasq 2>/dev/null; true"

	# Restore original resolv.conf so external DNS works for git clone.
	r "[ -f /etc/resolv.conf.aba-backup ] && sudo cp /etc/resolv.conf.aba-backup /etc/resolv.conf || true"

	# If DNS is still broken (e.g. backup also pointed to a dead dnsmasq),
	# fall back to a public resolver so git clone can proceed.
	if ! r "dig +short +timeout=3 github.com" | grep -q '^[0-9]'; then
		log "  DNS broken after reset; adding temporary upstream resolver"
		r "echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf > /dev/null"
	fi

	_pass "Reset"
}

# ── Phase 1: Infrastructure prerequisites ────────────────────────
phase_prereqs() {
	log "=== Phase 1: Infrastructure prerequisites ==="

	r "[ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa -q"
	r "grep -q \"\$(cat ~/.ssh/id_rsa.pub)\" ~/.ssh/authorized_keys 2>/dev/null || { cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; }"

	# z/VM guests cannot reach their own external IP ("No route to host").
	# Since everything runs on one host, use loopback for bastion-ip / DNS / registry.
	HOST_IP="127.0.0.1"
	log "  Using HOST_IP=$HOST_IP (z/VM external IP is not self-routable)"

	_pass "Prerequisites"
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

	r "cd ~/aba && aba --noask"

	# Registry FQDN: use /etc/hosts (reliable across all dnsmasq configs).
	# Remove stale entries first (e.g. old virbr0 IP from previous setups).
	r "sudo sed -i '/${REG_FQDN}/d' /etc/hosts"
	r "echo '${HOST_IP} ${REG_FQDN}' | sudo tee -a /etc/hosts > /dev/null"

	run_critical "Registry FQDN in /etc/hosts" \
		"grep -q '${HOST_IP}.*${REG_FQDN}' /etc/hosts"

	log "  Setting up DNS (dnsmasq) via ABA ..."
	run_critical "Setup DNS" \
		"cd ~/aba && aba setup dns -y --bastion-ip $HOST_IP"

	# If dnsmasq has no upstream (resolv.conf.aba-backup was also 127.0.0.1),
	# add a public resolver so external names (registry.redhat.io, github.com) resolve.
	if ! r "dig +short +timeout=3 github.com @127.0.0.1" | grep -q '^[0-9]'; then
		log "  Adding public upstream DNS (dnsmasq had none)"
		r "echo 'server=8.8.8.8' | sudo tee /etc/dnsmasq.d/aba-upstream.conf > /dev/null && sudo systemctl restart dnsmasq"
	fi

	log "  Setting up NTP (chrony) via ABA ..."
	run_critical "Setup NTP" \
		"cd ~/aba && aba setup ntp -y --bastion-ip $HOST_IP"
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

	# docker: classic Quay is too heavy; omr image is amd64-only.
	r "cd ~/aba && aba -d mirror --reg-host ${REG_FQDN} --vendor docker"

	r "cd ~/aba && aba mirror --name mirror"

	# Ensure the registry is in a clean state before install.
	if ! r "curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 https://${REG_FQDN}:8443/v2/" 2>&1 | grep -qE '(200|401)'; then
		log "  Registry not responding — cleaning up for fresh install"
		r "cd ~/aba && aba -d mirror uninstall --yes --delete-data 2>/dev/null; true"
		r "podman stop -a 2>/dev/null; podman rm -a -f 2>/dev/null; sudo podman stop -a 2>/dev/null; sudo podman rm -a -f 2>/dev/null; true"
	fi

	log "  Installing registry (skipped by Make if .available) ..."
	run_critical_stream "Registry install" \
		"cd ~/aba && aba -y -d mirror install"

	run_test "Registry health check" \
		"code=\$(curl -k -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 https://${REG_FQDN}:8443/v2/); echo HTTP_\$code; echo \$code | grep -qE '^(200|401)\$'"
}

# ── Phase 5: Image sync ─────────────────────────────────────────
phase_sync() {
	log "=== Phase 5: Image sync ==="
	[ "$ABORT" -eq 1 ] && { _skip "Image sync (prior failure)"; return; }

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

# ── Phase 7: Additional images ──────────────────────────────────
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

	# Dummy network for ISO generation — we won't install, just verify ISO creation.
	# All IPs must be within machine_network; dns_servers stays 127.0.0.1 (our dnsmasq).
	local _domain
	_domain=$(r "cd ~/aba && grep '^domain=' aba.conf | cut -d= -f2") || _domain="example.com"
	_domain=$(echo "$_domain" | tr -d '[:space:]')

	r "cd ~/aba && aba --machine-network 10.0.0.0/24 --gateway 10.0.0.1 --ntp 10.0.0.1"

	r "cd ~/aba && aba cluster --name $SNO_NAME --type sno >/dev/null 2>&1 || true"
	r "cd ~/aba && aba cluster --name $SNO_NAME --type sno"
	r "cd ~/aba && aba -d $SNO_NAME --starting-ip 10.0.0.100 --master-cpu 8 --master-memory 16 --ports enc0"
	r "sed -i 's/^#*data_disk=.*/data_disk=/' ~/aba/$SNO_NAME/cluster.conf"
	# Skip network checks (arping, NTP reachability) — we use dummy IPs for ISO-only.
	r "cd ~/aba && aba --verify conf"

	# Add DNS records for the dummy cluster so preflight passes.
	r "printf 'address=/api.${SNO_NAME}.${_domain}/10.0.0.100\naddress=/.apps.${SNO_NAME}.${_domain}/10.0.0.100\n' \
		| sudo tee /etc/dnsmasq.d/aba-${SNO_NAME}.${_domain}.conf > /dev/null && sudo systemctl restart dnsmasq"

	check_disks || true

	log "  Generating ISO (Make skips if agent.s390x.iso exists) ..."
	run_stream "ISO generated" \
		"cd ~/aba && aba -y -d $SNO_NAME iso"

	run_test "ISO file is s390x" \
		"ls ~/aba/$SNO_NAME/iso-agent-based/agent.s390x.iso"
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

	r "cd ~/aba 2>/dev/null && aba -d mirror uninstall --yes --delete-data; true"
	r "rm -rf ~/aba ~/.aba"
	r "sudo sed -i '/${REG_FQDN}/d' /etc/hosts; true"
	r "sudo rm -f /etc/dnsmasq.d/*.conf; sudo systemctl restart dnsmasq 2>/dev/null; true"

	_pass "Final cleanup"
}

# ── Report ───────────────────────────────────────────────────────
report() {
	local e=$(( $(date +%s) - START ))
	echo
	echo "═══════════════════════════════════════════════════════════"
	echo "  ABA s390x Test Report — $(date '+%Y-%m-%d %H:%M')"
	echo "  Branch: $BRANCH  Host: $HOST  Duration: $((e/60))m$((e%60))s"
	echo "  Flags:  reset=$DO_RESET  clean=$DO_CLEAN"
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
	phase_final_cleanup
	report

	[ "$FAIL" -gt 0 ] && exit 1
	exit 0
}

main
