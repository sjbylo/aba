#!/bin/bash
# A cached mirror-registry tarball from "latest" (3.0.0) is removed only when
# reg_vendor=quay. omr and docker files stay, including a sibling omr image.

set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)

pass=0
fail=0
_ok() { pass=$((pass + 1)); printf '  PASS  %s\n' "$*"; }
_fail() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$*"; }

script=scripts/quay-tarball-pin.sh
if grep -qx 'mirror_registry_url = https://mirror.openshift.com/pub/cgw/mirror-registry/2.0.9' templates/Makefile.mirror; then
	_ok "Makefile pins Quay mirror-registry to 2.0.9"
else
	_fail "Makefile does not pin Quay mirror-registry to 2.0.9"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

_sums_for() {
	# $1 hash, written as a file:// checksum list
	printf '%s  mirror-registry-amd64.tar.gz\n' "$1" > sums
}

_run() {
	out=$("$ROOT/scripts/quay-tarball-pin.sh" mirror-registry-amd64.tar.gz "file://${tmp}/sums" 2>/dev/null || true)
}

# Wrong vendor: the 3.0-shaped file and the omr image both stay.
echo 'reg_vendor=omr' > mirror.conf
echo 'not-2.0.9' > mirror-registry-amd64.tar.gz
echo 'omr-bytes' > omr-image.tgz
_sums_for 0000000000000000000000000000000000000000000000000000000000000000
_run
if [ -f mirror-registry-amd64.tar.gz ] && [ -f omr-image.tgz ] && [ -z "$out" ]; then
	_ok "omr vendor keeps the cached tarball and omr-image.tgz"
else
	_fail "omr vendor changed a file (out=${out:-empty})"
fi

echo 'reg_vendor=docker' > mirror.conf
_run
if [ -f mirror-registry-amd64.tar.gz ] && [ -f omr-image.tgz ]; then
	_ok "docker vendor keeps the cached tarball"
else
	_fail "docker vendor removed a file"
fi

# Quay + checksum mismatch: tarball and extracted installer files go, omr image stays.
echo 'reg_vendor=quay' > mirror.conf
echo 'extracted-3.0' > mirror-registry
echo 'ee' > execution-environment.tar
_run
if [ ! -f mirror-registry-amd64.tar.gz ] && [ ! -f mirror-registry ] && [ ! -f execution-environment.tar ] \
	&& [ -f omr-image.tgz ] && [ "$out" = replaced ]; then
	_ok "quay vendor replaces a tarball that is not the pin"
else
	_fail "quay mismatch did not replace only the quay files (out=${out:-empty})"
fi

# Quay + matching checksum: file stays.
echo 'hello-2.0.9' > mirror-registry-amd64.tar.gz
hash=$(sha256sum mirror-registry-amd64.tar.gz | awk '{print $1}')
_sums_for "$hash"
_run
if [ -f mirror-registry-amd64.tar.gz ] && [ -z "$out" ]; then
	_ok "quay vendor keeps a tarball that matches the pin"
else
	_fail "quay match removed the tarball (out=${out:-empty})"
fi

# No mirror.conf: do not guess.
rm -f mirror.conf
echo 'still-here' > mirror-registry-amd64.tar.gz
_sums_for 0000000000000000000000000000000000000000000000000000000000000000
_run
if [ -f mirror-registry-amd64.tar.gz ] && [ -z "$out" ]; then
	_ok "missing reg_vendor leaves the tarball"
else
	_fail "missing reg_vendor removed the tarball"
fi

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
