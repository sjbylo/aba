#!/bin/bash
# Test: reg-create-imageset-config.sh on OKD -- the real script in a scratch tree
#
# The image set config names the release by digest (read at run time). This test runs the script
# itself and checks what a user sees: the digest in the file, the two different abort messages
# (no digest published / manifest unreadable), excl_platform, the upgrade guard that comes before
# any lookup, and the platform / architecture block. Offline: curl and skopeo are shims.

cd "$(dirname "$0")/../.." || exit 1
REPO="$PWD"

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }
_chk() { [[ "$2" == "$3" ]] && _pass "$1" || _fail "$1: expected [$2] got [$3]"; }
_has() { [[ "$3" == *"$2"* ]] && _pass "$1" || _fail "$1: [$2] not in [${3:0:300}]"; }
_hasnt() { [[ "$3" != *"$2"* ]] && _pass "$1" || _fail "$1: [$2] must not be in [${3:0:300}]"; }

echo "=== reg-create-imageset-config.sh on OKD (scratch tree) ==="

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FX="$REPO/test/func/fixtures/okd-real"
export HOME="$T/home"; mkdir -p "$HOME/.aba" "$T/bin"
R="$T/repo"; mkdir -p "$R/mirror/data"
for n in scripts templates Makefile VERSION; do cp -a --reflink=auto "$REPO/$n" "$R/$n"; done
ln -s ../scripts "$R/mirror/scripts"; ln -s ../templates "$R/mirror/templates"; ln -s ../aba.conf "$R/mirror/aba.conf"
ln -s ../templates/Makefile.mirror "$R/mirror/Makefile"
printf 'reg_host=registry.example.test\nreg_port=8443\nreg_path=/ocp4\nreg_vendor=docker\n' > "$R/mirror/mirror.conf"

# Offline internet: the OKD graph and the release of one tag from the shipped real data; everything else fails.
cat > "$T/bin/curl" <<'EOS'
#!/usr/bin/bash
url=""; out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; http*) url="$1"; shift;; *) shift;; esac; done
echo "$url" >> "$CURL_LOG"
f=""
case "$url" in
	https://api.github.com/repos/okd-project/okd/releases/tags/*) f="$FX/release_${url##*/tags/}.json" ;;
	https://updates.okd.io/api/updates/graph\?channel=*) c="${url#*channel=}"; c="${c%%&*}"; f="$FX/graph_$c.json" ;;
esac
[ -n "$f" ] && [ -f "$f" ] || exit 22
cp "$f" "$out"
EOS
# Offline registry: the release index is a manifest list, its amd64 image is $CHILD. SK_MODE=down = unreachable.
cat > "$T/bin/skopeo" <<'EOS'
#!/usr/bin/bash
echo "$*" >> "$SKOPEO_LOG"
[ "${SK_MODE:-}" != down ] || exit 1
printf '{"schemaVersion":2,"manifests":[{"platform":{"architecture":"amd64","os":"linux"},"digest":"sha256:%s"},{"platform":{"architecture":"arm64","os":"linux"},"digest":"sha256:%s"}]}\n' "$CHILD" "$OTHER"
EOS
chmod +x "$T/bin/curl" "$T/bin/skopeo"
export FX CURL_LOG="$T/curl.log" SKOPEO_LOG="$T/skopeo.log"
CHILD=$(printf 'child' | sha256sum | cut -d' ' -f1); OTHER=$(printf 'other' | sha256sum | cut -d' ' -f1); export CHILD OTHER
PIN=$(sed -n 's/^Pull From: .*@sha256://p' <(jq -r .body "$FX/release_4.21.0-okd-scos.11.json"))

