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
	shift
	local tmpfile
	tmpfile=$(mktemp "/tmp/test-plans-${workflow}.XXXXXX")
	ABA_PROGRESS_FIFO="$tmpfile" bash scripts/progress-plan.sh "$workflow" "$@" 2>/dev/null
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
	# install also emits START|reg_prep so Preparation is in progress immediately
	bad_lines=$(grep -Ev '^(PLAN\|[a-z0-9_]+\|.+|START\|[a-z0-9_]+)$' "$tmpfile" 2>/dev/null | wc -l)

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
test_plan_count install   9
test_plan_count sync      8
test_plan_count save      6
test_plan_count load      5
test_plan_count uninstall 2
test_plan_count bundle    9
test_plan_count day2      8
test_plan_count day2-ntp  3
test_plan_count day2-osus 4
test_plan_count day2-virt 3
test_plan_count cluster-shutdown 4
test_plan_count cluster-startup  6
test_plan_count cluster-upgrade  3
test_plan_count cluster-install  6
echo ""

echo "--- PLAN format ---"
for wf in install sync save load uninstall bundle day2 day2-ntp day2-osus day2-virt cluster-shutdown cluster-startup cluster-upgrade cluster-install; do
	test_plan_format "$wf"
done
echo ""

echo "--- PLAN ID ↔ START/DONE cross-check ---"
test_plan_id_coverage install 9 \
	scripts/progress-plan.sh scripts/install-rpms.sh scripts/reg-install.sh \
	scripts/reg-install-docker.sh scripts/reg-install-quay.sh scripts/reg-install-omr.sh \
	scripts/reg-install-docker-remote.sh scripts/reg-install-quay-remote.sh scripts/reg-install-omr-remote.sh

test_plan_id_coverage sync 8 \
	scripts/install-rpms.sh scripts/reg-sync.sh scripts/download-catalogs-wait.sh

test_plan_id_coverage save 6 \
	scripts/install-rpms.sh scripts/reg-save.sh

test_plan_id_coverage load 5 \
	scripts/install-rpms.sh scripts/reg-load.sh

test_plan_id_coverage uninstall 2 \
	scripts/reg-uninstall.sh scripts/reg-uninstall-docker.sh scripts/reg-uninstall-quay.sh \
	scripts/reg-uninstall-omr.sh scripts/reg-uninstall-remote.sh

test_plan_id_coverage bundle 9 \
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

test_plan_id_coverage cluster-upgrade 3 \
	scripts/cluster-upgrade.sh

test_plan_id_coverage cluster-install 6 \
	scripts/bm-ask-edit.sh scripts/bm-ask-boot.sh scripts/monitor-install.sh \
	scripts/resolve-vips.sh scripts/infra-dns.sh scripts/create-install-config.sh \
	scripts/create-agent-config.sh scripts/preflight-check.sh \
	scripts/generate-image.sh \
	scripts/vmw-kill.sh scripts/vmw-refresh.sh \
	scripts/kvm-kill.sh scripts/kvm-refresh.sh \
	templates/Makefile.cluster

echo ""

# ── Child plan objects: day2 and save own their lines ──
echo "--- Composed plans (parent asks the child) ---"

_plan_lines() {
	grep '^PLAN|' "$1" | tr -d '\r'
}

# Run `script plan` away from the repo. stdout is only the plan.
# A set FIFO must stay absent: the child does not submit its own plan.
_child_plan() {
	local script="$1" label="$2" sentinel out rc
	sentinel=$(mktemp /tmp/plan-sentinel.XXXXXX)
	rm -f "$sentinel"
	out=$(cd /tmp && ABA_PROGRESS_FIFO="$sentinel" bash "$root/scripts/$script" plan)
	rc=$?
	if [ "$rc" -eq 0 ] && [ -n "$out" ] && [ ! -e "$sentinel" ]; then
		pass "$label plan prints steps and does not touch the FIFO"
	else
		local fifo_state="no"
		[ -e "$sentinel" ] && fifo_state="yes"
		fail "$label plan rc=$rc fifo_exists=$fifo_state"
	fi
	rm -f "$sentinel"
	printf '%s\n' "$out" > "/tmp/child-plan-$label.$$"
}

root=$(pwd)

_child_plan day2.sh day2
_child_plan reg-save.sh save
day2_stdout=$(cat "/tmp/child-plan-day2.$$")
save_stdout=$(cat "/tmp/child-plan-save.$$")
rm -f "/tmp/child-plan-day2.$$" "/tmp/child-plan-save.$$"

# progress-plan.sh from another directory must still find the child
_from_tmp() {
	local dest="$1"
	shift
	( cd /tmp && ABA_PROGRESS_FIFO="$dest" bash "$root/scripts/progress-plan.sh" "$@" 2>/dev/null )
}

day2_fifo=$(mktemp /tmp/test-day2-fifo.XXXXXX)
_from_tmp "$day2_fifo" day2
if [ "$(_plan_lines "$day2_fifo")" = "$day2_stdout" ]; then
	pass "day2 plan matches day2.sh plan"
