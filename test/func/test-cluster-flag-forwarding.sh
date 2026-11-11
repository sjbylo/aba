#!/bin/bash
# Test: Verify CLI flags flow through the full aba cluster -n pipeline
# Covers: first creation, override of existing cluster.conf, idempotent re-run
# Unit test (fast, local, no network, no cluster install)

set -e

cd "$(dirname "$0")/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0

test_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; pass=$((pass + 1)); }
test_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; fail=$((fail + 1)); FAILURES=1; }

assert_conf_value() {
	local file="$1" key="$2" expected="$3"
	local actual
	actual=$(grep -E "^${key}=" "$file" | head -1 | sed 's/[[:space:]]*#.*//' | cut -d= -f2)
	if [ "$actual" = "$expected" ]; then
		test_pass "$key=$expected"
	else
		test_fail "$key expected [$expected] got [$actual]"
	fi
}

CLUSTER_DIR="test-flagfwd-$$"

# Save and restore aba.conf around the test (non-interactive mode needed)
cp aba.conf aba.conf.test-backup

cleanup() {
	rm -rf "$CLUSTER_DIR"
	[ -f aba.conf.test-backup ] && mv aba.conf.test-backup aba.conf
}
trap cleanup EXIT

# Set non-interactive mode so create-cluster-conf.sh doesn't open an editor
sed -i -E 's/^ask=.*/ask=false/' aba.conf

echo
echo "=== Testing: CLI flag forwarding via aba cluster -n ==="
echo

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: First creation with flags
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Test 1: First creation with flags ---"

./aba cluster -n "$CLUSTER_DIR" -t standard --num-workers 7 --vlan 100 --mirror-name enclave1 -I proxy --step cluster.conf >/dev/null 2>&1

CONF="$CLUSTER_DIR/cluster.conf"

[ -f "$CONF" ] && test_pass "cluster.conf created" || test_fail "cluster.conf not created"

assert_conf_value "$CONF" num_workers 7
assert_conf_value "$CONF" vlan 100
assert_conf_value "$CONF" image_source proxy

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Override existing cluster.conf
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Test 2: Override existing cluster.conf ---"

./aba cluster -n "$CLUSTER_DIR" --num-workers 5 -I direct --mirror-name enclave2 --step cluster.conf >/dev/null 2>&1

assert_conf_value "$CONF" num_workers 5
assert_conf_value "$CONF" image_source enclave2
# vlan should be unchanged (not passed this time)
assert_conf_value "$CONF" vlan 100

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Idempotent re-run (no file change)
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Test 3: Idempotent re-run ---"

ts_before=$(stat -c %Y "$CONF")
sleep 1

./aba cluster -n "$CLUSTER_DIR" --num-workers 5 --step cluster.conf >/dev/null 2>&1

ts_after=$(stat -c %Y "$CONF")

if [ "$ts_before" = "$ts_after" ]; then
	test_pass "cluster.conf timestamp unchanged (no-op)"
else
	test_fail "cluster.conf timestamp changed (expected no-op)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: New --image-source flag
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Test 4: --image-source flag ---"

./aba cluster -n "$CLUSTER_DIR" --image-source proxy --step cluster.conf >/dev/null 2>&1
assert_conf_value "$CONF" image_source proxy

./aba cluster -n "$CLUSTER_DIR" --image-source enclave3 --step cluster.conf >/dev/null 2>&1
assert_conf_value "$CONF" image_source enclave3

./aba cluster -n "$CLUSTER_DIR" --image-source mirror --step cluster.conf >/dev/null 2>&1
assert_conf_value "$CONF" image_source mirror

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: --distribution flag (aba.conf key written like --platform; okd = stable|candidate only)
# ─────────────────────────────────────────────────────────────────────────────
echo "--- Test 5: --distribution flag ---"

# No test may reach the real network: any curl a command starts is answered by a stub that fails and logs the URL
_DIST_BIN=$(mktemp -d)
cat > "$_DIST_BIN/curl" <<'EOS'
#!/usr/bin/bash
echo "$*" >> "$(dirname "$0")/curl.log"
exit 22
EOS
chmod +x "$_DIST_BIN/curl"
_OLD_PATH="$PATH"
export PATH="$_DIST_BIN:$PATH"

