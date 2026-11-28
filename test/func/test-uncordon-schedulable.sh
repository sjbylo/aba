#!/bin/bash
# Test: uncordon is finished only when a fresh read shows the node is schedulable.
# Regression: oc adm uncordon exits 0 while spec.unschedulable and the taint remain.
# Tier: unit (oc is a stub)

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh 2>/dev/null

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== Uncordon re-read ==="

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
LOG=$TMP/oc.log
PHASE=$TMP/phase
READY=$TMP/ready
printf 'True\n' > "$READY"
aba_debug() { :; }
unset OC

oc() {
	printf '%s\n' "$*" >> "$LOG"
	case "$*" in
		*"adm uncordon"*)
			if [ "$(cat "$PHASE")" = flip ]; then
				printf 'clean\n' > "$PHASE"
			fi
			return 0
			;;
		*"get nodes"*)
			case "$(cat "$PHASE")" in
				fail) return 1 ;;
				empty) return 0 ;;
			esac
			if [[ "$*" == *"Ready"* ]]; then
				cat "$READY"
				return 0
			fi
			case "$(cat "$PHASE")" in
				clean)
					printf 'master1||\nmaster2||\n'
					;;
				taint)
					printf 'master1||yes\n'
					;;
				spec)
					printf 'master1|true|\n'
					;;
				*)
					printf 'master1|true|yes\nmaster2|true|yes\n'
					;;
			esac
			return 0
			;;
	esac
	return 0
}

_uncordon_count() {
	grep -c 'adm uncordon' "$LOG" 2>/dev/null || true
}

_reset() {
	: > "$LOG"
	printf '%s\n' "$1" > "$PHASE"
}

echo "Test 1: startup and rescue both use the shared re-read"
ok=1
grep -q 'cluster_uncordon_unschedulable' scripts/cluster-startup.sh || ok=
grep -q 'cluster_all_nodes_ready' scripts/cluster-startup.sh || ok=
grep -q 'cluster_uncordon_unschedulable' scripts/cluster-rescue.sh || ok=
grep -q 'Nodes are still unschedulable after 10 minutes.' scripts/cluster-startup.sh || ok=
grep -q 'Nodes are still unschedulable.' scripts/cluster-rescue.sh || ok=
if grep -q 'adm uncordon ${node}' scripts/cluster-startup.sh scripts/cluster-rescue.sh; then
	ok=
fi
if [ "$ok" ]; then
	_pass "both commands re-read; a failed uncordon aborts"
else
	_fail "startup or rescue still trusts oc adm uncordon"
fi

echo "Test 2: a failed node read is not success"
_reset fail
if ! cluster_nodes_schedulable; then
	_pass "schedulable read failed"
else
	_fail "failed oc get nodes returned success"
fi
if ! cluster_uncordon_unschedulable; then
	_pass "uncordon read failed"
else
	_fail "uncordon treated a failed read as done"
fi

echo "Test 3: no nodes is not success"
_reset empty
if ! cluster_nodes_schedulable; then
	_pass "empty node list"
else
	_fail "empty node list returned success"
fi

echo "Test 4: oc exits 0 and the cordon stays"
_reset stuck
if ! cluster_uncordon_unschedulable; then
	_pass "still unschedulable"
else
	_fail "uncordon returned success while the cordon stayed"
fi
if [ "$(_uncordon_count)" -ge 1 ]; then
	_pass "uncordon was attempted"
else
	_fail "uncordon was not attempted"
fi

echo "Test 5: taint alone, and spec.unschedulable alone, stay a failure"
_reset taint
if ! cluster_uncordon_unschedulable; then
	_pass "leftover taint"
else
	_fail "taint-only node was treated as schedulable"
fi
_reset spec
if ! cluster_nodes_schedulable; then
	_pass "spec.unschedulable"
else
	_fail "spec.unschedulable was treated as schedulable"
fi

echo "Test 6: the re-read after a real uncordon succeeds"
_reset flip
if cluster_uncordon_unschedulable; then
	_pass "cordon cleared on the second read"
else
	_fail "uncordon did not clear on the second read: $(cat "$LOG")"
fi
if [ "$(_uncordon_count)" -eq 2 ]; then
	_pass "both cordoned nodes were uncordoned"
else
	_fail "uncordon count=$(_uncordon_count), want 2"
fi

echo "Test 7: already schedulable does not call uncordon"
_reset clean
if cluster_uncordon_unschedulable && [ "$(_uncordon_count)" -eq 0 ]; then
	_pass "no uncordon"
else
	_fail "clean nodes were uncordoned or the read failed"
fi

echo "Test 8: Ready=True with the cordon still there is not ready"
_reset stuck
printf 'True\n' > "$READY"
if ! cluster_all_nodes_ready; then
	_pass "Ready=True and unschedulable"
else
	_fail "Ready=True hid SchedulingDisabled"
fi

echo "Test 9: Ready=True and schedulable passes; one NotReady does not"
_reset clean
printf 'True\nTrue\n' > "$READY"
if cluster_all_nodes_ready; then
	_pass "all Ready and schedulable"
else
	_fail "clean Ready nodes were not ready"
fi
printf 'True\nFalse\n' > "$READY"
if ! cluster_all_nodes_ready; then
	_pass "one node NotReady"
else
	_fail "NotReady was treated as ready"
fi

echo
echo "Results: $pass passed, $fail failed"
exit "$fail"
