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

auth_line=$(printf '%s\n' "$dry" | grep -n 'create-containers-auth.sh' | head -1 | cut -d: -f1)
pull_line=$(printf '%s\n' "$dry" | grep -n "podman pull ${image}" | head -1 | cut -d: -f1)
if [ -n "$auth_line" ] && [ -n "$pull_line" ] && [ "$auth_line" -lt "$pull_line" ]; then
	_ok "download-omr-image creates container auth before the pull"
else
	_fail "download-omr-image does not create container auth before the pull"
fi

inst_auth=$(grep -n 'create-containers-auth.sh' scripts/reg-install-omr.sh | head -1 | cut -d: -f1)
inst_pull=$(grep -n 'podman pull "\$_OMR_IMAGE"' scripts/reg-install-omr.sh | head -1 | cut -d: -f1)
if [ -n "$inst_auth" ] && [ -n "$inst_pull" ] && [ "$inst_auth" -lt "$inst_pull" ]; then
	_ok "reg-install-omr.sh creates container auth before the pull"
else
	_fail "reg-install-omr.sh does not create container auth before the pull"
fi

echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