_reset_dist() {
	sed -i -E '/^(distribution|ocp_channel)=/d' aba.conf
	printf 'distribution=ocp\t\t# test\nocp_channel=stable\n' >> aba.conf
}
# run aba, store output in $_dist_out, return its rc via $_dist_rc
_run_aba() { _dist_rc=0; _dist_out=$(./aba "$@" </dev/null 2>&1) || _dist_rc=$?; }
_expect_fail() {   # <label> <message-fragment> <aba args...>
	local label="$1" frag="$2"; shift 2
	_run_aba "$@"
	if [ "$_dist_rc" -ne 0 ] && [[ "$_dist_out" == *"$frag"* ]]; then test_pass "$label"
	else test_fail "$label (rc=$_dist_rc, want non-zero with [$frag]): $_dist_out"; fi
}

_reset_dist
_run_aba --distribution okd
[ "$_dist_rc" -eq 0 ] && test_pass "--distribution okd accepted" || test_fail "--distribution okd rc=$_dist_rc: $_dist_out"
assert_conf_value aba.conf distribution okd
_run_aba --distribution ocp
[ "$_dist_rc" -eq 0 ] && test_pass "--distribution ocp accepted" || test_fail "--distribution ocp rc=$_dist_rc: $_dist_out"
assert_conf_value aba.conf distribution ocp

# key missing from an older aba.conf: the flag adds it
sed -i -E '/^distribution=/d' aba.conf
_run_aba --distribution okd
assert_conf_value aba.conf distribution okd

_reset_dist
_expect_fail "--distribution bogus rejected"          "invalid distribution" --distribution bogus
assert_conf_value aba.conf distribution ocp
_expect_fail "--distribution OKD (case) rejected"     "invalid distribution" --distribution OKD
_expect_fail "--distribution ok (prefix) rejected"    "invalid distribution" --distribution ok
_expect_fail "--distribution ocpx (suffix) rejected"  "invalid distribution" --distribution ocpx
_expect_fail "--distribution with no value rejected"  "missing argument"     --distribution
_expect_fail "--distribution followed by an option rejected" "missing argument" --distribution --channel stable
assert_conf_value aba.conf distribution ocp

# okd takes stable|candidate only (same invocation and from aba.conf)
_reset_dist
_run_aba --distribution okd --channel candidate
[ "$_dist_rc" -eq 0 ] && test_pass "--distribution okd --channel candidate accepted" || test_fail "okd+candidate rc=$_dist_rc: $_dist_out"
assert_conf_value aba.conf ocp_channel candidate
assert_conf_value aba.conf distribution okd
_run_aba --channel stable
assert_conf_value aba.conf ocp_channel stable
_expect_fail "okd + --channel fast rejected (aba.conf okd)" "fast" --channel fast
_expect_fail "okd + --channel eus rejected (aba.conf okd)"  "eus"  -c eus
assert_conf_value aba.conf ocp_channel stable
_reset_dist
_expect_fail "--distribution okd --channel fast rejected (same command line)" "fast" --distribution okd --channel fast
# OCP keeps all four channels
_reset_dist
_run_aba --distribution ocp --channel fast
[ "$_dist_rc" -eq 0 ] && test_pass "ocp + --channel fast still accepted" || test_fail "ocp+fast rc=$_dist_rc: $_dist_out"
assert_conf_value aba.conf ocp_channel fast
_run_aba -c eus
assert_conf_value aba.conf ocp_channel eus

