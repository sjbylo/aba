#!/bin/bash
# test-okd-mirror-flows.sh -- reg-sync / reg-save / reg-load record and check the OKD release identity
#
# The real scripts run in a scratch tree (okd-fixture-lib.sh); oc-mirror, registry probes and release
# lookups are replaced. OCP runs must leave state.sh and the transfer tar exactly as before.

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
mirror_ran() { fx_calls | grep -q '^oc-mirror'; }
key() { grep "^$1=" "$FX_STATE" | head -1 | cut -d= -f2-; }

fx_init
trap fx_cleanup EXIT
echo "=== test-okd-mirror-flows.sh ==="
M="$FX_MIR/data/aba-transfer-metadata.json"

reset() {  # <okd|ocp>  fresh data dir, state of a just-installed registry, calls log
	rm -rf "$FX_MIR/data" "$FX_MIR/.oc-mirror-exit-code"; mkdir -p "$FX_MIR/data"
	printf 'reg_host=%s\nreg_port=%s\nreg_path=%s\nreg_vendor=docker\n' "$FX_HOST" "$FX_PORT" "$FX_REGPATH" > "$FX_MIR/mirror.conf"
	fx_conf "$1"; fx_state; fx_isc "$1"; fx_calls_reset
}

# ================================================================ reg-sync.sh
echo "--- reg-sync: OKD records distribution and release digest"
reset okd
fx_run reg-sync.sh
eq "okd sync: rc" 0 "$FX_RC"
eq "okd sync: distribution" "okd" "$(key distribution)"
eq "okd sync: mirror_release_digest" "$FX_DIGEST" "$(key mirror_release_digest)"
eq "okd sync: mirror_ocp_version" "$FX_OKD_VER" "$(key mirror_ocp_version)"
eq "okd sync: last_action" "sync" "$(key last_action)"

echo "--- reg-sync: OCP state.sh carries neither key"
reset ocp
fx_run reg-sync.sh
eq "ocp sync: rc" 0 "$FX_RC"
eq "ocp sync: no distribution" "0" "$(grep -c '^distribution=' "$FX_STATE")"
eq "ocp sync: no mirror_release_digest" "0" "$(grep -c '^mirror_release_digest=' "$FX_STATE")"
eq "ocp sync: mirror_ocp_version" "$FX_OCP_VER" "$(key mirror_ocp_version)"
reset ocp-explicit
fx_run reg-sync.sh
eq "ocp (distribution=ocp in aba.conf) sync: no distribution line" "0" "$(grep -c '^distribution=' "$FX_STATE")"

echo "--- reg-sync: digest unknown -> warn, distribution still recorded"
reset okd
sed -i '/release:/d' "$FX_MIR/data/imageset-config.yaml"
fx_run reg-sync.sh
eq "okd sync without digest: rc" 0 "$FX_RC"
has "okd sync without digest: warns" "$FX_OUT" "release digest"
eq "okd sync without digest: distribution recorded" "okd" "$(key distribution)"
eq "okd sync without digest: no digest key" "0" "$(grep -c '^mirror_release_digest=' "$FX_STATE")"
reset okd; fx_conf okd excl_platform=true
sed -i '/release:/d' "$FX_MIR/data/imageset-config.yaml"
fx_run reg-sync.sh
eq "okd sync with excl_platform: rc" 0 "$FX_RC"
hasnt "okd sync with excl_platform: no digest warning (no release is mirrored)" "$FX_OUT" "release digest"
eq "okd sync with excl_platform: distribution recorded" "okd" "$(key distribution)"

