#!/bin/bash
# Test: distribution helpers (dist_*) in include_all.sh -- ocp branch == today's constants,
# okd branch == the OKD distribution constants, nothing version-specific hard-coded.
# Unit tier: no network, no aba.conf in the repo needed.

cd "$(dirname "$0")/../.." || exit 1
REPO_ROOT="$PWD"
source scripts/include_all.sh 2>/dev/null
trap - ERR

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

# _eq <label> <expected> <actual>
_eq() {
	if [[ "$2" == "$3" ]]; then _pass "$1"; else _fail "$1: expected [$2] got [$3]"; fi
}
# _rc <label> <expected-rc> <cmd...>
_rc() {
	local label="$1" want="$2" got
	shift 2
	"$@" >/dev/null 2>&1
	got=$?
	if [[ "$got" -eq "$want" ]]; then _pass "$label"; else _fail "$label: expected rc=$want got rc=$got"; fi
}

_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp"' EXIT

echo "=== distribution helpers (unit) ==="

for fn in dist_of dist_version_is_valid dist_release_payload_repo dist_release_image_ref \
	dist_cli_base_url dist_cli_sha256_url dist_graph_api dist_pull_secret_required dist_channel_is_valid dist_supports_channels dist_target_problem; do
	if declare -F "$fn" >/dev/null; then _pass "helper defined: $fn"; else _fail "helper missing: $fn"; fi
done

# ---------------------------------------------------------------- dist_of
echo ""
echo "--- dist_of ---"
unset distribution
mkdir -p "$_tmp/none" "$_tmp/conf-okd" "$_tmp/conf-ocp" "$_tmp/conf-empty" "$_tmp/conf-comment"
printf 'ocp_version=4.22.1\nplatform=bm\n' > "$_tmp/none/aba.conf"
printf 'ocp_version=4.22.1\ndistribution=okd\t\t# comment\n' > "$_tmp/conf-okd/aba.conf"
printf 'distribution=ocp\n' > "$_tmp/conf-ocp/aba.conf"
printf 'distribution=\n' > "$_tmp/conf-empty/aba.conf"
printf '#distribution=okd\n' > "$_tmp/conf-comment/aba.conf"

mkdir -p "$_tmp/conf-space" "$_tmp/conf-tail"
printf 'distribution= okd\n' > "$_tmp/conf-space/aba.conf"
printf 'distribution=okd   \n' > "$_tmp/conf-tail/aba.conf"
mkdir -p "$_tmp/bare"
_eq "dist_of: no var, no aba.conf in cwd -> ocp" "ocp" "$(cd "$_tmp/bare" && dist_of)"
_eq "dist_of: aba.conf without the key -> ocp" "ocp" "$(cd "$_tmp/none" && dist_of)"
_eq "dist_of: aba.conf distribution=okd (with comment) -> okd" "okd" "$(cd "$_tmp/conf-okd" && dist_of)"
_eq "dist_of: aba.conf distribution=ocp -> ocp" "ocp" "$(cd "$_tmp/conf-ocp" && dist_of)"
_eq "dist_of: empty value -> ocp" "ocp" "$(cd "$_tmp/conf-empty" && dist_of)"
_eq "dist_of: commented key -> ocp" "ocp" "$(cd "$_tmp/conf-comment" && dist_of)"
_eq "dist_of: variable wins over aba.conf" "okd" "$(cd "$_tmp/conf-ocp" && distribution=okd dist_of)"
_eq "dist_of: variable ocp wins over aba.conf okd" "ocp" "$(cd "$_tmp/conf-okd" && distribution=ocp dist_of)"
_eq "dist_of: leading space in the value is not part of it" "okd" "$(cd "$_tmp/conf-space" && dist_of)"
_eq "dist_of: trailing spaces are not part of the value" "okd" "$(cd "$_tmp/conf-tail" && dist_of)"
_eq "dist_of: variable with surrounding spaces is trimmed" "okd" "$(distribution=" okd " dist_of)"
# run_once starts tasks with a fresh `bash -lc 'source include_all.sh; ...'`: no variable, only aba.conf
_eq "dist_of: fresh shell (as run_once) reads aba.conf" "okd" \
	"$(cd "$_tmp/conf-okd" && env -u distribution bash -c "source '$REPO_ROOT/scripts/include_all.sh' 2>/dev/null; trap - ERR; dist_of" 2>/dev/null || true)"