# Option order does not matter for the distribution/channel pair: same message, never an invalid pair on disk
_reset_dist
_expect_fail "--channel fast --distribution okd rejected" "channel [fast] is not available for distribution [okd]" --channel fast --distribution okd
assert_conf_value aba.conf distribution ocp
_reset_dist
_expect_fail "--distribution okd --channel fast rejected" "channel [fast] is not available for distribution [okd]" --distribution okd --channel fast
_pair_ok() {   # the pair written to aba.conf is valid for its distribution
	local d c; d=$(grep -E '^distribution=' aba.conf | head -1 | sed -E 's/^distribution=([^[:space:]#]*).*/\1/'); c=$(grep -E '^ocp_channel=' aba.conf | head -1 | sed -E 's/^ocp_channel=([^[:space:]#]*).*/\1/')
	if [ "$d" = okd ]; then [[ "$c" =~ ^(stable|candidate)$ ]]; else [[ "$c" =~ ^(fast|stable|candidate|eus)$ ]]; fi
}
_pair_ok && test_pass "no invalid pair on disk after '--distribution okd --channel fast'" || test_fail "invalid pair on disk: $(grep -E '^(distribution|ocp_channel)=' aba.conf | tr '\n' ' ')"
_reset_dist; _run_aba -c fast --distribution okd; _o1="$_dist_rc|$(printf '%s' "$_dist_out" | grep -c 'channel \[fast\] is not available')"
_reset_dist; _run_aba --distribution okd -c fast;  _o2="$_dist_rc|$(printf '%s' "$_dist_out" | grep -c 'channel \[fast\] is not available')"
[ "$_o1" = "$_o2" ] && [ "${_o1%%|*}" != 0 ] && test_pass "short options behave the same in both orders ($_o1)" || test_fail "short options differ by order: [$_o1] vs [$_o2]"
_reset_dist; _run_aba --channel eus --distribution okd; _o1="$_dist_rc|$_dist_out"
_reset_dist; _run_aba --distribution okd --channel eus; _o2="$_dist_rc|$_dist_out"
[ "$_o1" = "$_o2" ] && [ "${_o1%%|*}" != 0 ] && test_pass "eus: identical rc and message in both orders" || test_fail "eus differs by order: [$_o1] vs [$_o2]"
# channel aliases (-c f / -c e) are mapped before the check: nothing is written when the pair is invalid
for _al in "f fast" "e eus"; do
	set -- $_al
	_reset_dist
	_expect_fail "--distribution okd -c $1 rejected" "channel [$2] is not available for distribution [okd]" --distribution okd -c $1
	assert_conf_value aba.conf distribution ocp
	_reset_dist
	_expect_fail "-c $1 --distribution okd rejected" "channel [$2] is not available for distribution [okd]" -c $1 --distribution okd
	assert_conf_value aba.conf distribution ocp
done
# every --distribution on the line is checked against the channel in effect
_reset_dist
_expect_fail "--distribution okd --channel fast --distribution ocp: the first one is refused" "channel [fast] is not available for distribution [okd]" --distribution okd --channel fast --distribution ocp
# a conf whose channel is OCP-only is not turned into an okd conf by --distribution alone
_reset_dist; sed -i -E 's/^ocp_channel=.*/ocp_channel=fast/' aba.conf
_expect_fail "--distribution okd with ocp_channel=fast in aba.conf rejected" "channel [fast] is not available for distribution [okd]" --distribution okd
assert_conf_value aba.conf distribution ocp
# ... unless the same command line sets a valid channel (either order)
_reset_dist; sed -i -E 's/^ocp_channel=.*/ocp_channel=fast/' aba.conf
_run_aba --distribution okd --channel stable
[ "$_dist_rc" -eq 0 ] && test_pass "--distribution okd --channel stable fixes a fast conf" || test_fail "okd+stable on a fast conf rc=$_dist_rc: $_dist_out"
assert_conf_value aba.conf distribution okd
assert_conf_value aba.conf ocp_channel stable
_reset_dist; sed -i -E 's/^ocp_channel=.*/ocp_channel=fast/' aba.conf
_run_aba --channel stable --distribution okd
[ "$_dist_rc" -eq 0 ] && test_pass "--channel stable --distribution okd fixes a fast conf" || test_fail "stable+okd on a fast conf rc=$_dist_rc: $_dist_out"
assert_conf_value aba.conf distribution okd
assert_conf_value aba.conf ocp_channel stable
_reset_dist; sed -i -E 's/^ocp_channel=.*/ocp_channel=eus/' aba.conf
_run_aba --distribution okd -c c
[ "$_dist_rc" -eq 0 ] && test_pass "--distribution okd -c c fixes an eus conf" || test_fail "okd+c on an eus conf rc=$_dist_rc: $_dist_out"
assert_conf_value aba.conf ocp_channel candidate
# an unknown channel value keeps its own message (not the distribution one)
_reset_dist
_expect_fail "--distribution okd --channel bogus keeps the channel message" "wrong value [bogus]" --distribution okd --channel bogus
_expect_fail "--channel bogus --distribution okd keeps the channel message" "wrong value [bogus]" --channel bogus --distribution okd
# switching back to ocp is never blocked by the channel
_reset_dist; sed -i -E 's/^ocp_channel=.*/ocp_channel=fast/' aba.conf
_run_aba --distribution ocp
[ "$_dist_rc" -eq 0 ] && test_pass "--distribution ocp keeps a fast conf" || test_fail "ocp on a fast conf rc=$_dist_rc: $_dist_out"
assert_conf_value aba.conf ocp_channel fast
# Real OKD data behind a second stub: it answers the two OKD lookups (exact query forms only) from the shipped
# fixtures and fails everything else. The version is looked up, verified and written to aba.conf; the CLI
# downloads that follow are not what is tested here (they fail on this stub).
_OKD_BIN=$(mktemp -d)
cat > "$_OKD_BIN/curl" <<'EOS'
#!/usr/bin/bash
url=""; out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; http*) url="$1"; shift;; *) shift;; esac; done
echo "$url" >> "$(dirname "$0")/curl.log"
f=""
case "$url" in
	https://api.github.com/repos/okd-project/okd/releases\?per_page=100\&page=[0-9]) f="$OKD_FX/releases_p${url##*page=}.json"; [ -f "$f" ] || f="$(dirname "$0")/empty-list.json" ;;
	https://updates.okd.io/api/updates/graph\?channel=*\&arch=amd64)
		c="${url#*channel=}"; c="${c%%&*}"; f="$OKD_FX/graph_$c.json"; [ -f "$f" ] || f="$OKD_FX/graph_candidate-4.22.json" ;;
