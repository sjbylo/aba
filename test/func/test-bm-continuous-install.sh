#!/bin/bash
# Test: BM continuous install stamps, ask scripts, no legacy markers
# Regression for: BACKLOG #B80

cd "$(dirname "$0")/../.." || exit 1

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== BM continuous install (#B80) ==="

# Scripts exist and are executable
for s in bm-ask-edit.sh bm-ask-boot.sh; do
	if [ -x "scripts/$s" ]; then
		_pass "scripts/$s executable"
	else
		_fail "scripts/$s executable"
	fi
	bash -n "scripts/$s" && _pass "scripts/$s bash -n" || _fail "scripts/$s bash -n"
done

# Makefile: one chain, new stamps, no legacy
mf=templates/Makefile.cluster
if grep -q 'TARGET_DEPENDENCIES = check ../aba.conf iso .vms-stopped .iso-uploaded .vms-ready .bm-bmc-boot-done .install-complete' "$mf"; then
	_pass "unified TARGET_DEPENDENCIES"
else
	_fail "unified TARGET_DEPENDENCIES"
fi

for bad in '.bm-message' '.bm-nextstep' '.autopoweroff' '.autoupload' '.autorefresh' '.auto-agent-up:'; do
	if grep -qF "$bad" "$mf"; then
		_fail "Makefile must not contain $bad"
	else
		_pass "Makefile free of $bad"
	fi
done

# progress-plan has cluster-install
if grep -q 'cluster-install)' scripts/progress-plan.sh; then
	_pass "progress-plan.sh cluster-install"
else
	_fail "progress-plan.sh cluster-install"
fi

# Primed/backup must not fabricate .bm-message
if grep -n 'bm-message' scripts/backup.sh scripts/transfer-primed.sh 2>/dev/null; then
	_fail "backup/transfer-primed still reference .bm-message"
else
	_pass "backup/transfer-primed have no .bm-message"
fi

# aba.sh stamp sync uses new names
if grep -q 'touch .vms-stopped .iso-uploaded .vms-ready' scripts/aba.sh; then
	_pass "aba.sh create/refresh sync new stamps"
else
	_fail "aba.sh create/refresh sync new stamps"
fi
if grep -qE 'touch \.autopoweroff|\.autoupload|\.autorefresh' scripts/aba.sh; then
	_fail "aba.sh still touches old stamps"
else
	_pass "aba.sh has no old stamp touches"
fi

# monitor folds wait-agent
if grep -q 'wait-agent-up.sh' scripts/monitor-install.sh; then
	_pass "monitor-install folds wait-agent-up"
else
	_fail "monitor-install folds wait-agent-up"
fi

# TUI BM no longer forces --step iso only
if grep -q 'install_step="iso"' tui/v2/tui-cluster.sh; then
	_fail "TUI still forces BM install_step=iso"
else
	_pass "TUI does not force BM iso-only step"
fi

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
