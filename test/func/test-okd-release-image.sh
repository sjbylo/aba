#!/bin/bash
# Test: OKD release image is addressed by the digest oc-mirror recorded, never by a guessed tag.
#   - okd_mirror_release_digest reads the digest from the oc-mirror output (one function to switch to mirror state)
#   - dist_release_image_ref / check_release_image / verify-release-image.sh use it on okd; OCP keeps <version>-<arch>
#   - the openshift-install taken from the mirror must report that same digest
# Offline: curl, oc and openshift-install are shims (test/func/lib/okd-fixture.sh).

cd "$(dirname "$0")/../.." || exit 1
REPO=$PWD
export OKD_FX_REPO=$REPO
source test/func/lib/okd-fixture.sh

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }
_eq() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1: expected [$2] got [$3]"; fi; }
_has() { if grep -qF -- "$3" <<<"$2"; then _pass "$1"; else _fail "$1: [$3] not in [$(head -c 300 <<<"$2")]"; fi; }
_hasnt() { if grep -qF -- "$3" <<<"$2"; then _fail "$1: [$3] must not be in output"; else _pass "$1"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# digests derived from the version so nothing here is a literal release: output must follow the input
_hex() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
V_A=4.21.0-okd-scos.11; V_B=4.20.0-okd-scos.3; V_C=5.0.0-okd-scos.5
H_A=$(_hex $V_A); H_B=$(_hex $V_B); H_C=$(_hex $V_C); H_IDX=$(_hex index-digest-of-the-installer)

echo "=== okd_mirror_release_digest ==="

# <dir>: mirror dir layout (data/working-dir) or cluster dir layout (mirror/data/working-dir)
_wd() { local root="$1" layout="$2"; if [ "$layout" = mirror ]; then echo "$root/data/working-dir"; else echo "$root/mirror/data/working-dir"; fi; }
_mk() { # root layout [version hex]...  -> signature files
	local root="$1" layout="$2"; shift 2
	local wd; wd=$(_wd "$root" "$layout"); mkdir -p "$wd/signatures" "$wd/cluster-resources"
	while [ $# -ge 2 ]; do : > "$wd/signatures/$1-sha256-$2"; shift 2; done
}
_digest() { # root dir-to-run-in version -> prints "<rc>|<stdout>|<stderr>"
	local root="$1" in="$2" ver="$3" o e rc
	o=$( cd "$in" && source "$REPO/scripts/include_all.sh" 2>/dev/null; trap - ERR; okd_mirror_release_digest "$ver" 2>"$T/e" ); rc=$?
	e=$(cat "$T/e"); printf '%s|%s|%s' "$rc" "$o" "$e"
}
source "$REPO/scripts/include_all.sh" 2>/dev/null; trap - ERR
if ! declare -F okd_mirror_release_digest >/dev/null; then _fail "okd_mirror_release_digest is not defined"; fi

# cluster dir layout, three versions mirrored: each version gets its own digest
rm -rf "$T/d1"; mkdir -p "$T/d1"; _mk "$T/d1" cluster $V_A $H_A $V_B $H_B $V_C $H_C
for pair in "$V_A:$H_A" "$V_B:$H_B" "$V_C:$H_C"; do
	v=${pair%%:*}; h=${pair#*:}; r=$(_digest "$T/d1" "$T/d1" "$v")
	_eq "signatures: $v -> its digest" "0|sha256:$h|" "$r"
done
# mirror dir layout (data/ is local)
rm -rf "$T/d2"; mkdir -p "$T/d2"; _mk "$T/d2" mirror $V_A $H_A
_eq "mirror dir layout" "0|sha256:$H_A|" "$(_digest "$T/d2" "$T/d2" $V_A)"
# default version = $ocp_version
o=$( cd "$T/d1" && source "$REPO/scripts/include_all.sh" 2>/dev/null; trap - ERR; ocp_version=$V_B; okd_mirror_release_digest )
_eq "default version is ocp_version" "sha256:$H_B" "$o"
# the same digest recorded twice (two files) is one digest
_mk "$T/d1" cluster $V_A $H_A
: > "$T/d1/mirror/data/working-dir/signatures/${V_A}-sha256-${H_A}"
_eq "duplicate record of one digest" "0|sha256:$H_A|" "$(_digest "$T/d1" "$T/d1" $V_A)"

# signature-configmap.json as the only record (no signatures/ dir)
rm -rf "$T/d3"; mkdir -p "$T/d3/mirror/data/working-dir/cluster-resources"
printf '{"kind":"ConfigMap","binaryData":{"sha256-%s-1":"AAAA"}}\n' "$H_A" > "$T/d3/mirror/data/working-dir/cluster-resources/signature-configmap.json"
_eq "configmap fallback: one release" "0|sha256:$H_A|" "$(_digest "$T/d3" "$T/d3" $V_A)"
# one release signed by several keys: sha256-<digest>-1, -2 ... are one digest
printf '{"kind":"ConfigMap","binaryData":{"sha256-%s-1":"AAAA","sha256-%s-2":"BBBB"}}\n' "$H_A" "$H_A" > "$T/d3/mirror/data/working-dir/cluster-resources/signature-configmap.json"
_eq "configmap fallback: several signatures of one release" "0|sha256:$H_A|" "$(_digest "$T/d3" "$T/d3" $V_A)"
printf '{"kind":"ConfigMap","binaryData":{"sha256-%s-1":"AAAA","sha256-%s-1":"BBBB"}}\n' "$H_A" "$H_B" > "$T/d3/mirror/data/working-dir/cluster-resources/signature-configmap.json"
r=$(_digest "$T/d3" "$T/d3" $V_A)
_eq "configmap with two releases: refuses (rc)" 1 "${r%%|*}"
_has "configmap with two releases: says why" "$r" "more than one"
# the signatures record wins over the configmap when it names the version
_mk "$T/d3" cluster $V_A $H_A
_eq "signatures record wins over a configmap listing several" "0|sha256:$H_A|" "$(_digest "$T/d3" "$T/d3" $V_A)"

# the ConfigMap names no version: with per-version records present it must not answer for a version that has none
rm -rf "$T/d7"; mkdir -p "$T/d7"; _mk "$T/d7" cluster $V_A $H_A
printf '{"kind":"ConfigMap","binaryData":{"sha256-%s-1":"AAAA"}}\n' "$H_A" > "$T/d7/mirror/data/working-dir/cluster-resources/signature-configmap.json"
r=$(_digest "$T/d7" "$T/d7" $V_B); _eq "other version not mirrored: the ConfigMap of another release is not used" 1 "${r%%|*}"

# refusals
rm -rf "$T/d4"; mkdir -p "$T/d4"; _mk "$T/d4" cluster $V_A $H_A $V_A $H_B
r=$(_digest "$T/d4" "$T/d4" $V_A); _eq "two digests for one version: refuses" 1 "${r%%|*}"; _has "two digests: says why" "$r" "more than one"
r=$(_digest "$T/d1" "$T/d1" 4.99.0-okd-scos.1); _eq "version not mirrored: refuses" 1 "${r%%|*}"; _has "version not mirrored: names the version" "$r" "4.99.0-okd-scos.1"
rm -rf "$T/d5"; mkdir -p "$T/d5"
r=$(_digest "$T/d5" "$T/d5" $V_A); _eq "no oc-mirror output at all: refuses" 1 "${r%%|*}"; _has "no output: tells to sync or load" "$r" "sync"
r=$(_digest "$T/d1" "$T/d1" ""); _eq "no version: refuses" 1 "${r%%|*}"; _has "no version: says so" "$r" "No release version"
# one record whose digest part is malformed is no record at all
for bad in "${H_A^^}" "${H_A:1}" "${H_A}0" "zz${H_A:2}"; do
	rm -rf "$T/d8"; mkdir -p "$T/d8"; _mk "$T/d8" cluster $V_A "$bad"
	r=$(_digest "$T/d8" "$T/d8" $V_A); _eq "malformed digest [${bad:0:8}..${#bad}] is not a record" 1 "${r%%|*}"
done
# a version that is the prefix of another one only gets its own record
rm -rf "$T/d9"; mkdir -p "$T/d9"; _mk "$T/d9" cluster 4.21.0-okd-scos.1 $H_B 4.21.0-okd-scos.11 $H_A
_eq "sibling versions: ...scos.1 gets its own digest" "0|sha256:$H_B|" "$(_digest "$T/d9" "$T/d9" 4.21.0-okd-scos.1)"
_eq "sibling versions: ...scos.11 gets its own digest" "0|sha256:$H_A|" "$(_digest "$T/d9" "$T/d9" 4.21.0-okd-scos.11)"
r=$(_digest "$T/d9" "$T/d9" 4.21.0-okd-scos.2); _eq "sibling versions: ...scos.2 is not mirrored" 1 "${r%%|*}"
# a key numbered -2 only (no -1) is still a record
rm -rf "$T/d10"; mkdir -p "$T/d10/mirror/data/working-dir/cluster-resources"
printf '{"kind":"ConfigMap","binaryData":{"sha256-%s-2":"AAAA"}}\n' "$H_A" > "$T/d10/mirror/data/working-dir/cluster-resources/signature-configmap.json"
_eq "configmap key numbered -2 only" "0|sha256:$H_A|" "$(_digest "$T/d10" "$T/d10" $V_A)"
rm -rf "$T/d6"; mkdir -p "$T/d6"; _mk "$T/d6" cluster $V_A "${H_A^^}" $V_A "${H_A:1}" $V_A "${H_A}0" $V_A "zz${H_A:2}"
r=$(_digest "$T/d6" "$T/d6" $V_A); _eq "malformed digests (upper case, short, long, non-hex) are not records" 1 "${r%%|*}"
# stdout carries only the digest
_eq "stdout is exactly the digest" "sha256:$H_A" "$( cd "$T/d1" && source "$REPO/scripts/include_all.sh" 2>/dev/null; trap - ERR; okd_mirror_release_digest $V_A 2>/dev/null )"

echo ""
echo "=== dist_release_image_ref ==="
_ref() { ( cd "$1" && source "$REPO/scripts/include_all.sh" 2>/dev/null; trap - ERR; export distribution="$2"; dist_release_image_ref "$3" 2>"$T/e"; echo "rc=$?" ) | tr '\n' ' '; }
_eq "okd: digest from the mirror output" "sha256:$H_A rc=0 " "$(_ref "$T/d1" okd $V_A)"
_eq "okd: other version, other digest" "sha256:$H_C rc=0 " "$(_ref "$T/d1" okd $V_C)"
r=$(_ref "$T/d5" okd $V_A); _has "okd: nothing mirrored refuses" "$r" "rc=1"
_eq "ocp: tag as before" "4.21.14-$(uname -m) rc=0 " "$(_ref "$T/d5" ocp 4.21.14)"
_eq "ocp (key absent): tag as before" "5.0.3-$(uname -m) rc=0 " "$(_ref "$T/d5" "" 5.0.3)"

echo ""
echo "=== check_release_image ==="
# registry shim: curl logs the URLs it is asked for
_cri() { # root-of-credentials distribution version vendor v2code manifestcode -> "rc|var|log"
	local d="$T/reg"; rm -rf "$d"; mkdir -p "$d/bin"
	cp "$T/fx/bin/curl" "$d/bin/curl"
	local auth; auth=$(printf 'init:p4ssw0rd' | base64 -w0)
	printf '{"auths":{"registry.example.com:8443":{"auth":"%s"}}}\n' "$auth" > "$d/pull-secret-mirror.json"
	printf 'x\n' > "$d/rootCA.pem"
	: > "$d/log"
	( cd "$1" && env -i PATH="$d/bin:/usr/sbin:/usr/bin:/bin" HOME="$d" TMPDIR="$d" SHIM_LOG="$d/log" FAKE_V2_CODE="$5" FAKE_MANIFEST_CODE="$6" \
		bash -c "source '$REPO/scripts/include_all.sh' 2>/dev/null; trap - ERR; export ABA_TMP='$d/tmp'; mkdir -p \$ABA_TMP
			export distribution='$2' ocp_version='$3' regcreds_dir='$d' reg_host=registry.example.com reg_port=8443 reg_path=/ocp4/openshift4
			check_release_image $4; rc=\$?
			echo \"\$rc|http=\$_release_http_code|err=\$_release_check_err|extra=[\${_release_check_extra[*]}]\"" ) | tr '\n' ' '
	echo "|$(sort "$d/log" | tr '\n' ' ')"
}
okd_fx_init "$T/fx" 4.19.5 ocp mirror >/dev/null 2>&1
M="https://registry.example.com:8443/v2/ocp4/openshift4/openshift/release-images/manifests"
r=$(_cri "$T/d1" okd $V_A docker 200 200)
_has "okd: manifest asked by digest" "$r" "curl $M/sha256:$H_A"
_hasnt "okd: no guessed <version>-<arch> tag" "$r" "$V_A-"
_has "okd: succeeds" "$r" "0|"
r=$(_cri "$T/d1" okd $V_C docker 200 200)
_has "okd: other version, other digest" "$r" "curl $M/sha256:$H_C"
r=$(_cri "$T/d1" okd $V_A docker 200 404)
_has "okd: manifest 404 is reported" "$r" "1|http=404"
_has "okd: manifest 404 still asked by digest" "$r" "$M/sha256:$H_A"
# nothing recorded yet (before the first sync/load): the registry is still checked, the release is "not there"
r=$(_cri "$T/d5" okd $V_A docker 200 404)
_has "okd: no record -> fails" "$r" "1|http=404"
_has "okd: no record -> the registry itself is checked" "$r" "curl https://registry.example.com:8443/v2/ "
_hasnt "okd: no record -> no guessed <version>-<arch> tag" "$r" "$V_A-"
_hasnt "okd: no record -> no tag at all" "$r" "manifests/$V_A"
_has "okd: no record -> asks for a digest that cannot exist" "$r" "manifests/sha256:$(printf '0%.0s' $(seq 64))"
_has "okd: no record -> the reason is handed to the caller" "$r" "extra=[No oc-mirror output found"
r=$(_cri "$T/d5" okd $V_A docker 401 200)
_has "okd: no record + registry refuses -> still a registry error" "$r" "1|http=401"
r=$(_cri "$T/d5" ocp 4.19.5 docker 200 200)
_has "ocp: tag as before" "$r" "curl $M/4.19.5-$(uname -m)"
r=$(_cri "$T/d5" "" 5.0.3 docker 200 200)
_has "ocp (key absent): tag as before" "$r" "curl $M/5.0.3-$(uname -m)"
r=$(_cri "$T/d1" ocp 4.19.5 docker 200 200)
_has "ocp: an oc-mirror record present is ignored" "$r" "curl $M/4.19.5-$(uname -m)"

echo ""
echo "=== verify-release-image.sh ==="
IDMS=$REPO/test/func/fixtures/okd-idms-oc-mirror.yaml
sed 's#registry\.example\.com#registry.example.com#g' "$IDMS" > "$T/idms-example.yaml"
REF_BASE="registry.example.com:8443/ocp4/openshift4/openshift/release-images"
_verify() { # name ocp_version dist [mirror-output: yes|no] [env...]  -> $T/<name>/{out,rc,shim.log}
	local name="$1" ver="$2" dist="$3" rec="$4"; shift 4
	local r="$T/$name"
	okd_fx_init "$r" "$ver" "$dist" mirror >/dev/null 2>&1 || { _fail "$name: fixture"; return 1; }
	okd_fx_creds "$r" mirror with-ca
	[ "$rec" = yes ] && okd_fx_mirror_output "$r" "$ver" "$(_hex "$ver")" "$T/idms-example.yaml"
	: > "$r/shim.log"
	( export FAKE_INSTALL_VERSION="$ver"; for kv in "$@"; do export "$kv"; done
	  okd_fx_run "$r" bash scripts/verify-release-image.sh > "$r/out" 2>&1; echo $? > "$r/rc" )
}
INDEX_IMG="quay.io/okd/scos-release@sha256:$H_IDX"

# okd, the installer on PATH names the upstream index digest; the mirror holds only the recorded one
HV=$(_hex $V_A)
_verify v1 $V_A okd yes "FAKE_INSTALL_RELEASE_IMAGE=$INDEX_IMG"
_eq "okd: succeeds" 0 "$(cat "$T/v1/rc")"
[ "$(cat "$T/v1/rc")" = 0 ] || sed 's/^/    /' "$T/v1/out" | tail -8
_has "okd: oc extracts from the recorded digest" "$(cat "$T/v1/shim.log")" "$REF_BASE@sha256:$HV"
_hasnt "okd: not from the installer's own index digest" "$(cat "$T/v1/shim.log")" "$H_IDX"
_has "okd: --insecure=true kept as on OCP" "$(cat "$T/v1/shim.log")" "--insecure=true"
_has "okd: the registry is asked by digest" "$(cat "$T/v1/shim.log")" "manifests/sha256:$HV"
_hasnt "okd: never a version-arch tag" "$(cat "$T/v1/shim.log")" "$V_A-"
_has "okd: success message names the digest" "$(cat "$T/v1/out")" "release-images@sha256:$HV"
[ -x "$T/v1/demo/openshift-install-mirror-$V_A-registry.example.com-8443" ] && _pass "okd: installer from the mirror kept" || _fail "okd: installer from the mirror missing"
# the idms handed to oc is the one built from the install-config sources
_has "okd: oc is given the IDMS of the install config" "$(cat "$T/v1/shim.log")" "--idms-file=.idms.yaml"

# same, verify_conf=off: the connectivity check is skipped, the extraction still goes by digest
_verify v2 $V_A okd yes "FAKE_INSTALL_RELEASE_IMAGE=$INDEX_IMG"
sed -i 's/^verify_conf=.*/verify_conf=off/' "$T/v2/aba.conf"; : > "$T/v2/shim.log"; rm -f "$T"/v2/demo/openshift-install-mirror-*
( cd "$T/v2" && export FAKE_INSTALL_VERSION=$V_A FAKE_INSTALL_RELEASE_IMAGE=$INDEX_IMG; okd_fx_run "$T/v2" bash scripts/verify-release-image.sh > "$T/v2/out" 2>&1; echo $? > "$T/v2/rc" )
_eq "okd verify_conf=off: succeeds" 0 "$(cat "$T/v2/rc")"
_has "okd verify_conf=off: extraction by digest" "$(cat "$T/v2/shim.log")" "$REF_BASE@sha256:$HV"
_hasnt "okd verify_conf=off: registry not probed" "$(cat "$T/v2/shim.log")" "curl "

# the extracted installer reports another digest than the recorded one: stop and drop the binary
_verify v3 $V_A okd yes "FAKE_INSTALL_RELEASE_IMAGE=$INDEX_IMG" "FAKE_EXTRACT_RELEASE_IMAGE=$REF_BASE@sha256:$H_IDX"
[ "$(cat "$T/v3/rc")" != 0 ] && _pass "okd: installer with another digest -> fails" || _fail "okd: installer with another digest must fail"
_has "okd: message says which digests differ" "$(cat "$T/v3/out")" "$H_IDX"
_has "okd: message names the recorded digest" "$(cat "$T/v3/out")" "$HV"
[ ! -e "$T/v3/demo/openshift-install-mirror-$V_A-registry.example.com-8443" ] && _pass "okd: mismatching installer is not left for the ISO step" || _fail "okd: mismatching installer left in place"

# a stale installer from an earlier extraction (other digest) is caught when it is reused
_verify v4 $V_A okd yes "FAKE_INSTALL_RELEASE_IMAGE=$INDEX_IMG"
printf '#!/usr/bin/bash\necho "openshift-install %s"\necho "release image %s@sha256:%s"\n' "$V_A" "$REF_BASE" "$H_IDX" \
	> "$T/v4/demo/openshift-install-mirror-$V_A-registry.example.com-8443"; chmod +x "$T/v4/demo/openshift-install-mirror-$V_A-registry.example.com-8443"
: > "$T/v4/shim.log"
( export FAKE_INSTALL_VERSION=$V_A FAKE_INSTALL_RELEASE_IMAGE=$INDEX_IMG; okd_fx_run "$T/v4" bash scripts/verify-release-image.sh > "$T/v4/out" 2>&1; echo $? > "$T/v4/rc" )
[ "$(cat "$T/v4/rc")" != 0 ] && _pass "okd: stale installer reused -> fails" || _fail "okd: stale installer must be caught"
_hasnt "okd: stale installer: no extraction attempted before the check" "$(cat "$T/v4/shim.log")" "adm release extract"

# nothing recorded by oc-mirror: stop before touching the registry or oc
_verify v5 $V_A okd no "FAKE_INSTALL_RELEASE_IMAGE=$INDEX_IMG"
[ "$(cat "$T/v5/rc")" != 0 ] && _pass "okd: no oc-mirror output -> fails" || _fail "okd: no oc-mirror output must fail"
_has "okd: message tells what to do" "$(cat "$T/v5/out")" "sync"
_hasnt "okd: no oc call" "$(cat "$T/v5/shim.log")" "oc adm"

# the release is not in the registry: the message names the digest, not a tag
_verify v6 $V_A okd yes "FAKE_INSTALL_RELEASE_IMAGE=$INDEX_IMG" FAKE_MANIFEST_CODE=404
[ "$(cat "$T/v6/rc")" != 0 ] && _pass "okd: release missing in the registry -> fails" || _fail "okd: release missing must fail"
_has "okd: message shows the image by digest" "$(cat "$T/v6/out")" "release-images@sha256:$HV"
_hasnt "okd: message shows no guessed tag" "$(cat "$T/v6/out")" "release-images:$V_A"

# other versions and another major follow their own record
for v in $V_B $V_C; do
	_verify vv-$v $v okd yes "FAKE_INSTALL_RELEASE_IMAGE=$INDEX_IMG"
	_eq "okd $v: succeeds" 0 "$(cat "$T/vv-$v/rc")"
	_has "okd $v: its own digest" "$(cat "$T/vv-$v/shim.log")" "$REF_BASE@sha256:$(_hex "$v")"
done

# OCP is untouched: the digest comes from the installer on PATH, the registry is asked for <version>-<arch>
OCP_IMG="quay.io/openshift-release-dev/ocp-release@sha256:$H_IDX"
_verify o1 4.19.5 ocp no "FAKE_INSTALL_RELEASE_IMAGE=$OCP_IMG"
_eq "ocp: succeeds" 0 "$(cat "$T/o1/rc")"
_has "ocp: extraction from the installer's own digest" "$(cat "$T/o1/shim.log")" "$REF_BASE@sha256:$H_IDX"
_has "ocp: registry asked for the version-arch tag" "$(cat "$T/o1/shim.log")" "manifests/4.19.5-$(uname -m)"
_verify o2 4.19.5 ocp no "FAKE_INSTALL_RELEASE_IMAGE=$OCP_IMG" FAKE_MANIFEST_CODE=404
_has "ocp: error message keeps the tag" "$(cat "$T/o2/out")" "release-images:4.19.5-$(uname -m)"
_verify o3 4.19.5 ocp no "FAKE_INSTALL_RELEASE_IMAGE=$OCP_IMG" "FAKE_EXTRACT_RELEASE_IMAGE=$REF_BASE@sha256:$H_A"
_eq "ocp: no digest cross-check of the extracted installer (as before)" 0 "$(cat "$T/o3/rc")"

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