esac
[ -n "$f" ] && [ -f "$f" ] || exit 22
if [ -n "$out" ]; then cp "$f" "$out"; else cat "$f"; fi
EOS
chmod +x "$_OKD_BIN/curl"; printf '[]\n' > "$_OKD_BIN/empty-list.json"
export OKD_FX="$PWD/test/func/fixtures/okd-real"
_ver_before=$(grep -E '^ocp_version=' aba.conf | head -1)   # restored below: the CLI downloads that follow a stored version must not run on the first stub
_run_okd() { local P="$PATH"; PATH="$_OKD_BIN:$PATH"; _run_aba "$@"; PATH="$P"; }
_ok_version() {   # <label> <expected ocp_version> <aba args...>
	local label="$1" want="$2"; shift 2
	_reset_dist
	_run_okd "$@"
	if [ "$_dist_rc" -eq 0 ] && grep -q "^ocp_version=$want\b" aba.conf; then test_pass "$label"
	else test_fail "$label (rc=$_dist_rc, want ocp_version=$want, got $(grep -E '^ocp_version=' aba.conf | head -1)): $_dist_out"; fi
}
_ok_version "okd candidate: --version latest = the highest ec build of the head minor" 5.1.0-okd-scos.ec.2 --distribution okd --channel candidate --version latest
assert_conf_value aba.conf ocp_channel candidate
assert_conf_value aba.conf distribution okd
[[ "$_dist_out" == *"Pre-release"* ]] && test_pass "okd candidate ec build: the pre-release warning stays" || test_fail "no pre-release warning for an ec build: $_dist_out"
_ok_version "okd candidate: an explicit ec build" 5.0.0-okd-scos.ec.9 --distribution okd --channel candidate --version 5.0.0-okd-scos.ec.9
_ok_version "okd candidate: --version previous (options in the opposite order)" 5.0.0-okd-scos.ec.10 --version previous --channel candidate --distribution okd
_ok_version "okd candidate: channel alias given after the version (-c c)" 5.1.0-okd-scos.ec.2 --version latest -c c --distribution okd
_ok_version "okd candidate: an explicit ec build, the channel alias comes after it (-c c)" 5.1.0-okd-scos.ec.2 --version 5.1.0-okd-scos.ec.2 -c c --distribution okd
_ok_version "okd stable: channel alias given after the version (-c s)" 5.0.0-okd-scos.5 --version latest -c s --distribution okd
_ok_version "okd stable: --version latest is a GA build" 5.0.0-okd-scos.5 --distribution okd --channel stable --version latest
[[ "$_dist_out" != *"Pre-release"* ]] && test_pass "okd stable GA build: no pre-release warning" || test_fail "pre-release warning for a GA build: $_dist_out"
_ok_version "okd stable: a GA build the graph does not list (GitHub page 2)" 4.19.0-okd-scos.9 --distribution okd --version 4.19.0-okd-scos.9
_ok_version "okd: --version <okd tag> --distribution okd (version first)" 4.21.0-okd-scos.11 --version 4.21.0-okd-scos.11 --distribution okd
assert_conf_value aba.conf distribution okd
_reset_dist
_run_okd --distribution okd --channel candidate --version 5.0.0-okd-scos.5
[ "$_dist_rc" -ne 0 ] && [[ "$_dist_out" == *"not found in 'candidate' channel"* ]] && test_pass "okd candidate: a GA build is not a candidate build" || test_fail "GA build on candidate (rc=$_dist_rc): $_dist_out"
_reset_dist
_run_okd --distribution okd --channel candidate --version older
[ "$_dist_rc" -ne 0 ] && [[ "$_dist_out" == *"failed to look up the older version for channel [candidate]"* ]] && test_pass "okd candidate: --version older fails where candidate-4.22 lists nothing" || test_fail "older on candidate (rc=$_dist_rc): $_dist_out"
_reset_dist
_run_okd --distribution okd --channel stable --version 5.1.0-okd-scos.ec.2
[ "$_dist_rc" -ne 0 ] && [[ "$_dist_out" == *"incorrect version format"* && "$_dist_out" == *"candidate"* ]] && test_pass "okd stable: an ec build is refused with the channel hint" || test_fail "ec build on stable (rc=$_dist_rc): $_dist_out"
# the requests that went out: the exact query forms, nothing to the OCP graph
_bad=$(grep -E '^https://(api\.github\.com|updates\.okd\.io)/' "$_OKD_BIN/curl.log" | grep -v -E '^https://api\.github\.com/repos/okd-project/okd/releases\?per_page=100&page=[0-9]$|^https://updates\.okd\.io/api/updates/graph\?channel=(stable|candidate)-[0-9]+\.[0-9]+&arch=amd64$' | wc -l)
[ "$_bad" -eq 0 ] && test_pass "okd lookups use only per_page=100&page=N and channel=<stable|candidate>-X.Y&arch=amd64" || test_fail "unexpected OKD query strings: $(grep -E '^https://(api\.github\.com|updates\.okd\.io)/' "$_OKD_BIN/curl.log" | sort -u | head -5 | tr '\n' ' ')"
_n=$(grep -c 'candidate-5.1&arch=amd64' "$_OKD_BIN/curl.log" || true)
[ "$_n" -ge 1 ] && test_pass "okd candidate lookups ask the candidate-5.1 graph" || test_fail "candidate-5.1 graph never requested"
_n=$(grep -c '^https://api.openshift.com/' "$_OKD_BIN/curl.log" || true)
[ "$_n" -eq 0 ] && test_pass "okd runs never ask the OCP update graph" || test_fail "OCP update graph requested $_n times"
# a channel that is neither stable nor candidate in aba.conf is not silently read as stable
_reset_dist; sed -i -E 's/^ocp_channel=.*/ocp_channel=bogus/' aba.conf
_run_okd --distribution okd --version latest
[ "$_dist_rc" -ne 0 ] && [[ "$_dist_out" == *"bogus"* ]] && test_pass "okd: ocp_channel=bogus in aba.conf is refused, not read as stable" || test_fail "ocp_channel=bogus accepted (rc=$_dist_rc): $_dist_out"
rm -rf "$_OKD_BIN"
sed -i -E "s/^ocp_version=.*/$_ver_before/" aba.conf

