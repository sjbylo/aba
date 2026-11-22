#!/bin/bash
# Test: 'aba startup' on platform=bm with the API down asks to power on via the
# BMC when bmc.conf lists hosts, else shows the manual prompt.
# Offline: a recorder replaces scripts/bm-power.sh, a curl shim fakes the API,
# an oc shim fails the auth check so the script stops right after the power step.

cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf '  PASS  %s\n' "$*"; }
_fail() { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$*"; }

WORK=$(mktemp -d /tmp/aba-bm-startup.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
REPO=$WORK/repo
CL=$REPO/bm1
mkdir -p "$WORK/bin" "$WORK/home" "$CL/iso-agent-based/auth"
cp -a "$ROOT/scripts" "$REPO/scripts"

# The recorder logs its args and brings the fake API up.
printf '#!/bin/bash\necho "$*" >> %s\ntouch %s\n' "$WORK/power.log" "$WORK/api-up" > "$REPO/scripts/bm-power.sh"
printf '#!/bin/bash\nexit 0\n' > "$REPO/scripts/cli-install-all.sh"
# The API answers once api-up exists, or from call number $CURL_UP_AFTER.
cat > "$WORK/bin/curl" <<EOF
#!/bin/bash
n=\$(( \$(cat "$WORK/curl.count" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$WORK/curl.count"
[ -f "$WORK/api-up" ] && exit 0
[ -n "\${CURL_UP_AFTER:-}" ] && [ "\$n" -ge "\$CURL_UP_AFTER" ] && exit 0
exit 7
EOF
printf '#!/bin/bash\nexit 1\n' > "$WORK/bin/oc"
chmod +x "$REPO/scripts/bm-power.sh" "$REPO/scripts/cli-install-all.sh" "$WORK/bin/curl" "$WORK/bin/oc"
# After the shims: Git Bash ln -s may copy the directory.
ln -s "$REPO/scripts" "$CL/scripts"
export PATH="$WORK/bin:$PATH"
# aba.sh exports INFO_ABA=1 before it runs cluster-startup.sh.
export INFO_ABA=1

printf 'ask=true\n' > "$CL/aba.conf"
printf 'cluster_name=bm1\nbase_domain=example.com\n' > "$CL/cluster.conf"
printf 'platform=bm\n' > "$CL/state.sh"
printf 'clusters:\n- cluster:\n    server: https://api.bm1.example.com:6443\n' > "$CL/iso-agent-based/auth/kubeconfig"
printf 'bmc_host_master1=h-master1.example\nbmc_user_master1=admin\nbmc_password_master1=PLACEHOLDER\n' > "$CL/bmc.conf"
chmod 600 "$CL/bmc.conf"

BMC_Q="Power on bare-metal nodes via BMC"
MANUAL_Q="Power on the bare-metal servers for cluster"

# _startup <answer>: run cluster-startup.sh; sets out, rc, called.
_startup() {
	rm -f "$WORK/power.log" "$WORK/api-up" "$WORK/curl.count"
	out=$(cd "$CL" && printf '%s\n' "$1" | HOME=$WORK/home timeout 60 bash scripts/cluster-startup.sh 2>&1) && rc=0 || rc=$?
	called=$(cat "$WORK/power.log" 2>/dev/null)
}

echo
echo "=== Bare-metal startup BMC power-on tests (test-bm-startup-bmc.sh) ==="
echo

_startup y
[ "$called" = "On" ] && echo "$out" | grep -q "$BMC_Q" && ! echo "$out" | grep -q "$MANUAL_Q" \
	&& _pass "bmc hosts, yes: runs bm-power.sh On, one BMC question" \
	|| _fail "yes: rc=$rc called=[$called] out: $(echo "$out" | tail -5)"

_startup ""
[ "$called" = "On" ] \
	&& _pass "bmc hosts, empty answer: Yes is the default" \
	|| _fail "default: rc=$rc called=[$called] out: $(echo "$out" | tail -5)"

_startup n
[ "$rc" != 0 ] && [ -z "$called" ] && ! echo "$out" | grep -q "$MANUAL_Q" && echo "$out" | grep -q "re-run" \
	&& _pass "bmc hosts, no: exit non-zero, no power-on, no manual prompt" \
	|| _fail "no: rc=$rc called=[$called] out: $(echo "$out" | tail -5)"

ASK_OVERRIDE=1 CURL_UP_AFTER=2 _startup ""
unset ASK_OVERRIDE CURL_UP_AFTER
[ "$called" = "On" ] && echo "$out" | grep -q "$BMC_Q" && echo "$out" | grep -q '\[default: -y\]' \
	&& ! echo "$out" | grep -q "$MANUAL_Q" && ! echo "$out" | grep -q "not powering on" \
	&& echo "$out" | grep -q "Waiting for cluster API" \
	&& _pass "aba -y: answers yes, powers on, waits for the API" \
	|| _fail "aba -y: rc=$rc called=[$called] out: $(echo "$out" | tail -5)"

CURL_UP_AFTER=1 _startup y
[ -z "$called" ] && ! echo "$out" | grep -q "$BMC_Q" \
	&& _pass "API already up: no question, no power-on" \
	|| _fail "API up: rc=$rc called=[$called] out: $(echo "$out" | tail -5)"

mv "$CL/bmc.conf" "$CL/bmc.conf.bak"
_startup n
mv "$CL/bmc.conf.bak" "$CL/bmc.conf"
[ "$rc" != 0 ] && [ -z "$called" ] && echo "$out" | grep -q "$MANUAL_Q" && ! echo "$out" | grep -q "$BMC_Q" \
	&& _pass "no bmc.conf hosts: manual prompt, no power-on" \
	|| _fail "no hosts: rc=$rc called=[$called] out: $(echo "$out" | tail -5)"

# The flag itself, not only ASK_OVERRIDE. oc exits 1 after the power step.
printf '%s\n' '# Top level Makefile' > "$REPO/Makefile"
rm -f "$WORK/power.log" "$WORK/api-up" "$WORK/curl.count"
out=$(cd "$CL" && HOME=$WORK/home ABA_DO_NOT_UPDATE=1 timeout 60 bash "$REPO/scripts/aba.sh" -y startup </dev/null 2>&1) && rc=0 || rc=$?
called=$(cat "$WORK/power.log" 2>/dev/null)
[ "$called" = "On" ] && echo "$out" | grep -q '\[default: -y\]' && ! echo "$out" | grep -q "not powering on" \
	&& _pass "aba -y startup: the flag powers the node on" \
	|| _fail "aba -y startup: rc=$rc called=[$called] out: $(echo "$out" | tail -8)"

echo
echo "Results: $pass passed, $fail failed"
exit "$fail"
