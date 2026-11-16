#!/bin/bash
# The distribution file in effect, not a branch at the call site.
# OpenShift must not be asked to reach an OKD site. OKD must not be
# asked to reach registry.redhat.io. VMware is allowed for OKD.

cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
_fail() { fail=$(( fail + 1 )); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }

_has_line() { printf '%s\n' "$1" | grep -qx "$2"; }

echo "=== distribution helpers ==="

# shellcheck disable=SC1091
source scripts/include_all.sh

if [ "$(dist_of)" = "ocp" ]; then
	_pass "missing key loads OpenShift"
else
	_fail "missing key loads OpenShift (got $(dist_of))"
fi

_sites="$(dist_probe_sites)"
if _has_line "$_sites" api.openshift.com && _has_line "$_sites" mirror.openshift.com && _has_line "$_sites" registry.redhat.io; then
	_pass "OpenShift probe list is the three OpenShift hosts"
else
	_fail "OpenShift probe list (got: $_sites)"
fi
if _has_line "$_sites" updates.okd.io; then
	_fail "OpenShift probe list contains updates.okd.io"
else
	_pass "OpenShift probe list has no updates.okd.io"
fi

if dist_version_is_valid "4.22.22" stable; then
	_pass "OpenShift accepts 4.22.22"
else
	_fail "OpenShift accepts 4.22.22"
fi
if dist_version_is_valid "4.21.0-okd-scos.5" stable; then
	_fail "OpenShift rejects an OKD version"
else
	_pass "OpenShift rejects an OKD version"
fi
if dist_channel_is_valid fast && dist_channel_is_valid eus; then
	_pass "OpenShift keeps fast and eus"
else
	_fail "OpenShift keeps fast and eus"
fi
if dist_stop_unsupported upgrade; then
	_pass "OpenShift allows upgrade"
else
	_fail "OpenShift allows upgrade"
fi
if dist_is_prerelease "4.22.0-rc.1" && ! dist_is_prerelease "4.22.22"; then
	_pass "OpenShift pre-release is a hyphenated build"
else
	_fail "OpenShift pre-release is a hyphenated build"
fi

distribution=okd
dist_load

if [ "$(dist_of)" = "okd" ]; then
	_pass "distribution=okd loads the OKD file"
else
	_fail "distribution=okd loads the OKD file (got $(dist_of))"
fi

_sites="$(dist_probe_sites)"
if _has_line "$_sites" github.com && _has_line "$_sites" quay.io && _has_line "$_sites" updates.okd.io && _has_line "$_sites" mirror.openshift.com; then
	_pass "OKD probe list is github, quay, updates.okd.io, mirror.openshift.com"
else
	_fail "OKD probe list (got: $_sites)"
fi
if _has_line "$_sites" registry.redhat.io; then
	_fail "OKD probe list contains registry.redhat.io"
else
	_pass "OKD probe list has no registry.redhat.io"
fi

if dist_version_is_valid "4.21.0-okd-scos.5" stable; then
	_pass "OKD accepts 4.21.0-okd-scos.5"
else
	_fail "OKD accepts 4.21.0-okd-scos.5"
fi
if dist_version_is_valid "4.21.0-okd-scos.ec.1" candidate; then
	_pass "OKD candidate accepts an ec build"
else
	_fail "OKD candidate accepts an ec build"
fi
if dist_version_is_valid "4.21.0-okd-scos.ec.1" stable; then
	_fail "OKD stable rejects an ec build"
else
	_pass "OKD stable rejects an ec build"
fi
if dist_version_is_valid "4.22.22" stable; then
	_fail "OKD rejects a plain OpenShift version"
else
	_pass "OKD rejects a plain OpenShift version"
fi
if dist_channel_is_valid stable && dist_channel_is_valid candidate; then
	_pass "OKD channels are stable and candidate"
else
	_fail "OKD channels are stable and candidate"
fi
if dist_channel_is_valid fast || dist_channel_is_valid eus; then
	_fail "OKD rejects fast and eus"
else
	_pass "OKD rejects fast and eus"
fi
if dist_target_problem vmw; then
	_pass "OKD allows VMware"
else
	_fail "OKD allows VMware"
fi
if dist_is_prerelease "4.21.0-okd-scos.ec.1" && ! dist_is_prerelease "4.21.0-okd-scos.5"; then
	_pass "OKD pre-release is the ec build"
else
	_fail "OKD pre-release is the ec build"
fi

_ref="$(dist_catalog_ref community-operator 4.21)"
if [ "$_ref" = "registry.access.redhat.com/redhat/community-operator-index:v4.21" ]; then
	_pass "OKD community catalog is registry.access.redhat.com"
else
	_fail "OKD community catalog ref (got $_ref)"
fi
if [ "$(dist_catalogs)" = "community-operator" ]; then
	_pass "OKD catalog list is community only"
else
	_fail "OKD catalog list (got $(dist_catalogs))"
fi

_err="$(dist_stop_unsupported upgrade 2>&1)" || _rc=$?
if [ "${_rc:-0}" -ne 0 ] && printf '%s\n' "$_err" | grep -q "unsupported for OKD"; then
	_pass "OKD upgrade aborts"
else
	_fail "OKD upgrade aborts (rc ${_rc:-0})"