else
	fail "day2 plan drifted from day2.sh plan"
fi
rm -f "$day2_fifo"

save_fifo=$(mktemp /tmp/test-save-fifo.XXXXXX)
_from_tmp "$save_fifo" save
if [ "$(_plan_lines "$save_fifo")" = "$save_stdout" ]; then
	pass "save plan matches reg-save.sh plan"
else
	fail "save plan drifted from reg-save.sh plan"
fi
rm -f "$save_fifo"

bundle_fifo=$(mktemp /tmp/test-bundle-fifo.XXXXXX)
_from_tmp "$bundle_fifo" bundle
bundle_expect=$(printf '%s\n' "PLAN|bnd_preflight|Validate configuration|2" "$save_stdout" "PLAN|bnd_cli_wait|Verify CLI tools|3" "PLAN|bnd_pack|Pack bundle|10")
if [ "$(_plan_lines "$bundle_fifo")" = "$bundle_expect" ]; then
	pass "bundle plan is save's plan between its own steps"
else
	fail "bundle plan is not save's plan plus bundle steps"
	echo "got:"
	_plan_lines "$bundle_fifo"
fi
rm -f "$bundle_fifo"

up_fifo=$(mktemp /tmp/test-up-fifo.XXXXXX)
_from_tmp "$up_fifo" cluster-upgrade
up_ids=$(_plan_lines "$up_fifo" | cut -d'|' -f2 | tr '\n' ' ')
if [ "$up_ids" = "ug_preflight ug_trigger ug_progress " ] && ! grep -q 'ug_day2\|PLAN|access|' "$up_fifo"; then
	pass "upgrade plan without day-2 is preflight, trigger, wait"
else
	fail "upgrade plan without day-2: [$up_ids]"
fi
rm -f "$up_fifo"

up2_fifo=$(mktemp /tmp/test-up2-fifo.XXXXXX)
_from_tmp "$up2_fifo" cluster-upgrade --with-day2
up2_expect=$(printf '%s\n' "PLAN|ug_preflight|Preflight checks|2" "$day2_stdout" "PLAN|ug_trigger|Trigger upgrade|5" "PLAN|ug_progress|Wait for upgrade|70")
if [ "$(_plan_lines "$up2_fifo")" = "$up2_expect" ]; then
	pass "upgrade --with-day2 inserts day2.sh plan between its own steps"
else
	fail "upgrade --with-day2 composition is wrong"
	echo "got:"
	_plan_lines "$up2_fifo"
fi
rm -f "$up2_fifo"

if printf '%s\n' "$day2_stdout" | grep -q 'ug_'; then
	fail "day2 plan names an upgrade step"
else
	pass "day2 plan does not know upgrade"
fi
if printf '%s\n' "$save_stdout" | grep -q 'bnd_'; then
	fail "save plan names a bundle step"
else
	pass "save plan does not know bundle"
fi

if grep -q 'ug_day2' scripts/cluster-upgrade.sh scripts/progress-plan.sh; then
	fail "ug_day2 wrapper is still declared"
else
	pass "ug_day2 wrapper is gone"
fi

if grep -q 'image_source_is_mirror' scripts/cluster-upgrade.sh \
	&& grep -q 'progress-plan.sh cluster-upgrade --with-day2' scripts/cluster-upgrade.sh \
	&& grep -q 'progress-plan.sh cluster-upgrade$' scripts/cluster-upgrade.sh; then
	pass "upgrade asks day-2 only when day-2 will run"
else
	fail "upgrade plan selection is missing a branch"
fi

echo ""

# ── Orphan emitter check — START IDs that have no PLAN ──
echo "--- Orphan emitters (START without any PLAN) ---"

# Collect all PLAN IDs across all workflows
_all_plan_ids=""
for wf in install sync save load uninstall stop start bundle day2 day2-ntp day2-osus day2-virt cluster-shutdown cluster-startup cluster-upgrade cluster-install; do
	_tmpf=$(capture_plans "$wf")
	_all_plan_ids="$_all_plan_ids $(grep '^PLAN|' "$_tmpf" 2>/dev/null | cut -d'|' -f2)"
	rm -f "$_tmpf"
done
_all_plan_ids=$(echo "$_all_plan_ids" | tr ' ' '\n' | sort -u)

# Collect all START IDs from production scripts (exclude test/demo/progress-plan)
_all_start_ids=$(grep -rh 'aba_progress "START|' scripts/*.sh 2>/dev/null | \
	grep -v 'progress-plan\|tui-progress' | \
	sed 's/.*START|//;s/".*//' | \
	grep -v '^\$' | \
	sort -u)

# Find START IDs missing from any PLAN
_orphans=""
for sid in $_all_start_ids; do
	if ! echo "$_all_plan_ids" | grep -qx "$sid"; then
		_orphans="$_orphans $sid"
	fi
done

if [ -z "$_orphans" ]; then
	pass "No orphan START IDs (all emitters have a matching PLAN)"
else
	fail "Orphan START IDs (no PLAN):$_orphans"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
