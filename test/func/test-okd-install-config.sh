#!/bin/bash
# Test: install-config for OKD.
#   - imageDigestSources are built from the IDMS oc-mirror wrote for the mirror (real output kept as a fixture),
#     not from the static OCP template; a missing or foreign IDMS stops the render.
#   - OKD installed from a mirror gets two install-time manifests (Samples Operator Removed, OperatorHub default
#     sources off); direct/proxy keep the OKD defaults; OCP output does not change at all.
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

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

IDMS=$REPO/test/func/fixtures/okd-idms-oc-mirror.yaml
HEX_A=$(printf 'a%.0s' $(seq 64))

echo "=== okd install-config: imageDigestSources from the oc-mirror IDMS ==="

# Run _render_image_content_sources from create-install-config.sh in <dir> (a cluster dir whose ./mirror holds the
# oc-mirror output).  Prints the result variable; stderr goes to <dir>/err.  Env: distribution, ocp_version, reg_*.
_render() {
	local dir="$1" dist="$2" ver="$3" host="${4:-registry.example.com}" port="${5:-8443}" rpath="${6:-/ocp4/openshift4}"
	(
		cd "$dir" || exit 1
		source "$REPO/scripts/include_all.sh" 2>/dev/null
		trap - ERR
		eval "$(awk '/^_render_okd_image_content_sources\(\)/{p=1} p{print} p && /^}/{exit}' "$REPO/scripts/create-install-config.sh")"
		eval "$(awk '/^_render_image_content_sources\(\)/{p=1} p{print} p && /^}/{exit}' "$REPO/scripts/create-install-config.sh")"
		[ "$dist" = UNSET ] || export distribution="$dist"
		export reg_host="$host" reg_port="$port" reg_path="$rpath" ocp_version="$ver"
		unset ocp_major image_content_sources
		_render_image_content_sources 2>"$dir/err"
		rc=$?
		printf '%s\n' "$image_content_sources"
		exit $rc
	)
}

# a cluster dir with mirror/data/working-dir/cluster-resources/idms-oc-mirror.yaml = <idms-file>
_cdir() {
	local d="$1" idms="$2"
	rm -rf "$d"; mkdir -p "$d/mirror/data/working-dir/cluster-resources"
	ln -s "$REPO/scripts" "$d/scripts"; ln -s "$REPO/templates" "$d/templates"   # the OCP branch renders the template
	[ -n "$idms" ] && cp "$idms" "$d/mirror/data/working-dir/cluster-resources/idms-oc-mirror.yaml"
	return 0
}
_srcs() { yaml2json <<<"$1" | jq -r '[.[] | .source] | join(",")'; }
_dests() { yaml2json <<<"$1" | jq -r --arg s "$2" '.[] | select(.source == $s) | .mirrors | join(",")'; }
source "$REPO/scripts/include_all.sh" 2>/dev/null; trap - ERR

# --- the real oc-mirror IDMS -------------------------------------------------------------------------
_cdir "$T/c1" "$IDMS"
out=$(_render "$T/c1" okd 4.21.0-okd-scos.11); rc=$?
_eq "okd: real IDMS renders (rc)" 0 "$rc"
_eq "okd: sources = IDMS sources + payload alias, in IDMS order" \
	"quay.io/okd/scos-content,registry.ci.openshift.org/origin/release-scos,quay.io/okd/scos-release" "$(_srcs "$out")"
_eq "okd: scos-content mirrors to .../openshift/release" \
	"registry.example.com:8443/ocp4/openshift4/openshift/release" "$(_dests "$out" quay.io/okd/scos-content)"
_eq "okd: payload alias mirrors to the same .../openshift/release-images as the IDMS payload rule" \
	"registry.example.com:8443/ocp4/openshift4/openshift/release-images" "$(_dests "$out" quay.io/okd/scos-release)"
_eq "okd: payload rule from the IDMS kept" \
	"registry.example.com:8443/ocp4/openshift4/openshift/release-images" "$(_dests "$out" registry.ci.openshift.org/origin/release-scos)"
if grep -q 'openshift-release-dev' <<<"$out"; then _fail "okd: no OCP source may appear"; else _pass "okd: no OCP source"; fi
if grep -q 'ocp-v' <<<"$out"; then _fail "okd: no ocp-v* repo"; else _pass "okd: no ocp-v* repo"; fi

