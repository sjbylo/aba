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

# OKD releases are pinned by digest, not by a version tag.
# The digest lookup is a later step. This names the repo and the build.
dist_release_image_ref() {
	local ver="${1:?Usage: dist_release_image_ref <version>}"
	printf '%s\n' "${_ABA_OKD_PAYLOAD_REPO}:${ver}"
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