# conf <key=value>... : aba.conf of the scratch tree (OKD, bare metal, stable) plus the given lines
conf() {
	{ printf 'distribution=okd\nocp_version=4.21.0-okd-scos.11\nocp_channel=stable\nplatform=bm\ndomain=example.test\nverify_conf=all\nask=false\neditor=none\npull_secret_file=%s/.pull-secret.json\n' "$HOME"
	  printf '%s\n' "$@"; } > "$R/aba.conf"
}
# isc [env...] : run the real script; prints its output (colours stripped) and rc=N
isc() {
	rm -rf "$R/mirror/data"; mkdir -p "$R/mirror/data"; rm -rf "$HOME/.aba/cache"; : > "$CURL_LOG"; : > "$SKOPEO_LOG"
	( cd "$R/mirror" && env -i PATH="$T/bin:/usr/sbin:/usr/bin:/bin" HOME="$HOME" TERM=dumb PLAIN_OUTPUT=1 LC_ALL=C.UTF-8 FX="$FX" CURL_LOG="$CURL_LOG" \
		SKOPEO_LOG="$SKOPEO_LOG" CHILD="$CHILD" OTHER="$OTHER" "$@" INFO_ABA= timeout 100 scripts/reg-create-imageset-config.sh -f force </dev/null 2>&1; echo "rc=$?" ) | sed 's/\x1b\[[0-9;]*m//g'
}
rc_of() { sed -n 's/^rc=//p' <<< "$1" | tail -1; }
isc_file() { cat "$R/mirror/data/imageset-config.yaml" 2>/dev/null; }

# --- the file: the amd64 image of the release ------------------------------------------------
conf; out=$(isc env X=1)
_chk "okd: script succeeds" 0 "$(rc_of "$out")"
_chk "okd: no shell error text in the output of a successful run" 0 "$(grep -c -E 'unary operator|command not found|syntax error|: line [0-9]+:' <<< "$out")"
f=$(isc_file)
_has "okd: release is the amd64 image of the published digest" "release: quay.io/okd/scos-release@sha256:$CHILD" "$f"
_hasnt "okd: not the index digest" "$PIN" "$f"
_has "okd: no graph" "graph: false" "$f"
_hasnt "okd: no channels block" "channels:" "$f"
_hasnt "okd: a build the graph lists needs no request to GitHub" "api.github.com" "$(cat "$CURL_LOG")"
# a GA build the stable graph does not list (older than the graph): the release itself names its image
conf "ocp_version=4.19.0-okd-scos.19"; out=$(isc env X=1)
_chk "okd: an old GA build, not in any graph: script succeeds" 0 "$(rc_of "$out")"
_has "okd: an old GA build: release is the amd64 image of its published digest" "release: quay.io/okd/scos-release@sha256:$CHILD" "$(isc_file)"
_has "okd: an old GA build: asked GitHub for that tag" "https://api.github.com/repos/okd-project/okd/releases/tags/4.19.0-okd-scos.19" "$(cat "$CURL_LOG")"
_has "okd: an old GA build: the registry was asked for the digest GitHub names" "docker://quay.io/okd/scos-release@sha256:d6a4b74886326bd2196bd834f8351a4e142a9ffd278beef1b56f5da9cdb772e2" "$(cat "$SKOPEO_LOG")"

# --- the two ways the digest lookup fails say different things -------------------------------------
conf "ocp_version=4.21.0-okd-scos.99"; out=$(isc env X=1)
_chk "unknown build: aborts" 1 "$(rc_of "$out")"
_has "unknown build: no digest is published" "Cannot find the release image digest of OKD 4.21.0-okd-scos.99" "$out"
_hasnt "unknown build: not the manifest message" "Cannot read the release image manifest" "$out"
_chk "unknown build: no file written" "" "$(isc_file)"
conf; out=$(isc env SK_MODE=down)
_chk "registry unreachable: aborts" 1 "$(rc_of "$out")"
_has "registry unreachable: manifest message" "Cannot read the release image manifest of OKD 4.21.0-okd-scos.11" "$out"
_has "registry unreachable: names the architecture" "The image of architecture amd64 is needed" "$out"
_hasnt "registry unreachable: not the digest message" "Cannot find the release image digest" "$out"
_chk "registry unreachable: no file written" "" "$(isc_file)"