# the version only decides nothing here: other versions (and another major) render the same sources
for v in 4.20.0-okd-scos.3 5.0.0-okd-scos.5; do
	o2=$(_render "$T/c1" okd "$v"); rc=$?
	_eq "okd $v: renders" 0 "$rc"
	_eq "okd $v: same sources" "$(_srcs "$out")" "$(_srcs "$o2")"
done

# output follows the IDMS: another registry host, port and path
cat > "$T/idms-other.yaml" <<'EOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: idms-release-0
spec:
  imageDigestMirrors:
  - mirrors:
    - reg2.example.net:5000/okd/m/openshift/release
    source: quay.io/okd/scos-content
  - mirrors:
    - reg2.example.net:5000/okd/m/openshift/release-images
    source: registry.ci.openshift.org/origin/release-scos
EOF
_cdir "$T/c2" "$T/idms-other.yaml"
out=$(_render "$T/c2" okd 5.0.0-okd-scos.5 reg2.example.net 5000 /okd/m); rc=$?
_eq "okd other registry: renders" 0 "$rc"
_eq "okd other registry: alias follows the IDMS destination" \
	"reg2.example.net:5000/okd/m/openshift/release-images" "$(_dests "$out" quay.io/okd/scos-release)"

# an IDMS that already carries the payload alias is not doubled
cat > "$T/idms-alias.yaml" <<'EOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: idms-release-0
spec:
  imageDigestMirrors:
  - mirrors:
    - registry.example.com:8443/ocp4/openshift4/openshift/release-images
    source: quay.io/okd/scos-release
  - mirrors:
    - registry.example.com:8443/ocp4/openshift4/openshift/release
    source: quay.io/okd/scos-content
EOF
_cdir "$T/c3" "$T/idms-alias.yaml"
out=$(_render "$T/c3" okd 4.21.0-okd-scos.11); rc=$?
_eq "okd alias already in the IDMS: not doubled" "quay.io/okd/scos-release,quay.io/okd/scos-content" "$(_srcs "$out")"

# a rule with several mirrors keeps all of them, in order
cat > "$T/idms-multi.yaml" <<'EOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: idms-release-0
spec:
  imageDigestMirrors:
  - mirrors:
    - registry.example.com:8443/ocp4/openshift4/openshift/release-images
    - registry.example.com:8443/ocp4/openshift4/second/release-images
    source: registry.ci.openshift.org/origin/release-scos
EOF
_cdir "$T/c5" "$T/idms-multi.yaml"
out=$(_render "$T/c5" okd 4.21.0-okd-scos.11)
_eq "okd: several mirrors of one rule are all kept" \
	"registry.example.com:8443/ocp4/openshift4/openshift/release-images,registry.example.com:8443/ocp4/openshift4/second/release-images" "$(_dests "$out" registry.ci.openshift.org/origin/release-scos)"
_eq "okd: the payload alias gets all of them" \
	"registry.example.com:8443/ocp4/openshift4/openshift/release-images,registry.example.com:8443/ocp4/openshift4/second/release-images" "$(_dests "$out" quay.io/okd/scos-release)"

# the alias is in the IDMS already: the release-images rule is not needed to build it
cat > "$T/idms-alias2.yaml" <<'EOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: idms-release-0
spec:
  imageDigestMirrors:
  - mirrors:
    - registry.example.com:8443/ocp4/openshift4/openshift/payload
    source: quay.io/okd/scos-release
  - mirrors:
    - registry.example.com:8443/ocp4/openshift4/openshift/release
    source: quay.io/okd/scos-content
EOF
_cdir "$T/c3b" "$T/idms-alias2.yaml"
out=$(_render "$T/c3b" okd 4.21.0-okd-scos.11); rc=$?
_eq "okd alias in the IDMS, no release-images rule: renders (rc)" 0 "$rc"
_eq "okd alias in the IDMS, no release-images rule: its own destination" "registry.example.com:8443/ocp4/openshift4/openshift/payload" "$(_dests "$out" quay.io/okd/scos-release)"

