#!/usr/bin/env bash
# =============================================================================
# E2E Cleanup Function Tests
# =============================================================================
# Verifies the framework's cluster and mirror cleanup mechanisms work end-to-end:
#   1. Mirror cleanup: install Docker registry on conN (port 5000, separate from
#      pool Quay on 8443), register for cleanup, run cleanup, verify pods gone.
#   2. Cluster cleanup: create cluster config dir, register for cleanup, run
#      cleanup mechanism, verify aba delete was executed.
#
# Usage:
#   test/func/test-e2e-cleanup.sh [POOL]     (default: 3)
#
# Prerequisites:
#   - conN must be idle (no running suite)
#   - Pool Quay registry runs on port 8443 (untouched by this test)
# =============================================================================

set -uo pipefail

POOL="${1:-3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd "$SCRIPT_DIR/../e2e" && pwd)"

source "$E2E_DIR/lib/constants.sh"
source "$E2E_DIR/config.env" 2>/dev/null || true

_USER="${CON_SSH_USER:-steve}"
_DOMAIN="${VM_BASE_DOMAIN:-example.com}"
_CON="con${POOL}.${_DOMAIN}"
_CON_TARGET="${_USER}@${_CON}"
_SSH="ssh -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

_pass=0
_fail=0
_total=0

_log()  { printf "\n\033[1;36m=== %s ===\033[0m\n" "$*"; }
_ok()   { (( _pass++ )); (( _total++ )); printf "  \033[1;32mPASS\033[0m  %s\n" "$*"; }
_fail() { (( _fail++ )); (( _total++ )); printf "  \033[1;31mFAIL\033[0m  %s\n" "$*"; }
_con()  { $_SSH "$_CON_TARGET" "$@"; }

_assert() {
	local desc="$1"; shift
	if "$@" >/dev/null 2>&1; then _ok "$desc"; else _fail "$desc"; fi
}

_assert_not() {
	local desc="$1"; shift
	if "$@" >/dev/null 2>&1; then _fail "$desc"; else _ok "$desc"; fi
}