# --- excl_platform: the release block is commented, nothing else is ---------------------------------
printf 'quay.io/okd/example@sha256:%s\n' "$CHILD" > "$R/images.conf"
conf "excl_platform=true"; out=$(isc env X=1)
f=$(isc_file)
_chk "excl_platform: script succeeds" 0 "$(rc_of "$out")"
_has "excl_platform: release line commented" "#    release: quay.io/okd/scos-release@sha256:$CHILD" "$f"
_has "excl_platform: the block ends at its last key" "#    graph: false" "$f"
_has "excl_platform: additional images stay live" $'\n  additionalImages:' "$f"
_has "excl_platform: the image under it stays live" "- name: quay.io/okd/example@sha256:$CHILD" "$f"
conf "excl_platform=true" "ocp_version=4.21.0-okd-scos.99"; out=$(isc env X=1)
_chk "excl_platform: an unknown build does not stop the script" 0 "$(rc_of "$out")"
_has "excl_platform: the digest is shown as not resolved" "(not resolved, platform excluded)" "$(isc_file)"
rm -f "$R/images.conf"

# --- an upgrade target stops first, with the OKD message, before any lookup ---------------------------
printf 'ocp_upgrade_to=4.22.0-okd-scos.3\n' >> "$R/mirror/mirror.conf"
conf; out=$(isc env X=1)
_chk "okd + ocp_upgrade_to: aborts" 1 "$(rc_of "$out")"
_has "okd + ocp_upgrade_to: the OKD message" "Mirroring an upgrade target (ocp_upgrade_to=4.22.0-okd-scos.3) is unsupported for OKD" "$out"
_hasnt "okd + ocp_upgrade_to: no OCP upgrade text" "Upgrade mode" "$out"
_hasnt "okd + ocp_upgrade_to: no OCP graph path text" "No upgrade path" "$out"
_chk "okd + ocp_upgrade_to: nothing was looked up" 0 "$(wc -l < "$CURL_LOG")"
conf "ocp_version=4.21.0-okd-scos.99"; out=$(isc env X=1)
_has "okd + ocp_upgrade_to + unknown build: still the OKD message first" "is unsupported for OKD" "$out"
_hasnt "okd + ocp_upgrade_to + unknown build: not the digest message" "Cannot find the release image digest" "$out"
sed -i '/^ocp_upgrade_to=/d' "$R/mirror/mirror.conf"
printf 'ocp_upgrade_to=4.21.0-okd-scos.11\n' >> "$R/mirror/mirror.conf"
conf; out=$(isc env X=1)
_chk "okd + ocp_upgrade_to equal to ocp_version is no upgrade: succeeds" 0 "$(rc_of "$out")"
sed -i '/^ocp_upgrade_to=/d' "$R/mirror/mirror.conf"

# --- vSphere and other architectures stop at the config check ---------------------------------------
conf "platform=vmw"; out=$(isc env X=1)
_chk "okd + platform vmw: aborts" 1 "$(rc_of "$out")"
_has "okd + platform vmw: clear message" "platform [vmw] (VMware vSphere) is not supported for OKD" "$out"
_chk "okd + platform vmw: nothing looked up" 0 "$(wc -l < "$CURL_LOG")"
mkdir -p "$T/arm"; printf '#!/usr/bin/bash\n[ "$1" = "-m" ] && { echo aarch64; exit 0; }\nexec /usr/bin/uname "$@"\n' > "$T/arm/uname"; chmod +x "$T/arm/uname"
conf; out=$(PATH="$T/arm:$PATH"; isc env PATH="$T/arm:$T/bin:/usr/sbin:/usr/bin:/bin")
_chk "okd on arm64: aborts" 1 "$(rc_of "$out")"
_has "okd on arm64: clear message" "architecture [arm64] is not supported for OKD" "$out"
_chk "okd on arm64: nothing looked up" 0 "$(wc -l < "$CURL_LOG")"

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
