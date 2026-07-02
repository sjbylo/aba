#!/bin/bash
# Unit tests for day2 apply_custom_manifests() WAVED-manifest behavior.
#
# A "wave" is a numbered subdirectory (NN-name/) of day2-custom-manifests/.
# Waves are applied in NUMERIC order (so 2 before 10), and an optional per-wave
# '.wait' file makes day2 run 'oc wait <condition>' before starting the next wave.
# Flat (unprefixed) files must still be applied exactly as before (backward compat).
#
# No real cluster is available: 'oc' is stubbed via a PATH shim that just logs its
# arguments to a file, so we can assert the ORDER of apply/wait calls.

cd "$(dirname "$0")/../.."
REPO_ROOT="$PWD"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0
FAILURES=""

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$(( pass + 1 )); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1 -- $2"; fail=$(( fail + 1 )); FAILURES=1; }

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

# Load aba helpers (aba_info / aba_debug / aba_warning / aba_info_ok)
source scripts/include_all.sh dummy_arg 2>/dev/null

# day2.sh executes a whole pipeline when sourced, so we cannot source it. Extract
# just the apply_custom_manifests() definition and eval it to test in isolation.
_fn_src="$(sed -n '/^apply_custom_manifests() {/,/^}/p' scripts/day2.sh)"
eval "$_fn_src"
if ! type apply_custom_manifests >/dev/null 2>&1; then
	echo "FATAL: could not extract apply_custom_manifests() from scripts/day2.sh" >&2
	exit 1
fi

# --- oc PATH shim: log every 'oc ...' call to $OC_LOG, with failure injection ---
_shim_dir="$_tmp/bin"
mkdir -p "$_shim_dir"
cat > "$_shim_dir/oc" <<'MOCK'
#!/bin/bash
echo "oc $*" >> "$OC_LOG"
verb="$1"
if [ "$verb" = "apply" ]; then
	f="${@: -1}"							# manifest path is the last arg
	if [ -n "$OC_APPLY_FAIL_ON" ] && [[ "$f" == *"$OC_APPLY_FAIL_ON"* ]]; then
		exit 1
	fi
	exit 0
fi
if [ "$verb" = "wait" ]; then
	[ -n "$OC_WAIT_FAIL" ] && exit 1
	exit 0
fi
exit 0
MOCK
chmod +x "$_shim_dir/oc"
export PATH="$_shim_dir:$PATH"

# --- helpers ------------------------------------------------------------------

_mk() {									# create a non-empty manifest at $1
	mkdir -p "$(dirname "$1")"
	printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n' "$(basename "$1")" > "$1"
}

_LAST_LOG=""
_LAST_RC=""
_run_apply() {								# $1 = cluster dir
	local dir="$1"
	_LAST_LOG="$_tmp/order-$RANDOM.log"
	: > "$_LAST_LOG"
	local rc=0
	( export OC_LOG="$_LAST_LOG"; cd "$dir" && apply_custom_manifests ) >/dev/null 2>&1 || rc=$?
	_LAST_RC="$rc"
}

_apply_line() {								# echo first line no. of 'apply ... $2'
	grep -n "apply .*$2" "$1" 2>/dev/null | head -1 | cut -d: -f1
}

_assert_before() {							# name log fileA fileB
	local name="$1" log="$2" a="$3" b="$4" la lb
	la="$(_apply_line "$log" "$a")"
	lb="$(_apply_line "$log" "$b")"
	if [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ]; then
		test_pass "$name"
	else
		test_fail "$name" "expected $a(line=${la:-none}) before $b(line=${lb:-none}); log: $(tr '\n' '|' <"$log")"
	fi
}

_assert_applied() {							# name log basename
	if grep -q "apply .*$3" "$2"; then
		test_pass "$1"
	else
		test_fail "$1" "$3 not applied; log: $(tr '\n' '|' <"$2")"
	fi
}

_assert_wait_between() {						# name log fileA waitPat fileB
	local name="$1" log="$2" a="$3" pat="$4" b="$5" la lw lb
	la="$(_apply_line "$log" "$a")"
	lw="$(grep -n "wait .*$pat" "$log" 2>/dev/null | head -1 | cut -d: -f1)"
	lb="$(_apply_line "$log" "$b")"
	if [ -n "$la" ] && [ -n "$lw" ] && [ -n "$lb" ] && [ "$la" -lt "$lw" ] && [ "$lw" -lt "$lb" ]; then
		test_pass "$name"
	else
		test_fail "$name" "expected apply($a)=$la < wait=$lw < apply($b)=$lb; log: $(tr '\n' '|' <"$log")"
	fi
}

echo
echo "=== Testing: day2 apply_custom_manifests() waves ==="
echo

# --- Test A: waves applied in NUMERIC order (lexicographic would put 10 before 2)
echo "--- Test A: numeric wave ordering ---"
fxA="$_tmp/clusterA"
_mk "$fxA/day2-custom-manifests/2-early/early.yaml"
_mk "$fxA/day2-custom-manifests/10-first/first.yaml"
_mk "$fxA/day2-custom-manifests/20-third/third.yaml"
_run_apply "$fxA"
_assert_before "wave 2 applied before wave 10 (numeric, not lexicographic)" "$_LAST_LOG" "early.yaml" "first.yaml"
_assert_before "wave 10 applied before wave 20" "$_LAST_LOG" "first.yaml" "third.yaml"

