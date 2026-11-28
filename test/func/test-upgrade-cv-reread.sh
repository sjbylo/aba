#!/bin/bash
# Test: upgrade pre-flight re-reads ClusterVersion without parsing oc text
# Regression: Upgradeable=False right after day2 clears on the next read.
# A condition that stays False, including AdminAckRequired, still aborts.
# Tier: unit (no network; oc is a stub)

cd "$(dirname "$0")/../.." || exit 1

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== Upgrade ClusterVersion re-read ==="

if ! command -v jq >/dev/null 2>&1; then
	echo "jq is required"
	exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

_cv_json() {
	local status="$1" reason="$2" message="$3"
	jq -n --arg s "$status" --arg r "$reason" --arg m "$message" \
		'{status:{conditions:[{type:"Upgradeable",status:$s,reason:$r,message:$m}]}}'
}

# --- The wait must not be chosen by matching oc's message text ---
echo "Test 1: source does not branch on oc message phrases"
_phrase_hit=0
while IFS= read -r _line; do
	case "$_line" in
		*unable\ to\ handle\ the\ request*|*context\ deadline\ exceeded*|*connection\ refused*|*TLS\ handshake*)
			case "$_line" in
				*:[^#]*#*) ;;
				*) _phrase_hit=1; echo "    $_line" ;;
			esac
			;;
	esac
done < <(grep -nF -e 'unable to handle the request' -e 'context deadline exceeded' -e 'connection refused' -e 'TLS handshake' scripts/cluster-upgrade.sh || true)
if [ "$_phrase_hit" -eq 0 ]; then
	_pass "phrase matches stay in comments"
else
	_fail "phrase match is in executable code"
fi

if grep -q 'too weak and can break' scripts/cluster-upgrade.sh \
	&& grep -q 'Do not decide this by reading oc output' scripts/cluster-upgrade.sh \
	&& grep -q 'every 15 seconds' scripts/cluster-upgrade.sh; then
	_pass "comment says not to read oc output, and to re-read every 15s"
else
	_fail "missing re-read comment"
fi

if grep -q 'local delay="${1:-15}"' scripts/cluster-upgrade.sh \
	&& grep -q 'local attempts="${2:-13}"' scripts/cluster-upgrade.sh \
	&& grep -q 'try_cmd -n "$attempts" -d "$delay" -m "ClusterVersion Upgradeable"' scripts/cluster-upgrade.sh \
	&& ! grep -q 'cluster_upgrade_wait_upgradeable' scripts/cluster-upgrade.sh; then
	_pass "wait is try_cmd every 15s, 13 attempts"
else
	_fail "wait is not try_cmd 15s x 13"
fi

# Extract the three helpers. Brace pairs inside ${var:-default} net to zero.
awk '
/^[[:space:]]*_cv_read_upgradeable\(\)/ { found=1; depth=0; n=0 }
found {
	line=$0
	for (i=1; i<=length(line); i++) {
		c = substr(line, i, 1)
		if (c == "{") depth++
		if (c == "}") depth--
	}
	print
	if (found && depth == 0 && line ~ /}/) {
		n++
		if (n == 3) exit
	}
}
' scripts/cluster-upgrade.sh > "$TMP/funcs.sh"

if grep -q '^[[:space:]]*cluster_upgrade_upgradeable_gate()' "$TMP/funcs.sh" \
	&& grep -q '^[[:space:]]*_cv_upgradeable_ready()' "$TMP/funcs.sh" \
	&& grep -q 'try_cmd' "$TMP/funcs.sh"; then
	_pass "extracted the upgradeable gate"
else
	_fail "failed to extract the upgradeable gate"
	echo ""
	echo "Results: $pass passed, $fail failed"
	exit "$fail"
fi

cat > "$TMP/harness.sh" << 'HARNESS'
#!/bin/bash
set -e
# Real try_cmd. Stub the log helpers afterwards so the retry text is plain.
. scripts/include_all.sh 2>/dev/null || true
trap - ERR
set -e
aba_info() { echo "INFO: $*"; }
aba_warn() { echo "WARN: $*"; }
aba_success() { echo "OK: $*"; }
aba_abort() { echo "ABORT: $*"; exit 1; }
opt_force="${OPT_FORCE:-}"
oc() {
	local n
	n=$(cat "$COUNT")
	n=$(( n + 1 ))
	echo "$n" > "$COUNT"
	if [ "${OC_FAIL:-}" = 1 ]; then
		echo "oc: connection refused" >&2
		return 1
	fi
	if [ -f "$SEQ/$n.json" ]; then
		cat "$SEQ/$n.json"
		return 0
	fi
	cat "$SEQ/last.json"
}
HARNESS
cat "$TMP/funcs.sh" >> "$TMP/harness.sh"
cat >> "$TMP/harness.sh" << 'TAIL'
cluster_upgrade_upgradeable_gate "$INTERVAL" "$MAX"
echo GATE_OK
TAIL
chmod +x "$TMP/harness.sh"

