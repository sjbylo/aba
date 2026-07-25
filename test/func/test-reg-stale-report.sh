#!/bin/bash
# Unit tests for reg_stale_report / _reg_probe_set / reg_finish_uninstall.
#
# Fail-closed probes: SSH/tool failures must NOT look like "already gone".
# Pure bash with PATH stubs — no real registry, no network.
#
# Intended to run on conno.example.com (not bastion).

cd "$(dirname "$0")/../.."
REPO_ROOT="$PWD"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$(( pass + 1 )); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1 -- $2"; fail=$(( fail + 1 )); }

export PATH="$REPO_ROOT/scripts:$PATH"
# Fresh load of reg-common (bypass double-source guard if re-run in same shell)
unset _REG_COMMON_LOADED
source scripts/reg-common.sh

STUB_DIR=$(mktemp -d)
WORKDIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR" "$WORKDIR"' EXIT

# Default stubs: tools succeed with empty output → grep -q → exit 1 (absent)
cat >"$STUB_DIR/podman" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"$STUB_DIR/ss" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"$STUB_DIR/systemctl" <<'EOF'
#!/bin/bash
# default: inactive
echo inactive
exit 3
EOF
chmod +x "$STUB_DIR/podman" "$STUB_DIR/ss" "$STUB_DIR/systemctl"

# Fake ssh wrapper controlled by FAKE_SSH_RC / FAKE_SSH_OUT
cat >"$STUB_DIR/fake-ssh" <<'EOF'
#!/bin/bash
# Last arg is the remote command (matches ssh ... "cmd")
cmd="${*: -1}"
if [ -n "${FAKE_SSH_RC:-}" ] && [ "${FAKE_SSH_RC}" != "0" ] && [ "${FAKE_SSH_RC}" != "1" ]; then
	# Transport / tool failure path
	exit "$FAKE_SSH_RC"
fi
# Run the remote snippet locally under stubs
bash -c "$cmd"
rc=$?
[ -n "${FAKE_SSH_RC:-}" ] && exit "$FAKE_SSH_RC"
exit "$rc"
EOF
chmod +x "$STUB_DIR/fake-ssh"

export PATH="$STUB_DIR:/bin:/usr/bin"

reg_root="$WORKDIR/reg-root-absent"
reg_port=59999

echo
echo "=== reg_stale_report unit tests ==="
echo

# --- helpers -----------------------------------------------------------------
_run_report() {
	local vendor="$1"
	local ssh_cmd="${2:-}"
	local out rc=0
	# Under set -e + ERR: successful probe must not abort the caller
	set -e
	trap 'echo ERR_FIRED; return 9' ERR
	if [ -n "$ssh_cmd" ]; then
		out=$(reg_stale_report "$vendor" "$ssh_cmd") || rc=$?
	else
		out=$(reg_stale_report "$vendor") || rc=$?
	fi
	trap - ERR
	set +e
	REPORT_OUT="$out"
	REPORT_RC="$rc"
}

_expect_empty() {
	local name="$1" vendor="$2"
	_run_report "$vendor"
	if [ "$REPORT_RC" -eq 0 ] && [ -z "$REPORT_OUT" ]; then
		test_pass "$name"
	else
		test_fail "$name" "rc=$REPORT_RC out=[$REPORT_OUT]"
	fi
}

_expect_contains() {
	local name="$1" vendor="$2" needle="$3"
	_run_report "$vendor"
	if [ "$REPORT_RC" -eq 0 ] && [[ "$REPORT_OUT" == *"$needle"* ]]; then
		test_pass "$name"
	else
		test_fail "$name" "rc=$REPORT_RC out=[$REPORT_OUT] missing [$needle]"
	fi
}

_expect_abort() {
	local name="$1"
	shift
	local out rc=0
	set +e
	trap - ERR
	out=$(reg_stale_report "$@" 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ] && [[ "$out" == *"Registry probe failed"* || "$out" == *"unknown vendor"* || "$out" == *"[ABA] Error"* ]]; then
		test_pass "$name"
	else
		test_fail "$name" "expected abort, rc=$rc out=[$out]"
	fi
}

# --- 1) all absent → empty, rc=0 ---------------------------------------------
_expect_empty "docker all-absent → empty rc=0" docker
_expect_empty "quay all-absent → empty rc=0" quay
_expect_empty "quay-ng all-absent → empty rc=0" quay-ng

