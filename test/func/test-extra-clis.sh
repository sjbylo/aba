#!/usr/bin/env bash
# Verify optional extra CLIs stay off download-all/install-all, appear on *-extra-clis,
# and install to ~/bin on the disco side when artifacts are already present.
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

# --- Disco-side install: artifacts present → installed to ~/bin ---------------
# Simulates air-gap unpack: tarballs/binaries already under cli/, no download.
# Uses cli-install-all.sh (same path as disco bundle install).
section "disco install: artifacts → ~/bin via cli-install-all.sh"

TEST_HOME=$(mktemp -d)
STAGING=$(mktemp -d)
BACKUP_DIR=$(mktemp -d)
CREATED_ARTS=()
HAD_BUNDLE=0
[ -e .bundle ] && HAD_BUNDLE=1

restore_disco_artifacts() {
	local f base
	for f in "${CREATED_ARTS[@]:-}"; do
		base=$(basename "$f")
		rm -f "$f"
		if [ -e "$BACKUP_DIR/$base" ]; then
			mv "$BACKUP_DIR/$base" "$f"
		fi
	done
	if [ "$HAD_BUNDLE" -eq 0 ]; then
		rm -f .bundle
	fi
	rm -rf "$TEST_HOME" "$STAGING" "$BACKUP_DIR"
}
trap 'cleanup_test_kn; restore_disco_artifacts' EXIT

_make_stub() {
	# $1 = binary name inside staging dir
	printf '#!/bin/bash\n# aba func-test stub\nexit 0\n' > "$STAGING/$1"
	chmod +x "$STAGING/$1"
}

_place_art() {
	# $1 = path under cli/
	local dest="cli/$1"
	if [ -e "$dest" ]; then
		mv "$dest" "$BACKUP_DIR/$(basename "$dest")"
	fi
	mv "$2" "$dest"
	CREATED_ARTS+=("$dest")
}

# Resolve host-specific artifact filenames from cli/Makefile (single source of truth)
while read -r tool art; do
	[ -n "$tool" ] || continue
	case "$tool" in
		virtctl|roxctl)
			_make_stub "$tool"
			_place_art "$art" "$STAGING/$tool"
			;;
		kn|helm|opm|argocd)
			_make_stub "$tool"
			tar -C "$STAGING" -czf "$STAGING/$art" "$tool"
			_place_art "$art" "$STAGING/$art"
			;;
		tkn)
			_make_stub tkn
			# tkn recipe extracts member name "tkn" specifically
			tar -C "$STAGING" -czf "$STAGING/$art" tkn
			_place_art "$art" "$STAGING/$art"
			;;
		*)
			ko "unexpected extra artifact mapping: $tool $art"
			;;
	esac
done < <(make -sC cli --eval 'print-extra-artifacts: ; @printf "%s %s\n" virtctl "$(virtctl_file)" kn "$(kn_tar_file)" tkn "$(tkn_tar_file)" helm "$(helm_tar_file)" opm "$(local_opm_tar)" argocd "$(argocd_tar_file)" roxctl "$(roxctl_file)"' print-extra-artifacts)

avail=$(make --no-print-directory -sC cli out-install-extra-available)
for t in $EXTRA_TOOLS; do
	if echo "$avail" | grep -qw "$t"; then
		ok "out-install-extra-available lists $t"
	else
		ko "out-install-extra-available missing $t (got: $avail)"
	fi
done

# Reset install task state so run_once actually runs make for these tools
for t in $EXTRA_TOOLS; do
	scripts/cli-install-all.sh --reset "$t" >/dev/null 2>&1 || true
done

# .bundle → skip download wait (disco / transfer tree)
touch .bundle

set +e
install_out=$(
	HOME="$TEST_HOME" \
	PLAIN_OUTPUT=1 \
	scripts/cli-install-all.sh --wait $EXTRA_TOOLS 2>&1
)
install_rc=$?
set -e

if [ "$install_rc" -eq 0 ]; then
	ok "cli-install-all.sh --wait extras exited 0"
else
	ko "cli-install-all.sh --wait extras failed (rc=$install_rc): $install_out"
fi

for t in $EXTRA_TOOLS; do
	if [ -x "$TEST_HOME/bin/$t" ]; then
		ok "disco install placed ~/bin/$t"
	else
		ko "disco install missing $TEST_HOME/bin/$t"
	fi
done

# Restore real cli/ artifacts; ensure stubs did not leak into the real ~/bin
restore_disco_artifacts
trap cleanup_test_kn EXIT
CREATED_ARTS=()
for t in $EXTRA_TOOLS; do
	if [ -x "$HOME/bin/$t" ] && head -1 "$HOME/bin/$t" 2>/dev/null | grep -q 'aba func-test stub'; then
		ko "stub leaked to real ~/bin/$t"
	else
		ok "no stub leak in ~/bin/$t"
	fi
done

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
