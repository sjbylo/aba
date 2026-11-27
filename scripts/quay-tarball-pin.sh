#!/bin/bash
# Drop a cached Quay mirror-registry tarball that is not the pinned release.
# mirror-registry/latest now serves 3.0.0. Make will not replace a file that
# already exists, so a Quay mirror keeps installing that binary.
# Called from templates/Makefile.mirror (quay-tarball-pin), cwd = mirror dir.
# No-op unless mirror.conf says reg_vendor=quay. omr, docker, and auto keep
# whatever file is already there, including their own images, unless
# QUAY_PIN_ANY_VENDOR=1 (set by the registry upgrade).
# Prints "replaced" on stdout when the tarball was removed.

set -euo pipefail

tarball=${1:?}
sums_url=${2:?}

vendor=$(grep '^reg_vendor=' mirror.conf 2>/dev/null | head -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//;s/[[:space:]]*$//' || true)
# Upgrade sets QUAY_PIN_ANY_VENDOR=1: it always runs Quay, whatever reg_vendor says.
if [ "${QUAY_PIN_ANY_VENDOR:-}" != 1 ]; then
	[ "${vendor:-}" = quay ] || exit 0
fi
[ -f "$tarball" ] || exit 0

sums=$(mktemp)
trap 'rm -f "$sums"' EXIT
if ! curl -f --retry 8 -sL --max-time 60 -o "$sums" "$sums_url"; then
	echo "[ABA] Could not read Quay mirror-registry checksums. Leaving $(basename "$tarball")." >&2
	exit 0
fi
base=$(basename "$tarball")
if grep "  ${base}$" "$sums" | sha256sum --check --status; then
	exit 0
fi
echo "[ABA] Replacing Quay mirror-registry tarball. It is not the pinned release." >&2
rm -f "$tarball" "${tarball}.sha256" mirror-registry execution-environment.tar image-archive.tar sqlite3.tar
echo replaced
