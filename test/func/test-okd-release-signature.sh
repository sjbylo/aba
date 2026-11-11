#!/bin/bash
# test-okd-release-signature.sh -- release signature environment for oc-mirror on OKD
#
# OKD release signatures are published on the OpenShift CI bucket, not on mirror.openshift.com, so
# oc-mirror needs OCP_SIGNATURE_URL (base URL, must end with "/") and OCP_SIGNATURE_VERIFICATION_PK
# (public key file). ensure_release_signature_env exports both for OKD, leaves a value the user set
# alone, and never touches the environment of an OCP run.
# Offline: the real reg-sync/save/load scripts run in a scratch tree (okd-fixture-lib.sh) where
# oc-mirror is replaced by a function that logs the signature variables it would have inherited.

cd "$(dirname "$0")/../.." || exit 1
ABA_ROOT="$PWD"
source test/func/okd-fixture-lib.sh

pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$(( pass + 1 )); }
bad() { echo "  ✗ $1"; fail=$(( fail + 1 )); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected '$2', got '$3')"; }
has() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1 (missing '$3' in: $(head -c 400 <<<"$2"))"; }
hasnt() { grep -qF -- "$3" <<<"$2" && bad "$1 (unexpected '$3')" || ok "$1"; }
nonzero() { [ "$2" != 0 ] && ok "$1" || bad "$1 (rc was 0)"; }

# Distribution constants: where the signatures live and who signs them.
SIG_URL='https://storage.googleapis.com/openshift-ci-release/releases/signatures/openshift/release/'
KEY_REL=templates/okd-release-signing-key.asc
KEY_FPR=6A9588F07F2D3AE7973AD2A9193E53CCD2E2F7A4
KEY_SHA=19586464328474fa4eabcc6cd7db7fcc96fd9f52baa2a18a8915bbd1b156ae1d

fx_init
trap fx_cleanup EXIT
echo "=== test-okd-release-signature.sh ==="

# oc-mirror stand-in: log the signature variables the real command would inherit.
cat >> "$FX_REPO/scripts/include_all.sh" <<'EOF'
_run_oc_mirror_with_retry() {
	# a child process, like the real oc-mirror: only exported variables arrive
	bash -c 'echo "oc-mirror $0 URL=${OCP_SIGNATURE_URL-<unset>} PK=${OCP_SIGNATURE_VERIFICATION_PK-<unset>}"' "$1" >> "$FX_CALLS"
	mkdir -p data/working-dir/cluster-resources
	return 0
}
EOF

# ------------------------------------------------------------------ key file
echo "--- shipped public key"
[ -s "$KEY_REL" ] && ok "key file shipped" || bad "key file $KEY_REL missing"
eq "key file checksum" "$KEY_SHA" "$(sha256sum "$KEY_REL" 2>/dev/null | cut -d' ' -f1)"
eq "key file is an armored public key" "-----BEGIN PGP PUBLIC KEY BLOCK-----" "$(head -1 "$KEY_REL" 2>/dev/null)"
if command -v gpg >/dev/null; then
	_gh=$(mktemp -d)
	eq "key fingerprint" "$KEY_FPR" "$(GNUPGHOME=$_gh gpg --batch --show-keys --with-colons "$KEY_REL" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
	rm -rf "$_gh"
else
	ok "gpg not installed: fingerprint check skipped"
fi

# ------------------------------------------------------------------ helper
echo "--- ensure_release_signature_env"
fx_fn 'declare -F ensure_release_signature_env >/dev/null && echo defined'
eq "helper is defined" "defined" "$FX_OUT"

sigenv() {  # <fn-args-env-prefix> -> prints "URL=[..] PK=[..]" after the helper ran (distribution from aba.conf)
	fx_fn 'ensure_release_signature_env; echo "URL=[${OCP_SIGNATURE_URL-<unset>}] PK=[${OCP_SIGNATURE_VERIFICATION_PK-<unset>}]"' "${1:-}"
}
KEY_ABS="$FX_REPO/$KEY_REL"

