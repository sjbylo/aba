#!/bin/bash
# test-day2-wait-gate-abort.sh — Failed .wait gate must abort (not warn-and-continue)
#
# Regression for: ADR-011 amendment / Mateusz feedback — gate failures are fatal.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ABA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

_green() { echo -e "\033[0;32m$*\033[0m"; }
_red() { echo -e "\033[0;31m$*\033[0m"; }

PASS=0
FAIL=0

assert_pass() { PASS=$(( PASS + 1 )); _green "  ✓ $1"; }
assert_fail() { FAIL=$(( FAIL + 1 )); _red "  ✗ $1"; }

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		assert_pass "$desc"
	else
		assert_fail "$desc (expected: '$expected', got: '$actual')"
	fi
}

assert_contains() {
	local desc="$1" haystack="$2" needle="$3"
	if echo "$haystack" | grep -qF "$needle"; then
		assert_pass "$desc"
	else
		assert_fail "$desc (needle '$needle' not found)"
	fi
}

assert_not_contains() {
	local desc="$1" haystack="$2" needle="$3"
	if ! echo "$haystack" | grep -qF "$needle"; then
		assert_pass "$desc"
	else
		assert_fail "$desc (unexpected needle '$needle' found)"
	fi
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

CLUSTER="$TMPDIR/testcluster"
mkdir -p "$CLUSTER"

echo "=== test-day2-wait-gate-abort.sh ==="
echo

# Harness: failing oc wait + aba_abort that exits 1 (mirrors real aba_abort)
cat > "$TMPDIR/harness.sh" << 'HARNESS'
#!/bin/bash
aba_info() { :; }
aba_debug() { :; }
aba_warn() { echo "WARN: $*" >&2; }
aba_success() { :; }
aba_abort() { echo "ABORT: $*" >&2; exit 1; }

oc() {
	if [ "$1" = "apply" ] && [ "$2" = "-f" ]; then
		echo "$(basename "$3")"
		return 0
	elif [ "$1" = "wait" ]; then
		shift
		echo "OC_WAIT: $*" >&2
		return 1
	fi
}
HARNESS

awk '
/^apply_custom_manifests\(\)/ { found=1; depth=0 }
found {
	for (i=1; i<=length($0); i++) {
		c = substr($0, i, 1)
		if (c == "{") depth++
		if (c == "}") depth--
	}
	print
	if (found && depth == 0 && $0 ~ /}/) exit
}
' "$ABA_ROOT/scripts/day2.sh" >> "$TMPDIR/harness.sh"

cat >> "$TMPDIR/harness.sh" << 'TAIL'
apply_custom_manifests
TAIL
chmod +x "$TMPDIR/harness.sh"

# --- Failed wait gate aborts; wave 20 must not run ---
echo "Test 1: failed .wait gate aborts (does not continue)"
rm -rf "$CLUSTER/day2-custom-manifests"
mkdir -p "$CLUSTER/day2-custom-manifests/10-crd"
mkdir -p "$CLUSTER/day2-custom-manifests/20-cr"
echo "kind: CRD" > "$CLUSTER/day2-custom-manifests/10-crd/crd.yaml"
cat > "$CLUSTER/day2-custom-manifests/10-crd/.wait" << 'EOF'
--for=condition=available deployment/my-ctrl -n default --timeout=1s
EOF
echo "kind: CR" > "$CLUSTER/day2-custom-manifests/20-cr/cr.yaml"

stdout=$(cd "$CLUSTER" && bash -e "$TMPDIR/harness.sh" 2>/dev/null) && rc=0 || rc=$?
stderr=$(cd "$CLUSTER" && bash -e "$TMPDIR/harness.sh" 2>&1 1>/dev/null) || true

assert_eq "failed wait exits non-zero" "1" "$rc"
assert_contains "abort message names wait gate" "$stderr" "Wait gate failed"
assert_contains "abort message names wave" "$stderr" "10-crd"
assert_not_contains "wave 20 not applied after failed gate" "$stdout" "cr.yaml"
assert_contains "wave 10 applied before gate" "$stdout" "crd.yaml"

# --- Successful wait still applies later waves ---
echo "Test 2: successful .wait still continues to next wave"
cat > "$TMPDIR/harness-ok.sh" << 'HARNESS'
#!/bin/bash
aba_info() { :; }
aba_debug() { :; }
aba_warn() { echo "WARN: $*" >&2; }
aba_success() { :; }
aba_abort() { echo "ABORT: $*" >&2; exit 1; }

oc() {
	if [ "$1" = "apply" ] && [ "$2" = "-f" ]; then
		echo "$(basename "$3")"
		return 0
	elif [ "$1" = "wait" ]; then
		shift
		echo "OC_WAIT: $*" >&2
		return 0
	fi
}
HARNESS

awk '
/^apply_custom_manifests\(\)/ { found=1; depth=0 }
found {
	for (i=1; i<=length($0); i++) {
		c = substr($0, i, 1)
		if (c == "{") depth++
		if (c == "}") depth--
	}
	print
	if (found && depth == 0 && $0 ~ /}/) exit
}
' "$ABA_ROOT/scripts/day2.sh" >> "$TMPDIR/harness-ok.sh"
echo "apply_custom_manifests" >> "$TMPDIR/harness-ok.sh"
chmod +x "$TMPDIR/harness-ok.sh"

stdout=$(cd "$CLUSTER" && bash -e "$TMPDIR/harness-ok.sh" 2>/dev/null) && rc=0 || rc=$?
assert_eq "successful wait exits 0" "0" "$rc"
assert_contains "wave 20 applied after successful gate" "$stdout" "cr.yaml"

echo
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -gt 0 ] && exit 1
exit 0