# ---------------------------------------------------------------- dist_version_is_valid
echo ""
echo "--- dist_version_is_valid ---"
# ocp: regex of _is_version_string, unchanged
for v in 4.22.0 4.21.14 5.0.0 5.0.3 4.22.0-rc.1 5.0.0-rc.1 5.0.0-ec.2 4.23.0-ec.3; do
	_rc "ocp valid: $v" 0 env distribution=ocp bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid '$v'"
done
for v in "" foo 4.22 4.22.0- 04.22.0x 4.21.0-okd-scos.11 5.0.0-okd-scos.5 v4.22.0; do
	_rc "ocp invalid: [$v]" 1 env distribution=ocp bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid '$v'"
done
# ocp result == _is_version_string for every input (byte-for-byte same predicate)
for v in 4.22.0 5.0.0-ec.2 4.21.0-okd-scos.11 foo ""; do
	distribution=ocp dist_version_is_valid "$v"; _a=$?
	_is_version_string "$v"; _b=$?
	_eq "ocp: dist_version_is_valid == _is_version_string for [$v]" "$_b" "$_a"
done
# okd: only X.Y.Z-okd-scos.N, any release (no fixed version), incl. another major
for v in 4.21.0-okd-scos.11 4.20.0-okd-scos.3 5.0.0-okd-scos.5 4.22.7-okd-scos.1 10.2.3-okd-scos.40; do
	_rc "okd valid: $v" 0 env distribution=okd bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid '$v'"
done
for v in "" foo 4.22 4.22.0 5.0.0 4.22.0-rc.1 5.0.0-ec.2 4.21.0-okd-scos. 4.21.0-okd-scos.ec.2 4.21.0-okd-scos.11x \
	v4.21.0-okd-scos.11 4.21-okd-scos.11 4.21.0-okd-scos.11-1 "4.21.0-okd-scos.11 " " 4.21.0-okd-scos.11" 4.21.0-0.okd-2025-01-01-000000; do
	_rc "okd invalid: [$v]" 1 env distribution=okd bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid '$v'"
done
_rc "okd invalid: embedded newline" 1 env distribution=okd bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid \$'4.21.0-okd-scos.1\nfoo'"
_rc "okd invalid: no argument" 1 env distribution=okd bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid"

# okd pre-release builds (-okd-scos.ec.N): valid only when the channel argument is candidate.
# No channel, stable, and any other channel keep the strict release form.
for v in 5.0.0-okd-scos.ec.9 5.1.0-okd-scos.ec.2 4.22.0-okd-scos.ec.16 4.21.0-okd-scos.ec.0 10.2.3-okd-scos.ec.40; do
	_rc "okd candidate valid (ec build): $v" 0 env distribution=okd bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid '$v' candidate"
	_rc "okd stable invalid (ec build): $v" 1 env distribution=okd bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid '$v' stable"
	_rc "okd without channel invalid (ec build): $v" 1 env distribution=okd bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid '$v'"
	_rc "okd empty channel invalid (ec build): $v" 1 env distribution=okd bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid '$v' ''"
	_rc "okd fast channel invalid (ec build): $v" 1 env distribution=okd bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid '$v' fast"
done
# GA builds stay valid on every channel; the channel does not widen anything else
for ch in stable candidate ""; do
	_rc "okd GA build valid with channel [$ch]" 0 env distribution=okd bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid 5.0.0-okd-scos.5 '$ch'"
