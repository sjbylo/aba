#!/bin/bash
# Test progress events for all workflows
#
# Verifies:
#   1. progress-plan.sh emits correct PLANs for each workflow
#   2. Every PLAN ID has a matching START and DONE in the execution scripts
#   3. aba_progress function works with/without FIFO

cd "$(dirname "$0")/../.." || exit 1

source scripts/include_all.sh skip

PASS=0
FAIL=0

pass() {
	echo -e "\033[32m✓ $1\033[0m"
	PASS=$((PASS + 1))
}

fail() {
	echo -e "\033[31m✗ $1\033[0m"
	FAIL=$((FAIL + 1))
}

# ── Function tests ──

test_aba_progress_function() {
	local fifo="/tmp/test-progress-fifo.$$"
	rm -f "$fifo"
	mkfifo "$fifo"

	export ABA_PROGRESS_FIFO="$fifo"
	aba_progress "PLAN|test|Test step" &
	local line
	read -t 2 line < "$fifo"
	unset ABA_PROGRESS_FIFO

	rm -f "$fifo"

	if [ "$line" = "PLAN|test|Test step" ]; then
		pass "aba_progress writes to FIFO"
	else
		fail "aba_progress: expected 'PLAN|test|Test step', got '$line'"
	fi
}

test_aba_progress_noop() {
	unset ABA_PROGRESS_FIFO
	aba_progress "PLAN|test|Test step" 2>/dev/null
	if [ $? -eq 0 ]; then
		pass "aba_progress is no-op without FIFO"
	else
		fail "aba_progress should return 0 without FIFO"
	fi
}

# ── Plan emitter tests ──

# Run progress-plan.sh for a workflow and capture PLANs to a temp file.
# Returns the temp file path via stdout.
capture_plans() {
	local workflow="$1"
	local tmpfile="/tmp/test-plans-$workflow.$$"
	ABA_PROGRESS_FIFO="$tmpfile" bash scripts/progress-plan.sh "$workflow" 2>/dev/null
	echo "$tmpfile"
}

# Test that progress-plan.sh emits the expected number of PLANs for a workflow.
test_plan_count() {
	local workflow="$1" expected="$2"
	local tmpfile
	tmpfile=$(capture_plans "$workflow")
	local count
	count=$(grep -c '^PLAN|' "$tmpfile" 2>/dev/null) || count=0

	if [ "$count" -eq "$expected" ]; then
		pass "$workflow: $count PLANs"
	else
		fail "$workflow: expected $expected PLANs, got $count"
	fi

	rm -f "$tmpfile"
}

# Test that all PLANs are well-formed (PLAN|id|text)
test_plan_format() {
	local workflow="$1"
	local tmpfile
	tmpfile=$(capture_plans "$workflow")
	local bad_lines
	bad_lines=$(grep -v '^PLAN|[a-z0-9_]*|.' "$tmpfile" 2>/dev/null | wc -l)

	if [ "$bad_lines" -eq 0 ]; then
		pass "$workflow: all PLANs well-formed"
	else
		fail "$workflow: $bad_lines malformed PLAN lines"
		grep -v '^PLAN|[a-z_]*|.' "$tmpfile" 2>/dev/null | head -3
	fi

	rm -f "$tmpfile"
}

# Test that every PLAN ID has a matching START and DONE in the execution scripts.
# $1=workflow, $2=expected PLAN count, remaining args=scripts to search
test_plan_id_coverage() {
	local workflow="$1" expected="$2"
	shift 2
	local scripts=("$@")

	local tmpfile
	tmpfile=$(capture_plans "$workflow")
	local plan_ids
	plan_ids=$(grep '^PLAN|' "$tmpfile" | cut -d'|' -f2)

	local missing_start="" missing_done="" id
	for id in $plan_ids; do
		local found_start=false found_done=false s
		for s in "${scripts[@]}"; do
			grep -q "\"START|$id\"" "$s" 2>/dev/null && found_start=true
			grep -q "\"DONE|$id\"" "$s" 2>/dev/null && found_done=true
			# Also check variable-based IDs (e.g. $_rpms_id)
			grep -q 'START|\$_rpms_id' "$s" 2>/dev/null && [[ "$id" == rpms_ext || "$id" == rpms_int ]] && found_start=true
			grep -q 'DONE|\$_rpms_id' "$s" 2>/dev/null && [[ "$id" == rpms_ext || "$id" == rpms_int ]] && found_done=true
		done
		$found_start || missing_start="$missing_start $id"
		$found_done || missing_done="$missing_done $id"
	done

	local ok=true details=""
	if [ -n "$missing_start" ]; then
		details="${details}missing START:$missing_start; "
		ok=false
	fi
	if [ -n "$missing_done" ]; then
		details="${details}missing DONE:$missing_done; "
		ok=false
	fi

	if $ok; then
		pass "$workflow: all $expected PLAN IDs have START+DONE in scripts"
	else
		fail "$workflow: ${details%%; }"
	fi

	rm -f "$tmpfile"
}

