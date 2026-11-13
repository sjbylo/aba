#!/bin/bash
# test-okd-state-identity.sh -- release identity of the three states (aba.conf, mirror state, cluster state)
#
# The distribution and the release digest are recorded only for OKD; every OCP result stays exactly
# as it was and readers default to ocp. Real functions and scripts run in a scratch tree; only the
# transports are replaced (see okd-fixture-lib.sh). No network.

cd "$(dirname "$0")/../.." || exit 1
ABA_ROOT="$PWD"
source test/func/okd-fixture-lib.sh

pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$(( pass + 1 )); }
bad() { echo "  ✗ $1"; fail=$(( fail + 1 )); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected '$2', got '$3')"; }
has() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1 (missing '$3' in: $(head -c 300 <<<"$2"))"; }
hasnt() { grep -qF -- "$3" <<<"$2" && bad "$1 (unexpected '$3')" || ok "$1"; }

fx_init
trap fx_cleanup EXIT
echo "=== test-okd-state-identity.sh ==="

# ---------------------------------------------------------------- _isc_release_version
echo "--- _isc_release_version: channels -> maxVersion, else transfer metadata"
fx_isc ocp
printf '{\n  "ocp_version": "%s",\n  "ocp_channel": "stable"\n}\n' "$FX_OKD_VER2" > "$FX_MIR/data/meta.json"
fx_fn '_isc_release_version data/imageset-config.yaml'
eq "ISC with channels: maxVersion" "$FX_OCP_VER" "$FX_OUT"
fx_fn '_isc_release_version data/imageset-config.yaml data/meta.json'
eq "ISC with channels wins over metadata" "$FX_OCP_VER" "$FX_OUT"
sed -i "s/minVersion: .*/minVersion: 7.6.1/" "$FX_MIR/data/imageset-config.yaml"
fx_fn '_isc_release_version data/imageset-config.yaml'
eq "ISC with a version range: the upper end" "$FX_OCP_VER" "$FX_OUT"
fx_isc okd
fx_fn '_isc_release_version data/imageset-config.yaml data/meta.json'
eq "ISC without channels: metadata version" "$FX_OKD_VER2" "$FX_OUT"
fx_fn '_isc_release_version data/imageset-config.yaml'
eq "ISC without channels and no metadata: empty" "" "$FX_OUT"
fx_fn '_isc_release_version data/imageset-config.yaml data/missing.json'
eq "missing metadata file: empty" "" "$FX_OUT"
fx_fn '_isc_release_version data/missing.yaml data/meta.json'
eq "missing ISC: metadata version" "$FX_OKD_VER2" "$FX_OUT"

# ---------------------------------------------------------------- _isc_release_digest
echo "--- _isc_release_digest: digest of platform.release, never a tag"
fx_fn '_isc_release_digest data/imageset-config.yaml'
eq "digest ref" "$FX_DIGEST" "$FX_OUT"
fx_isc ocp
fx_fn '_isc_release_digest data/imageset-config.yaml'
eq "ISC without platform.release: empty" "" "$FX_OUT"
sed -i "s#^    graph: true#    release: quay.io/okd/scos-release:${FX_OKD_VER}\n    graph: false#" "$FX_MIR/data/imageset-config.yaml"
fx_fn '_isc_release_digest data/imageset-config.yaml'
eq "tag ref is not a digest: empty" "" "$FX_OUT"
fx_isc okd "sha256:zz"
fx_fn '_isc_release_digest data/imageset-config.yaml'
eq "malformed digest: empty" "" "$FX_OUT"
fx_isc okd; sed -i 's#scos-release@sha256#scos-release:sha256#' "$FX_MIR/data/imageset-config.yaml"
fx_fn '_isc_release_digest data/imageset-config.yaml'
eq "digest without @: empty" "" "$FX_OUT"
fx_isc okd "${FX_DIGEST}00"
fx_fn '_isc_release_digest data/imageset-config.yaml'
eq "digest with trailing characters: empty" "" "$FX_OUT"