done
for v in 5.0.0-okd-scos.ec. 5.0.0-okd-scos.ec 5.0.0-okd-scos.ec.x 5.0.0-okd-scos.ec.9x 5.0.0-okd-scos.EC.9 5.0.0-okd-scos.rc.9 5.0.0-okd-scos.ec.9.1 \
	5.0.0-okd-scos.ecc.9 5.0-okd-scos.ec.9 v5.0.0-okd-scos.ec.9 5.0.0-okd-scos.ec.-1 5.0.0-ec.2 5.0.0-rc.1 5.0.0 4.22.1 "5.0.0-okd-scos.ec.9 " " 5.0.0-okd-scos.ec.9" foo ""; do
	_rc "okd candidate invalid: [$v]" 1 env distribution=okd bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid '$v' candidate"
done
_rc "okd candidate invalid: embedded newline" 1 env distribution=okd bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid \$'5.0.0-okd-scos.ec.9\nfoo' candidate"
# the channel argument never changes the ocp answer
for ch in "" stable candidate fast eus; do
	for v in 4.22.0 5.0.0-ec.2 4.22.0-rc.1; do
		_rc "ocp valid [$v] with channel [$ch]" 0 env distribution=ocp bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid '$v' '$ch'"
	done
	for v in 4.21.0-okd-scos.11 5.0.0-okd-scos.ec.9 foo; do
		_rc "ocp invalid [$v] with channel [$ch]" 1 env distribution=ocp bash -c "source scripts/include_all.sh 2>/dev/null; dist_version_is_valid '$v' '$ch'"
	done
done
# from aba.conf (fresh shell): same answers
_rc "distribution from aba.conf (okd): ec build valid on candidate" 0 bash -c "unset distribution; cd '$_tmp/conf-okd'; source '$REPO_ROOT/scripts/include_all.sh' 2>/dev/null; dist_version_is_valid 5.0.0-okd-scos.ec.9 candidate"
_rc "distribution from aba.conf (okd): ec build invalid on stable" 1 bash -c "unset distribution; cd '$_tmp/conf-okd'; source '$REPO_ROOT/scripts/include_all.sh' 2>/dev/null; dist_version_is_valid 5.0.0-okd-scos.ec.9 stable"
# pre-release classification: GA builds are releases, ec builds are pre-releases (the warning stays)
_rc "_is_prerelease: okd ec build is a pre-release" 0 bash -c "source scripts/include_all.sh 2>/dev/null; _is_prerelease 5.0.0-okd-scos.ec.9"
_rc "_is_prerelease: okd GA build is not" 1 bash -c "source scripts/include_all.sh 2>/dev/null; _is_prerelease 5.0.0-okd-scos.5"

# ---------------------------------------------------------------- payload repo / graph / CLI URLs
echo ""
echo "--- constants per distribution ---"
distribution=ocp
_eq "ocp payload repo"   "quay.io/openshift-release-dev/ocp-release" "$(dist_release_payload_repo)"
_eq "ocp graph api"      "$ABA_GRAPH_API" "$(dist_graph_api)"
_eq "ocp graph api is today's constant" "https://api.openshift.com/api/upgrades_info/v1/graph" "$(dist_graph_api)"
_arch="$(uname -m)"
_eq "ocp cli base url 4.21.14" "https://mirror.openshift.com/pub/openshift-v4/$_arch/clients/ocp/4.21.14" "$(dist_cli_base_url 4.21.14)"
_eq "ocp cli base url 5.0.3 (major 5)" "https://mirror.openshift.com/pub/openshift-v5/$_arch/clients/ocp/5.0.3" "$(dist_cli_base_url 5.0.3)"
_eq "ocp cli base url ec -> dev-preview" "https://mirror.openshift.com/pub/openshift-v4/$_arch/clients/ocp-dev-preview/4.23.0-ec.1" "$(dist_cli_base_url 4.23.0-ec.1)"
_eq "ocp cli base url rc stays under ocp" "https://mirror.openshift.com/pub/openshift-v4/$_arch/clients/ocp/4.22.0-rc.1" "$(dist_cli_base_url 4.22.0-rc.1)"
_eq "ocp cli sha256 url" "https://mirror.openshift.com/pub/openshift-v4/$_arch/clients/ocp/4.21.14/sha256sum.txt" "$(dist_cli_sha256_url 4.21.14)"
_eq "ocp release image ref (tag) 4.21.14" "4.21.14-$_arch" "$(dist_release_image_ref 4.21.14)"
_eq "ocp release image ref (tag) 5.0.3" "5.0.3-$_arch" "$(dist_release_image_ref 5.0.3)"