echo "--- reg-sync: mirror holds the other distribution -> abort before oc-mirror"
reset okd; fx_state "mirror_ocp_version=$FX_OCP_VER" "last_action=sync"
fx_run reg-sync.sh
nonzero "okd conf, ocp content: rc" "$FX_RC"
has "okd conf, ocp content: message" "$FX_OUT" "distribution"
mirror_ran && bad "okd conf, ocp content: oc-mirror must not run" || ok "okd conf, ocp content: oc-mirror not run"
eq "okd conf, ocp content: state untouched" "0" "$(grep -c '^distribution=' "$FX_STATE")"
reset ocp; fx_state "distribution=okd" "mirror_ocp_version=$FX_OKD_VER" "mirror_release_digest=$FX_DIGEST"
fx_run reg-sync.sh
nonzero "ocp conf, okd content: rc" "$FX_RC"
mirror_ran && bad "ocp conf, okd content: oc-mirror must not run" || ok "ocp conf, okd content: oc-mirror not run"

echo "--- reg-sync: unsupported operations abort for OKD"
reset okd
printf 'ocp_upgrade_to=9.8.9-okd-scos.7\n' >> "$FX_MIR/mirror.conf"
fx_run reg-sync.sh
nonzero "okd + ocp_upgrade_to: rc" "$FX_RC"
has "okd + ocp_upgrade_to: message" "$FX_OUT" "unsupported for OKD in ABA"
mirror_ran && bad "okd + ocp_upgrade_to: oc-mirror must not run" || ok "okd + ocp_upgrade_to: oc-mirror not run"
reset okd
printf 'ocp_upgrade_to=%s\n' "$FX_OKD_VER" >> "$FX_MIR/mirror.conf"
fx_run reg-sync.sh
eq "okd + ocp_upgrade_to equal to ocp_version is not an upgrade" 0 "$FX_RC"
reset okd; fx_conf okd op_sets=acm
fx_run reg-sync.sh
nonzero "okd + op_sets: rc" "$FX_RC"
has "okd + op_sets: message" "$FX_OUT" "unsupported for OKD in ABA"
has "okd + op_sets: hint to clear" "$FX_OUT" "aba --op-sets"
reset ocp; fx_conf ocp op_sets=acm
fx_run reg-sync.sh
hasnt "ocp + op_sets: not blocked" "$FX_OUT" "unsupported for OKD"