fi

_ps="$(mktemp /tmp/aba-okd-ps.XXXXXX)"
rm -f "$_ps"
if dist_pull_secret_ensure "$_ps" && jq -e '.auths.fake.auth' "$_ps" >/dev/null; then
	_pass "OKD writes a placeholder pull secret when none is required"
else
	_fail "OKD writes a placeholder pull secret when none is required"
fi
rm -f "$_ps"
ops=virt
_ps="$(mktemp -u /tmp/aba-okd-ps.XXXXXX)"
if dist_pull_secret_ensure "$_ps"; then
	_fail "OKD refuses a missing pull secret when operators are selected"
else
	_pass "OKD refuses a missing pull secret when operators are selected"
fi
[ ! -e "$_ps" ] || _fail "OKD did not leave a secret file behind"
unset ops

# Back to OpenShift, without writing aba.conf.
unset distribution
dist_load
_ps="$(mktemp -u /tmp/aba-ocp-ps.XXXXXX)"
if dist_pull_secret_ensure "$_ps"; then
	_fail "OpenShift does not invent a pull secret"
else
	_pass "OpenShift does not invent a pull secret"
fi
if [ "$(dist_of)" = "ocp" ] && ! dist_version_is_valid "4.21.0-okd-scos.5" stable; then
	_pass "clearing the variable loads OpenShift again"
else
	_fail "clearing the variable loads OpenShift again"
fi

# Flag path: a copy of the tree, so the real aba.conf is not edited.
echo "=== image set template ==="
_isc="$(mktemp -d /tmp/aba-isc.XXXXXX)"
git show HEAD:templates/imageset-config.yaml.j2 > "$_isc/old.j2"
env ARCH=amd64 ocp_channel=stable ocp_version=4.22.22 ocp_ver_major=4.22 \
	ocp_upgrade_to= release_ref= has_operators=false \
	scripts/j2 templates/imageset-config.yaml.j2 > "$_isc/new.out"
env ARCH=amd64 ocp_channel=stable ocp_version=4.22.22 ocp_ver_major=4.22 \
	ocp_upgrade_to= has_operators=false \
	scripts/j2 "$_isc/old.j2" > "$_isc/old.out"
if diff -q "$_isc/old.out" "$_isc/new.out" >/dev/null; then
	_pass "OpenShift image set render is unchanged"
else
	_fail "OpenShift image set render is unchanged"
fi
env ARCH=amd64 ocp_channel=stable ocp_version=5.0.0-okd-scos.6 ocp_ver_major=5.0 \
	ocp_upgrade_to= has_operators=false \
	release_ref='quay.io/okd/scos-release@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
	scripts/j2 templates/imageset-config.yaml.j2 > "$_isc/okd.out"
if grep -q '^    release: quay.io/okd/scos-release@sha256:' "$_isc/okd.out" \
	&& grep -q '^    graph: false$' "$_isc/okd.out" \
	&& grep -q 'registry.access.redhat.com/redhat/community-operator-index' "$_isc/okd.out" \
	&& ! grep -q 'type: ocp' "$_isc/okd.out"; then
	_pass "OKD image set pins the release digest"
else
	_fail "OKD image set pins the release digest"
fi
rm -rf "$_isc"

echo "=== --distribution flag ==="
_before="$(sha256sum "$ROOT/aba.conf" | awk '{print $1}')"
WORK="$(mktemp -d /tmp/aba-dist-flag.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

REPO="$WORK/repo"
mkdir -p "$REPO" "$WORK/home"
cp -a "$ROOT/scripts" "$REPO/scripts"
cp -f "$ROOT/Makefile" "$ROOT/VERSION" "$ROOT/aba.conf" "$REPO/"
ln -s "$ROOT/templates" "$REPO/templates"
if [ -f "$ROOT/images.conf" ]; then
	cp -f "$ROOT/images.conf" "$REPO/images.conf"
fi

_run() {
	HOME="$WORK/home" ABA_DO_NOT_UPDATE=1 "$REPO/scripts/aba.sh" "$@"
}

_err="$(cd "$REPO" && _run --distribution okd --channel fast 2>&1)" || _rc=$?
if [ "${_rc:-0}" -ne 0 ] && printf '%s\n' "$_err" | grep -q "not a channel"; then
	_pass "--distribution okd rejects channel fast"
else
	_fail "--distribution okd rejects channel fast (rc ${_rc:-0})"
fi
if grep -q '^distribution=okd$' "$REPO/aba.conf"; then
	_pass "--distribution okd writes distribution=okd"
else
	_fail "--distribution okd writes distribution=okd"
fi

# nope is not a channel, so aba stops in the flag check, after the key
# is removed and before any download starts.
_err="$(cd "$REPO" && _run --distribution ocp --channel nope 2>&1)" || _rc=$?
if grep -q '^distribution=' "$REPO/aba.conf"; then
	_fail "--distribution ocp removes the key"
else
	_pass "--distribution ocp removes the key"
fi

_after="$(sha256sum "$ROOT/aba.conf" | awk '{print $1}')"
if [ "$_before" = "$_after" ]; then
	_pass "repo aba.conf was not modified"
else
	_fail "repo aba.conf was not modified"
fi

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