distribution=okd
_eq "okd payload repo"   "quay.io/okd/scos-release" "$(dist_release_payload_repo)"
_eq "okd graph api"      "https://updates.okd.io/api/updates/graph" "$(dist_graph_api)"
_eq "okd cli base url (version A)" "https://github.com/okd-project/okd/releases/download/4.21.0-okd-scos.11" "$(dist_cli_base_url 4.21.0-okd-scos.11)"
_eq "okd cli base url (version B)" "https://github.com/okd-project/okd/releases/download/4.20.0-okd-scos.3" "$(dist_cli_base_url 4.20.0-okd-scos.3)"
_eq "okd cli base url (major 5)"   "https://github.com/okd-project/okd/releases/download/5.0.0-okd-scos.5" "$(dist_cli_base_url 5.0.0-okd-scos.5)"
_eq "okd cli sha256 url follows the version" "https://github.com/okd-project/okd/releases/download/5.0.0-okd-scos.5/sha256sum.txt" "$(dist_cli_sha256_url 5.0.0-okd-scos.5)"
_eq "okd cli sha256 url (other version)" "https://github.com/okd-project/okd/releases/download/4.20.0-okd-scos.3/sha256sum.txt" "$(dist_cli_sha256_url 4.20.0-okd-scos.3)"

# a version is mandatory for the version-dependent helpers (no silent empty URL/tag)
for fn in dist_release_image_ref dist_cli_base_url dist_cli_sha256_url; do
	for d in ocp okd; do
		bash -c "distribution=$d; source scripts/include_all.sh 2>/dev/null; $fn" >/dev/null 2>&1 \
			&& _fail "$fn without a version must fail ($d)" || _pass "$fn without a version fails ($d)"
	done
done
# okd release image ref needs the mirror digest -> not decidable from the version: must refuse, not guess
# (a directory without oc-mirror output, so a mirror synced in this tree cannot answer)
_out=$(cd "$_tmp/bare" && dist_release_image_ref 4.21.0-okd-scos.11 2>&1); _rc=$?
[[ $_rc -ne 0 ]] && _pass "okd release image ref refuses (rc=$_rc)" || _fail "okd release image ref must not succeed without a digest"
[[ "$_out" == *"oc-mirror"* ]] && _pass "okd release image ref message names oc-mirror" || _fail "okd release image ref message lacks the cause: [$_out]"
# no internal ids in any user-visible text of the helper
_ids='\b(EP|ABA|DEC|OQ|WP)-[0-9]+|\bT[D]D\b'
_hits=$(printf '%s\n' "$_out" | grep -c -E "$_ids" || true)
_eq "okd release image ref message carries no internal id" "0" "$_hits"
# the ocp path must not call dist_of's okd side: same input, ocp stays a plain tag
distribution=ocp
_eq "ocp release image ref unaffected by an earlier okd call" "4.21.14-$_arch" "$(dist_release_image_ref 4.21.14)"

# ---------------------------------------------------------------- pull secret / channels
echo ""
echo "--- pull secret and channels ---"
distribution=ocp
_rc "ocp: pull secret required (nothing selected)" 0 bash -c "distribution=ocp; source scripts/include_all.sh 2>/dev/null; ops=; op_sets=; dist_pull_secret_required"
_rc "ocp: pull secret required (operators)"        0 bash -c "distribution=ocp; source scripts/include_all.sh 2>/dev/null; ops=x; dist_pull_secret_required"
_rc "okd: pull secret not required (no operators)" 1 bash -c "distribution=okd; source scripts/include_all.sh 2>/dev/null; ops=; op_sets=; dist_pull_secret_required"
_rc "okd: pull secret required when ops set"       0 bash -c "distribution=okd; source scripts/include_all.sh 2>/dev/null; ops=web-terminal; op_sets=; dist_pull_secret_required"
_rc "okd: pull secret required when op_sets set"   0 bash -c "distribution=okd; source scripts/include_all.sh 2>/dev/null; ops=; op_sets=acm; dist_pull_secret_required"