# --- Test B: per-wave .wait triggers 'oc wait' BEFORE the next wave
echo "--- Test B: .wait gates the next wave ---"
fxB="$_tmp/clusterB"
_mk "$fxB/day2-custom-manifests/10-one/one.yaml"
printf -- '--for=condition=Established crd/widgets.example.com --timeout=60s\n' > "$fxB/day2-custom-manifests/10-one/.wait"
_mk "$fxB/day2-custom-manifests/20-two/two.yaml"
_run_apply "$fxB"
_assert_wait_between ".wait runs 'oc wait' between wave 10 and wave 20" "$_LAST_LOG" "one.yaml" "widgets.example.com" "two.yaml"

# --- Test C: flat/unprefixed files still applied (backward compatible)
echo "--- Test C: flat files (legacy layout) still apply ---"
fxC="$_tmp/clusterC"
_mk "$fxC/day2-custom-manifests/aaa.yaml"
_mk "$fxC/day2-custom-manifests/bbb.yml"
_run_apply "$fxC"
_assert_applied "flat aaa.yaml applied" "$_LAST_LOG" "aaa.yaml"
_assert_applied "flat bbb.yml applied" "$_LAST_LOG" "bbb.yml"

# --- Test C2: top-level flat files applied even when waves are present
echo "--- Test C2: flat + waves mixed layout ---"
fxC2="$_tmp/clusterC2"
_mk "$fxC2/day2-custom-manifests/top.yaml"
_mk "$fxC2/day2-custom-manifests/10-w/w.yaml"
_run_apply "$fxC2"
_assert_applied "top-level flat file applied in waved layout" "$_LAST_LOG" "top.yaml"
_assert_applied "wave file applied in waved layout" "$_LAST_LOG" "w.yaml"

# --- Test D: empty / missing directory is a no-op (existing behavior preserved)
echo "--- Test D: empty/missing is a no-op ---"
fxD="$_tmp/clusterD"
mkdir -p "$fxD"
_run_apply "$fxD"
if [ ! -s "$_LAST_LOG" ] && [ "$_LAST_RC" -eq 0 ]; then
	test_pass "missing day2-custom-manifests: no oc calls, rc=0"
else
	test_fail "missing day2-custom-manifests no-op" "rc=$_LAST_RC log=$(tr '\n' '|' <"$_LAST_LOG")"
fi
fxD2="$_tmp/clusterD2"
mkdir -p "$fxD2/day2-custom-manifests"
_run_apply "$fxD2"
if [ ! -s "$_LAST_LOG" ] && [ "$_LAST_RC" -eq 0 ]; then
	test_pass "empty day2-custom-manifests: no oc calls, rc=0"
else
	test_fail "empty day2-custom-manifests no-op" "rc=$_LAST_RC log=$(tr '\n' '|' <"$_LAST_LOG")"
fi

# --- Test E: a failed 'oc apply' is non-fatal (return 0, keep going)
echo "--- Test E: apply failure is non-fatal ---"
fxE="$_tmp/clusterE"
_mk "$fxE/day2-custom-manifests/10-a/bad.yaml"
_mk "$fxE/day2-custom-manifests/20-b/good.yaml"
export OC_APPLY_FAIL_ON="bad.yaml"
_run_apply "$fxE"
unset OC_APPLY_FAIL_ON
if [ "$_LAST_RC" -eq 0 ]; then
	test_pass "apply failure keeps rc=0 (non-fatal)"
else
	test_fail "apply failure non-fatal" "rc=$_LAST_RC"
fi
_assert_applied "next wave still applied after a failed apply" "$_LAST_LOG" "good.yaml"

# --- Test F: an 'oc wait' timeout is non-fatal and does not block later waves
echo "--- Test F: wait timeout is non-fatal ---"
fxF="$_tmp/clusterF"
_mk "$fxF/day2-custom-manifests/10-a/a.yaml"
printf -- '--for=condition=Ready pod/foo --timeout=1s\n' > "$fxF/day2-custom-manifests/10-a/.wait"
_mk "$fxF/day2-custom-manifests/20-b/b.yaml"
export OC_WAIT_FAIL=1
_run_apply "$fxF"
unset OC_WAIT_FAIL
if [ "$_LAST_RC" -eq 0 ]; then
	test_pass "wait timeout keeps rc=0 (non-fatal)"
else
	test_fail "wait timeout non-fatal" "rc=$_LAST_RC"
fi
_assert_applied "next wave still applied after a wait timeout" "$_LAST_LOG" "b.yaml"