# ---------------------------------------------------------------- cluster_installed_distribution
echo "--- cluster_installed_distribution"
CD="$FX_ROOT/cl"; mkdir -p "$CD"
fx_fn 'cluster_installed_distribution .' "$CD"; rc=$FX_RC
eq "no state: returns 1" 1 "$rc"; eq "no state: prints nothing" "" "$FX_OUT"
printf 'cluster_name=c1\nplatform=kvm\n' > "$CD/state.sh"
fx_fn 'cluster_installed_distribution .' "$CD"
eq "state without the key is ocp" "ocp" "$FX_OUT"; eq "state without the key: rc 0" 0 "$FX_RC"
printf 'cluster_name=c1\nplatform=kvm\ndistribution=okd\nrelease_digest=%s\n' "$FX_DIGEST" > "$CD/state.sh"
fx_fn 'cluster_installed_distribution .' "$CD"
eq "state distribution=okd" "okd" "$FX_OUT"
mkdir -p "$CD/clusterstate"; printf 'distribution=ocp\n' > "$CD/clusterstate/state.sh"
fx_fn 'cluster_installed_distribution .' "$CD"
eq "clusterstate/state.sh is preferred over state.sh" "ocp" "$FX_OUT"
printf "distribution='okd' # note\n" > "$CD/clusterstate/state.sh"
fx_fn 'cluster_installed_distribution .' "$CD"
eq "quotes and trailing comment are stripped" "okd" "$FX_OUT"
printf 'distribution=bogus\n' > "$CD/clusterstate/state.sh"
fx_fn 'cluster_installed_distribution .' "$CD"
eq "unknown value is treated as ocp" "ocp" "$FX_OUT"
fx_fn 'cluster_installed_distribution' "$CD"
eq "default directory is the working directory" "ocp" "$FX_OUT"
printf 'cluster_name=c1\n' > "$CD/clusterstate/state.sh"
fx_fn 'set -eo pipefail; cluster_installed_distribution .; echo reached' "$CD"
eq "state without the key under errexit: prints ocp and carries on" "ocp reached" "$(tr '\n' ' ' <<<"$FX_OUT" | sed 's/ *$//')"
rm -rf "$CD"

# ---------------------------------------------------------------- okd_release_detected
echo "--- okd_release_detected: by version tag or by payload image, never by default"
fx_fn "okd_release_detected $FX_OKD_VER ''"; eq "okd version tag" 0 "$FX_RC"
fx_fn "okd_release_detected '' quay.io/okd/scos-release@$FX_DIGEST"; eq "okd payload image" 0 "$FX_RC"
fx_fn "okd_release_detected $FX_OCP_VER quay.io/openshift-release-dev/ocp-release@$FX_DIGEST"; eq "ocp version and image" 1 "$FX_RC"
fx_fn "okd_release_detected '' ''"; eq "nothing known" 1 "$FX_RC"
fx_fn "unset _ABA_OKD_PAYLOAD_REPO; okd_release_detected $FX_OCP_VER quay.io/openshift-release-dev/ocp-release@$FX_DIGEST"
eq "empty payload constant does not match every image" 1 "$FX_RC"

# ---------------------------------------------------------------- mirror state helpers
echo "--- mirror state: record only for okd, readers default to ocp"
S="$FX_ROOT/state.sh"
printf 'reg_host=h\nreg_port=1\nmirror_ocp_version=%s\n' "$FX_OCP_VER" > "$S"
cp "$S" "$S.orig"
fx_conf ocp
fx_fn "okd_record_mirror_state $S $FX_DIGEST"
eq "ocp: state.sh is left byte-identical" "" "$(cmp "$S" "$S.orig" 2>&1)"
fx_conf ocp-explicit
fx_fn "okd_record_mirror_state $S $FX_DIGEST"
eq "ocp (explicit): state.sh is left byte-identical" "" "$(cmp "$S" "$S.orig" 2>&1)"
fx_conf okd
fx_fn "okd_record_mirror_state $S $FX_DIGEST"
eq "okd: distribution recorded" "distribution=okd" "$(grep '^distribution=' "$S")"
eq "okd: digest recorded" "mirror_release_digest=$FX_DIGEST" "$(grep '^mirror_release_digest=' "$S")"
eq "okd: other keys preserved" "3" "$(grep -c -E '^(reg_host|reg_port|mirror_ocp_version)=' "$S")"
fx_fn "okd_record_mirror_state $S $FX_DIGEST2"
eq "okd: second record replaces the digest" "mirror_release_digest=$FX_DIGEST2" "$(grep '^mirror_release_digest=' "$S")"
eq "okd: no duplicate keys" "1" "$(grep -c '^mirror_release_digest=' "$S")"
fx_fn "okd_record_mirror_state $S ''"
has "okd: empty digest warns" "$FX_OUT" "release digest"
eq "okd: empty digest keeps the previous one" "mirror_release_digest=$FX_DIGEST2" "$(grep '^mirror_release_digest=' "$S")"