fx_conf okd; FX_ENV=
sigenv
eq "okd: base URL, ends with a slash" "URL=[$SIG_URL] PK=[$KEY_ABS]" "$FX_OUT"
eq "okd: helper rc" 0 "$FX_RC"
fx_fn 'ensure_release_signature_env; [ -s "$OCP_SIGNATURE_VERIFICATION_PK" ] && echo readable; case "$OCP_SIGNATURE_URL" in */) echo slash;; esac; bash -c '"'"'echo child-url=$OCP_SIGNATURE_URL; echo child-key=$OCP_SIGNATURE_VERIFICATION_PK'"'"''
has "okd: key path points at a readable file" "$FX_OUT" "readable"
has "okd: URL ends with /" "$FX_OUT" "slash"
has "okd: URL is exported to children" "$FX_OUT" "child-url=$SIG_URL"
has "okd: key is exported to children" "$FX_OUT" "child-key=$KEY_ABS"
FX_ENV="DEBUG_ABA=1"; sigenv
has "okd: debug output names URL and key" "$FX_OUT" "Release signatures: $SIG_URL key: $KEY_ABS"
FX_ENV=
sigenv "$FX_REPO"
eq "okd from the aba root: same values" "URL=[$SIG_URL] PK=[$KEY_ABS]" "$FX_OUT"
fx_fn 'ensure_release_signature_env; ensure_release_signature_env; echo "URL=[$OCP_SIGNATURE_URL] PK=[$OCP_SIGNATURE_VERIFICATION_PK]"'
eq "okd: second call changes nothing" "URL=[$SIG_URL] PK=[$KEY_ABS]" "$FX_OUT"
# oc-mirror runs in mirror/data: the key path must not depend on the directory
fx_fn 'ensure_release_signature_env; cd data 2>/dev/null || cd /; [ -s "$OCP_SIGNATURE_VERIFICATION_PK" ] && echo ok'
eq "okd: key path is absolute (oc-mirror runs in data/)" "ok" "$FX_OUT"

echo "--- a value the user set wins"
FX_ENV="OCP_SIGNATURE_URL=https://signatures.example.test/base/"; sigenv
eq "user URL kept, key still ours" "URL=[https://signatures.example.test/base/] PK=[$KEY_ABS]" "$FX_OUT"
FX_ENV="OCP_SIGNATURE_VERIFICATION_PK=/etc/user/key.asc"; sigenv
eq "user key kept, URL still ours" "URL=[$SIG_URL] PK=[/etc/user/key.asc]" "$FX_OUT"
FX_ENV="OCP_SIGNATURE_URL=https://signatures.example.test/base/ OCP_SIGNATURE_VERIFICATION_PK=/etc/user/key.asc"; sigenv
eq "both set by the user: both kept" "URL=[https://signatures.example.test/base/] PK=[/etc/user/key.asc]" "$FX_OUT"
FX_ENV="OCP_SIGNATURE_URL=https://signatures.example.test/base"; sigenv
eq "user URL without the slash is not rewritten" "URL=[https://signatures.example.test/base] PK=[$KEY_ABS]" "$(tail -1 <<<"$FX_OUT")"
has "user URL without the slash: warns, names the slash" "$FX_OUT" "end with"
FX_ENV="OCP_SIGNATURE_URL= OCP_SIGNATURE_VERIFICATION_PK="; sigenv
eq "empty user values count as unset" "URL=[$SIG_URL] PK=[$KEY_ABS]" "$FX_OUT"
FX_ENV=
sigenv; hasnt "no warning for the default URL" "$FX_OUT" "end with"

echo "--- the key file is required"
mv "$FX_REPO/$KEY_REL" "$FX_REPO/$KEY_REL.off"
sigenv
nonzero "okd without the key file: rc" "$FX_RC"
has "okd without the key file: names the file" "$FX_OUT" "okd-release-signing-key.asc"
hasnt "okd without the key file: nothing exported" "$FX_OUT" "URL=[$SIG_URL]"
FX_ENV="OCP_SIGNATURE_VERIFICATION_PK=/etc/user/key.asc"; sigenv
eq "okd without the key file but with a user key: fine" "URL=[$SIG_URL] PK=[/etc/user/key.asc]" "$FX_OUT"
FX_ENV=
mv "$FX_REPO/$KEY_REL.off" "$FX_REPO/$KEY_REL"

echo "--- OCP: the environment is left alone"
for _d in ocp ocp-explicit; do
	fx_conf "$_d"; sigenv
	eq "$_d: nothing exported, no output" "URL=[<unset>] PK=[<unset>]" "$FX_OUT"
done
fx_fn 'unset distribution; ensure_release_signature_env; echo "URL=[${OCP_SIGNATURE_URL-<unset>}]"'
eq "no distribution key: treated as ocp" "URL=[<unset>]" "$FX_OUT"
FX_ENV="OCP_SIGNATURE_URL=https://signatures.example.test/base OCP_SIGNATURE_VERIFICATION_PK=/etc/user/key.asc"; sigenv
eq "ocp: user values untouched (not even the slash)" "URL=[https://signatures.example.test/base] PK=[/etc/user/key.asc]" "$FX_OUT"
FX_ENV=

