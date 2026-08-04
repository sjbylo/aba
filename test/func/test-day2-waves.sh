#!/bin/bash
# test-day2-waves.sh — Validate waved day2-custom-manifests logic
#
# Tests:
# 1. Flat mode (no numbered subdirs): alphabetical order
# 2. Waved mode: numeric order via sort -V
# 3. Top-level flat files applied before waves
# 4. .wait file parsed correctly (comments/blanks skipped)
# 5. Empty wave dir skipped
# 6. Empty manifest files skipped with warning
# 7. Backward compatibility: no dir = no-op

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

# --- Setup ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

CLUSTER="$TMPDIR/testcluster"
mkdir -p "$CLUSTER"

echo "=== test-day2-waves.sh ==="
echo

# Create a test harness that sources just the function we need
cat > "$TMPDIR/harness.sh" << 'HARNESS'
#!/bin/bash
aba_info() { :; }
aba_debug() { :; }
aba_warn() { echo "WARN: $*" >&2; }
aba_success() { :; }

# Mock oc: output applied filenames to stdout for capture
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

# Extract apply_custom_manifests from day2.sh using awk (handles nested braces)
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

# --- Test 1: No directory = no-op ---
echo "Test 1: No day2-custom-manifests dir (no-op)"
cd "$CLUSTER"
rm -rf day2-custom-manifests
output=$(bash "$TMPDIR/harness.sh" 2>/dev/null)
assert_eq "No dir produces no output" "" "$output"

# --- Test 2: Empty directory = no-op ---
echo "Test 2: Empty directory"
mkdir -p "$CLUSTER/day2-custom-manifests"
output=$(bash "$TMPDIR/harness.sh" 2>/dev/null)
assert_eq "Empty dir produces no output" "" "$output"

# --- Test 3: Flat mode (legacy) ---
echo "Test 3: Flat mode - alphabetical order"
rm -rf "$CLUSTER/day2-custom-manifests"
mkdir -p "$CLUSTER/day2-custom-manifests"
echo "kind: A" > "$CLUSTER/day2-custom-manifests/b-second.yaml"
echo "kind: B" > "$CLUSTER/day2-custom-manifests/a-first.yaml"
output=$(cd "$CLUSTER" && bash "$TMPDIR/harness.sh" 2>/dev/null)
expected=$(printf "a-first.yaml\nb-second.yaml\n")
assert_eq "Flat mode: alphabetical" "$expected" "$output"

# --- Test 4: Waved mode - numeric order ---
echo "Test 4: Waved mode - numeric order (sort -V)"
rm -rf "$CLUSTER/day2-custom-manifests"
mkdir -p "$CLUSTER/day2-custom-manifests/10-first"
mkdir -p "$CLUSTER/day2-custom-manifests/2-early"
mkdir -p "$CLUSTER/day2-custom-manifests/20-second"
echo "kind: A" > "$CLUSTER/day2-custom-manifests/10-first/a.yaml"
echo "kind: B" > "$CLUSTER/day2-custom-manifests/2-early/b.yaml"
echo "kind: C" > "$CLUSTER/day2-custom-manifests/20-second/c.yaml"
output=$(cd "$CLUSTER" && bash "$TMPDIR/harness.sh" 2>/dev/null)
expected=$(printf "b.yaml\na.yaml\nc.yaml\n")
assert_eq "Waved mode: 2 < 10 < 20" "$expected" "$output"

# --- Test 5: Top-level files applied before waves ---
echo "Test 5: Top-level files before waves"
echo "kind: Top" > "$CLUSTER/day2-custom-manifests/top.yaml"
output=$(cd "$CLUSTER" && bash "$TMPDIR/harness.sh" 2>/dev/null)
first_line=$(echo "$output" | head -1)
assert_eq "Top-level file first" "top.yaml" "$first_line"

# --- Test 6: .wait file triggers oc wait ---
echo "Test 6: .wait file processed"
rm -rf "$CLUSTER/day2-custom-manifests"
mkdir -p "$CLUSTER/day2-custom-manifests/10-crd"
mkdir -p "$CLUSTER/day2-custom-manifests/20-cr"
echo "kind: CRD" > "$CLUSTER/day2-custom-manifests/10-crd/crd.yaml"
cat > "$CLUSTER/day2-custom-manifests/10-crd/.wait" << 'EOF'
# Wait for CRD controller
--for=condition=available deployment/my-ctrl -n default --timeout=60s
EOF
echo "kind: CR" > "$CLUSTER/day2-custom-manifests/20-cr/cr.yaml"
stderr_output=$(cd "$CLUSTER" && bash "$TMPDIR/harness.sh" 2>&1 1>/dev/null)
assert_contains ".wait triggers oc wait" "$stderr_output" "OC_WAIT: --for=condition=available"
assert_not_contains ".wait skips comments" "$stderr_output" "Wait for CRD"

# --- Test 7: Empty manifest file skipped ---
echo "Test 7: Empty manifest file produces warning"
rm -rf "$CLUSTER/day2-custom-manifests"
mkdir -p "$CLUSTER/day2-custom-manifests"
touch "$CLUSTER/day2-custom-manifests/empty.yaml"
echo "kind: OK" > "$CLUSTER/day2-custom-manifests/good.yaml"
stderr_output=$(cd "$CLUSTER" && bash "$TMPDIR/harness.sh" 2>&1 1>/dev/null)
assert_contains "Empty file warns" "$stderr_output" "WARN"
output=$(cd "$CLUSTER" && bash "$TMPDIR/harness.sh" 2>/dev/null)
assert_contains "Good file applied" "$output" "good.yaml"
assert_not_contains "Empty file not applied" "$output" "empty.yaml"

# --- Summary ---
echo
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -gt 0 ] && exit 1
exit 0
