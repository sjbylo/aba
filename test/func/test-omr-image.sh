#!/bin/bash
# The omr vendor pulls the official mirror-registry image, not the quay.io dev tag.

set -u
cd "$(dirname "$0")/../.." || exit 1

pass=0
fail=0
_ok() { pass=$((pass + 1)); printf '  PASS  %s\n' "$*"; }
_fail() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$*"; }

image='registry.redhat.io/openshift/mirror-registry-rhel9:v3.0'

if grep -qx "_OMR_IMAGE=\"\${OMR_IMAGE:-${image}}\"" scripts/include_all.sh; then
	_ok "include_all.sh defaults omr to the official image"
else
	_fail "include_all.sh does not default omr to ${image}"
fi

if grep -qx "OMR_IMAGE ?= ${image}" templates/Makefile.mirror; then
	_ok "Makefile.mirror defaults OMR_IMAGE to the official image"
else
	_fail "Makefile.mirror does not default OMR_IMAGE to ${image}"
fi

if grep -q 'quay.io/sjbylo/quay-mirror' scripts/include_all.sh templates/Makefile.mirror; then
	_fail "quay.io/sjbylo/quay-mirror is still a default"
else
	_ok "quay.io dev image is no longer a default"
fi

# make -n must name the new image and must not pull it.
# -B so an existing omr-image.tgz does not hide the recipe. -n does not pull.
dry=$(make -n -B -C mirror download-omr-image 2>&1) || { _fail "make -n download-omr-image failed"; dry=""; }
if printf '%s\n' "$dry" | grep -q "podman pull ${image}"; then
	_ok "download-omr-image pulls ${image}"
else
	_fail "download-omr-image does not pull ${image}"
fi

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