fx_fn "mirror_recorded_distribution $S"
eq "recorded distribution okd" "okd" "$FX_OUT"
fx_fn "mirror_recorded_distribution $S.orig"
eq "state without key reads as ocp" "ocp" "$FX_OUT"
fx_fn "mirror_recorded_distribution $FX_ROOT/none.sh"
eq "missing state reads as ocp" "ocp" "$FX_OUT"
printf 'distribution=bogus\n' > "$S.bogus"
fx_fn "mirror_recorded_distribution $S.bogus"
eq "unknown recorded value reads as ocp" "ocp" "$FX_OUT"
printf '{\n  "release_digest_prev": "sha256:aa",\n  "release_digest": "%s"\n}\n' "$FX_DIGEST" > "$FX_ROOT/meta-keys.json"
fx_fn "_transfer_meta_value $FX_ROOT/meta-keys.json release_digest"
eq "metadata key is matched whole, not by prefix" "$FX_DIGEST" "$FX_OUT"

echo "--- mirror_distribution_guard: mismatch is an error, an empty registry is not"
: > "$S.empty"; printf 'reg_host=h\nreg_status=installed\n' > "$S.empty"
printf 'reg_host=h\ndistribution=okd\nmirror_ocp_version=%s\nmirror_release_digest=%s\n' "$FX_OKD_VER" "$FX_DIGEST" > "$S.okd"
printf 'reg_host=h\nmirror_ocp_version=%s\n' "$FX_OCP_VER" > "$S.ocp"
for pair in "ocp:$S.empty:0" "ocp:$S.ocp:0" "ocp:$S.okd:1" "okd:$S.empty:0" "okd:$S.ocp:1" "okd:$S.okd:0" "ocp:$FX_ROOT/none.sh:0"; do
	c="${pair%%:*}"; rest="${pair#*:}"; f="${rest%:*}"; want="${rest##*:}"
	fx_conf "$c"
	fx_fn "mirror_distribution_guard $f"
	eq "aba.conf=$c, state=$(basename "$f"): rc" "$want" "$FX_RC"
	[ "$want" = 1 ] && has "  message names both distributions" "$FX_OUT" "distribution"
	[ "$want" = 0 ] && eq "  silent when consistent" "" "$FX_OUT"
done

echo "--- _state_override_mirror exports the digest, never the distribution"
fx_conf okd
mkdir -p "$FX_HOME/.aba/mirror/mirror"
printf 'reg_host=h.example\nreg_port=8443\ndistribution=okd\nmirror_ocp_version=%s\nmirror_release_digest=%s\n' "$FX_OKD_VER" "$FX_DIGEST" > "$FX_STATE"
fx_fn 'normalize-mirror-conf'
has "mirror_release_digest exported" "$FX_OUT" "export mirror_release_digest='$FX_DIGEST'"
hasnt "distribution is not exported from the mirror state" "$FX_OUT" "export distribution="
printf 'reg_host=h.example\nreg_port=8443\nmirror_ocp_version=%s\n' "$FX_OCP_VER" > "$FX_STATE"
fx_fn 'normalize-mirror-conf'
hasnt "no digest line when the state has none" "$FX_OUT" "mirror_release_digest"

