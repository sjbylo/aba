#!/bin/bash
# Test: okd_release_payload_ref -- release payload pull spec of an OKD build
#
# The ImageSetConfiguration for OKD names the release by digest. The digest is
# read at run time (update graph node, else GitHub release notes), never kept
# in the code. Unit tier: HTTP is mocked by a curl shim, no network needed.
# The release notes are read with one request per build (releases/tags/<tag>), so a
# build of any age resolves, whichever page of the release list it would be on.

cd "$(dirname "$0")/../.." || exit 1
source scripts/include_all.sh 2>/dev/null
trap - ERR

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }
_chk() { [[ "$2" == "$3" ]] && _pass "$1" || _fail "$1: expected [$2] got [$3]"; }

echo "=== okd_release_payload_ref (unit) ==="

_ROOT="$PWD"
_FX=$(mktemp -d); _BIN=$(mktemp -d); _HOME=$(mktemp -d)
trap 'rm -rf "$_FX" "$_BIN" "$_HOME"' EXIT
export _FX CURL_LOG="$_HOME/curl.log"
export ABA_CACHE_DIR="$_HOME/cache" RUN_ONCE_DIR="$_HOME/run_once"

# Offline "internet": only the OKD lookup URLs answer, every URL is logged.
cat > "$_BIN/curl" <<'EOS'
#!/usr/bin/bash
url=""; out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; http*) url="$1"; shift;; *) shift;; esac; done
echo "$url" >> "$CURL_LOG"
f=""
case "$url" in
	https://api.github.com/repos/okd-project/okd/releases/tags/*)
		# GitHub "get a release by tag": the object of that tag, 404 (curl -f: 22) for an unknown one
		t="${url##*/tags/}"; f="$_FX/tag.json"
		[ -f "$_FX/releases.json" ] && jq -c --arg t "$t" '.[] | select(.tag_name == $t)' "$_FX/releases.json" | head -1 > "$f"
		[ -s "$f" ] || f="" ;;
	https://updates.okd.io/api/updates/graph\?channel=*)
		c="${url#*channel=}"; c="${c%%&*}"; a="${url##*arch=}"; f="$_FX/graph_${c}_${a}.json" ;;
esac
[ -n "$f" ] && [ -f "$f" ] || exit 22
cp "$f" "$out"
EOS
chmod +x "$_BIN/curl"

# Offline registry: "skopeo inspect --raw docker://repo@sha256:<d>" answers from $_FX/manifest_<d>.json;
# a digest without a fixture is a plain single-architecture image. SK_FAIL=1 = registry unreachable.
cat > "$_BIN/skopeo" <<'EOS'
#!/usr/bin/bash
echo "$*" >> "$SKOPEO_LOG"
[ -z "${SK_FAIL:-}" ] || exit 1
ref="${*: -1}"; d="${ref##*@sha256:}"
if [ -f "$_FX/manifest_$d.json" ]; then cat "$_FX/manifest_$d.json"
else echo '{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json","layers":[]}'; fi
EOS
chmod +x "$_BIN/skopeo"
export PATH="$_BIN:$PATH" SKOPEO_LOG="$_HOME/skopeo.log"

REPO="quay.io/okd/scos-release"
# A digest that depends on the input, so a result that ignores the input cannot pass
dg() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