# OKD pre-release builds (-okd-scos.ec.N) belong to the candidate channel only (format level, nothing is looked up)
_reset_dist
_expect_fail "okd + stable: an ec build is refused with the channel hint" "candidate" --distribution okd --version 5.1.0-okd-scos.ec.2
_expect_fail "okd + stable: ec build message says incorrect version format" "incorrect version format" --distribution okd --channel stable --version 5.1.0-okd-scos.ec.2
_reset_dist
_run_aba --version 4.21.0-okd-scos.11
[[ "$_dist_out" == *"incorrect version format"* ]] && test_pass "--version <okd tag> without --distribution okd: refused (ocp conf)" || test_fail "okd tag accepted on an ocp conf: $_dist_out"
assert_conf_value aba.conf distribution ocp
_expect_fail "ocp: an ec-style OKD build is still refused" "incorrect version format" --channel candidate --version 5.1.0-okd-scos.ec.2
_expect_fail "okd + candidate: malformed ec build refused" "incorrect version format" --distribution okd --channel candidate --version 5.1.0-okd-scos.ec.2x
_expect_fail "okd + candidate: OCP ec build refused" "incorrect version format" --distribution okd --channel candidate --version 5.1.0-ec.2

# Version syntax follows the distribution (rejections happen before any lookup)
_reset_dist
_expect_fail "okd rejects an OCP-style version"  "incorrect version format" --distribution okd --version 4.22.1
_expect_fail "okd rejects garbage"               "incorrect version format" --distribution okd --version foo
_expect_fail "ocp rejects an OKD-style version"  "incorrect version format" --distribution ocp --version 4.21.0-okd-scos.11
_expect_fail "ocp rejects a 5.x OKD-style version" "incorrect version format" --version 5.0.0-okd-scos.5
assert_conf_value aba.conf distribution ocp
# The error text follows the distribution: OKD shows the OKD form and no OCP example, OCP keeps its text
_reset_dist
_run_aba --distribution okd --version 4.22.1
[[ "$_dist_out" == *"incorrect version format '4.22.1' — expected X.Y.Z-okd-scos.N (X.Y.Z-okd-scos.ec.N on the candidate channel)"* ]] && test_pass "okd: version error shows the OKD form" || test_fail "okd version error text: $_dist_out"
[[ "$_dist_out" != *"4.22.0"* && "$_dist_out" != *"5.0.0-ec.2"* && "$_dist_out" != *"X.Y.Z-suffix.N"* ]] && test_pass "okd: version error shows no OCP example" || test_fail "OCP example in the okd version error: $_dist_out"
_reset_dist
_run_aba --distribution okd --version 9.9
[[ "$_dist_out" == *"incorrect version format '9.9' — expected X.Y.Z-okd-scos.N"* && "$_dist_out" != *"5.0.0-ec.2"* ]] && test_pass "okd: version error after a failed X.Y lookup shows the OKD form" || test_fail "okd X.Y lookup error text: $_dist_out"
_reset_dist
_run_aba --distribution ocp --version foo
[[ "$_dist_out" == *"incorrect version format 'foo' — expected X.Y.Z or X.Y.Z-suffix.N (e.g. 4.22.0, 5.0.0-ec.2)"* ]] && test_pass "ocp: version error text is unchanged" || test_fail "ocp version error text: $_dist_out"
_reset_dist
_run_aba --distribution ocp --version 9.9
[[ "$_dist_out" == *"incorrect version format '9.9' — expected X.Y.Z or X.Y.Z-suffix.N (e.g. 4.22.0, 5.0.0-ec.2)"* ]] && test_pass "ocp: version error after a failed X.Y lookup is unchanged" || test_fail "ocp X.Y lookup error text: $_dist_out"