# --- 2) reg_root present -----------------------------------------------------
mkdir -p "$WORKDIR/reg-root-present"
reg_root="$WORKDIR/reg-root-present"
_expect_contains "docker detects reg_root" docker "reg_root"
_expect_contains "quay detects reg_root" quay "reg_root"
reg_root="$WORKDIR/reg-root-absent"
rm -rf "$WORKDIR/reg-root-present"

# --- 3) port listening (ss stub) ---------------------------------------------
cat >"$STUB_DIR/ss" <<EOF
#!/bin/bash
echo "LISTEN 0 128 0.0.0.0:${reg_port} 0.0.0.0:* users:((\"nginx\",pid=1,fd=1))"
exit 0
EOF
chmod +x "$STUB_DIR/ss"
_expect_contains "docker detects listening port" docker "Port $reg_port"
# reset ss
cat >"$STUB_DIR/ss" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$STUB_DIR/ss"

# --- 4) containers / secrets -------------------------------------------------
cat >"$STUB_DIR/podman" <<'EOF'
#!/bin/bash
if [[ "$*" == *secret* ]]; then
	echo redis_pass
	exit 0
fi
if [[ "$*" == *ps* ]]; then
	echo quay-app
	echo registry
	exit 0
fi
exit 0
EOF
chmod +x "$STUB_DIR/podman"
_expect_contains "docker detects registry container" docker "registry container"
_expect_contains "quay detects containers" quay "Quay containers"
_expect_contains "quay detects redis_pass" quay "redis_pass"
# reset podman empty
cat >"$STUB_DIR/podman" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$STUB_DIR/podman"

# --- 5) quay-ng systemctl active / inactive ----------------------------------
cat >"$STUB_DIR/systemctl" <<'EOF'
#!/bin/bash
echo active
exit 0
EOF
chmod +x "$STUB_DIR/systemctl"
_expect_contains "quay-ng detects active service" quay-ng "quay.service still active"

cat >"$STUB_DIR/systemctl" <<'EOF'
#!/bin/bash
echo inactive
exit 3
EOF
chmod +x "$STUB_DIR/systemctl"
_expect_empty "quay-ng inactive → empty" quay-ng

# --- 6) SSH transport failure (rc=255) → abort, not empty --------------------
export FAKE_SSH_RC=255
_expect_abort "ssh rc=255 aborts (fail-closed)" docker "$STUB_DIR/fake-ssh"
unset FAKE_SSH_RC

# --- 7) podman missing (127) → abort ----------------------------------------
cat >"$STUB_DIR/podman" <<'EOF'
#!/bin/bash
exit 127
EOF
chmod +x "$STUB_DIR/podman"
_expect_abort "podman exit 127 aborts (fail-closed)" docker
cat >"$STUB_DIR/podman" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$STUB_DIR/podman"

# --- 8) unknown vendor -------------------------------------------------------
_expect_abort "unknown vendor aborts" not-a-vendor

# --- 9) reg_finish_uninstall clears regcreds ---------------------------------
regcreds_dir="$WORKDIR/regcreds"
mkdir -p "$regcreds_dir"
echo keepme=1 >"$regcreds_dir/state.sh"
echo junk >"$regcreds_dir/other"
set +e
out=$(reg_finish_uninstall "Docker" "already uninstalled" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ ! -e "$regcreds_dir/state.sh" ] && [ ! -e "$regcreds_dir/other" ] \
	&& [[ "$out" == *"already uninstalled"* ]]; then
	test_pass "reg_finish_uninstall clears regcreds + success msg"
else
	test_fail "reg_finish_uninstall" "rc=$rc leftovers=$(ls -A "$regcreds_dir" 2>/dev/null) out=[$out]"
fi

# --- 10) $() under set -e when all absent ------------------------------------
set -e
trap 'test_fail "set -e \$() safe" "ERR fired"; exit 1' ERR
_stale=$(reg_stale_report docker)
[ -z "$_stale" ]
trap - ERR
test_pass "set -e + \$() with empty report does not abort"

echo
echo "========================================"
if [ "$fail" -eq 0 ]; then
	printf "  ${GREEN}ALL %d TESTS PASSED${NC}\n" "$pass"
else
	printf "  ${RED}%d failed, %d passed${NC}\n" "$fail" "$pass"
fi
echo "========================================"
echo

exit "$fail"