# graph: args "version" or "version=payload"
mk_graph() {
	local out="$1" s v p; shift
	for s in "$@"; do
		v="${s%%=*}"; p="$REPO@sha256:$(dg "$v")"
		[[ "$s" == *=* ]] && p="${s#*=}"
		jq -nc --arg v "$v" --arg p "$p" '{version:$v,payload:$p}'
	done | jq -sc '{nodes: ., edges: []}' > "$out"
}
# releases: args "tag" or "tag:pre" ; the notes carry a "Pull From" line
mk_releases() {
	local out="$1" s t pre body; shift
	for s in "$@"; do
		t="${s%%:*}"; pre=false; [[ "$s" == *:pre ]] && pre=true
		body=$(printf 'Client tools\n\nName:           %s\nDigest:         sha256:%s\n\nPull From: %s@sha256:%s\n\nRelease Metadata:\n' "$t" "$(dg "gh-$t")" "$REPO" "$(dg "gh-$t")")
		jq -nc --arg t "$t" --arg b "$body" --argjson p "$pre" '{tag_name:$t,name:$t,prerelease:$p,draft:false,body:$b}'
	done | jq -sc '.' > "$out"
}
reset() { rm -rf "$_FX"/* "$ABA_CACHE_DIR"; : > "$CURL_LOG"; : > "$SKOPEO_LOG"; unset SK_FAIL; }
# manifest list: args file arch=digest...
mk_list() {
	local out="$1" s; shift
	for s in "$@"; do jq -nc --arg a "${s%%=*}" --arg d "${s#*=}" '{platform:{architecture:$a,os:"linux"},digest:$d}'; done \
		| jq -sc '{schemaVersion:2,mediaType:"application/vnd.docker.distribution.manifest.list.v2+json",manifests:.}' > "$out"
}

export ARCH=amd64
export distribution=okd

if declare -F okd_release_payload_ref >/dev/null; then
	_pass "helper defined: okd_release_payload_ref"
else
	_fail "helper missing: okd_release_payload_ref"
	echo "Results: $pass passed, $fail failed"; exit 1
fi

# --- graph node ---------------------------------------------------------------
reset
mk_graph "$_FX/graph_stable-4.21_amd64.json" 4.21.0-okd-scos.10 4.21.0-okd-scos.11
mk_graph "$_FX/graph_stable-4.20_amd64.json" 4.20.0-okd-scos.8
mk_graph "$_FX/graph_stable-5.0_amd64.json" 5.0.0-okd-scos.5
_chk "graph node digest (4.21)" "$REPO@sha256:$(dg 4.21.0-okd-scos.11)" "$(okd_release_payload_ref 4.21.0-okd-scos.11 stable)"
_chk "the right node of several (4.21 older build)" "$REPO@sha256:$(dg 4.21.0-okd-scos.10)" "$(okd_release_payload_ref 4.21.0-okd-scos.10 stable)"
_chk "another minor gives another digest (4.20)" "$REPO@sha256:$(dg 4.20.0-okd-scos.8)" "$(okd_release_payload_ref 4.20.0-okd-scos.8 stable)"
_chk "another major (5.0)" "$REPO@sha256:$(dg 5.0.0-okd-scos.5)" "$(okd_release_payload_ref 5.0.0-okd-scos.5 stable)"
_chk "channel defaults to stable" "$REPO@sha256:$(dg 5.0.0-okd-scos.5)" "$(okd_release_payload_ref 5.0.0-okd-scos.5)"
grep -q '^https://updates.okd.io/api/updates/graph?channel=stable-5.0&arch=amd64$' "$CURL_LOG" \
	&& _pass "asked the OKD graph for channel-minor and arch" || _fail "graph URL not requested: $(cat "$CURL_LOG")"
_n=$(grep -vc -E '^https://(updates.okd.io|api.github.com/repos/okd-project)/' "$CURL_LOG")
_chk "no host other than the OKD graph / GitHub contacted" 0 "$_n"

# --- cache: a second call does not hit the network again --------------------------
: > "$CURL_LOG"
okd_release_payload_ref 4.21.0-okd-scos.11 stable >/dev/null
_chk "second lookup is served from the cache" 0 "$(wc -l < "$CURL_LOG")"

# --- channel and arch are part of the question ----------------------------------------
reset
mk_graph "$_FX/graph_candidate-4.22_amd64.json" 4.22.0-okd-scos.4
mk_graph "$_FX/graph_stable-4.22_amd64.json" 4.22.0-okd-scos.3
_chk "candidate-only build found in the candidate graph" "$REPO@sha256:$(dg 4.22.0-okd-scos.4)" "$(okd_release_payload_ref 4.22.0-okd-scos.4 candidate)"
okd_release_payload_ref 4.22.0-okd-scos.4 stable >/dev/null 2>&1; _chk "candidate-only build is not in the stable graph (no github data)" 1 $?
reset
mk_graph "$_FX/graph_stable-4.21_arm64.json" 4.21.0-okd-scos.11=$REPO@sha256:$(dg arm-4.21.0-okd-scos.11)
ARCH=arm64 okd_release_payload_ref 4.21.0-okd-scos.11 stable > "$_HOME/o" 2>/dev/null
_chk "arch is passed to the graph" "$REPO@sha256:$(dg arm-4.21.0-okd-scos.11)" "$(cat "$_HOME/o")"

# --- GitHub release notes when the graph does not list the build -------------------------
reset
mk_graph "$_FX/graph_stable-4.21_amd64.json" 4.21.0-okd-scos.10
mk_releases "$_FX/releases.json" 4.21.0-okd-scos.11 4.21.0-okd-scos.10 4.22.0-okd-scos.4:pre
_chk "build the graph lacks: Pull From line of the release" "$REPO@sha256:$(dg gh-4.21.0-okd-scos.11)" "$(okd_release_payload_ref 4.21.0-okd-scos.11 stable)"
_chk "graph wins over the release notes" "$REPO@sha256:$(dg 4.21.0-okd-scos.10)" "$(okd_release_payload_ref 4.21.0-okd-scos.10 stable)"
reset
mk_releases "$_FX/releases.json" 4.22.0-okd-scos.4:pre
_chk "pre-release on GitHub (candidate builds)" "$REPO@sha256:$(dg gh-4.22.0-okd-scos.4)" "$(okd_release_payload_ref 4.22.0-okd-scos.4 candidate)"

# --- nothing found -> failure, no output ----------------------------------------------
reset
out=$(okd_release_payload_ref 4.21.0-okd-scos.11 stable 2>/dev/null); rc=$?
_chk "no data at all: rc" 1 "$rc"; _chk "no data at all: nothing printed" "" "$out"
reset
mk_graph "$_FX/graph_stable-4.21_amd64.json" 4.21.0-okd-scos.10
mk_releases "$_FX/releases.json" 4.21.0-okd-scos.10
out=$(okd_release_payload_ref 4.21.0-okd-scos.99 stable 2>/dev/null); rc=$?
_chk "unknown build: rc" 1 "$rc"; _chk "unknown build: nothing printed" "" "$out"

# --- a payload that is not a digest of the OKD payload repo is never used ----------------
for bad in "$REPO:4.21.0-okd-scos.11" "$REPO@sha256:abc" "$REPO@sha256:$(dg x | tr a-f A-F)" "quay.io/openshift-release-dev/ocp-release@sha256:$(dg x)" "$REPO@sha256:$(dg x)x" "x $REPO@sha256:$(dg x)" "$REPO-other@sha256:$(dg x)" "other/$REPO@sha256:$(dg x)"; do
	reset
	mk_graph "$_FX/graph_stable-4.21_amd64.json" "4.21.0-okd-scos.11=$bad"
	out=$(okd_release_payload_ref 4.21.0-okd-scos.11 stable 2>/dev/null); rc=$?
	_chk "rejected graph payload [$bad]" "1|" "$rc|$out"
done
reset
mk_graph "$_FX/graph_stable-4.21_amd64.json" "4.21.0-okd-scos.11=$REPO:latest"
mk_releases "$_FX/releases.json" 4.21.0-okd-scos.11
_chk "a bad graph payload falls back to the release notes" "$REPO@sha256:$(dg gh-4.21.0-okd-scos.11)" "$(okd_release_payload_ref 4.21.0-okd-scos.11 stable)"
reset
jq -nc --arg t 4.21.0-okd-scos.11 --arg b "Pull From: quay.io/openshift-release-dev/ocp-release@sha256:$(dg x)" '[{tag_name:$t,prerelease:false,draft:false,body:$b}]' > "$_FX/releases.json"
okd_release_payload_ref 4.21.0-okd-scos.11 stable >/dev/null 2>&1; _chk "release notes pointing at another repo are rejected" 1 $?

# --- some builds publish a manifest list: the image of this architecture is the answer ---------------
reset
IDX="$(dg index-4.21.0-okd-scos.11)"
mk_graph "$_FX/graph_stable-4.21_amd64.json" "4.21.0-okd-scos.11=$REPO@sha256:$IDX"
mk_list "$_FX/manifest_$IDX.json" "amd64=sha256:$(dg child-amd64)" "arm64=sha256:$(dg child-arm64)"
_chk "manifest list from the graph -> amd64 image" "$REPO@sha256:$(dg child-amd64)" "$(okd_release_payload_ref 4.21.0-okd-scos.11 stable)"
grep -q "^inspect --raw docker://$REPO@sha256:$IDX\$" "$SKOPEO_LOG" && _pass "asked the registry for the manifest of the published digest (anonymous, raw)" || _fail "skopeo call: $(cat "$SKOPEO_LOG")"
_chk "no credentials passed to skopeo" 0 "$(grep -c -E 'authfile|creds' "$SKOPEO_LOG")"
reset
mk_graph "$_FX/graph_stable-4.21_arm64.json" "4.21.0-okd-scos.11=$REPO@sha256:$IDX"
mk_list "$_FX/manifest_$IDX.json" "amd64=sha256:$(dg child-amd64)" "arm64=sha256:$(dg child-arm64)"
_chk "manifest list -> image of the host architecture (arm64)" "$REPO@sha256:$(dg child-arm64)" "$(ARCH=arm64 okd_release_payload_ref 4.21.0-okd-scos.11 stable)"
reset
mk_releases "$_FX/releases.json" 4.21.0-okd-scos.11
GH="$(dg gh-4.21.0-okd-scos.11)"
mk_list "$_FX/manifest_$GH.json" "amd64=sha256:$(dg child-gh)"
_chk "manifest list from the release notes -> amd64 image" "$REPO@sha256:$(dg child-gh)" "$(okd_release_payload_ref 4.21.0-okd-scos.11 stable)"
reset
mk_graph "$_FX/graph_stable-4.21_amd64.json" "4.21.0-okd-scos.11=$REPO@sha256:$IDX"
mk_list "$_FX/manifest_$IDX.json" "arm64=sha256:$(dg child-arm64)"
out=$(okd_release_payload_ref 4.21.0-okd-scos.11 stable 2>/dev/null); rc=$?
_chk "manifest list without this architecture: rc 2, nothing printed" "2|" "$rc|$out"
mk_list "$_FX/manifest_$IDX.json" "amd64=sha256:$(dg a1)" "amd64=sha256:$(dg a2)"
out=$(okd_release_payload_ref 4.21.0-okd-scos.11 stable 2>/dev/null); rc=$?
_chk "two different amd64 images: ambiguous, rc 2" "2|" "$rc|$out"
mk_list "$_FX/manifest_$IDX.json" "amd64=sha256:$(dg a1)" "amd64=sha256:$(dg a1)"
_chk "same amd64 image listed twice: fine" "$REPO@sha256:$(dg a1)" "$(okd_release_payload_ref 4.21.0-okd-scos.11 stable)"
mk_list "$_FX/manifest_$IDX.json" "amd64=sha256:abc"
okd_release_payload_ref 4.21.0-okd-scos.11 stable >/dev/null 2>&1; _chk "malformed child digest: rc 2" 2 $?
printf 'not json\n' > "$_FX/manifest_$IDX.json"
okd_release_payload_ref 4.21.0-okd-scos.11 stable >/dev/null 2>&1; _chk "unreadable manifest: rc 2" 2 $?
printf '[1,2]\n' > "$_FX/manifest_$IDX.json"
okd_release_payload_ref 4.21.0-okd-scos.11 stable >/dev/null 2>&1; _chk "manifest of unexpected shape: rc 2" 2 $?
rm -f "$_FX/manifest_$IDX.json"
_chk "single image (no list): the published digest itself" "$REPO@sha256:$IDX" "$(okd_release_payload_ref 4.21.0-okd-scos.11 stable)"
SK_FAIL=1 okd_release_payload_ref 4.21.0-okd-scos.11 stable >/dev/null 2>&1; _chk "registry unreachable: rc 2" 2 $?
reset
mk_graph "$_FX/graph_stable-4.21_amd64.json" 4.21.0-okd-scos.11
_chk "skopeo is not asked for an unknown build" 0 "$(okd_release_payload_ref 4.21.0-okd-scos.99 stable >/dev/null 2>&1; wc -l < "$SKOPEO_LOG")"

# --- details of reading the sources -----------------------------------------------------------------------
reset
mk_releases "$_FX/releases.json" 4.21.0-okd-scos.11
sed -i 's/\\n/\\r\\n/g' "$_FX/releases.json"
_chk "release notes with CRLF line ends" "$REPO@sha256:$(dg gh-4.21.0-okd-scos.11)" "$(okd_release_payload_ref 4.21.0-okd-scos.11 stable)"
reset
mk_graph "$_FX/graph_stable-4.21_amd64.json" "4.21.0-okd-scos.11=$REPO@sha256:$IDX"
jq -nc --arg d "sha256:$(dg skip-attestation)" --arg c "sha256:$(dg real-child)" \
	'{schemaVersion:2,manifests:[{platform:{architecture:"amd64",os:"unknown"},digest:$d},{platform:{architecture:"amd64",os:"linux"},digest:$c}]}' > "$_FX/manifest_$IDX.json"
_chk "only the linux image counts (not an attestation entry)" "$REPO@sha256:$(dg real-child)" "$(okd_release_payload_ref 4.21.0-okd-scos.11 stable)"
reset
mk_graph "$_FX/graph_stable-4.21_amd64.json" "4.21.0-okd-scos.11=$REPO@sha256:$IDX" "4.21.0-okd-scos.12=$REPO@sha256:$(dg other)"
_chk "payload of the asked build, not of its neighbour" "$REPO@sha256:$IDX" "$(okd_release_payload_ref 4.21.0-okd-scos.11 stable)"
reset
mk_graph "$_FX/graph_stable-4.21_amd64.json" "4.21.0-okd-scos.11=$REPO@sha256:$IDX"
okd_release_payload_ref 4.21.0-okd-scos.11 stable >/dev/null 2>&1
_chk "the graph is asked for the minor of the build, not the major" 1 "$(grep -c 'channel=stable-4.21&' "$CURL_LOG")"

# --- inputs that are not an OKD build never reach the network ------------------------------
reset
for v in "" 4.21.0 4.21 5.0.0-okd-scos 4.21.0-okd-scos.11x "4.21.0-okd-scos.11 4.21.1" latest; do
	okd_release_payload_ref "$v" stable >/dev/null 2>&1; _chk "version [$v] rejected" 1 $?
done
_chk "no request made for those inputs" 0 "$(wc -l < "$CURL_LOG")"
reset
distribution=ocp okd_release_payload_ref 4.21.0-okd-scos.11 stable >/dev/null 2>&1; _chk "ocp distribution: refused" 1 $?
_chk "ocp distribution: no request" 0 "$(wc -l < "$CURL_LOG")"
reset
mk_graph "$_FX/graph_stable-4.22_amd64.json" "4.22.1=quay.io/openshift-release-dev/ocp-release@sha256:$(dg ocp-4.22.1)"
out=$(distribution=ocp okd_release_payload_ref 4.22.1 stable 2>/dev/null); rc=$?
_chk "ocp distribution with an OCP version: refused, nothing printed" "1|" "$rc|$out"
_chk "ocp distribution with an OCP version: no request" 0 "$(wc -l < "$CURL_LOG")"

# --- fresh shell (as a run_once task) reads the distribution from aba.conf ----------------------
reset
mkdir -p "$_HOME/proj"; printf 'distribution=okd\n' > "$_HOME/proj/aba.conf"
mk_graph "$_FX/graph_stable-4.21_amd64.json" 4.21.0-okd-scos.11
_got=$(cd "$_HOME/proj" && env -u distribution PATH="$PATH" ABA_CACHE_DIR="$ABA_CACHE_DIR" bash -c "source $_ROOT/scripts/include_all.sh 2>/dev/null; trap - ERR; ARCH=amd64; okd_release_payload_ref 4.21.0-okd-scos.11 stable")
_chk "distribution taken from aba.conf in a fresh shell" "$REPO@sha256:$(dg 4.21.0-okd-scos.11)" "$_got"

# --- any build the resolver accepts resolves: graph node, else ONE request for that tag ------------------------
# Real release objects (see fixtures/okd-real/README); the expected digests are the Pull From lines of GitHub.
RFX="$_ROOT/test/func/fixtures/okd-real"
real_releases() { jq -sc '.' "$RFX"/release_*.json > "$_FX/releases.json"; }
gh_calls() { grep -c '^https://api.github.com/' "$CURL_LOG"; }
D419="d6a4b74886326bd2196bd834f8351a4e142a9ffd278beef1b56f5da9cdb772e2"
D4211="dd553282fb655f2461278af54c6eacda022b105664236ce4ad57091b5f6439c4"
DEC7="55e34130432c4d3e29599c7ce723ebb77274a1af851d9379078894808359135f"

reset; real_releases
_chk "old GA build (no graph data at all, page 2 of the list): digest of its release" "$REPO@sha256:$D419" "$(okd_release_payload_ref 4.19.0-okd-scos.19 stable)"
_chk "old GA build: exactly one GitHub request" 1 "$(gh_calls)"
_chk "old GA build: the request names the tag, no list page" "https://api.github.com/repos/okd-project/okd/releases/tags/4.19.0-okd-scos.19" "$(grep '^https://api.github.com/' "$CURL_LOG")"
: > "$CURL_LOG"
okd_release_payload_ref 4.19.0-okd-scos.19 stable >/dev/null
_chk "old GA build: a second lookup is served from the cache" 0 "$(gh_calls)"
_chk "old GA build: one cache entry per tag" "okd_release_4.19.0-okd-scos.19.json" "$(ls "$ABA_CACHE_DIR" | grep '^okd_release_' | sed -E 's/\.[A-Za-z0-9]{6}$//' | paste -sd' ')"
_chk "old GA build: cache entry keeps the Pull From line, not the notes" 1 "$([[ $(stat -c %s "$ABA_CACHE_DIR/okd_release_4.19.0-okd-scos.19.json") -lt 400 ]] && echo 1 || echo 0)"

reset; real_releases
jq -c '.nodes |= map(select(.version != "4.21.0-okd-scos.11"))' "$RFX/graph_stable-4.21.json" > "$_FX/graph_stable-4.21_amd64.json"
_chk "lab pin absent from the stable graph: digest from its release" "$REPO@sha256:$D4211" "$(okd_release_payload_ref 4.21.0-okd-scos.11 stable)"
reset; real_releases
cp "$RFX/graph_stable-4.21.json" "$_FX/graph_stable-4.21_amd64.json"
_chk "lab pin listed by the graph: same digest" "$REPO@sha256:$D4211" "$(okd_release_payload_ref 4.21.0-okd-scos.11 stable)"
_chk "a build the graph lists: no GitHub request" 0 "$(gh_calls)"

reset; real_releases
_chk "ec build on candidate (graph has no node): digest from its release" "$REPO@sha256:$DEC7" "$(okd_release_payload_ref 4.20.0-okd-scos.ec.7 candidate)"
okd_release_payload_ref 4.20.0-okd-scos.ec.7 stable >/dev/null 2>&1; _chk "ec build on stable: not a valid version there, rc 1" 1 $?

# a tag from page 3 of a 250-release list (synthetic; the list itself is never read)
reset
mk_releases "$_FX/releases.json" $(for i in $(seq 1 250); do printf '7.%s.0-okd-scos.1 ' "$i"; done)
_chk "tag from page 3 of 250: digest from its release" "$REPO@sha256:$(dg gh-7.230.0-okd-scos.1)" "$(okd_release_payload_ref 7.230.0-okd-scos.1 stable)"
_chk "tag from page 3 of 250: one request, for that tag" "https://api.github.com/repos/okd-project/okd/releases/tags/7.230.0-okd-scos.1" "$(grep '^https://api.github.com/' "$CURL_LOG")"

# nothing found for that tag -> no output, rc 1 (the caller aborts)
reset; real_releases
out=$(okd_release_payload_ref 4.19.0-okd-scos.99 stable 2>/dev/null); rc=$?
_chk "tag GitHub does not know: rc" 1 "$rc"; _chk "tag GitHub does not know: nothing printed" "" "$out"
_chk "tag GitHub does not know: not cached" 0 "$(ls "$ABA_CACHE_DIR" 2>/dev/null | grep -c '^okd_release_' || true)"
# GitHub answering with another release, or with a list, is no answer
reset; real_releases
mkdir -p "$ABA_CACHE_DIR"
cp "$RFX/release_4.19.0-okd-scos.19.json" "$_FX/other.json"
cat > "$_BIN/curl" <<'EOS'
#!/usr/bin/bash
url=""; out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; http*) url="$1"; shift;; *) shift;; esac; done
echo "$url" >> "$CURL_LOG"
case "$url" in
	https://api.github.com/repos/okd-project/okd/releases/tags/*) cp "$_FX/other.json" "$out" ;;
	*) exit 22 ;;
esac
EOS
okd_release_payload_ref 4.21.0-okd-scos.11 stable >/dev/null 2>&1; _chk "answer is the release of another tag: rc 1" 1 $?
_chk "answer is the release of another tag: not used for the asked build" 0 "$(ls "$ABA_CACHE_DIR" 2>/dev/null | grep -c '^okd_release_4.21.0-okd-scos.11.json$' || true)"
jq -sc '.' "$RFX"/release_*.json > "$_FX/other.json"
rm -rf "$ABA_CACHE_DIR"
okd_release_payload_ref 4.19.0-okd-scos.19 stable >/dev/null 2>&1; _chk "answer is a list, not a release: rc 1" 1 $?
_chk "answer is a list, not a release: not cached" 0 "$(ls "$ABA_CACHE_DIR" 2>/dev/null | grep -c '^okd_release_' || true)"
printf 'not json' > "$_FX/other.json"
okd_release_payload_ref 4.19.0-okd-scos.19 stable >/dev/null 2>&1; _chk "answer is not JSON: rc 1" 1 $?

echo ""
echo "Results: $pass passed, $fail failed"
exit "$fail"
