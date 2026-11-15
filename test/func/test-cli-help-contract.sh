#!/bin/bash
# Test: help files are what aba prints, and every documented long flag is handled.
# Re-run this before and after a parser or registry refactor. It locks the CLI
# contract without starting a registry or a cluster.

cd "$(dirname "$0")/../.." || exit 1

export ABA_DO_NOT_UPDATE=1

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

echo "=== CLI help contract ==="

# stdout of these commands must be the help file, byte for byte.
check_help() {
	local file="$1"
	shift
	local out
	out=$(mktemp)
	if ABA_DO_NOT_UPDATE=1 ./scripts/aba.sh "$@" >"$out" 2>/dev/null; then
		if diff -q "$out" "$file" >/dev/null; then
			_pass "aba $* matches $file"
		else
			_fail "aba $* does not match $file"
		fi
	else
		_fail "aba $* failed (expected help from $file)"
	fi
	rm -f "$out"
}

check_help others/help-aba.txt --help
check_help others/help-aba.txt help
check_help others/help-mirror.txt --help mirror
check_help others/help-mirror.txt mirror --help
check_help others/help-cluster.txt --help cluster
check_help others/help-cluster.txt cluster --help
check_help others/help-bundle.txt --help bundle
check_help others/help-deploy.txt --help deploy
check_help others/help-transfer.txt --help transfer
check_help others/help-setup.txt --help setup
check_help others/help-import.txt --help import

# Long options in a help file must appear in one of the handler scripts.
# Delegated commands (show-operators, setup) keep their flags outside aba.sh.
check_flags() {
	local helpfile="$1"
	shift
	local flag found f
	while read -r flag; do
		[ -n "$flag" ] || continue
		found=
		for f in "$@"; do
			if grep -q -F -- "$flag" "$f"; then
				found=1
				break
			fi
		done
		if [ "$found" ]; then
			_pass "$flag documented in $helpfile is handled"
		else
			_fail "$flag documented in $helpfile is not handled"
		fi
	done < <(grep -oE -- '--[a-zA-Z0-9][a-zA-Z0-9-]*' "$helpfile" | sort -u)
}

check_flags others/help-aba.txt scripts/aba.sh scripts/show-ops.sh
check_flags others/help-mirror.txt scripts/aba.sh
check_flags others/help-cluster.txt scripts/aba.sh
check_flags others/help-bundle.txt scripts/aba.sh
check_flags others/help-deploy.txt scripts/aba.sh
check_flags others/help-transfer.txt scripts/aba.sh
check_flags others/help-import.txt scripts/aba.sh
check_flags others/help-setup.txt scripts/aba.sh tools/setup-dns.sh tools/setup-ntp.sh tools/setup-kvm-host.sh

# help-mirror documents -u as the short form of --reg-user.
if grep -q -F -- '-u,' others/help-mirror.txt && grep -q ' = "-u"' scripts/aba.sh; then
	_pass "help-mirror -u is accepted by the parser"
else
	_fail "help-mirror -u does not match the parser"
fi

# Registry installers share one prelude. Vendor scripts only keep what differs.
if grep -q 'reg_install_begin docker' scripts/reg-install-docker.sh \
	&& grep -q 'reg_install_begin quay' scripts/reg-install-quay.sh \
	&& grep -q 'reg_install_begin "$_OMR_VENDOR"' scripts/reg-install-omr.sh \
	&& grep -q '^reg_install_begin()' scripts/reg-common.sh; then
	_pass "local registry installers share reg_install_begin"
else
	_fail "local registry installers do not share reg_install_begin"
fi

echo
echo "Results: $pass passed, $fail failed"
exit "$fail"