# ================================================================ reg-save.sh
echo "--- reg-save: OKD bundle always carries its identity"
tarlist() { tar tf "$FX_MIR/data/aba-transfer.tar" 2>/dev/null | sort | tr '\n' ' '; }
reset okd
fx_run reg-save.sh
eq "okd save: rc" 0 "$FX_RC"
eq "okd save: tar content" "mirror/data/aba-transfer-metadata.json mirror/data/imageset-config.yaml " "$(tarlist)"
mt="$FX_ROOT/meta.json"; tar xOf "$FX_MIR/data/aba-transfer.tar" mirror/data/aba-transfer-metadata.json > "$mt" 2>/dev/null
eq "okd save: metadata is valid JSON" "true" "$(jq -e . "$mt" >/dev/null 2>&1 && echo true || echo false)"
eq "okd save: ocp_version" "$FX_OKD_VER" "$(jq -r .ocp_version "$mt" 2>/dev/null)"
eq "okd save: ocp_channel" "stable" "$(jq -r .ocp_channel "$mt" 2>/dev/null)"
eq "okd save: distribution" "okd" "$(jq -r .distribution "$mt" 2>/dev/null)"
eq "okd save: release_digest" "$FX_DIGEST" "$(jq -r .release_digest "$mt" 2>/dev/null)"
eq "okd save: no stray metadata left in data/" "no" "$([ -f "$M" ] && echo yes || echo no)"
reset okd
printf 'ocp_upgrade_to=9.8.9-okd-scos.7\n' >> "$FX_MIR/mirror.conf"
fx_run reg-save.sh
nonzero "okd save + ocp_upgrade_to: rc" "$FX_RC"
has "okd save + ocp_upgrade_to: message" "$FX_OUT" "unsupported for OKD in ABA"
mirror_ran && bad "okd save + ocp_upgrade_to: oc-mirror must not run" || ok "okd save + ocp_upgrade_to: oc-mirror not run"
reset okd; fx_conf okd ocp_channel=candidate
fx_run reg-save.sh
tar xOf "$FX_MIR/data/aba-transfer.tar" mirror/data/aba-transfer-metadata.json > "$mt" 2>/dev/null
eq "okd save: the configured channel is recorded" "candidate" "$(jq -r .ocp_channel "$mt" 2>/dev/null)"
reset okd; sed -i '/release:/d' "$FX_MIR/data/imageset-config.yaml"
fx_run reg-save.sh
eq "okd save without a release line: rc" 0 "$FX_RC"
has "okd save without a release line: warns" "$FX_OUT" "No release digest found"
reset okd; fx_conf okd excl_platform=true; sed -i '/release:/d' "$FX_MIR/data/imageset-config.yaml"
fx_run reg-save.sh
hasnt "okd save with excl_platform: no warning (no release is mirrored)" "$FX_OUT" "No release digest found"
eq "okd save with excl_platform: the bundle still says okd" "okd" "$(tar xOf "$FX_MIR/data/aba-transfer.tar" mirror/data/aba-transfer-metadata.json 2>/dev/null | jq -r .distribution 2>/dev/null)"
reset okd
printf 'x: 1\n' > "$FX_MIR/data/imageset-config-digest.yaml"
fx_run reg-save.sh
eq "okd save with a digest ISC: rc" 0 "$FX_RC"
tar xOf "$FX_MIR/data/aba-transfer.tar" mirror/data/aba-transfer-metadata.json > "$mt" 2>/dev/null
eq "okd save with a digest ISC: its checksum is in the metadata" "$(sha256sum "$FX_MIR/data/imageset-config-digest.yaml" | cut -d' ' -f1)" "$(jq -r .digest_isc_sha256 "$mt" 2>/dev/null)"
reset okd; fx_conf okd op_sets=odf
fx_run reg-save.sh
nonzero "okd save + op_sets: rc" "$FX_RC"
has "okd save + op_sets: message" "$FX_OUT" "unsupported for OKD in ABA"
reset okd; fx_state "mirror_ocp_version=$FX_OCP_VER" "last_action=sync"
fx_run reg-save.sh
eq "okd save does not look at the mirror state (connected side)" 0 "$FX_RC"

echo "--- reg-save: OCP bundle is unchanged"
reset ocp
fx_run reg-save.sh
eq "ocp save: rc" 0 "$FX_RC"
eq "ocp save: only the ISC in the tar (no metadata without upgrade)" "mirror/data/imageset-config.yaml " "$(tarlist)"
reset ocp
printf 'ocp_upgrade_to=7.6.9\n' >> "$FX_MIR/mirror.conf"
fx_run reg-save.sh
eq "ocp upgrade save: rc" 0 "$FX_RC"
tar xOf "$FX_MIR/data/aba-transfer.tar" mirror/data/aba-transfer-metadata.json 2>/dev/null | sed 's/"created": ".*"/"created": "T"/' > "$mt"
eq "ocp upgrade save: metadata keys exactly as before" "architecture,created,digest_isc_sha256,ocp_channel,ocp_version" "$(jq -r 'keys|join(",")' "$mt" 2>/dev/null)"
eq "ocp upgrade save: ocp_version is the target" "7.6.9" "$(jq -r .ocp_version "$mt" 2>/dev/null)"