# ------------------------------------------------------------------ call sites
echo "--- reg-sync / reg-save / reg-load pass the variables to oc-mirror"
reset() {  # <okd|ocp>
	rm -rf "$FX_MIR/data" "$FX_MIR/.oc-mirror-exit-code"; mkdir -p "$FX_MIR/data"
	printf 'reg_host=%s\nreg_port=%s\nreg_path=%s\nreg_vendor=docker\n' "$FX_HOST" "$FX_PORT" "$FX_REGPATH" > "$FX_MIR/mirror.conf"
	fx_conf "$1"; fx_state; fx_isc "$1"; fx_calls_reset
}
mk_bundle() {  # <kind> <metadata-json> -> data/aba-transfer.tar + data/mirror_000001.tar
	local kind="$1" meta="$2" t="$FX_ROOT/bundle"
	rm -rf "$t"; mkdir -p "$t/mirror/data"
	fx_isc "$kind"; cp "$FX_MIR/data/imageset-config.yaml" "$t/mirror/data/"
	[ "$meta" != - ] && printf '%s\n' "$meta" > "$t/mirror/data/aba-transfer-metadata.json"
	rm -f "$FX_MIR/data/imageset-config.yaml" "$FX_MIR/data/.created"
	( cd "$t" && tar cf "$FX_MIR/data/aba-transfer.tar" mirror )
	touch "$FX_MIR/data/mirror_000001.tar"
}
okd_meta() { printf '{\n  "ocp_version": "%s",\n  "ocp_channel": "stable",\n  "architecture": "amd64",\n  "created": "2026-01-01T00:00:00Z",\n  "digest_isc_sha256": "",\n  "distribution": "okd",\n  "release_digest": "%s"\n}' "$FX_OKD_VER" "$FX_DIGEST"; }
mirror_line() { fx_calls | grep '^oc-mirror' | head -1; }
FX_PK="$FX_MIR/$KEY_REL"; FX_PK=$(readlink -f "$FX_PK")

for s in sync save; do
	reset okd; FX_ENV=
	fx_run reg-$s.sh
	eq "okd $s: rc" 0 "$FX_RC"
	eq "okd $s: oc-mirror sees URL and key" "oc-mirror $s URL=$SIG_URL PK=$FX_PK" "$(mirror_line)"
	reset okd; FX_ENV="OCP_SIGNATURE_URL=https://signatures.example.test/base/"
	fx_run reg-$s.sh
	eq "okd $s: user URL reaches oc-mirror" "oc-mirror $s URL=https://signatures.example.test/base/ PK=$FX_PK" "$(mirror_line)"
	reset ocp; FX_ENV=
	fx_run reg-$s.sh
	eq "ocp $s: rc" 0 "$FX_RC"
	eq "ocp $s: oc-mirror sees no signature variables" "oc-mirror $s URL=<unset> PK=<unset>" "$(mirror_line)"
	reset ocp; FX_ENV="OCP_SIGNATURE_URL=https://signatures.example.test/base"
	fx_run reg-$s.sh
	eq "ocp $s: user value passes through untouched" "oc-mirror $s URL=https://signatures.example.test/base PK=<unset>" "$(mirror_line)"
done
FX_ENV=

reset okd; mk_bundle okd "$(okd_meta)"
fx_run reg-load.sh
eq "okd load: rc" 0 "$FX_RC"
eq "okd load: oc-mirror sees URL and key" "oc-mirror load URL=$SIG_URL PK=$FX_PK" "$(mirror_line)"
reset ocp; fx_conf ocp; mk_bundle ocp -
fx_run reg-load.sh
eq "ocp load: rc" 0 "$FX_RC"
eq "ocp load: oc-mirror sees no signature variables" "oc-mirror load URL=<unset> PK=<unset>" "$(mirror_line)"

# the key file is checked before oc-mirror starts: a missing file stops the run
reset okd; mv "$FX_REPO/$KEY_REL" "$FX_REPO/$KEY_REL.off"
fx_run reg-sync.sh
nonzero "okd sync without the key file: rc" "$FX_RC"
fx_calls | grep -q '^oc-mirror' && bad "okd sync without the key file: oc-mirror must not run" || ok "okd sync without the key file: oc-mirror not run"
mv "$FX_REPO/$KEY_REL.off" "$FX_REPO/$KEY_REL"

# ------------------------------------------------------------------ audit: ocp_upgrade_to / channels on sync and save
echo "--- OKD sync and save are not blocked by an empty or equal upgrade target, nor by candidate"
for s in sync save; do
	reset okd; printf 'ocp_upgrade_to=\n' >> "$FX_MIR/mirror.conf"; fx_run reg-$s.sh
	eq "okd $s with an empty ocp_upgrade_to: rc" 0 "$FX_RC"
	reset okd; printf 'ocp_upgrade_to=%s\n' "$FX_OKD_VER" >> "$FX_MIR/mirror.conf"; fx_run reg-$s.sh
	eq "okd $s with ocp_upgrade_to equal to ocp_version: rc" 0 "$FX_RC"
	reset okd; fx_conf okd ocp_channel=candidate; fx_run reg-$s.sh
	eq "okd $s with the candidate channel: rc" 0 "$FX_RC"
done

echo
echo "release signature environment: $pass passed, $fail failed"
[ "$fail" = 0 ]
