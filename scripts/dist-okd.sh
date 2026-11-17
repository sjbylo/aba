#!/bin/bash
# OKD values for the dist_* functions.
#
# Loaded only by scripts/dist.sh when distribution=okd. The names match
# scripts/dist-ocp.sh. Nothing in this file is consulted on an OpenShift
# run, so an OpenShift user is not asked to reach an OKD site.

# Prints okd. The OpenShift file prints ocp.
dist_of() {
	printf '%s\n' okd
}

# Release builds are X.Y.Z-okd-scos.N. Candidate also lists X.Y.Z-okd-scos.ec.N.
# The OpenShift version check is not widened to accept these.
_ABA_OKD_VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+-okd-scos\.[0-9]+$'
_ABA_OKD_CANDIDATE_VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+-okd-scos\.(ec\.)?[0-9]+$'

# Placeholder so tools that insist on a pull-secret file still start.
# Operators need a real secret; dist_pull_secret_required says when.
_ABA_OKD_FAKE_PULL_SECRET='{"auths":{"fake":{"auth":"aWQ6cGFzcwo="}}}'

ABA_OKD_GRAPH_API="https://updates.okd.io/api/updates/graph"
ABA_OKD_RELEASES_API="https://api.github.com/repos/okd-project/okd/releases"
_ABA_OKD_DOWNLOAD_BASE="https://github.com/okd-project/okd/releases/download"
_ABA_OKD_PAYLOAD_REPO="quay.io/okd/scos-release"

# $1 version, $2 channel. Pre-release builds are valid on candidate only.
dist_version_is_valid() {
	local re="$_ABA_OKD_VERSION_RE"
	[ "${2:-}" = "candidate" ] && re="$_ABA_OKD_CANDIDATE_VERSION_RE"
	[[ "${1:-}" =~ $re ]]
}

# Repository that holds the release payload images.
dist_release_payload_repo() {
	printf '%s\n' "$_ABA_OKD_PAYLOAD_REPO"
}

