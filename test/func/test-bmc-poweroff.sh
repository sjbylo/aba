#!/bin/bash
# Test: scripts/bm-poweroff.sh and the 'aba stop' / 'aba kill' dispatch on platform=bm.
# Offline: a curl shim on PATH answers from test/func/lib/bmc-redfish-stub.sh; no real BMC.
# A sleep shim makes the 120s PowerState poll instant.

cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf '  PASS  %s\n' "$*"; }
_fail() { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$*"; }

WORK=$(mktemp -d /tmp/aba-bmc-poweroff.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
CL=$WORK/cluster
mkdir -p "$WORK/bin" "$CL"
ln -s "$ROOT/scripts" "$CL/scripts"

# The shim records each ResetType it sends, so the test can check the order.
cat > "$WORK/bin/curl" <<EOF
#!/bin/bash
prev=
for a in "\$@"; do
	if [ "\$prev" = "--data-binary" ] && [ -f "\${a#@}" ]; then
		t=\$(jq -r '.ResetType // empty' "\${a#@}" 2>/dev/null)
		[ -n "\$t" ] && echo "\$t" >> "$WORK/resets.log"
	fi
	prev=\$a
done
source "$ROOT/test/func/lib/bmc-redfish-stub.sh"
_bmc_stub_curl "\$@"
rc=\$?
rm -f "\$_REDFISH_LAST_BODY"
exit \$rc
EOF
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/sleep"
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/make"
chmod +x "$WORK/bin/curl" "$WORK/bin/sleep" "$WORK/bin/make"
export PATH="$WORK/bin:$PATH"
export _STUB_CALL_LOG=$WORK/calls.log _STUB_POWER_FILE=$WORK/power
: > "$_STUB_CALL_LOG"

printf 'ask=false\n' > "$CL/aba.conf"
for n in master1 master2 worker1; do
	printf 'bmc_host_%s=h-%s.example\nbmc_user_%s=admin\nbmc_password_%s=PLACEHOLDER\nbmc_type_%s=redfish\nbmc_insecure_%s=true\n' \
		"$n" "$n" "$n" "$n" "$n" "$n"
done > "$CL/bmc.conf"
chmod 600 "$CL/bmc.conf"

# _run <ResetType>: run bm-poweroff.sh with every host On; sets out, rc, resets.
_run() {
	printf 'h-master1.example=On\nh-master2.example=On\nh-worker1.example=On\n' > "$_STUB_POWER_FILE"
	[ "${ALL_OFF:-}" ] && sed -i 's/=On$/=Off/' "$_STUB_POWER_FILE"
	: > "$WORK/resets.log"
	out=$(cd "$CL" && bash scripts/bm-poweroff.sh "$1" </dev/null 2>&1) && rc=0 || rc=$?
	resets=$(tr '\n' ' ' < "$WORK/resets.log")
}

echo
echo "=== BMC power-off tests (test-bmc-poweroff.sh) ==="
echo

_run GracefulShutdown
[ "$rc" = 0 ] && [ "$resets" = "GracefulShutdown GracefulShutdown GracefulShutdown " ] && echo "$out" | grep -q "powered off 3/3" \
	&& _pass "stop: GracefulShutdown on each node, waits for Off" \
	|| _fail "stop: rc=$rc resets=[$resets] out: $out"

_STUB_GRACEFUL_400=true; export _STUB_GRACEFUL_400
_run GracefulShutdown
unset _STUB_GRACEFUL_400
[ "$rc" = 0 ] && [ "$resets" = "GracefulShutdown ForceOff GracefulShutdown ForceOff GracefulShutdown ForceOff " ] \
	&& _pass "stop: GracefulShutdown HTTP 400 falls back to ForceOff" \
	|| _fail "stop 400: rc=$rc resets=[$resets] out: $out"

_run ForceOff
[ "$rc" = 0 ] && [ "$resets" = "ForceOff ForceOff ForceOff " ] \
	&& _pass "kill: ForceOff on each node" \
	|| _fail "kill: rc=$rc resets=[$resets] out: $out"

ALL_OFF=1 _run ForceOff
[ "$rc" = 0 ] && [ -z "$resets" ] && echo "$out" | grep -q "powered off 3/3" \
	&& _pass "already Off: no Reset POST, counts as success" \
	|| _fail "already Off: rc=$rc resets=[$resets] out: $out"

_STUB_STUCK_HOST=h-worker1.example; export _STUB_STUCK_HOST
_run ForceOff
unset _STUB_STUCK_HOST
[ "$rc" = 1 ] && echo "$out" | grep -q "failed: worker1" && echo "$out" | grep -q "never reached Off" \
	&& _pass "stuck On: exit 1 and names the node" \
	|| _fail "stuck: rc=$rc out: $out"

export _STUB_POST_RESET_401=true _STUB_STATE_FILE=$WORK/state
: > "$_STUB_STATE_FILE"
_run ForceOff
unset _STUB_POST_RESET_401 _STUB_STATE_FILE
[ "$rc" = 0 ] && [ "$resets" = "ForceOff ForceOff ForceOff " ] \
	&& _pass "401 after Reset: log in again, no second Reset" \
	|| _fail "401 after Reset: rc=$rc resets=[$resets] out: $out"

grep -qE 'EjectMedia|^PATCH ' "$_STUB_CALL_LOG" \
	&& _fail "power-off sent EjectMedia or a boot PATCH" \
	|| _pass "no media eject and no boot override PATCH"

mv "$CL/bmc.conf" "$CL/bmc.conf.bak"
_run ForceOff
mv "$CL/bmc.conf.bak" "$CL/bmc.conf"
[ "$rc" != 0 ] && echo "$out" | grep -q "BMC UI" \
	&& _pass "no bmc.conf hosts: abort, points to the BMC UI" \
	|| _fail "no hosts: rc=$rc out: $out"

# aba dispatch: a sandbox repo with platform=bm and a recorder in place of bm-poweroff.sh.
REPO=$WORK/repo
mkdir -p "$REPO/bm1" "$WORK/home"
cp -a "$ROOT/scripts" "$REPO/scripts"
cp -f "$ROOT/Makefile" "$ROOT/VERSION" "$REPO/"
printf '#!/bin/bash\necho "$*" > %s\n' "$WORK/dispatch.log" > "$REPO/scripts/bm-poweroff.sh"
printf 'platform=bm\nask=false\nocp_version=4.19.0\n' > "$REPO/aba.conf"
printf 'cluster_name=bm1\nbase_domain=example.com\n' > "$REPO/bm1/cluster.conf"

# _aba <args>: run aba in the sandbox cluster dir; sets out, rc, called.
_aba() {
	rm -f "$WORK/dispatch.log"
	out=$(cd "$REPO/bm1" && HOME=$WORK/home ABA_DO_NOT_UPDATE=1 bash "$REPO/scripts/aba.sh" "$@" </dev/null 2>&1) && rc=0 || rc=$?
	called=$(cat "$WORK/dispatch.log" 2>/dev/null)
}

_aba stop
[ "$rc" = 0 ] && [ "$called" = "GracefulShutdown" ] && _pass "aba stop on bm runs bm-poweroff.sh GracefulShutdown" \
	|| _fail "aba stop: rc=$rc called=[$called] out: $(echo "$out" | tail -5)"
_aba kill
[ "$rc" = 0 ] && [ "$called" = "ForceOff" ] && _pass "aba kill on bm runs bm-poweroff.sh ForceOff" \
	|| _fail "aba kill: rc=$rc called=[$called] out: $(echo "$out" | tail -5)"
_aba stop --workers
[ "$rc" != 0 ] && [ -z "$called" ] && echo "$out" | grep -q "not supported on bare metal" \
	&& _pass "aba stop --workers on bm aborts" \
	|| _fail "aba stop --workers: rc=$rc called=[$called] out: $(echo "$out" | tail -5)"

echo
echo "Results: $pass passed, $fail failed"
exit "$fail"