# ================================================================ reg-load.sh
mk_bundle() {  # <kind> <metadata-json|-> [extra tar members: none]  -> data/aba-transfer.tar + data/mirror_000001.tar
	local kind="$1" meta="$2" t="$FX_ROOT/bundle"
	rm -rf "$t"; mkdir -p "$t/mirror/data"
	fx_isc "$kind" "${3:-$FX_DIGEST}"; cp "$FX_MIR/data/imageset-config.yaml" "$t/mirror/data/"
	[ "${4:-}" = norelease ] && sed -i '/release:/d' "$t/mirror/data/imageset-config.yaml"
	[ "$meta" != - ] && printf '%s\n' "$meta" > "$t/mirror/data/aba-transfer-metadata.json"
	rm -f "$FX_MIR/data/imageset-config.yaml" "$FX_MIR/data/.created"
	( cd "$t" && tar cf "$FX_MIR/data/aba-transfer.tar" mirror )
	touch "$FX_MIR/data/mirror_000001.tar"
}
meta_json() {  # <version> <dist|-> <digest|->
	printf '{\n  "ocp_version": "%s",\n  "ocp_channel": "stable",\n  "architecture": "amd64",\n  "created": "2026-01-01T00:00:00Z",\n  "digest_isc_sha256": ""' "$1"
	[ "$2" != - ] && printf ',\n  "distribution": "%s"' "$2"
	[ "$3" != - ] && printf ',\n  "release_digest": "%s"' "$3"
	printf '\n}'
}

echo "--- reg-load: OKD bundle verified, identity recorded"
reset okd; mk_bundle okd "$(meta_json "$FX_OKD_VER" okd "$FX_DIGEST")"
fx_run reg-load.sh
eq "okd load: rc" 0 "$FX_RC"
eq "okd load: distribution" "okd" "$(key distribution)"
eq "okd load: mirror_release_digest" "$FX_DIGEST" "$(key mirror_release_digest)"
eq "okd load: mirror_ocp_version from metadata" "$FX_OKD_VER" "$(key mirror_ocp_version)"
eq "okd load: last_action" "load" "$(key last_action)"
eq "okd load: skip marker written by the real load" "yes" "$([ -f "$FX_MIR/data/.images-loaded" ] && echo yes || echo no)"
hasnt "okd load: no unknown-version warning" "$FX_OUT" "release version"

echo "--- reg-load: a second load without the transfer tar reads the version from the metadata of the first"
rm -f "$FX_MIR/data/aba-transfer.tar"; sed -i '/^mirror_ocp_version=/d' "$FX_STATE"; fx_calls_reset
fx_run reg-load.sh
eq "second okd load without a tar: rc" 0 "$FX_RC"
eq "second okd load without a tar: version from the metadata left by the first" "$FX_OKD_VER" "$(key mirror_ocp_version)"
hasnt "second okd load without a tar: no unknown-version warning" "$FX_OUT" "release version"

echo "--- reg-load: bundle without OKD identity is rejected (older bundle or OCP content)"
reset okd; mk_bundle okd -
fx_run reg-load.sh
nonzero "okd conf, no metadata: rc" "$FX_RC"
has "okd conf, no metadata: says to save again" "$FX_OUT" "aba -d mirror save"
mirror_ran && bad "okd conf, no metadata: oc-mirror must not run" || ok "okd conf, no metadata: oc-mirror not run"
eq "okd conf, no metadata: no skip marker (the load did not happen)" "no" "$([ -f "$FX_MIR/data/.images-loaded" ] && echo yes || echo no)"
eq "okd conf, no metadata: no distribution recorded" "0" "$(grep -c '^distribution=' "$FX_STATE")"
reset okd; mk_bundle ocp "$(meta_json "$FX_OCP_VER" - -)"
fx_run reg-load.sh
nonzero "okd conf, ocp bundle: rc" "$FX_RC"
mirror_ran && bad "okd conf, ocp bundle: oc-mirror must not run" || ok "okd conf, ocp bundle: oc-mirror not run"
reset ocp; mk_bundle okd "$(meta_json "$FX_OKD_VER" okd "$FX_DIGEST")"
fx_run reg-load.sh
nonzero "ocp conf, okd bundle: rc" "$FX_RC"
has "ocp conf, okd bundle: message" "$FX_OUT" "OKD"
mirror_ran && bad "ocp conf, okd bundle: oc-mirror must not run" || ok "ocp conf, okd bundle: oc-mirror not run"