# --- Test G: waved mode still applies non-numbered subdir manifests -----------
echo "--- waved mode keeps non-wave subdir manifests (no silent drop) ---"
fxG="$_tmp/clusterG"
_mk "$fxG/day2-custom-manifests/10-app/app.yaml"
_mk "$fxG/day2-custom-manifests/base/storageclass.yaml"
_run_apply "$fxG"
_assert_applied "waved mode: wave manifest applied"                          "$_LAST_LOG" "app.yaml"
_assert_applied "waved mode: non-numbered subdir manifest applied (kept)"    "$_LAST_LOG" "storageclass.yaml"

# --- Test H: an indented .wait comment is ignored, not passed to 'oc wait' -----
echo "--- .wait indented comment ignored ---"
fxH="$_tmp/clusterH"
_mk "$fxH/day2-custom-manifests/10-a/a.yaml"
printf '  # just a comment\n--for=condition=Ready pod/foo\n' > "$fxH/day2-custom-manifests/10-a/.wait"
_mk "$fxH/day2-custom-manifests/20-b/b.yaml"
_run_apply "$fxH"
if grep -q 'wait .*comment' "$_LAST_LOG"; then
	test_fail ".wait indented comment ignored" "comment was passed to oc wait: $(grep wait "$_LAST_LOG" | tr '\n' '|')"
else
	test_pass ".wait indented comment ignored (not passed to oc wait)"
fi
grep -q 'wait .*pod/foo' "$_LAST_LOG" && test_pass ".wait real condition still honored" || test_fail ".wait real condition" "pod/foo wait missing"

# --- Test I: top-level numbered files order by number relative to waves --------
echo "--- numeric ordering across waves and top-level files ---"
fxI="$_tmp/clusterI"
_mk "$fxI/day2-custom-manifests/10-operators/op.yaml"
_mk "$fxI/day2-custom-manifests/99-postconfig.yaml"
_run_apply "$fxI"
_assert_before "wave 10-operators applied before top-level 99-postconfig.yaml (legacy order kept)" "$_LAST_LOG" "op.yaml" "99-postconfig.yaml"

# --- Test J: .wait robustness (trailing comment, bad quotes, unreadable file) --
echo "--- .wait parsing robustness ---"

# L3: a trailing '# comment' must be stripped, not passed to oc wait as argv.
fxJ="$_tmp/clusterJ"
_mk "$fxJ/day2-custom-manifests/10-w/a.yaml"
printf -- '--for=condition=Ready pod/foo --timeout=5s # wait for foo\n' > "$fxJ/day2-custom-manifests/10-w/.wait"
_run_apply "$fxJ"
if grep -q 'wait .*pod/foo' "$_LAST_LOG" && ! grep -q 'wait .*comment' "$_LAST_LOG" && ! grep -q 'wait .*#' "$_LAST_LOG"; then
	test_pass ".wait trailing '# comment' stripped before oc wait"
else
	test_fail ".wait trailing comment" "comment leaked to oc wait: $(grep wait "$_LAST_LOG" | tr '\n' '|')"
fi

# L2: a line xargs cannot parse (unbalanced quote) is skipped, not run truncated.
fxK="$_tmp/clusterK"
_mk "$fxK/day2-custom-manifests/10-w/a.yaml"
printf -- "--for=condition=Ready pod/foo --timeout=5s'\n" > "$fxK/day2-custom-manifests/10-w/.wait"
_run_apply "$fxK"
if grep -q 'apply .*a.yaml' "$_LAST_LOG" && ! grep -q '^oc wait' "$_LAST_LOG"; then
	test_pass "unbalanced-quote .wait line skipped (oc wait not run with truncated argv)"
else
	test_fail ".wait bad quote" "oc wait ran on an unparseable line: $(grep wait "$_LAST_LOG" | tr '\n' '|')"
fi

# M4: an unreadable .wait must be non-fatal even under 'set -e' (day2.sh is bash -e):
# the gate is skipped and later waves still apply (no whole-run abort).
fxL="$_tmp/clusterL"
_mk "$fxL/day2-custom-manifests/10-w/a.yaml"
_mk "$fxL/day2-custom-manifests/20-w/b.yaml"
printf -- '--for=condition=Ready pod/foo\n' > "$fxL/day2-custom-manifests/10-w/.wait"
chmod 000 "$fxL/day2-custom-manifests/10-w/.wait"
_LAST_LOG="$_tmp/order-e.log"; : > "$_LAST_LOG"; _erc=0
( set -e; export OC_LOG="$_LAST_LOG"; cd "$fxL" && apply_custom_manifests ) >/dev/null 2>&1 || _erc=$?
chmod 644 "$fxL/day2-custom-manifests/10-w/.wait" 2>/dev/null
if [ "$_erc" -eq 0 ] && grep -q 'apply .*a.yaml' "$_LAST_LOG" && grep -q 'apply .*b.yaml' "$_LAST_LOG"; then
	test_pass "unreadable .wait is non-fatal under set -e (later waves still apply)"
else
	test_fail "M4 unreadable .wait" "run aborted (rc=$_erc) or wave 20 skipped: $(tr '\n' '|' <"$_LAST_LOG")"
fi

echo
echo "=== Results: $pass passed, $fail failed ==="
echo

[ -z "$FAILURES" ] && exit 0 || exit 1