echo "--- bundle_distribution_guard"
M="$FX_MIR/data/aba-transfer-metadata.json"; rm -f "$M"
printf '{\n  "ocp_version": "%s",\n  "distribution": "okd",\n  "release_digest": "%s"\n}\n' "$FX_OKD_VER" "$FX_DIGEST" > "$M.okd"
printf '{\n  "ocp_version": "%s",\n  "ocp_channel": "stable"\n}\n' "$FX_OCP_VER" > "$M.ocp"
fx_conf ocp; fx_fn "bundle_distribution_guard $M.ocp";  eq "ocp conf, ocp bundle" 0 "$FX_RC"
fx_conf ocp; fx_fn "bundle_distribution_guard $M";       eq "ocp conf, no metadata" 0 "$FX_RC"
fx_conf okd; fx_fn "bundle_distribution_guard $M.okd";  eq "okd conf, okd bundle" 0 "$FX_RC"
fx_conf okd; fx_fn "bundle_distribution_guard $M.ocp";  eq "okd conf, ocp metadata: abort" 1 "$FX_RC"
fx_conf okd; fx_fn "bundle_distribution_guard $M";       eq "okd conf, no metadata: abort" 1 "$FX_RC"
has "  old-bundle message says to save again" "$FX_OUT" "aba -d mirror save"
fx_conf ocp; fx_fn "bundle_distribution_guard $M.okd";  eq "ocp conf, okd bundle: abort" 1 "$FX_RC"
has "  message tells how to switch" "$FX_OUT" "--distribution okd"

# ---------------------------------------------------------------- externalize_cluster_state
echo "--- externalize_cluster_state: distribution and release digest for okd only, immutable"
EX="$FX_REPO/ex1"; EXS="$FX_HOME/.aba/clusters/ex1.example.test"
mk_ex() {  # <image_source> -- fresh cluster dir
	rm -rf "$EX" "$EXS"; mkdir -p "$EX"
	ln -s ../scripts "$EX/scripts"; ln -s ../templates "$EX/templates"; ln -s ../aba.conf "$EX/aba.conf"
	printf 'cluster_name=ex1\nbase_domain=example.test\nstarting_ip=10.0.0.10\nmachine_network=10.0.0.0/24\nnum_masters=1\nnum_workers=0\nimage_source=%s\n' "$1" > "$EX/cluster.conf"
}
oi_shim() {  # <digest|-> -- openshift-install that reports a release image
	if [ "$1" = - ]; then printf '#!/bin/bash\nexit 1\n' > "$FX_BIN/openshift-install"
	else printf '#!/bin/bash\necho "openshift-install %s"\necho "built from image sha256:%s"\necho "release image quay.io/okd/scos-release@%s"\n' "$FX_OKD_VER" "$(printf 'ab%.0s' $(seq 32))" "$1" > "$FX_BIN/openshift-install"; fi
	chmod +x "$FX_BIN/openshift-install"
}
st() { grep "^$1=" "$EXS/state.sh" | head -1 | cut -d= -f2-; }
oi_shim -
mk_ex mirror; fx_conf ocp; fx_fn 'externalize_cluster_state' "$EX"
eq "ocp: state.sh written" "yes" "$([ -s "$EXS/state.sh" ] && echo yes || echo no)"
eq "ocp: no distribution line" "0" "$(grep -c '^distribution=' "$EXS/state.sh")"
eq "ocp: no release_digest line" "0" "$(grep -c '^release_digest=' "$EXS/state.sh")"
eq "ocp: same 12 lines as before" "12" "$(grep -c '' "$EXS/state.sh")"
fx_fn 'cluster_installed_distribution .' "$EX"
eq "ocp: reads back as ocp" "ocp" "$FX_OUT"