echo "--- reg-load: config-only transfer is checked too"
reset okd; mk_bundle ocp "$(meta_json "$FX_OCP_VER" - -)"; rm -f "$FX_MIR/data/mirror_000001.tar"
fx_run reg-load.sh
nonzero "config-only ocp bundle on okd conf: rc" "$FX_RC"
reset okd; mk_bundle okd "$(meta_json "$FX_OKD_VER" okd "$FX_DIGEST")"; rm -f "$FX_MIR/data/mirror_000001.tar"
fx_run reg-load.sh
eq "config-only okd bundle on okd conf: rc" 0 "$FX_RC"

echo "--- reg-load: version and digest must agree"
reset okd; mk_bundle okd "$(meta_json "$FX_OKD_VER2" okd "$FX_DIGEST")"
fx_run reg-load.sh
nonzero "bundle version differs from aba.conf: rc" "$FX_RC"
has "bundle version differs: unsupported" "$FX_OUT" "unsupported for OKD in ABA"
mirror_ran && bad "bundle version differs: oc-mirror must not run" || ok "bundle version differs: oc-mirror not run"
reset okd; mk_bundle okd "$(meta_json "$FX_OKD_VER" okd "$FX_DIGEST2")"
fx_run reg-load.sh
nonzero "metadata digest differs from the ISC digest: rc" "$FX_RC"
has "digest conflict: message" "$FX_OUT" "digest"
mirror_ran && bad "digest conflict: oc-mirror must not run" || ok "digest conflict: oc-mirror not run"

reset okd; mk_bundle okd "$(meta_json "$FX_OKD_VER" okd "$FX_DIGEST")" "$FX_DIGEST" norelease
fx_run reg-load.sh
eq "metadata digest, ISC without a release line: no conflict, rc" 0 "$FX_RC"
eq "metadata digest, ISC without a release line: digest from the metadata" "$FX_DIGEST" "$(key mirror_release_digest)"

echo "--- reg-load: registry holds the other distribution"
reset okd; mk_bundle okd "$(meta_json "$FX_OKD_VER" okd "$FX_DIGEST")"; fx_state "mirror_ocp_version=$FX_OCP_VER" "last_action=sync"
fx_run reg-load.sh
nonzero "okd load into an ocp mirror: rc" "$FX_RC"
mirror_ran && bad "okd load into an ocp mirror: oc-mirror must not run" || ok "okd load into an ocp mirror: oc-mirror not run"

echo "--- reg-load: no transfer tar -> version unknown is a warning, not silence"
reset okd; touch "$FX_MIR/data/mirror_000001.tar"
fx_run reg-load.sh
eq "okd load without transfer tar: rc" 0 "$FX_RC"
has "okd load without transfer tar: tar warning (existing)" "$FX_OUT" "No aba-transfer.tar"
has "okd load without transfer tar: version warning" "$FX_OUT" "release version"
eq "okd load without transfer tar: digest from the local ISC" "$FX_DIGEST" "$(key mirror_release_digest)"
eq "okd load without transfer tar: version not guessed" "0" "$(grep -c '^mirror_ocp_version=' "$FX_STATE")"

echo "--- reg-load: OCP is unchanged"
reset ocp; mk_bundle ocp -
fx_run reg-load.sh
eq "ocp load: rc" 0 "$FX_RC"
eq "ocp load: mirror_ocp_version from the ISC" "$FX_OCP_VER" "$(key mirror_ocp_version)"
eq "ocp load: no distribution" "0" "$(grep -c '^distribution=' "$FX_STATE")"
eq "ocp load: no digest" "0" "$(grep -c '^mirror_release_digest=' "$FX_STATE")"
hasnt "ocp load: no new warning" "$FX_OUT" "release version"
reset ocp; mk_bundle ocp "$(meta_json "$FX_OCP_VER" - -)"
fx_run reg-load.sh
eq "ocp load with metadata: rc" 0 "$FX_RC"
eq "ocp load with metadata: mirror_ocp_version" "$FX_OCP_VER" "$(key mirror_ocp_version)"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