# IDMS with operator content: kept as well (all stay inside the registry)
cat > "$T/idms-ops.yaml" <<'EOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: idms-operator-0
spec:
  imageDigestMirrors:
  - mirrors:
    - registry.example.com:8443/ocp4/openshift4/openshift/release-images
    source: registry.ci.openshift.org/origin/release-scos
  - mirrors:
    - registry.example.com:8443/ocp4/openshift4/community/foo
    source: quay.io/community/foo
EOF
_cdir "$T/c4" "$T/idms-ops.yaml"
out=$(_render "$T/c4" okd 4.21.0-okd-scos.11)
_eq "okd operator rule kept next to the release rules" \
	"registry.ci.openshift.org/origin/release-scos,quay.io/community/foo,quay.io/okd/scos-release" "$(_srcs "$out")"

# --- fail closed ---------------------------------------------------------------------------------------
_fails() { # label dir [host port path] -> must abort with a message naming the problem
	local label="$1" dir="$2" want="$3"; shift 3
	local out rc
	out=$(_render "$dir" okd 4.21.0-okd-scos.11 "$@" 2>&1); rc=$?
	if [ "$rc" -ne 0 ] && grep -qi -- "$want" "$dir/err"; then _pass "okd $label: stops ($(head -c 80 "$dir/err" | tr '\n' ' '))"
	else _fail "okd $label: must abort naming '$want' (rc=$rc) $(cat "$dir/err")"; fi
	if [ -n "$out" ]; then _fail "okd $label: no content sources may be produced, got [$out]"; fi
}
_cdir "$T/f1" ""
_fails "IDMS missing" "$T/f1" "aba -d mirror sync"
_cdir "$T/f2" "$IDMS"; : > "$T/f2/mirror/data/working-dir/cluster-resources/idms-oc-mirror.yaml"
_fails "IDMS empty" "$T/f2" "idms-oc-mirror"
_cdir "$T/f3" "$IDMS"; printf 'not: [valid\n' > "$T/f3/mirror/data/working-dir/cluster-resources/idms-oc-mirror.yaml"
_fails "IDMS not YAML" "$T/f3" "not valid YAML"
_cdir "$T/f4" "$IDMS"; printf 'apiVersion: config.openshift.io/v1\nkind: ImageDigestMirrorSet\nspec:\n  imageDigestMirrors: []\n' > "$T/f4/mirror/data/working-dir/cluster-resources/idms-oc-mirror.yaml"
_fails "IDMS without rules" "$T/f4" "imageDigestMirrors"
for kind in "mirrors: []" "nomirrors: x"; do
	cat > "$T/idms-nomir.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
spec:
  imageDigestMirrors:
  - $kind
    source: quay.io/okd/scos-content
  - mirrors:
    - registry.example.com:8443/ocp4/openshift4/openshift/release-images
    source: registry.ci.openshift.org/origin/release-scos
EOF
	_cdir "$T/f9" "$T/idms-nomir.yaml"
	_fails "IDMS rule with [$kind]" "$T/f9" "no usable imageDigestMirrors"
done
_cdir "$T/f5" "$IDMS"
_fails "IDMS of another registry" "$T/f5" "registry" other.example.com 8443 /ocp4/openshift4
_fails "IDMS of another path" "$T/f5" "registry" registry.example.com 8443 /elsewhere
_fails "IDMS of another port" "$T/f5" "registry" registry.example.com 9443 /ocp4/openshift4
cat > "$T/idms-norel.yaml" <<'EOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
spec:
  imageDigestMirrors:
  - mirrors:
    - registry.example.com:8443/ocp4/openshift4/openshift/release
    source: quay.io/okd/scos-content
EOF
_cdir "$T/f6" "$T/idms-norel.yaml"
_fails "IDMS without the release-images rule" "$T/f6" "release-images"
# a mirror under a sibling path of the registry path, or a rule that only looks like the release-images one
sed 's#/ocp4/openshift4/#/ocp4/openshift4x/#' "$IDMS" > "$T/idms-sibling.yaml"
_cdir "$T/f6b" "$T/idms-sibling.yaml"
_fails "IDMS mirror under a sibling path" "$T/f6b" "registry"
cat > "$T/idms-lookalike.yaml" <<'EOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
spec:
  imageDigestMirrors:
  - mirrors:
    - registry.example.com:8443/ocp4/openshift4/openshift/old-release-images
    source: registry.ci.openshift.org/origin/release-scos