# Test that progress-plan.sh rejects unknown workflows
test_plan_unknown() {
	local out
	out=$(ABA_PROGRESS_FIFO=/dev/null bash scripts/progress-plan.sh bogus-workflow 2>&1)
	local rc=$?
	if [ $rc -ne 0 ] && echo "$out" | grep -q "Unknown workflow"; then
		pass "Unknown workflow rejected"
	else
		fail "Unknown workflow should exit non-zero with error (rc=$rc)"
	fi
}

# Test install conditional: with .available, no PLANs should be emitted
test_plan_install_cached() {
	local tmpdir
	tmpdir=$(mktemp -d /tmp/test-cached-install.XXXXXX)
	touch "$tmpdir/.available"
	local tmpfile="$tmpdir/plans"
	( cd "$tmpdir" && ABA_PROGRESS_FIFO="$tmpfile" bash "$OLDPWD/scripts/progress-plan.sh" install 2>/dev/null )
	local count
	count=$(grep -c '^PLAN|' "$tmpfile" 2>/dev/null) || count=0

	if [ "$count" -eq 0 ]; then
		pass "install (cached): 0 PLANs when .available exists"
	else
		fail "install (cached): expected 0 PLANs, got $count"
	fi

	rm -rf "$tmpdir"
}

# ── Run tests ──

echo "=== Progress Event Tests ==="
echo ""

echo "--- Function tests ---"
test_aba_progress_function
test_aba_progress_noop
echo ""

echo "--- Plan emitter (progress-plan.sh) ---"
test_plan_unknown
test_plan_install_cached
echo ""

# Workflow: expected PLANs, execution scripts
echo "--- PLAN counts ---"
test_plan_count install   8
test_plan_count sync      8
test_plan_count save      6
test_plan_count load      5
test_plan_count uninstall 2
test_plan_count bundle    8
test_plan_count day2      8
test_plan_count day2-ntp  3
test_plan_count day2-osus 4
test_plan_count day2-virt 3
test_plan_count cluster-shutdown 4
test_plan_count cluster-startup  6
test_plan_count cluster-upgrade  4
echo ""

echo "--- PLAN format ---"
for wf in install sync save load uninstall bundle day2 day2-ntp day2-osus day2-virt cluster-shutdown cluster-startup cluster-upgrade; do
	test_plan_format "$wf"
done
echo ""

echo "--- PLAN ID ↔ START/DONE cross-check ---"
test_plan_id_coverage install 8 \
	scripts/install-rpms.sh scripts/reg-install.sh scripts/reg-install-docker.sh scripts/reg-install-quay.sh

test_plan_id_coverage sync 8 \
	scripts/install-rpms.sh scripts/reg-sync.sh scripts/download-catalogs-wait.sh

test_plan_id_coverage save 6 \
	scripts/install-rpms.sh scripts/reg-save.sh

test_plan_id_coverage load 5 \
	scripts/install-rpms.sh scripts/reg-load.sh

test_plan_id_coverage uninstall 2 \
	scripts/reg-uninstall.sh scripts/reg-uninstall-docker.sh scripts/reg-uninstall-quay.sh \
	scripts/reg-uninstall-omr.sh scripts/reg-uninstall-remote.sh

test_plan_id_coverage bundle 8 \
	scripts/make-bundle.sh scripts/install-rpms.sh scripts/reg-save.sh

test_plan_id_coverage day2 8 \
	scripts/day2.sh

test_plan_id_coverage day2-ntp 3 \
	scripts/day2-config-ntp.sh

test_plan_id_coverage day2-osus 4 \
	scripts/day2-config-osus.sh

test_plan_id_coverage day2-virt 3 \
	scripts/day2-config-virt.sh

test_plan_id_coverage cluster-shutdown 4 \
	scripts/cluster-graceful-shutdown.sh

test_plan_id_coverage cluster-startup 6 \
	scripts/cluster-startup.sh

test_plan_id_coverage cluster-upgrade 4 \
	scripts/cluster-upgrade.sh

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
