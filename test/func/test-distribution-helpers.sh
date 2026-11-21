#!/bin/bash
# The distribution file in effect, not a branch at the call site.
# OpenShift must not be asked to reach an OKD site. OKD must not be
# asked to reach registry.redhat.io. VMware is allowed for OKD.

cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD

# dist_load reads aba.conf. Save the checkout file and write the key the
# case under test needs. The flag section below runs in a sandbox copy.
_conf_save=$(mktemp)
cp -a "$ROOT/aba.conf" "$_conf_save"
_restore_aba_conf() {
	if [ -n "${_conf_save:-}" ] && [ -f "$_conf_save" ]; then
		cp -a "$_conf_save" "$ROOT/aba.conf"
		rm -f "$_conf_save"
		_conf_save=
	fi
}
trap _restore_aba_conf EXIT

_set_dist() {
	local v="$1"
	if grep -q '^distribution=' "$ROOT/aba.conf"; then
		sed -i "s/^distribution=.*/distribution=$v/" "$ROOT/aba.conf"
	else
		printf 'distribution=%s\n' "$v" >>"$ROOT/aba.conf"
	fi
	dist_load
}

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
_fail() { fail=$(( fail + 1 )); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }

_has_line() { printf '%s\n' "$1" | grep -qx "$2"; }

echo "=== distribution helpers ==="

# shellcheck disable=SC1091
source scripts/include_all.sh

_set_dist ocp

if [ "$(dist_of)" = "ocp" ]; then
	_pass "distribution=ocp loads OpenShift"
else
	_fail "distribution=ocp loads OpenShift (got $(dist_of))"
fi
if [ "$(dist_display)" = "OCP" ]; then
	_pass "OpenShift display name is OCP"
else
	_fail "OpenShift display name is OCP (got $(dist_display))"
fi
if [ "$(dist_cli_install_file linux amd64 4.22.22)" = "openshift-install-linux-4.22.22.tar.gz" ] \
	&& [ "$(dist_cli_install_file linux arm64 4.22.22)" = "openshift-install-linux-4.22.22.tar.gz" ]; then
	_pass "OpenShift installer name has no arch token"
else
	_fail "OpenShift installer name has no arch token"
fi
if dist_vm_secure_boot; then
	_pass "OpenShift keeps VMware secure boot"
else
	_fail "OpenShift keeps VMware secure boot"
fi
if dist_tui_allowed; then
	_pass "OpenShift keeps the TUI"
else
	_fail "OpenShift keeps the TUI"
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
if [ -z "$(dist_oc_mirror_flags)" ]; then
	_pass "OpenShift adds no oc-mirror flag"
else
	_fail "OpenShift adds no oc-mirror flag"
fi
if dist_is_prerelease "4.22.0-rc.1" && ! dist_is_prerelease "4.22.22"; then
	_pass "OpenShift pre-release is a hyphenated build"
else
	_fail "OpenShift pre-release is a hyphenated build"
fi

_set_dist okd

if [ "$(dist_of)" = "okd" ]; then
	_pass "distribution=okd loads the OKD file"
else
	_fail "distribution=okd loads the OKD file (got $(dist_of))"
fi
if [ "$(dist_display)" = "OKD" ]; then
	_pass "OKD display name is OKD"
else
	_fail "OKD display name is OKD (got $(dist_display))"
fi
if [ "$(dist_cli_install_file linux amd64 4.21.0-okd-scos.11)" = "openshift-install-linux-4.21.0-okd-scos.11.tar.gz" ] \
	&& [ "$(dist_cli_install_file linux arm64 4.21.0-okd-scos.11)" = "openshift-install-linux-arm64-4.21.0-okd-scos.11.tar.gz" ]; then
	_pass "OKD amd64 installer has no arch token"
else
	_fail "OKD amd64 installer has no arch token"
fi
if dist_vm_secure_boot; then
	_fail "OKD leaves VMware secure boot off"
else
	_pass "OKD leaves VMware secure boot off"
fi
if dist_tui_allowed; then
	_fail "OKD stops the TUI"