EOF
_cdir "$T/f6c" "$T/idms-lookalike.yaml"
_fails "IDMS with only a look-alike of the release-images rule" "$T/f6c" "release-images"
cat > "$T/idms-space.yaml" <<'EOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
spec:
  imageDigestMirrors:
  - mirrors:
    - registry.example.com:8443/ocp4/openshift4/openshift/release-images
    source: "registry.ci.openshift.org/origin/release scos"
EOF
_cdir "$T/f6d" "$T/idms-space.yaml"
_fails "IDMS source with a space" "$T/f6d" "not a valid"
# a value that is not a plain registry reference must never reach the install-config
cat > "$T/idms-evil.yaml" <<'EOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
spec:
  imageDigestMirrors:
  - mirrors:
    - "registry.example.com:8443/ocp4/openshift4/openshift/release-images\npullSecret: x"
    source: registry.ci.openshift.org/origin/release-scos
EOF
_cdir "$T/f7" "$T/idms-evil.yaml"
_fails "IDMS value with a newline" "$T/f7" "not a valid"
cat > "$T/idms-evil2.yaml" <<'EOF'
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
spec:
  imageDigestMirrors:
  - mirrors:
    - registry.example.com:8443/ocp4/openshift4/openshift/release-images
    source: "a: b #x"
EOF
_cdir "$T/f8" "$T/idms-evil2.yaml"
_fails "IDMS source with YAML syntax" "$T/f8" "not a valid"

# --- OCP does not change -------------------------------------------------------------------------------
for dist in ocp "" UNSET; do
	_cdir "$T/o1" ""    # no oc-mirror output at all: OCP never looks at it
	o=$(_render "$T/o1" "$dist" 4.19.5 registry.example.com 8443 /ocp4/openshift4)
	if grep -q 'source: quay.io/openshift-release-dev/ocp-v4.0-art-dev' <<<"$o" && grep -q 'source: quay.io/openshift-release-dev/ocp-release' <<<"$o" \
		&& ! grep -q 'okd' <<<"$o"; then _pass "ocp (distribution='$dist'): template output, no IDMS needed"
	else _fail "ocp (distribution='$dist'): template output expected"; echo "$o"; fi
done
o=$(_render "$T/c1" ocp 4.19.5 registry.example.com 8443 /ocp4/openshift4)
if ! grep -q 'scos' <<<"$o"; then _pass "ocp ignores an IDMS present in the mirror dir"; else _fail "ocp must not read the oc-mirror IDMS"; fi

# =====================================================================================================
echo ""
echo "=== okd install-time manifests ==="
_man() { # run _okd_install_manifests in <dir> with distribution and image_content_sources
	local dir="$1" dist="$2" ics="$3"
	( cd "$dir" || exit 1
	  source "$REPO/scripts/include_all.sh" 2>/dev/null; trap - ERR
	  eval "$(awk '/^_okd_install_manifests\(\)/{p=1} p{print} p && /^}/{exit}' "$REPO/scripts/create-install-config.sh")"
	  [ "$dist" = UNSET ] || export distribution="$dist"
	  export image_content_sources="$ics"
	  _okd_install_manifests >"$dir/man.out" 2>&1 )
}
SAMPLES=openshift/99-aba-samples-removed.yaml
HUB=openshift/99-aba-operatorhub-default-sources-off.yaml
ICS=$'- mirrors:\n  - h:1/x\n  source: s'

mkdir -p "$T/m1"; _man "$T/m1" okd "$ICS"
[ -s "$T/m1/$SAMPLES" ] && _pass "okd+mirror: samples manifest written" || _fail "okd+mirror: samples manifest missing"
[ -s "$T/m1/$HUB" ] && _pass "okd+mirror: operatorhub manifest written" || _fail "okd+mirror: operatorhub manifest missing"
_eq "samples: apiVersion/kind/name/managementState" "samples.operator.openshift.io/v1 Config cluster Removed" \
	"$(yaml2json < "$T/m1/$SAMPLES" | jq -r '[.apiVersion, .kind, .metadata.name, .spec.managementState] | join(" ")')"