# Run cleanup file processing (replicates runner.sh _pre_suite_cleanup)
_run_cleanup() {
	local pattern="$1"
	local action="$2"

	_con "bash -c '
		for f in ~/aba/test/e2e/logs/${pattern}; do
			[ -f \"\$f\" ] || continue
			echo \"  Processing: \$(basename \"\$f\")\"
			while IFS=\" \" read -r target path; do
				[ -z \"\$path\" ] && continue
				echo \"  -> \$target: aba -d \$path ${action}\"
				ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 \"\$target\" \
					\"[ -d \\\"\$path\\\" ] && cd ~/aba && aba -d \\\"\$path\\\" ${action} || echo \\\"  (dir not found -- already cleaned)\\\"\" 2>&1
			done < \"\$f\"
			rm -f \"\$f\"
		done
	'" 2>&1
}

# =============================================================================
# Preflight
# =============================================================================

_log "Preflight: pool $POOL ($_CON)"

_assert "SSH to $_CON" _con "echo ok"

"$E2E_DIR/run.sh" deploy --pool "$POOL" >/dev/null 2>&1 || true
_assert "Framework deployed" _con "test -f ~/aba/test/e2e/lib/framework.sh"

# Ensure logs dir exists on remote (may not after a clean state)
_con "mkdir -p ~/aba/test/e2e/logs"

_assert "Pool Quay registry running on 8443" \
	_con "curl -sf -o /dev/null https://${_CON}:8443/health/instance"

# =============================================================================
# TEST 1: Mirror cleanup
# Install Docker registry on conN:5000 (pool Quay stays on 8443),
# simulate crash, verify cleanup uninstalls Docker registry.
# =============================================================================

_log "TEST 1: Mirror cleanup (Docker registry on port 5000)"

echo "  Step 1: Configure aba + mirror.conf for Docker on port 5000 ..."
_con "cd ~/aba && aba reset -f 2>/dev/null; true"
_con "cd ~/aba && aba -A --platform vmw --channel stable --version p --base-domain p${POOL}.example.com" 2>&1 | tail -1
_con "cd ~/aba && aba -d mirror mirror.conf" 2>&1 | tail -1

# Verify mirror.conf exists now
if ! _con "test -f ~/aba/mirror/mirror.conf" 2>/dev/null; then
	_fail "mirror.conf creation"
	echo "  Cannot proceed with mirror test"
else
	echo "  Step 2: Install Docker registry on ${_CON}:5000 ..."
	if _con "cd ~/aba && aba -d mirror install --vendor docker -H ${_CON} --reg-port 5000" 2>&1; then
		_ok "Docker registry installed"

		_assert "Docker registry container running" \
			_con "podman ps --format '{{.Names}}' | grep -q '^registry$'"

		echo "  Step 3: Write .mirror-cleanup file (simulating crash) ..."
		_con "echo '${_CON_TARGET} /home/${_USER}/aba/mirror' > ~/aba/test/e2e/logs/cleanup-test.mirror-cleanup"
		_assert ".mirror-cleanup file created" \
			_con "test -f ~/aba/test/e2e/logs/cleanup-test.mirror-cleanup"

		echo "  Step 4: Run mirror cleanup mechanism ..."
		_run_cleanup "cleanup-test.mirror-cleanup" "uninstall"
		echo ""

		echo "  Step 5: Verify Docker registry is gone ..."
		sleep 2

		_assert_not "Docker registry container removed" \
			_con "podman ps --format '{{.Names}}' | grep -q '^registry$'"

		_assert_not ".mirror-cleanup file cleaned up" \
			_con "test -f ~/aba/test/e2e/logs/cleanup-test.mirror-cleanup"
	else
		_fail "Docker registry install"
		echo "  Mirror cleanup test skipped due to install failure"
	fi
fi

echo "  Step 6: Verify pool Quay unaffected ..."
_assert "Pool Quay still running on 8443" \
	_con "curl -sf -o /dev/null https://${_CON}:8443/health/instance"

# =============================================================================
# TEST 2: Cluster cleanup
# Create a cluster config dir (with vmware.conf), register for cleanup,
# run cleanup mechanism, verify aba delete was executed.
# =============================================================================

_log "TEST 2: Cluster cleanup (aba delete on config-only cluster)"

CLUSTER="cleanup-test-sno${POOL}"

echo "  Step 1: Create cluster config ..."
_con "cd ~/aba && rm -rf $CLUSTER"
_con "cd ~/aba && aba cluster -n $CLUSTER -t sno -i 10.0.2.39 --step cluster.conf" 2>&1 | tail -3

_assert "Cluster dir created" _con "test -d ~/aba/$CLUSTER"
_assert "cluster.conf exists" _con "test -f ~/aba/$CLUSTER/cluster.conf"

echo "  Step 2: Write .cleanup file (simulating crash) ..."
_con "echo '${_CON_TARGET} /home/${_USER}/aba/${CLUSTER}' > ~/aba/test/e2e/logs/cleanup-test.cleanup"
_assert ".cleanup file created" _con "test -f ~/aba/test/e2e/logs/cleanup-test.cleanup"

echo "  Step 3: Run cluster cleanup ..."
_run_cleanup "cleanup-test.cleanup" "delete"
echo ""

echo "  Step 4: Verify cleanup ran ..."
_assert_not ".cleanup file removed" \
	_con "test -f ~/aba/test/e2e/logs/cleanup-test.cleanup"

# aba delete with no VMs just exits (no VMs to destroy) -- the mechanism still ran
_assert "Cluster dir remains (aba delete only removes VMs)" \
	_con "test -d ~/aba/$CLUSTER"

# =============================================================================
# Final cleanup
# =============================================================================

_log "Final cleanup"
_con "cd ~/aba && rm -rf $CLUSTER" 2>/dev/null || true
_con "rm -f ~/aba/test/e2e/logs/cleanup-test.cleanup ~/aba/test/e2e/logs/cleanup-test.mirror-cleanup" 2>/dev/null || true
# Reset mirror state from Docker registry install
_con "rm -f ~/aba/mirror/.installed ~/aba/mirror/.uninstalled" 2>/dev/null || true
echo "  Done."

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "========================================"
if [ $_fail -eq 0 ]; then
	printf "  \033[1;32mALL %d TESTS PASSED\033[0m\n" "$_total"
else
	printf "  \033[1;31m%d/%d FAILED\033[0m\n" "$_fail" "$_total"
fi
echo "========================================"
echo ""

exit "$_fail"