# Digest (sha256:<64 hex>) of the release oc-mirror stored for version $1.
# The mirror does not tag it as <version>-<arch>. The name of the signature
# file is <version>-sha256-<digest>. Errors go to stderr.
dist_release_image_ref() {
	local ver="${1:-${ocp_version:-}}" wd f d
	local -a found=()
	if [ -z "$ver" ]; then
		echo "No release version given" >&2
		return 1
	fi
	if [ -d data/working-dir ]; then
		wd=data/working-dir
	elif [ -d mirror/data/working-dir ]; then
		wd=mirror/data/working-dir
	else
		echo "No oc-mirror output found: run 'aba -d mirror sync' (or 'load') first" >&2
		return 1
	fi
	for f in "$wd/signatures/${ver}-sha256-"*; do
		d="${f##*-sha256-}"
		[[ "$d" =~ ^[0-9a-f]{64}$ ]] && found+=("sha256:$d")
	done
	if [ ${#found[@]} -eq 0 ] && ! compgen -G "$wd/signatures/*" >/dev/null && [ -s "$wd/cluster-resources/signature-configmap.json" ]; then
		mapfile -t found < <(jq -r '(.binaryData // {}) | keys[] | capture("^sha256-(?<d>[0-9a-f]{64})-[0-9]+$").d | "sha256:" + .' \
			"$wd/cluster-resources/signature-configmap.json" 2>/dev/null)
	fi
	if [ ${#found[@]} -gt 0 ]; then
		mapfile -t found < <(printf '%s\n' "${found[@]}" | sed '/^$/d' | sort -u)
	fi
	if [ ${#found[@]} -eq 0 ]; then
		echo "oc-mirror has not recorded a release image for $ver under $wd" >&2
		return 1
	fi
	if [ ${#found[@]} -gt 1 ]; then
		echo "oc-mirror recorded more than one release image under $wd (${found[*]})" >&2
		return 1
	fi
	printf '%s\n' "${found[0]}"
}

# Directory holding the CLI tarballs for version $1.
dist_cli_base_url() {
	local ver="${1:?Usage: dist_cli_base_url <version>}"
	printf '%s\n' "${_ABA_OKD_DOWNLOAD_BASE}/${ver}"
}

# Checksum file next to the CLI tarballs for version $1.
dist_cli_sha256_url() {
	local ver="${1:?Usage: dist_cli_sha256_url <version>}"
	printf '%s\n' "$(dist_cli_base_url "$ver")/sha256sum.txt"
}

# Update graph. Not the OpenShift graph.
dist_graph_api() {
	printf '%s\n' "$ABA_OKD_GRAPH_API"
}

# A Red Hat pull secret is needed only when operators are selected.
dist_pull_secret_required() {
	[ -n "${ops:-}" ] || [ -n "${op_sets:-}" ]
}

# Channels OKD publishes. fast and eus are OpenShift channels.
dist_channel_is_valid() {
	[[ "${1:-}" =~ ^(stable|candidate)$ ]]
}

# OKD releases are not selected by a channels block in the image set.
dist_supports_channels() {
	return 1
}

# VMware is allowed. Other CPU architectures are not.
# $1 is the platform. Prints a reason and returns 1 when refused.
dist_target_problem() {
	if [ "${ARCH:-amd64}" != "amd64" ]; then
		echo "architecture [${ARCH}] is not supported for OKD in ABA (x86_64 only)"
		return 1
	fi
	return 0
}

# The community catalog is the one served without a Red Hat account.
dist_catalogs() {
	echo "community-operator"
}

# Image of operator catalog $1 for major.minor $2.
# registry.redhat.io wants an account. The access host serves this catalog.
dist_catalog_ref() {
	local cat="${1:?Usage: dist_catalog_ref <catalog> <version_short>}"
	local ver="${2:?Usage: dist_catalog_ref <catalog> <version_short>}"
	case " $(dist_catalogs) " in
		*" $cat "*) ;;
		*) return 1 ;;
	esac
	printf '%s\n' "registry.access.redhat.com/redhat/${cat}-index:v${ver}"
}

# Paths, one per line, of the catalog index files for minor $1.
dist_catalog_index_files() {
	local ver="${1:?Usage: dist_catalog_index_files <version_short> [dir]}"
	local dir="${2:-.index}"
	local cat
	for cat in $(dist_catalogs); do
		printf '%s\n' "${dir}/${cat}-index-v${ver}"
	done
}

# Operator-name rejection against the Red Hat catalogs is a later step.
# Usage: dist_catalog_reject_blocked_ops <version_short>...
dist_catalog_reject_blocked_ops() {
	return 0
}

# Hosts a connected OKD run must be able to reach.
# registry.redhat.io is not one of them.
dist_probe_sites() {
	printf '%s\n' github.com quay.io updates.okd.io mirror.openshift.com
}

# Host used by the short save/sync reachability check.
dist_quick_probe_host() {
	printf '%s\n' quay.io
}

# Empty when no pull secret is required. Callers that require one
# ask dist_pull_secret_required first.
dist_pull_secret_registry() {
	printf '%s\n' ""
}

# Fresh install is supported. Upgrade and the Red Hat day-2 addons are not.
# $1 is the command name.
dist_stop_unsupported() {
	local op="${1:-this command}"
	aba_abort "$op is unsupported for OKD in ABA." \
		"aba.conf has distribution=okd. ABA installs OKD but does not upgrade it or set up Red Hat services on it."
}

# A GA build is X.Y.Z-okd-scos.N. The pre-release form has .ec. in it.
dist_is_prerelease() {
	[[ "${1:-}" == *.ec.* ]]
}

# The answer for the release list must be a JSON list of the fields we read.
_okd_validate_releases() {
	local f="$1"
	jq -ce 'if type == "array" then [.[] | {tag_name, prerelease, draft}] else error("not a list") end' "$f" > "$f.r" 2>/dev/null \
		&& mv -f "$f.r" "$f"
	local rc=$?
	rm -f "$f.r"
	return $rc
}

# One release object. Keep the tag and the Pull From lines. That is all we read.
_okd_validate_release() {
	local f="$1"
	jq -ce 'if type == "object" and (.tag_name | type) == "string" then {tag_name, body: ([(.body // "") | split("\n")[] | select(startswith("Pull From:"))] | join("\n"))} else error("not a release") end' "$f" > "$f.r" 2>/dev/null \
		&& mv -f "$f.r" "$f"
	local rc=$?
	rm -f "$f.r"
	return $rc
}

# GA release tags, oldest first. Follow GitHub pages until a short page.
_okd_ga_tags() {
	local ttl page=1 cache_file n
	ttl="$(parse_duration "$ABA_CACHE_TTL")"
	while [[ $page -le 10 ]]; do
		cache_file="${ABA_CACHE_DIR}/okd_releases_p${page}.json"
		_fetch_cached "${ABA_OKD_RELEASES_API}?per_page=100&page=${page}" "$cache_file" "$ttl" _okd_validate_releases || break
		jq -r '.[] | select((.prerelease // false) == false and (.draft // false) == false) | .tag_name' "$cache_file" 2>/dev/null
		n="$(jq 'length' "$cache_file" 2>/dev/null)" || break
		[[ "$n" -ge 100 ]] || break
		page=$(( page + 1 ))
	done | grep -E "$_ABA_OKD_VERSION_RE" | _semver_sort || true
}

_okd_ga_minors() {
	_okd_ga_tags | awk -F. '{print $1 "." $2}'
}

# The pattern a channel holds. Candidate also accepts the ec form.
_okd_version_re() {
	if [ "${1:-}" = "candidate" ]; then
		printf '%s\n' "$_ABA_OKD_CANDIDATE_VERSION_RE"
	else
		printf '%s\n' "$_ABA_OKD_VERSION_RE"
	fi
}

# Release builds sort by build number. A pre-release (.ec.N) sorts first.
_okd_sort() {
	awk -F'[.-]' '{ printf "%08d %08d %08d %d %08d %s\n", $1, $2, $3, ($0 ~ /\.ec\./) ? 0 : 1, $NF, $0 }' | sort | cut -d' ' -f6
}

_okd_all_versions() {
	local channel="${1:-stable}"
	local minor="${2:-}"

	[[ -n "$minor" ]] || minor="$(_okd_head_minor "$channel")"
	[[ -n "$minor" ]] || return 0

	_fetch_graph_cached "$channel" "$minor" | jq -r '.nodes[].version' 2>/dev/null \
		| grep -E "$(_okd_version_re "$channel")" \
		| grep "^${minor}\." | _okd_sort || true
}

_okd_list_versions() {
	local channel="${1:-stable}"
	local minor="${2:-}"

	[[ -n "$minor" ]] || minor="$(_okd_head_minor "$channel")"
	[[ -n "$minor" ]] || return 0

	if [[ "$channel" = "stable" ]]; then
		{ _okd_all_versions "$channel" "$minor"; _okd_ga_tags | grep "^${minor}\." || true; } | sort -u | _okd_sort || true
	else
		_okd_all_versions "$channel" "$minor"
	fi
}

_okd_verify_release() {
	local ver="$1" channel="$2" minor="$3"

	dist_version_is_valid "$ver" "$channel" || return 1
	_okd_all_versions "$channel" "$minor" | grep -qxF "$ver" && return 0

	[[ "$channel" = "stable" ]] || return 1
	_okd_ga_tags | grep -qxF "$ver"
}

_okd_tip() {
	local channel="$1" minor="$2" v

	v="$(_okd_all_versions "$channel" "$minor" | tail -n1)"
	[[ -n "$v" || "$channel" != "stable" ]] || v="$(_okd_ga_tags | grep "^${minor}\." | tail -n1 || true)"
	printf '%s\n' "$v"
}

_okd_prev_minor() {
	local minor="$1" prev maj

	prev="$(_prev_minor "$minor")"
	if [[ -n "$prev" ]]; then
		echo "$prev"
		return 0
	fi

	maj="${minor%%.*}"
	[[ "$maj" =~ ^[0-9]+$ && "$maj" -gt 1 ]] || { echo ""; return 0; }
	_okd_ga_minors | grep "^$(( maj - 1 ))\." | tail -n1 || true
}

_okd_head_minor() {
	local channel="${1:-stable}"
	local best n jump steps=0 crossed=0

	best="$(_okd_ga_minors | tail -n1)"
	[[ -n "$best" ]] || return 0

	if [[ "$channel" = "candidate" ]]; then
		while [[ $steps -lt 6 ]]; do
			steps=$(( steps + 1 ))
			n="$(_next_minor "$best")"
			if [[ -n "$(_okd_all_versions candidate "$n" | tail -n1)" ]]; then
				best="$n"
				continue
			fi
			[[ $crossed -eq 0 ]] || break
			crossed=1
			jump="$(_next_major "$best")"
			[[ -n "$(_okd_all_versions candidate "$jump" | tail -n1)" ]] || break
			best="$jump"
		done
	fi

	printf '%s\n' "$best"
}

_okd_fetch_latest_version() {
	local channel="${1:-stable}"
	local minor v

	minor="$(_okd_head_minor "$channel")"
	[[ -n "$minor" ]] || return 1
	v="$(_okd_tip "$channel" "$minor")"
	dist_version_is_valid "$v" "$channel" && echo "$v" && return 0
	return 1
}

_okd_fetch_previous_version() {
	local channel="${1:-stable}"
	local minor prev v

	minor="$(_okd_head_minor "$channel")"
	[[ -n "$minor" ]] || return 1
	prev="$(_okd_prev_minor "$minor")"
	[[ -n "$prev" ]] || return 1
	v="$(_okd_tip "$channel" "$prev")"
	dist_version_is_valid "$v" "$channel" && echo "$v" && return 0
	return 1
}

_okd_fetch_older_version() {
	local channel="${1:-stable}"
	local minor prev older v

	minor="$(_okd_head_minor "$channel")"
	[[ -n "$minor" ]] || return 1
	prev="$(_okd_prev_minor "$minor")"
	[[ -n "$prev" ]] || return 1
	older="$(_okd_prev_minor "$prev")"
	[[ -n "$older" ]] || return 1
	v="$(_okd_tip "$channel" "$older")"
	dist_version_is_valid "$v" "$channel" && echo "$v" && return 0
	return 1
}

_okd_fetch_latest_z_version() {
	local channel="${1:-stable}"
	local minor="${2:-}"
	local v prev

	[[ -n "$minor" ]] || minor="$(_okd_head_minor "$channel")"
	[[ -n "$minor" ]] || return 1
	v="$(_okd_tip "$channel" "$minor")"
	if [[ -z "$v" ]]; then
		prev="$(_okd_prev_minor "$minor")"
		[[ -n "$prev" ]] || return 1
		v="$(_okd_tip "$channel" "$prev")"
	fi
	dist_version_is_valid "$v" "$channel" && echo "$v" && return 0
	return 1
}

dist_fetch_latest_minor_version() { _okd_head_minor "$@"; }
dist_fetch_all_versions() { _okd_list_versions "$@"; }
dist_fetch_latest_version() { _okd_fetch_latest_version "$@"; }
dist_fetch_latest_z_version() { _okd_fetch_latest_z_version "$@"; }
dist_fetch_previous_version() { _okd_fetch_previous_version "$@"; }
dist_fetch_older_version() { _okd_fetch_older_version "$@"; }

# $1 version, $2 channel. The minor is the first two numbers.
dist_verify_release() {
	local ver="${1:-}" channel="${2:-stable}" minor
	[[ -n "$ver" ]] || return 1
	minor="$(printf '%s\n' "$ver" | cut -d. -f1-2)"
	_okd_verify_release "$ver" "$channel" "$minor"
}

# $2 is a digest reference of payload repo $1.
_okd_is_payload_ref() {
	[[ "$2" == "$1"@sha256:* ]] && [[ "${2#*@sha256:}" =~ ^[0-9a-f]{64}$ ]]
}

# Digest published for build $1 on channel $2. The graph node first, then
# the Pull From line of that GitHub release. A tag is not accepted.
_okd_release_payload_spec() {
	local ver="$1" channel="$2" minor repo ref rel
	minor="$(printf '%s\n' "$ver" | cut -d. -f1-2)"
	repo="$(dist_release_payload_repo)"

	while read -r ref; do
		_okd_is_payload_ref "$repo" "$ref" && { echo "$ref"; return 0; }
	done < <(_fetch_graph_cached "$channel" "$minor" 2>/dev/null \
		| jq -r --arg v "$ver" '.nodes[] | select(.version == $v) | .payload' 2>/dev/null)

	rel="${ABA_CACHE_DIR}/okd_release_${ver}.json"
	_fetch_cached "${ABA_OKD_RELEASES_API}/tags/${ver}" "$rel" "$(parse_duration "$ABA_CACHE_TTL")" _okd_validate_release || return 1
	jq -e --arg t "$ver" '.tag_name == $t' "$rel" >/dev/null 2>&1 || { rm -f "$rel"; return 1; }
	while read -r ref; do
		_okd_is_payload_ref "$repo" "$ref" && { echo "$ref"; return 0; }
	done < <(jq -r --arg t "$ver" 'select(.tag_name == $t) | .body // empty' "$rel" 2>/dev/null \
		| tr -d '\r' | sed -n 's/^Pull From: *//p')
	return 1
}

# Write the placeholder when no secret is required. Operators still need a real one.
# $1 is the file path. Prints a problem and returns 1 when it cannot proceed.
dist_pull_secret_ensure() {
	local f="${1:?Usage: dist_pull_secret_ensure <file>}"
	if [ -s "$f" ]; then
		return 0
	fi
	if dist_pull_secret_required; then
		echo "No pull secret found at $f (needed because operators are selected)" >&2
		return 1
	fi
	( umask 077; printf '%s\n' "$_ABA_OKD_FAKE_PULL_SECRET" > "$f" ) || {
		echo "Cannot write $f" >&2
		return 1
	}
	aba_info "No pull secret at $f: using the OKD placeholder." >&2
	return 0
}

# Pull spec of the release image for this architecture. The signature belongs
# to that image, not to the multi-arch list. Returns 1 when no digest is
# published, 2 when the manifest cannot be read.
dist_release_payload_ref() {
	local ver="${1:-}" channel="${2:-stable}" spec raw child
	dist_version_is_valid "$ver" "$channel" || return 1
	spec="$(_okd_release_payload_spec "$ver" "$channel")" || return 1

	raw="$(timeout 60 skopeo inspect --raw "docker://${spec}" 2>/dev/null)" || return 2
	if [[ "$(jq -r 'if has("manifests") then "list" else "image" end' <<< "$raw" 2>/dev/null)" == "image" ]]; then
		printf '%s\n' "$spec"
		return 0
	fi
	child="$(jq -r --arg a "$ARCH" '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a) | .digest] | unique | if length == 1 then .[0] else empty end' <<< "$raw" 2>/dev/null)"
	_okd_is_payload_ref "${spec%@*}" "${spec%@*}@${child}" || return 2
	printf '%s\n' "${spec%@*}@${child}"
}

# Manifest name in the mirror. A digest, because there is no version-arch tag.
dist_mirror_manifest_ref() {
	dist_release_image_ref "${1:-${ocp_version:-}}"
}

# quay.io/okd/scos-content publishes no cosign tags, so save and load fail
# unless oc-mirror is told to drop them. sync verifies the release signature
# from the CI store instead, so it must not drop signatures. A flag the user
# already set is kept. $1 is the action.
dist_oc_mirror_flags() {
	case "${1:-sync}" in
	save|load) ;;
	*) return 0 ;;
	esac
	case " ${OC_MIRROR_FLAGS-} " in
		*" --remove-signatures "*|*" --remove-signatures="*) return 0 ;;
	esac
	printf '%s\n' --remove-signatures
}

# oc-mirror appends the digest to this URL as written, so it must end in /.
# A value the user already exported wins. The key path is absolute because
# oc-mirror runs in data/.
dist_prepare_oc_mirror() {
	local key=""

	if [ -z "${OCP_SIGNATURE_VERIFICATION_PK:-}" ]; then
		key=$(readlink -f templates/okd-release-signing-key.asc)
		[ -s "$key" ] || aba_abort \
			"Release signing key not found: templates/okd-release-signing-key.asc" \
			"oc-mirror needs it to verify the OKD release signature." \
			"Restore the file from the ABA installation, or set OCP_SIGNATURE_VERIFICATION_PK to a key file."
	fi
	if [ -z "${OCP_SIGNATURE_URL:-}" ]; then
		export OCP_SIGNATURE_URL="https://storage.googleapis.com/openshift-ci-release/releases/signatures/openshift/release/"
	elif [[ "$OCP_SIGNATURE_URL" != */ ]]; then
		aba_warn "OCP_SIGNATURE_URL ($OCP_SIGNATURE_URL) does not end with '/'." \
			"oc-mirror appends the release digest to it as is and will not find the signature."
	fi
	[ -n "$key" ] && export OCP_SIGNATURE_VERIFICATION_PK="$key"
	return 0
}

# Record which distribution the registry holds. OpenShift state files stay as they are.
# $1 state file, $2 release digest (may be empty).
dist_record_mirror_state() {
	local state="${1:?Usage: dist_record_mirror_state <state-file> <digest>}"
	local digest="${2:-}"
	replace-value-conf -q -n distribution -v okd -f "$state"
	if [ -n "$digest" ]; then
		replace-value-conf -q -n mirror_release_digest -v "$digest" -f "$state"
	elif [ "${excl_platform:-}" != "true" ]; then
		aba_warn "The release digest of the mirrored OKD release is unknown; mirror_release_digest was not recorded."
	fi
}

# Image sources come from the IDMS oc-mirror wrote. The payload repo is added
# when that file has no rule for it. No IDMS means there is nothing to guess.
dist_render_image_content_sources() {
	local _idms=mirror/data/working-dir/cluster-resources/idms-oc-mirror.yaml
	local _dest="$reg_host:$reg_port$reg_path/"
	local _re='\A[A-Za-z0-9][A-Za-z0-9._:/@-]*\z'
	local _json _src _payload
	if [ ! -s "$_idms" ]; then
		aba_abort "No oc-mirror IDMS found: $_idms" \
			"Run 'aba -d mirror sync' (or 'aba -d mirror load') first; the install-config is built from it."
	fi
	if ! _json=$(yaml2json < "$_idms" 2>/dev/null); then
		aba_abort "Could not read $_idms (not valid YAML)"
	fi
	if ! jq -e '(.spec.imageDigestMirrors // []) | length > 0 and all(.[]; (.source | type == "string") and ((.mirrors // []) | length > 0))' <<<"$_json" >/dev/null 2>&1; then
		aba_abort "$_idms has no usable imageDigestMirrors"
	fi
	if ! jq -e --arg re "$_re" 'all(.spec.imageDigestMirrors[]; (.source | test($re)) and all(.mirrors[]; test($re)))' <<<"$_json" >/dev/null 2>&1; then
		aba_abort "$_idms has a source or mirror that is not a valid registry reference"
	fi
	if ! jq -e --arg dest "$_dest" 'all(.spec.imageDigestMirrors[].mirrors[]; startswith($dest))' <<<"$_json" >/dev/null 2>&1; then
		aba_abort "$_idms points outside the registry in mirror.conf (expected mirrors under $_dest)" \
			"The IDMS may come from another registry; run 'aba -d mirror sync' (or 'load') again."
	fi
	_payload=$(dist_release_payload_repo)
	if ! _src=$(jq -r --arg payload "$_payload" '
		.spec.imageDigestMirrors as $m
		| (if any($m[]; .source == $payload) then $m
		   else ($m | map(select(.mirrors[0] | endswith("/openshift/release-images"))) | .[0]) as $rel
		   | if $rel == null then error("no release-images rule") else $m + [{mirrors: $rel.mirrors, source: $payload}] end
		   end)
		| .[] | "- mirrors:", (.mirrors[] | "  - " + .), "  source: " + .source' <<<"$_json" 2>/dev/null); then
		aba_abort "$_idms has no rule for the release images (.../openshift/release-images)" \
			"Run 'aba -d mirror sync' (or 'load') again."
	fi
	export image_content_sources="$_src"
}

# A mirror install must not let the Samples Operator or OperatorHub call the internet.
# Direct and proxy installs keep the OKD defaults, and a previous mirror manifest is removed.
dist_install_manifests() {
	local _dir=openshift
	local _samples=$_dir/99-aba-samples-removed.yaml
	local _hub=$_dir/99-aba-operatorhub-default-sources-off.yaml
	if [ -n "${image_content_sources:-}" ]; then
		mkdir -p "$_dir"
		cat > "$_samples" <<'END'
# File generated by ABA (github.com/sjbylo/aba)
apiVersion: samples.operator.openshift.io/v1
kind: Config
metadata:
  name: cluster
spec:
  managementState: Removed
END
		cat > "$_hub" <<'END'
# File generated by ABA (github.com/sjbylo/aba)
apiVersion: config.openshift.io/v1
kind: OperatorHub
metadata:
  name: cluster
spec:
  disableAllDefaultSources: true
END
		aba_info "OKD from a mirror: added install-time manifests to $PWD/$_dir (Samples Operator removed, OperatorHub default sources off)"
	else
		rm -f "$_samples" "$_hub"
		rmdir "$_dir" 2>/dev/null || true
	fi
}