_eq "operatorhub: apiVersion/kind/name/disableAllDefaultSources" "config.openshift.io/v1 OperatorHub cluster true" \
	"$(yaml2json < "$T/m1/$HUB" | jq -r '[.apiVersion, .kind, .metadata.name, .spec.disableAllDefaultSources] | join(" ")')"
_eq "exactly two manifests" 2 "$(ls "$T/m1/openshift" | wc -l)"
cp "$T/m1/$SAMPLES" "$T/s1"; _man "$T/m1" okd "$ICS"
cmp -s "$T/s1" "$T/m1/$SAMPLES" && _pass "second run: same content" || _fail "second run changed the samples manifest"

# a file the user keeps in openshift/ is left alone; a stale manifest goes when the mirror is no longer used
echo "user: 1" > "$T/m1/openshift/10-mine.yaml"
_man "$T/m1" okd ""
[ ! -e "$T/m1/$SAMPLES" ] && [ ! -e "$T/m1/$HUB" ] && _pass "okd direct/proxy: stale manifests removed" || _fail "okd direct/proxy: stale manifests remain"
[ -s "$T/m1/openshift/10-mine.yaml" ] && _pass "okd direct/proxy: user manifest kept" || _fail "okd direct/proxy: user manifest lost"

mkdir -p "$T/m2"; _man "$T/m2" okd ""
[ ! -e "$T/m2/openshift" ] && _pass "okd direct/proxy: no openshift/ dir created" || _fail "okd direct/proxy: openshift/ created"
mkdir -p "$T/m2b"; _man "$T/m2b" okd "$ICS"; _man "$T/m2b" okd ""
[ ! -e "$T/m2b/openshift" ] && _pass "okd: openshift/ dir removed again when ABA created it and it is empty" || _fail "okd: empty openshift/ left behind"

for dist in ocp "" UNSET; do
	mkdir -p "$T/m3"; rm -rf "$T/m3/openshift"; _man "$T/m3" "$dist" "$ICS"
	[ ! -e "$T/m3/openshift" ] && _pass "ocp (distribution='$dist') with a mirror: nothing written" || _fail "ocp (distribution='$dist'): openshift/ must not be created"
	[ ! -s "$T/m3/man.out" ] && _pass "ocp (distribution='$dist'): no output" || _fail "ocp (distribution='$dist'): output [$(cat "$T/m3/man.out")]"
done
# a stale file with the same name on OCP is none of our business
mkdir -p "$T/m4/openshift"; echo "keep: me" > "$T/m4/$SAMPLES"
_man "$T/m4" ocp ""
[ -s "$T/m4/$SAMPLES" ] && _pass "ocp: existing file untouched" || _fail "ocp: removed a file it does not own"