mk_ex mirror; fx_conf okd; fx_state "mirror_ocp_version=$FX_OKD_VER" "distribution=okd" "mirror_release_digest=$FX_DIGEST"
oi_shim "$FX_DIGEST2"   # the installer's digest, not the per-arch digest the mirror recorded
fx_fn 'externalize_cluster_state' "$EX"
eq "okd mirror: distribution" "okd" "$(st distribution)"
eq "okd mirror: release_digest is the installer's" "$FX_DIGEST2" "$(st release_digest)"
eq "okd mirror: the mirror state is not used" "0" "$(grep -c "$FX_DIGEST" "$EXS/state.sh")"
eq "okd mirror: platform line unchanged" "bm" "$(st platform)"
fx_fn 'cluster_installed_distribution .' "$EX"
eq "okd: reads back as okd" "okd" "$FX_OUT"

mk_ex direct; fx_conf okd; rm -f "$FX_STATE"
oi_shim "$FX_DIGEST2"
fx_fn 'externalize_cluster_state' "$EX"
eq "okd direct: distribution" "okd" "$(st distribution)"
eq "okd direct: release_digest from the installer" "$FX_DIGEST2" "$(st release_digest)"

mk_ex direct; fx_conf okd; oi_shim -
fx_fn 'externalize_cluster_state' "$EX"
eq "okd, digest unknown: distribution still recorded" "okd" "$(st distribution)"
eq "okd, digest unknown: empty release_digest" "" "$(st release_digest)"
has "okd, digest unknown: warns" "$FX_OUT" "release digest"

mk_ex direct; fx_conf okd; oi_shim "$FX_DIGEST"
fx_fn 'externalize_cluster_state' "$EX"
fx_conf ocp; oi_shim "$FX_DIGEST2"      # aba.conf changed afterwards: the installed cluster keeps its identity
fx_fn 'externalize_cluster_state' "$EX"
eq "immutable: still okd after aba.conf changed" "okd" "$(st distribution)"
eq "immutable: digest unchanged" "$FX_DIGEST" "$(st release_digest)"
eq "immutable: not duplicated" "1" "$(grep -c '^release_digest=' "$EXS/state.sh")"

mk_ex direct; fx_conf ocp; oi_shim -
fx_fn 'externalize_cluster_state' "$EX"
fx_conf okd; oi_shim "$FX_DIGEST"       # an installed ocp cluster is not relabelled either
fx_fn 'externalize_cluster_state' "$EX"
eq "immutable: ocp stays ocp after aba.conf changed to okd" "0" "$(grep -c '^distribution=' "$EXS/state.sh")"
rm -rf "$EX" "$EXS"; fx_conf ocp

# ---------------------------------------------------------------- resolve_cluster_channel
echo "--- resolve_cluster_channel returns early on okd"
fx_calls_reset
fx_conf okd; fx_isc ocp   # an ISC with channels must not be consulted on okd
mkdir -p "$FX_REPO/cluster1"; ln -sf ../aba.conf "$FX_REPO/cluster1/aba.conf"
fx_fn "ocp_version=$FX_OKD_VER ocp_channel=stable; image_source=mirror; reg_host=$FX_HOST reg_port=$FX_PORT reg_path=$FX_REGPATH; resolve_cluster_channel $FX_OKD_VER" "$FX_REPO/cluster1"
eq "okd: channel from aba.conf, major.minor" "stable-9.8" "$FX_OUT"
eq "okd: no registry lookup" "0" "$(fx_calls | grep -c '^skopeo')"
fx_conf okd; fx_fn "ocp_version=$FX_OKD_VER ocp_channel=candidate; resolve_cluster_channel" "$FX_REPO/cluster1"
eq "okd: default version and channel" "candidate-9.8" "$FX_OUT"
fx_conf ocp; fx_isc ocp
fx_calls_reset
fx_fn "ocp_version=$FX_OCP_VER ocp_channel=fast; image_source=mirror; resolve_cluster_channel $FX_OCP_VER" "$FX_REPO/cluster1"
eq "ocp: unchanged (still asks the registry, falls back to aba.conf)" "fast-7.6" "$FX_OUT"
eq "ocp: registry was consulted" "1" "$(fx_calls | grep -c '^skopeo')"
fx_conf ocp distribution=bogus; fx_calls_reset
fx_fn "ocp_version=$FX_OCP_VER ocp_channel=fast; image_source=mirror; reg_host=$FX_HOST reg_port=$FX_PORT reg_path=$FX_REGPATH; resolve_cluster_channel $FX_OCP_VER" "$FX_REPO/cluster1"
eq "unknown distribution value takes the ocp path (registry consulted)" "1" "$(fx_calls | grep -c '^skopeo')"
fx_conf ocp