else
	_pass "OKD stops the TUI"
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
if [ -z "$(dist_oc_mirror_flags sync)" ] && [ "$(dist_oc_mirror_flags save)" = "--remove-signatures" ] && [ "$(dist_oc_mirror_flags load)" = "--remove-signatures" ]; then
	_pass "OKD sync keeps signatures and save/load drop them"
else
	_fail "OKD sync keeps signatures and save/load drop them"
fi
OC_MIRROR_FLAGS=--remove-signatures
if [ -z "$(dist_oc_mirror_flags save)" ]; then
	_pass "OKD does not repeat a flag the user already set"
else
	_fail "OKD does not repeat a flag the user already set"
fi
unset OC_MIRROR_FLAGS
unset OCP_SIGNATURE_URL OCP_SIGNATURE_VERIFICATION_PK
dist_prepare_oc_mirror
if [[ "$OCP_SIGNATURE_URL" == */ ]] && [ -s "$OCP_SIGNATURE_VERIFICATION_PK" ]; then
	_pass "OKD points oc-mirror at the CI signature store"
else
	_fail "OKD points oc-mirror at the CI signature store"
fi
unset OCP_SIGNATURE_URL OCP_SIGNATURE_VERIFICATION_PK
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

_sig=$(mktemp -d /tmp/aba-okd-sig.XXXXXX)
mkdir -p "$_sig/data/working-dir/signatures"
touch "$_sig/data/working-dir/signatures/5.0.0-okd-scos.6-sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
_ref="$(cd "$_sig" && dist_release_image_ref 5.0.0-okd-scos.6)"
if [ "$_ref" = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]; then
	_pass "OKD release ref is the digest oc-mirror recorded"
else
	_fail "OKD release ref is the digest oc-mirror recorded (got $_ref)"
fi
rm -rf "$_sig"

_txt=$(mktemp /tmp/aba-okd-rel.XXXXXX)
_dig=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat > "$_txt" <<EOF
Name:           4.22.0-okd-scos.10
Digest:         sha256:${_dig}
OS/Arch:        linux/${ARCH}
EOF
_ref="$(_okd_payload_ref_from_release_txt "$_txt" 4.22.0-okd-scos.10)"
if [ "$_ref" = "quay.io/okd/scos-release@sha256:${_dig}" ]; then
	_pass "OKD release.txt Digest is the payload ref"
else
	_fail "OKD release.txt Digest is the payload ref (got $_ref)"
fi
printf '\nPull From: quay.io/okd/scos-release@sha256:%s\n' "$_dig" >> "$_txt"
_ref="$(_okd_payload_ref_from_release_txt "$_txt" 4.22.0-okd-scos.10)"
if [ "$_ref" = "quay.io/okd/scos-release@sha256:${_dig}" ]; then
	_pass "OKD release.txt accepts a Pull From line that matches Digest"
else
	_fail "OKD release.txt accepts a matching Pull From line (got $_ref)"
fi
_bad=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
cat > "$_txt" <<EOF
Name:           4.22.0-okd-scos.10
Digest:         sha256:${_dig}
OS/Arch:        linux/${ARCH}
Pull From: quay.io/okd/scos-release@sha256:${_bad}
EOF
_rc=0
_err="$(_okd_payload_ref_from_release_txt "$_txt" 4.22.0-okd-scos.10 2>&1)" || _rc=$?
if [ "$_rc" -eq 1 ] && printf '%s\n' "$_err" | grep -q "does not match its Digest"; then
	_pass "OKD release.txt stops when Pull From disagrees with Digest"
else
	_fail "OKD release.txt stops when Pull From disagrees with Digest (rc $_rc)"
fi
sed -i '/^Pull From:/d' "$_txt"
sed -i "s|^OS/Arch:.*|OS/Arch:        linux/notarch|" "$_txt"
_rc=0
_err="$(_okd_payload_ref_from_release_txt "$_txt" 4.22.0-okd-scos.10 2>&1)" || _rc=$?
if [ "$_rc" -eq 1 ] && printf '%s\n' "$_err" | grep -q "this host needs linux/${ARCH}"; then
	_pass "OKD release.txt stops when OS/Arch is another architecture"
else
	_fail "OKD release.txt stops when OS/Arch is another architecture (rc $_rc)"
fi
rm -f "$_txt"