_run() {
	local seq="$1" interval="$2" max="$3" force="$4" oc_fail="${5:-}"
	echo 0 > "$TMP/count"
	RUN_OUT=$(SEQ="$seq" COUNT="$TMP/count" INTERVAL="$interval" MAX="$max" OPT_FORCE="$force" OC_FAIL="$oc_fail" bash "$TMP/harness.sh" 2>&1) && RUN_RC=0 || RUN_RC=$?
	RUN_CALLS=$(cat "$TMP/count")
}

# --- False with unrelated wording, then clear. Must not abort. ---
echo "Test 2: Upgradeable=False that clears is not an abort"
mkdir -p "$TMP/clear"
_cv_json False SomeOperatorDegraded "unrelated operator is sad" > "$TMP/clear/1.json"
cp "$TMP/clear/1.json" "$TMP/clear/2.json"
_cv_json True AsExpected "ok" > "$TMP/clear/3.json"
_run "$TMP/clear" 1 10 ""
if [ "$RUN_RC" -eq 0 ] && echo "$RUN_OUT" | grep -q 'GATE_OK' \
	&& echo "$RUN_OUT" | grep -q 'ClusterVersion Upgradeable' \
	&& ! echo "$RUN_OUT" | grep -q '^ABORT:' \
	&& [ "$RUN_CALLS" -ge 3 ]; then
	_pass "cleared on a later read (calls=$RUN_CALLS)"
else
	_fail "cleared condition still aborted (rc=$RUN_RC calls=$RUN_CALLS)"
	echo "$RUN_OUT"
fi

# --- AdminAckRequired stays False. Must abort after the re-reads. ---
echo "Test 3: AdminAckRequired still aborts"
mkdir -p "$TMP/ack"
_cv_json False AdminAckRequired "admin acknowledgment required" > "$TMP/ack/last.json"
_run "$TMP/ack" 1 2 ""
if [ "$RUN_RC" -eq 1 ] && echo "$RUN_OUT" | grep -q 'ABORT:' \
	&& echo "$RUN_OUT" | grep -q 'AdminAckRequired' \
	&& [ "$RUN_CALLS" -ge 2 ]; then
	_pass "AdminAckRequired aborted after re-read (calls=$RUN_CALLS)"
else
	_fail "AdminAckRequired did not abort (rc=$RUN_RC calls=$RUN_CALLS)"
	echo "$RUN_OUT"
fi

# --- The transport phrase is not a special case. It still aborts if it stays. ---
echo "Test 4: a transport phrase that stays False still aborts"
mkdir -p "$TMP/blip"
_cv_json False ConsoleCustomRouteSync_FailedDeleteCustomRoutes "the server is currently unable to handle the request" > "$TMP/blip/last.json"
_run "$TMP/blip" 1 2 ""
if [ "$RUN_RC" -eq 1 ] && echo "$RUN_OUT" | grep -q 'ABORT:' \
	&& echo "$RUN_OUT" | grep -q 'unable to handle the request' \
	&& [ "$RUN_CALLS" -ge 2 ]; then
	_pass "staying False aborts even when the message looks like an API blip"
else
	_fail "transport phrase was treated as success (rc=$RUN_RC calls=$RUN_CALLS)"
	echo "$RUN_OUT"
fi

# --- --force does not wait ---
echo "Test 5: --force proceeds on the first read"
_run "$TMP/ack" 1 30 "--force"
if [ "$RUN_RC" -eq 0 ] && echo "$RUN_OUT" | grep -q 'GATE_OK' \
	&& echo "$RUN_OUT" | grep -q -- '--force specified' \
	&& ! echo "$RUN_OUT" | grep -q 'retrying in' \
	&& [ "$RUN_CALLS" -eq 1 ]; then
	_pass "--force did not wait"
else
	_fail "--force waited or aborted (rc=$RUN_RC calls=$RUN_CALLS)"
	echo "$RUN_OUT"
fi

# --- Already upgradeable ---
echo "Test 6: Upgradeable=True does not warn"
mkdir -p "$TMP/ok"
_cv_json True AsExpected "ok" > "$TMP/ok/last.json"
_run "$TMP/ok" 1 10 ""
if [ "$RUN_RC" -eq 0 ] && echo "$RUN_OUT" | grep -q 'GATE_OK' \
	&& ! echo "$RUN_OUT" | grep -q 'WARN:' \
	&& [ "$RUN_CALLS" -eq 1 ]; then
	_pass "already upgradeable"
else
	_fail "already upgradeable took the wait path (rc=$RUN_RC calls=$RUN_CALLS)"
	echo "$RUN_OUT"
fi

# --- oc itself failing is an API blip: try_cmd retries, then does not abort ---
echo "Test 7: unreadable ClusterVersion is retried and does not abort"
_run "$TMP/ok" 0 3 "" 1
if [ "$RUN_RC" -eq 0 ] && echo "$RUN_OUT" | grep -q 'GATE_OK' \
	&& ! echo "$RUN_OUT" | grep -q '^ABORT:' \
	&& [ "$RUN_CALLS" -ge 2 ]; then
	_pass "oc failure retried then continued (calls=$RUN_CALLS)"
else
	_fail "oc failure aborted (rc=$RUN_RC calls=$RUN_CALLS)"
	echo "$RUN_OUT"
fi

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