# OKD is not installed on VMware vSphere (platform vmw) nor on another architecture than x86_64: stop with a clear
# message, whichever order the options come in, and never leave an unsupported pair in aba.conf. OCP is not affected.
_set_plat() { sed -i -E "s/^platform=.*/platform=$1/" aba.conf; }
_plat_of() { grep -E '^platform=' aba.conf | head -1 | sed -E 's/^platform=([^[:space:]#]*).*/\1/'; }
_unsup_ok() {   # <label> <expected platform left in aba.conf> <expected distribution left> <aba args...>
	local label="$1" wplat="$2" wdist="$3"; shift 3
	_run_aba "$@"
	local gplat gdist; gplat=$(_plat_of); gdist=$(grep -E '^distribution=' aba.conf | head -1 | sed -E 's/^distribution=([^[:space:]#]*).*/\1/')
	if [ "$_dist_rc" -ne 0 ] && [[ "$_dist_out" == *"not supported for OKD"* ]] && [[ "$_dist_out" == *"vmw"* ]] && [ "$gplat" = "$wplat" ] && [ "$gdist" = "$wdist" ]; then test_pass "$label"
	else test_fail "$label (rc=$_dist_rc, platform=$gplat want $wplat, distribution=$gdist want $wdist): $_dist_out"; fi
}
_reset_dist; _set_plat bm
_unsup_ok "--distribution okd --platform vmw rejected" bm ocp --distribution okd --platform vmw
_reset_dist; _set_plat bm
_unsup_ok "--platform vmw --distribution okd rejected (opposite order)" bm ocp --platform vmw --distribution okd
_reset_dist; _set_plat bm
_unsup_ok "-p vmw --distribution okd rejected (short option)" bm ocp -p vmw --distribution okd
_reset_dist; _set_plat vmw
_unsup_ok "--distribution okd with platform=vmw in aba.conf rejected" vmw ocp --distribution okd
_reset_dist; sed -i -E 's/^distribution=.*/distribution=okd/' aba.conf; sed -i -E 's/^ocp_channel=.*/ocp_channel=stable/' aba.conf; _set_plat bm
_unsup_ok "--platform vmw with distribution=okd in aba.conf rejected" bm okd --platform vmw
_reset_dist; _set_plat bm
_run_aba --distribution okd --platform kvm
[ "$_dist_rc" -eq 0 ] && [ "$(_plat_of)" = kvm ] && test_pass "--distribution okd --platform kvm accepted" || test_fail "okd + kvm refused (rc=$_dist_rc): $_dist_out"
_reset_dist; _set_plat bm
_run_aba --platform bm --distribution okd
[ "$_dist_rc" -eq 0 ] && test_pass "--platform bm --distribution okd accepted" || test_fail "okd + bm refused (rc=$_dist_rc): $_dist_out"
_reset_dist; _set_plat bm
_run_aba --distribution ocp --platform vmw
[ "$_dist_rc" -eq 0 ] && [ "$(_plat_of)" = vmw ] && test_pass "ocp + vmw is unchanged: accepted" || test_fail "ocp + vmw refused (rc=$_dist_rc): $_dist_out"
_reset_dist; _set_plat vmw
_run_aba --distribution ocp
[ "$_dist_rc" -eq 0 ] && test_pass "--distribution ocp with platform=vmw accepted" || test_fail "ocp on a vmw conf refused (rc=$_dist_rc): $_dist_out"
# another architecture (uname reports aarch64 here)
mkdir -p "$_DIST_BIN/arm"; printf '#!/usr/bin/bash\n[ "$1" = "-m" ] && { echo aarch64; exit 0; }\nexec /usr/bin/uname "$@"\n' > "$_DIST_BIN/arm/uname"; chmod +x "$_DIST_BIN/arm/uname"
_run_arm() { local P="$PATH"; PATH="$_DIST_BIN/arm:$PATH"; _run_aba "$@"; PATH="$P"; }
_reset_dist; _set_plat bm
_run_arm --distribution okd
if [ "$_dist_rc" -ne 0 ] && [[ "$_dist_out" == *"not supported for OKD"* ]] && [[ "$_dist_out" == *"arm64"* ]] && ! grep -q '^distribution=okd' aba.conf; then test_pass "--distribution okd on arm64 rejected, aba.conf unchanged"
else test_fail "okd on arm64 (rc=$_dist_rc): $_dist_out"; fi
_reset_dist; _set_plat bm
_run_arm --distribution ocp
[ "$_dist_rc" -eq 0 ] && test_pass "--distribution ocp on arm64 accepted" || test_fail "ocp on arm64 refused (rc=$_dist_rc): $_dist_out"
_reset_dist; _set_plat bm

# The suite stayed offline. The CLI downloads that aba starts in the background once a version is stored (they
# fetch the tarballs of an OKD build from the OCP mirror today and are not part of this test) are left out.
_dl='/clients/ocp/[0-9]+\.[0-9]+\.[0-9]+-okd-scos\.(ec\.)?[0-9]+/'
# (platform vmw on an OCP conf starts the govc download the same way, also left out)
_dl="$_dl|github\.com/vmware/govmomi/"
# (the X.Y lookups of 9.x that the version error tests ask for are refused by the stub, they are meant to fail)
_dl="$_dl|[-/=]9\.[0-9]+([^0-9]|$)"
grep -v -E "$_dl" "$_DIST_BIN/curl.log" > "$_DIST_BIN/curl.rest" 2>/dev/null || true
if [ -s "$_DIST_BIN/curl.rest" ]; then test_fail "no network attempted by Test 5 (curl was started: $(head -3 "$_DIST_BIN/curl.rest" | tr '\n' ' '))"
else test_pass "no network attempted by Test 5"; fi
export PATH="$_OLD_PATH"
rm -rf "$_DIST_BIN"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Results: $pass passed, $fail failed ==="

[ "$fail" -gt 0 ] && exit 1
exit 0