# clean removes what ABA wrote there and nothing else, for OKD only (the cluster dir says okd in aba.conf or in its state)
mkdir -p "$T/m5/openshift"; ln -s "$REPO/scripts" "$T/m5/scripts"; ln -s "$REPO/templates" "$T/m5/templates"
echo "distribution=okd" > "$T/m5/aba.conf"
_man "$T/m5" okd "$ICS"; echo "user: 1" > "$T/m5/openshift/10-mine.yaml"
( cd "$T/m5" && env -i PATH="/usr/bin:/bin" HOME="$T" bash scripts/cluster-clean.sh >/dev/null 2>&1 )
[ ! -e "$T/m5/$SAMPLES" ] && [ ! -e "$T/m5/$HUB" ] && _pass "clean: generated manifests removed" || _fail "clean: generated manifests remain"
[ -s "$T/m5/openshift/10-mine.yaml" ] && _pass "clean: user manifest kept" || _fail "clean: user manifest lost"
# an empty openshift/ dir of the user (no generated manifest) is not touched by clean, whatever the distribution
mkdir -p "$T/m7/openshift"; ln -s "$REPO/scripts" "$T/m7/scripts"; ln -s "$REPO/templates" "$T/m7/templates"
( cd "$T/m7" && env -i PATH="/usr/bin:/bin" HOME="$T" bash scripts/cluster-clean.sh >/dev/null 2>&1 )
[ -d "$T/m7/openshift" ] && _pass "clean: user's empty openshift/ dir kept" || _fail "clean: removed a user's empty openshift/ dir"
mkdir -p "$T/m6"; ln -s "$REPO/scripts" "$T/m6/scripts"; ln -s "$REPO/templates" "$T/m6/templates"
echo "distribution=okd" > "$T/m6/aba.conf"; _man "$T/m6" okd "$ICS"
( cd "$T/m6" && env -i PATH="/usr/bin:/bin" HOME="$T" bash scripts/cluster-clean.sh >/dev/null 2>&1 )
[ ! -e "$T/m6/openshift" ] && _pass "clean: empty openshift/ dir removed" || _fail "clean: empty openshift/ left behind"
# OCP: a file of the user that happens to start with 99-aba- is none of clean's business (nor is its directory)
for k in "none" "ocp" "empty"; do
	d="$T/m8-$k"; mkdir -p "$d/openshift"; ln -s "$REPO/scripts" "$d/scripts"; ln -s "$REPO/templates" "$d/templates"
	case "$k" in ocp) echo "distribution=ocp" > "$d/aba.conf" ;; empty) echo "distribution=" > "$d/aba.conf" ;; esac
	echo "user: 1" > "$d/openshift/99-aba-mine.yaml"; echo "user: 2" > "$d/openshift/10-mine.yaml"
	( cd "$d" && env -i PATH="/usr/bin:/bin" HOME="$T" bash scripts/cluster-clean.sh >/dev/null 2>&1 )
	[ -s "$d/openshift/99-aba-mine.yaml" ] && [ -s "$d/openshift/10-mine.yaml" ] && _pass "clean on ocp (aba.conf: $k): openshift/ untouched" || _fail "clean on ocp (aba.conf: $k): removed a user file ($(ls "$d/openshift" 2>&1 | tr '\n' ' '))"
done
d="$T/m8-only"; mkdir -p "$d/openshift"; ln -s "$REPO/scripts" "$d/scripts"; ln -s "$REPO/templates" "$d/templates"; echo "x: 1" > "$d/openshift/99-aba-mine.yaml"
( cd "$d" && env -i PATH="/usr/bin:/bin" HOME="$T" bash scripts/cluster-clean.sh >/dev/null 2>&1 )
[ -s "$d/openshift/99-aba-mine.yaml" ] && _pass "clean on ocp: the only user file in openshift/ kept, and so is the directory" || _fail "clean on ocp: removed the only user file"
# a cluster installed as OKD stays an OKD cluster for clean even if aba.conf was changed to ocp since
d="$T/m9"; mkdir -p "$d/clusterstate"; ln -s "$REPO/scripts" "$d/scripts"; ln -s "$REPO/templates" "$d/templates"
echo "distribution=ocp" > "$d/aba.conf"; echo "distribution=okd" > "$d/clusterstate/state.sh"
_man "$d" okd "$ICS"
( cd "$d" && env -i PATH="/usr/bin:/bin" HOME="$T" bash scripts/cluster-clean.sh >/dev/null 2>&1 )
[ ! -e "$d/$SAMPLES" ] && [ ! -e "$d/$HUB" ] && _pass "clean: cluster installed as okd (state) but aba.conf says ocp: generated manifests removed" || _fail "clean: okd cluster state not honoured"

# =====================================================================================================
echo ""
echo "=== create-install-config.sh end to end (shims) ==="
# the real IDMS names the lab registry; the fixture tree uses registry.example.com, so give the IDMS the same host
sed 's#registry\.example\.com#registry.example.com#g' "$IDMS" > "$T/idms-example.yaml"
r=$T/e1; okd_fx_init "$r" 4.21.0-okd-scos.11 okd mirror || _fail "e1 fixture"
okd_fx_creds "$r" mirror with-ca
okd_fx_mirror_output "$r" 4.21.0-okd-scos.11 "$HEX_A" "$T/idms-example.yaml"
export FAKE_INSTALL_VERSION=4.21.0-okd-scos.11
export FAKE_INSTALL_RELEASE_IMAGE="registry.example.com:8443/ocp4/openshift4/openshift/release-images@sha256:$HEX_A"
okd_fx_run "$r" bash scripts/create-install-config.sh > "$r/out" 2>&1; rc=$?
unset FAKE_INSTALL_VERSION FAKE_INSTALL_RELEASE_IMAGE
_eq "okd mirror: create-install-config.sh succeeds" 0 "$rc"
[ "$rc" -eq 0 ] || sed 's/^/    /' "$r/out" | tail -15
ic=$(yaml2json < "$r/demo/install-config.yaml" 2>/dev/null)
_eq "okd mirror: install-config sources" "quay.io/okd/scos-content,registry.ci.openshift.org/origin/release-scos,quay.io/okd/scos-release" \
	"$(jq -r '[(.ImageDigestSources // .imageDigestSources)[] | .source] | join(",")' <<<"$ic")"