# ---------------------------------------------------------------- check-version-mismatch.sh
echo "--- check-version-mismatch.sh returns early on okd"
fx_conf okd; fx_isc okd; sleep 1; touch "$FX_MIR/data/imageset-config.yaml"
fx_run check-version-mismatch.sh
eq "okd with a channel-less ISC: exit 0" 0 "$FX_RC"
hasnt "okd: no error output" "$FX_OUT" "Error"
fx_conf ocp; fx_isc ocp; sleep 1; touch "$FX_MIR/data/imageset-config.yaml"
sed -i "s/maxVersion: .*/maxVersion: 6.0.0/; s/minVersion: .*/minVersion: 6.0.0/" "$FX_MIR/data/imageset-config.yaml"
fx_run check-version-mismatch.sh
eq "ocp: a real mismatch still exits 1" 1 "$FX_RC"
has "ocp: mismatch text unchanged" "$FX_OUT" "no longer matches"

# ---------------------------------------------------------------- transfer-info.sh
echo "--- transfer-info.sh shows the bundle identity for okd only"
mk_tar() {  # <kind> <metadata-file|-> -> data/aba-transfer.tar
	local kind="$1" meta="$2" t="$FX_ROOT/tar"
	rm -rf "$t"; mkdir -p "$t/mirror/data"
	fx_isc "$kind"; cp "$FX_MIR/data/imageset-config.yaml" "$t/mirror/data/"
	[ "$meta" != - ] && cp "$meta" "$t/mirror/data/aba-transfer-metadata.json"
	rm -f "$FX_MIR/data/imageset-config.yaml" "$FX_MIR/data/aba-transfer.tar"
	( cd "$t" && tar cf "$FX_MIR/data/aba-transfer.tar" mirror )
}
printf '{\n  "ocp_version": "%s",\n  "ocp_channel": "stable",\n  "architecture": "amd64",\n  "created": "2026-01-01T00:00:00Z",\n  "digest_isc_sha256": "",\n  "distribution": "okd",\n  "release_digest": "%s"\n}\n' "$FX_OKD_VER" "$FX_DIGEST" > "$FX_ROOT/meta-okd.json"
printf '{\n  "ocp_version": "%s",\n  "ocp_channel": "stable",\n  "architecture": "amd64",\n  "created": "2026-01-01T00:00:00Z",\n  "digest_isc_sha256": ""\n}\n' "$FX_OCP_VER" > "$FX_ROOT/meta-ocp.json"
mk_tar okd "$FX_ROOT/meta-okd.json"
fx_run transfer-info.sh --shell
has "okd shell: version from metadata" "$FX_OUT" "transfer_ocp_version=$FX_OKD_VER"
has "okd shell: distribution" "$FX_OUT" "transfer_distribution=okd"
has "okd shell: digest" "$FX_OUT" "transfer_release_digest=$FX_DIGEST"
fx_run transfer-info.sh
has "okd human: labelled OKD" "$FX_OUT" "OKD: $FX_OKD_VER"
has "okd human: digest line" "$FX_OUT" "$FX_DIGEST"
mk_tar ocp "$FX_ROOT/meta-ocp.json"
fx_run transfer-info.sh --shell
hasnt "ocp shell: no distribution key" "$FX_OUT" "transfer_distribution"
hasnt "ocp shell: no digest key" "$FX_OUT" "transfer_release_digest"
eq "ocp shell: exactly the original 8 keys" 8 "$(grep -c '^transfer_' <<<"$FX_OUT")"
fx_run transfer-info.sh
has "ocp human: labelled OCP" "$FX_OUT" "OCP: $FX_OCP_VER"
hasnt "ocp human: not labelled OKD" "$FX_OUT" "OKD"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