for c in fast stable candidate eus; do
	_rc "ocp channel ok: $c" 0 bash -c "distribution=ocp; source scripts/include_all.sh 2>/dev/null; dist_channel_is_valid $c"
done
for c in "" bogus Stable stablex xfast eus2 "fast "; do
	_rc "ocp channel bad: [$c]" 1 bash -c "distribution=ocp; source scripts/include_all.sh 2>/dev/null; dist_channel_is_valid '$c'"
done
for c in stable candidate; do
	_rc "okd channel ok: $c" 0 bash -c "distribution=okd; source scripts/include_all.sh 2>/dev/null; dist_channel_is_valid $c"
done
for c in fast eus "" bogus stablex xcandidate "stable "; do
	_rc "okd channel bad: [$c]" 1 bash -c "distribution=okd; source scripts/include_all.sh 2>/dev/null; dist_channel_is_valid '$c'"
done
# fresh shell (as run_once): only aba.conf says which distribution
_rc "distribution from aba.conf (okd): fast is not a channel" 1 bash -c "unset distribution; cd '$_tmp/conf-okd'; source '$REPO_ROOT/scripts/include_all.sh' 2>/dev/null; dist_channel_is_valid fast"
_rc "distribution from aba.conf (okd): candidate is a channel" 0 bash -c "unset distribution; cd '$_tmp/conf-okd'; source '$REPO_ROOT/scripts/include_all.sh' 2>/dev/null; dist_channel_is_valid candidate"
_rc "distribution from aba.conf (ocp): fast is a channel" 0 bash -c "unset distribution; cd '$_tmp/conf-ocp'; source '$REPO_ROOT/scripts/include_all.sh' 2>/dev/null; dist_channel_is_valid fast"
# dist_channel_is_valid needs the channel as its argument; none -> invalid for both distributions
_rc "ocp: dist_channel_is_valid without an argument is false" 1 bash -c "distribution=ocp; source scripts/include_all.sh 2>/dev/null; dist_channel_is_valid"
_rc "okd: dist_channel_is_valid without an argument is false" 1 bash -c "distribution=okd; source scripts/include_all.sh 2>/dev/null; dist_channel_is_valid"

# dist_supports_channels (no argument): does the image-set config carry a channels block?
_rc "ocp: dist_supports_channels (no argument)" 0 bash -c "distribution=ocp; source scripts/include_all.sh 2>/dev/null; dist_supports_channels"
_rc "okd: dist_supports_channels (no argument)" 1 bash -c "distribution=okd; source scripts/include_all.sh 2>/dev/null; dist_supports_channels"
_rc "default distribution (variable unset, no aba.conf): dist_supports_channels" 0 bash -c "unset distribution; cd '$_tmp/none' 2>/dev/null; source '$REPO_ROOT/scripts/include_all.sh' 2>/dev/null; dist_supports_channels"
_rc "distribution from aba.conf (okd): dist_supports_channels" 1 bash -c "unset distribution; cd '$_tmp/conf-okd'; source '$REPO_ROOT/scripts/include_all.sh' 2>/dev/null; dist_supports_channels"
# the two predicates answer different questions: a valid OKD channel does not mean a channels block
_rc "okd: stable is a valid channel yet there is no channels block" 1 bash -c "distribution=okd; source scripts/include_all.sh 2>/dev/null; dist_channel_is_valid stable && dist_supports_channels"
_rc "ocp: a channels block and a valid channel agree" 0 bash -c "distribution=ocp; source scripts/include_all.sh 2>/dev/null; dist_channel_is_valid stable && dist_supports_channels"