[ -s "$r/demo/$SAMPLES" ] && [ -s "$r/demo/$HUB" ] && _pass "okd mirror: both install-time manifests next to install-config.yaml" || _fail "okd mirror: install-time manifests missing"
if grep -q 'openshift-release-dev' "$r/demo/install-config.yaml"; then _fail "okd mirror: OCP source in install-config.yaml"; else _pass "okd mirror: no OCP source in install-config.yaml"; fi

# direct: no content sources, no manifests
r=$T/e2; okd_fx_init "$r" 4.21.0-okd-scos.11 okd direct || _fail "e2 fixture"
okd_fx_creds "$r" none no-ca
export FAKE_INSTALL_VERSION=4.21.0-okd-scos.11
okd_fx_run "$r" bash scripts/create-install-config.sh > "$r/out" 2>&1; rc=$?
unset FAKE_INSTALL_VERSION
_eq "okd direct: create-install-config.sh succeeds" 0 "$rc"
[ "$rc" -eq 0 ] || sed 's/^/    /' "$r/out" | tail -15
[ ! -e "$r/demo/openshift" ] && _pass "okd direct: no install-time manifests (OKD defaults)" || _fail "okd direct: openshift/ created"
if grep -qi 'ImageDigestSources' "$r/demo/install-config.yaml"; then _fail "okd direct: no mirror sources expected"; else _pass "okd direct: no mirror sources"; fi

# OCP mirror: the same run as before the change, no openshift/ dir
r=$T/e3; okd_fx_init "$r" 4.19.5 ocp mirror || _fail "e3 fixture"
okd_fx_creds "$r" mirror with-ca
export FAKE_INSTALL_VERSION=4.19.5 FAKE_INSTALL_RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release@sha256:$HEX_A"
okd_fx_run "$r" bash scripts/create-install-config.sh > "$r/out" 2>&1; rc=$?
unset FAKE_INSTALL_VERSION FAKE_INSTALL_RELEASE_IMAGE
_eq "ocp mirror: create-install-config.sh succeeds" 0 "$rc"
[ ! -e "$r/demo/openshift" ] && _pass "ocp mirror: no openshift/ dir" || _fail "ocp mirror: openshift/ created"
grep -q 'ocp-v4.0-art-dev' "$r/demo/install-config.yaml" && _pass "ocp mirror: template sources" || _fail "ocp mirror: template sources missing"

# okd with a mirror but no oc-mirror IDMS: no install-config is written, the run fails
r=$T/e4; okd_fx_init "$r" 4.21.0-okd-scos.11 okd mirror || _fail "e4 fixture"
okd_fx_creds "$r" mirror with-ca
export FAKE_INSTALL_VERSION=4.21.0-okd-scos.11
okd_fx_run "$r" bash scripts/create-install-config.sh > "$r/out" 2>&1; rc=$?
unset FAKE_INSTALL_VERSION
[ "$rc" -ne 0 ] && _pass "okd mirror without oc-mirror output: fails (rc=$rc)" || _fail "okd mirror without oc-mirror output must fail"
[ ! -e "$r/demo/install-config.yaml" ] && _pass "okd mirror without oc-mirror output: no install-config.yaml" || _fail "okd mirror without oc-mirror output: install-config.yaml written"
[ ! -e "$r/demo/openshift" ] && _pass "okd mirror without oc-mirror output: no manifests" || _fail "okd mirror without oc-mirror output: manifests written"

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