# The file is okd here. An export must not switch the functions.
export distribution=ocp
dist_load
if [ "$(dist_of)" = "okd" ]; then
	_pass "an exported distribution does not override aba.conf"
else
	_fail "an exported distribution does not override aba.conf (got $(dist_of))"
fi
unset distribution
_set_dist ocp
if [ -z "$(dist_oc_mirror_flags)" ]; then
	_pass "OpenShift oc-mirror flags stay empty"
else
	_fail "OpenShift oc-mirror flags stay empty"
fi
_ps="$(mktemp -u /tmp/aba-ocp-ps.XXXXXX)"
if dist_pull_secret_ensure "$_ps"; then
	_fail "OpenShift does not invent a pull secret"
else
	_pass "OpenShift does not invent a pull secret"
fi
if [ "$(dist_of)" = "ocp" ] && ! dist_version_is_valid "4.21.0-okd-scos.5" stable; then
	_pass "distribution=ocp loads OpenShift again"
else
	_fail "distribution=ocp loads OpenShift again"
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
_restore_aba_conf
_before="$(sha256sum "$ROOT/aba.conf" | awk '{print $1}')"
WORK="$(mktemp -d /tmp/aba-dist-flag.XXXXXX)"
cleanup() { _restore_aba_conf; rm -rf "$WORK"; }
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
# is written and before any download starts.
_err="$(cd "$REPO" && _run --distribution ocp --channel nope 2>&1)" || _rc=$?
if grep -q '^distribution=ocp$' "$REPO/aba.conf"; then
	_pass "--distribution ocp writes distribution=ocp"
else
	_fail "--distribution ocp writes distribution=ocp"
fi

_rc=0
_err="$(cd "$REPO" && _run --distribution 2>&1)" || _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s\n' "$_err" | grep -q 'missing argument after option --distribution'; then
	_pass "missing --distribution value is rejected"
else
	_fail "missing --distribution value is rejected (rc $_rc)"
fi

_after="$(sha256sum "$ROOT/aba.conf" | awk '{print $1}')"
if [ "$_before" = "$_after" ]; then
	_pass "repo aba.conf was not modified"
else
	_fail "repo aba.conf was not modified"
fi

echo ""
# save/sync reachability gate: one quick curl, curl --retry 2, abort with curl's error.
_bin=$(mktemp -d)
_clog=$(mktemp)
cat > "$_bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${ABA_CURL_LOG:?}"
if [ "${ABA_CURL_RC:-0}" != 0 ]; then
	echo "curl: (28) Failed to connect" >&2
	exit "$ABA_CURL_RC"
fi
exit 0
EOF
chmod +x "$_bin/curl"
_ps=$(mktemp)
printf '%s\n' '{"auths":{"registry.redhat.io":{"auth":"eHg="}}}' > "$_ps"
_rc=0
_err=$(
	PATH="$_bin:$PATH" ABA_CURL_LOG="$_clog" ABA_CURL_RC=28 pull_secret_file="$_ps" \
		require_internet_and_pull_secret 2>&1
) || _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s\n' "$_err" | grep -q 'curl: (28) Failed to connect' \
	&& grep -q -- '--retry 2' "$_clog" \
	&& grep -q -- '--connect-timeout 5' "$_clog" \
	&& grep -q -- '--max-time 10' "$_clog"; then
	_pass "save/sync probe aborts with curl's error and --retry 2"
else
	_fail "save/sync probe aborts with curl's error and --retry 2 (rc $_rc)"
	printf '%s\n' "$_err" | head -20
fi
: > "$_clog"
_rc=0
_err=$(
	PATH="$_bin:$PATH" ABA_CURL_LOG="$_clog" ABA_CURL_RC=0 pull_secret_file="$_ps" \
		require_internet_and_pull_secret 2>&1
) || _rc=$?
if [ "$_rc" -eq 0 ]; then
	_pass "save/sync probe continues when the registry answers"
else
	_fail "save/sync probe continues when the registry answers (rc $_rc)"
	printf '%s\n' "$_err" | head -20
fi
rm -rf "$_bin" "$_clog" "$_ps"

echo "Results: $pass passed, $fail failed"
exit "$fail"