# ---------------------------------------------------------------- dist_target_problem (platform, architecture)
echo ""
echo "--- dist_target_problem ---"
_tp() { bash -c "distribution=$1; source scripts/include_all.sh 2>/dev/null; ARCH=$3; dist_target_problem $2; echo \"rc=\$?\"" 2>&1 | paste -sd'|'; }
_eq "okd bm amd64: fine, silent"       "rc=0" "$(_tp okd bm amd64)"
_eq "okd kvm amd64: fine, silent"      "rc=0" "$(_tp okd kvm amd64)"
_eq "okd vmw amd64: platform reason"   "platform [vmw] (VMware vSphere) is not supported for OKD in ABA (use: bm, kvm)|rc=1" "$(_tp okd vmw amd64)"
_eq "okd bm arm64: architecture reason" "architecture [arm64] is not supported for OKD in ABA (x86_64 only)|rc=1" "$(_tp okd bm arm64)"
_eq "okd vmw arm64: the platform is named first" "platform [vmw] (VMware vSphere) is not supported for OKD in ABA (use: bm, kvm)|rc=1" "$(_tp okd vmw arm64)"
_eq "okd with no platform on s390x: architecture" "architecture [s390x] is not supported for OKD in ABA (x86_64 only)|rc=1" "$(_tp okd '' s390x)"
_eq "ocp vmw arm64: never a problem" "rc=0" "$(_tp ocp vmw arm64)"
_eq "ocp (variable unset, no aba.conf) vmw arm64: never a problem" "rc=0" "$(bash -c "unset distribution; cd '$_tmp/none' 2>/dev/null; source '$REPO_ROOT/scripts/include_all.sh' 2>/dev/null; ARCH=arm64; dist_target_problem vmw; echo \"rc=\$?\"" 2>&1 | paste -sd'|')"
_eq "okd from aba.conf (fresh shell) vmw: platform reason" "platform [vmw] (VMware vSphere) is not supported for OKD in ABA (use: bm, kvm)|rc=1" "$(bash -c "unset distribution; cd '$_tmp/conf-okd'; source '$REPO_ROOT/scripts/include_all.sh' 2>/dev/null; ARCH=amd64; dist_target_problem vmw; echo \"rc=\$?\"" 2>&1 | paste -sd'|')"

# ---------------------------------------------------------------- resolve_cluster_channel (okd: aba.conf decides)
echo ""
echo "--- resolve_cluster_channel on okd ---"
_rcc() { ( cd "$_tmp/none" 2>/dev/null; bash -c "distribution=okd; source '$REPO_ROOT/scripts/include_all.sh' 2>/dev/null; trap - ERR; $1" 2>/dev/null ); }
_eq "okd stable + version: stable-<major.minor>"        "stable-4.21"    "$(_rcc 'ocp_channel=stable; resolve_cluster_channel 4.21.0-okd-scos.11')"
_eq "okd candidate + version: candidate-<major.minor>"  "candidate-4.21" "$(_rcc 'ocp_channel=candidate; resolve_cluster_channel 4.21.0-okd-scos.11')"
_eq "okd candidate + pre-release build: candidate-5.1"  "candidate-5.1"  "$(_rcc 'ocp_channel=candidate; resolve_cluster_channel 5.1.0-okd-scos.ec.2')"
_eq "okd channel from the variable, version from ocp_version" "candidate-5.0" "$(_rcc 'ocp_channel=candidate; ocp_version=5.0.0-okd-scos.5; resolve_cluster_channel')"
_eq "okd without ocp_channel: stable"                   "stable-4.21"    "$(_rcc 'unset ocp_channel; resolve_cluster_channel 4.21.0-okd-scos.11')"
_eq "okd without a version: the channel alone"          "candidate"      "$(_rcc 'ocp_channel=candidate; unset ocp_version; resolve_cluster_channel')"

