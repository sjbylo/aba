#!/usr/bin/env bash
# Verify optional extra CLIs stay off download-all/install-all and appear on *-extra-clis.
# Usage: bash test/func/test-extra-clis.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ABA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
cd "$ABA_ROOT"

pass=0
fail=0

ok() { echo "PASS: $*"; pass=$((pass + 1)); }
ko() { echo "FAIL: $*"; fail=$((fail + 1)); }

section() { echo; echo "=== $* ==="; }

EXTRA_TOOLS="virtctl kn tkn helm opm argocd roxctl"

section "out-download-all excludes extra CLIs"
core=$(make --no-print-directory -sC cli out-download-all)
for t in $EXTRA_TOOLS; do
	if echo "$core" | grep -qw "$t"; then
		ko "out-download-all unexpectedly lists $t: $core"
	else
		ok "out-download-all omits $t"
	fi
done

section "out-download-extra-clis lists all extra CLIs"
extra=$(make --no-print-directory -sC cli out-download-extra-clis)
for t in $EXTRA_TOOLS; do
	if echo "$extra" | grep -qw "$t"; then
		ok "out-download-extra-clis lists $t"
	else
		ko "out-download-extra-clis missing $t: $extra"
	fi
done

section "out-install-all excludes extra CLIs"
inst=$(make --no-print-directory -sC cli out-install-all)
for t in $EXTRA_TOOLS; do
	if echo "$inst" | grep -qw "$t"; then
		ko "out-install-all unexpectedly lists $t: $inst"
	else
		ok "out-install-all omits $t"
	fi
done

section "out-install-extra-clis lists all extra CLIs"
inst_extra=$(make --no-print-directory -sC cli out-install-extra-clis)
for t in $EXTRA_TOOLS; do
	if echo "$inst_extra" | grep -qw "$t"; then
		ok "out-install-extra-clis lists $t"
	else
		ko "out-install-extra-clis missing $t: $inst_extra"
	fi
done

section "download-* targets exist (dry-run)"
for t in $EXTRA_TOOLS; do
	if make -n -C cli "download-$t" >/dev/null 2>&1; then
		ok "make -n download-$t ok"
	else
		ko "make -n download-$t failed"
	fi
done

section "cli-download-all.sh --extra uses out-download-extra-clis"
# Reset any prior state, start non-blocking, then immediately reset (no long wait)
if scripts/cli-download-all.sh --reset --extra >/dev/null 2>&1; then
	ok "cli-download-all.sh --reset --extra"
else
	ko "cli-download-all.sh --reset --extra failed"
fi

# Force optional-download failure via unreachable kn_base_url + synthetic kn_tar_file.
# Avoids real CDN downloads and does not touch the host's real kn-*.tar.gz.
BAD_KN_URL="http://127.0.0.1:9"
TEST_KN_TAR="kn-extra-cli-fail-test.tar.gz"
cleanup_test_kn() {
	rm -f "cli/$TEST_KN_TAR" "cli/.${TEST_KN_TAR}.tmp."* 2>/dev/null || true
}
trap cleanup_test_kn EXIT
cleanup_test_kn

section "optional-download hard-fail (SOFT_EXTRA unset)"
set +e
hard_out=$(make --no-print-directory -C cli \
	kn_base_url="$BAD_KN_URL" kn_tar_file="$TEST_KN_TAR" \
	"$TEST_KN_TAR" 2>&1)
hard_rc=$?
set -e
if [ "$hard_rc" -ne 0 ] && echo "$hard_out" | grep -q 'Download failed'; then
	ok "hard-fail: make exits non-zero on bad kn_base_url (rc=$hard_rc)"
else
	ko "hard-fail: expected non-zero + Download failed (rc=$hard_rc): $hard_out"
fi
if [ -e "cli/$TEST_KN_TAR" ]; then
	ko "hard-fail: unexpected artifact left at cli/$TEST_KN_TAR"
else
	ok "hard-fail: no successful kn artifact left"
fi

section "optional-download soft-fail (SOFT_EXTRA=1)"
cleanup_test_kn
set +e
soft_out=$(make --no-print-directory -C cli SOFT_EXTRA=1 \
	kn_base_url="$BAD_KN_URL" kn_tar_file="$TEST_KN_TAR" \
	"$TEST_KN_TAR" 2>&1)
soft_rc=$?
set -e
if [ "$soft_rc" -eq 0 ] && echo "$soft_out" | grep -q 'Skipping (optional CLI)'; then
	ok "soft-fail: SOFT_EXTRA=1 exits 0 and skips"
else
	ko "soft-fail: expected rc=0 + Skipping (got rc=$soft_rc): $soft_out"
fi
if [ -e "cli/$TEST_KN_TAR" ]; then
	ko "soft-fail: unexpected artifact left at cli/$TEST_KN_TAR"
else
	ok "soft-fail: no successful kn artifact left"
fi
cleanup_test_kn

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