# ---------------------------------------------------------------- aba.sh: options that decide the distribution are read first
echo ""
echo "--- aba.sh option pre-scan (order independence) ---"
_pre=$(awk '/^new_args=\(\)/ {p=1} p {print} p && /^set -- "\$\{new_args\[@\]\}"/ {exit}' "$REPO_ROOT/scripts/aba.sh")
_eq "pre-scan block found" "1" "$([[ "$_pre" == *"_CLI_DISTRIBUTION"* && "$_pre" == *"_CLI_PLATFORM"* ]] && echo 1 || echo 0)"
_scan() { bash -c "i=1; $_pre; echo \"dist=\$_CLI_DISTRIBUTION plat=\$_CLI_PLATFORM args=\$*\"" _ "$@" 2>&1; }
_eq "--distribution okd alone" "dist=okd plat= args=--distribution okd" "$(_scan --distribution okd)"
_eq "--version X --distribution okd (distribution last)" "dist=okd plat= args=--version 4.21.0-okd-scos.11 --distribution okd" "$(_scan --version 4.21.0-okd-scos.11 --distribution okd)"
_eq "--channel candidate --distribution okd" "dist=okd plat= args=--channel candidate --distribution okd" "$(_scan --channel candidate --distribution okd)"
_eq "-v l --distribution ocp" "dist=ocp plat= args=-v l --distribution ocp" "$(_scan -v l --distribution ocp)"
_eq "--distribution given twice: the last one counts" "dist=ocp plat= args=--distribution okd --distribution ocp" "$(_scan --distribution okd --distribution ocp)"
_eq "--distribution with a bad value is not remembered" "dist= plat= args=--distribution foo" "$(_scan --distribution foo)"
_eq "--platform vmw --distribution okd" "dist=okd plat=vmw args=--platform vmw --distribution okd" "$(_scan --platform vmw --distribution okd)"
_eq "--distribution okd -p kvm" "dist=okd plat=kvm args=--distribution okd -p kvm" "$(_scan --distribution okd -p kvm)"
_eq "--platform with a bad value is not remembered" "dist= plat= args=--platform foo" "$(_scan --platform foo)"
_eq "--platform bm" "dist= plat=bm args=--platform bm" "$(_scan --platform bm)"

# ---------------------------------------------------------------- no hard-coded OKD release (design rule)
echo ""
echo "--- no version/digest literals in the helper code ---"
_src=$(declare -f dist_of dist_version_is_valid dist_release_payload_repo dist_release_image_ref \
	dist_cli_base_url dist_cli_sha256_url dist_graph_api dist_pull_secret_required dist_channel_is_valid dist_supports_channels 2>/dev/null)
_hits=$(printf '%s\n' "$_src" | grep -c -E '[0-9]+\.[0-9]+\.[0-9]+-okd|okd-scos\.[0-9]+[^+]|sha256:[0-9a-f]{6}|[^a-z]4\.2[0-9]' || true)
_eq "helper bodies contain no OKD version/digest literal" "0" "$_hits"
[[ -n "$_src" ]] && _pass "helper bodies were inspected" || _fail "helper bodies are empty (functions missing)"

# ---------------------------------------------------------------- no internal ids in product text
echo ""
echo "--- no internal ids in product text ---"
_hits=$(grep -r -n -E "$_ids" scripts templates tui cli 2>/dev/null | wc -l)
_eq "scripts/ templates/ tui/ cli/ contain no internal ids" "0" "$_hits"

# ---------------------------------------------------------------- registration (one line, 'Config / normalize' block)
echo ""
echo "--- registered in run-all-tests.sh ---"
_n=$(grep -c -P '^\ttest/func/test-distribution-helpers\.sh$' test/func/run-all-tests.sh || true)
_eq "test-distribution-helpers.sh registered once, tab-indented" "1" "$_n"
_blk=$(awk '/# Config \/ normalize/{f=1;next} /^\t#/{f=0} f' test/func/run-all-tests.sh)
printf '%s\n' "$_blk" | grep -q 'test-distribution-helpers.sh' && _pass "registered in the Config / normalize block" \
	|| _fail "not in the Config / normalize block"

echo ""
echo "Results: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
