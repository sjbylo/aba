#!/bin/bash
# OpenShift values for the dist_* functions.
#
# One distribution is one file of these functions. scripts/dist.sh loads
# this file when distribution is missing, empty, or ocp. The OKD file
# is scripts/dist-okd.sh. Callers use the functions and do not carry
# their own copy of a URL or a catalog list.
#
# No distribution key is read here. Loading this file means OpenShift.

# Prints ocp. The OKD file prints okd.
dist_of() {
	printf '%s\n' ocp
}

# $1 version, $2 channel. The channel does not change the OpenShift rule.
dist_version_is_valid() {
	_is_version_string "${1:-}"
}

# Repository that holds the release payload images.
dist_release_payload_repo() {
	printf '%s\n' "quay.io/openshift-release-dev/ocp-release"
}

# Tag of the release image inside the mirror registry for version $1.
dist_release_image_ref() {
	local ver="${1:?Usage: dist_release_image_ref <version>}"
	printf '%s\n' "${ver}-$(uname -m)"
}

# Directory holding the CLI tarballs for version $1.
# Engineering candidates live under ocp-dev-preview, same as cli/Makefile.
dist_cli_base_url() {
	local ver="${1:?Usage: dist_cli_base_url <version>}"
	local dir=ocp
	[[ "$ver" == *-ec.* ]] && dir=ocp-dev-preview
	printf '%s\n' "https://mirror.openshift.com/pub/openshift-v$(ocp_major_of "$ver")/$(uname -m)/clients/${dir}/${ver}"
}

# Checksum file next to the CLI tarballs for version $1.
dist_cli_sha256_url() {
	local ver="${1:?Usage: dist_cli_sha256_url <version>}"
	printf '%s\n' "$(dist_cli_base_url "$ver")/sha256sum.txt"
}

# Update-graph (Cincinnati) endpoint. ABA_GRAPH_API is set by include_all.sh.
dist_graph_api() {
	printf '%s\n' "$ABA_GRAPH_API"
}

# OpenShift always needs a Red Hat pull secret.
dist_pull_secret_required() {
	return 0
}

# Succeeds when $1 is a channel OpenShift publishes.
dist_channel_is_valid() {
	[[ "${1:-}" =~ ^(fast|stable|candidate|eus)$ ]]
}

# OpenShift image-set config selects releases with a channels block.
dist_supports_channels() {
	return 0
}

# OpenShift has no platform or architecture restriction here.
# $1 is the platform. Prints a reason and returns 1 when the combination
# cannot be used. Always succeeds for OpenShift.
dist_target_problem() {
	return 0
}

# Operator catalogs, in lookup priority.
dist_catalogs() {
	echo "redhat-operator certified-operator community-operator"
}

# Image of operator catalog $1 (e.g. community-operator) for major.minor $2.
dist_catalog_ref() {
	local cat="${1:?Usage: dist_catalog_ref <catalog> <version_short>}"
	local ver="${2:?Usage: dist_catalog_ref <catalog> <version_short>}"
	printf '%s\n' "registry.redhat.io/redhat/${cat}-index:v${ver}"
}

# Paths, one per line, of the catalog index files for minor $1.
# $2 is the directory (default: .index of the current directory).
dist_catalog_index_files() {
	local ver="${1:?Usage: dist_catalog_index_files <version_short> [dir]}"
	local dir="${2:-.index}"
	local cat
	for cat in $(dist_catalogs); do
		printf '%s\n' "${dir}/${cat}-index-v${ver}"
	done
}

# OpenShift does not reject operators for living in a Red Hat catalog.
# Usage: dist_catalog_reject_blocked_ops <version_short>...
dist_catalog_reject_blocked_ops() {
	return 0
}

# Hosts a connected OpenShift run must be able to reach.
# Order is the order the connectivity check reports them.
dist_probe_sites() {
	printf '%s\n' api.openshift.com mirror.openshift.com registry.redhat.io
}

# Host used by the short save/sync reachability check.
dist_quick_probe_host() {
	printf '%s\n' registry.redhat.io
}

# Registry name that must appear in a required pull secret.
dist_pull_secret_registry() {
	printf '%s\n' registry.redhat.io
}

# Upgrade, day2-osus, day2-virt, and import are supported for OpenShift.
# $1 is the command name. Prints nothing and returns 0.
dist_stop_unsupported() {
	return 0
}

# A hyphen marks an OpenShift pre-release (rc, ec). A GA version has none.
dist_is_prerelease() {
	[[ "${1:-}" == *-* ]]
}

# The bodies stay in include_all.sh. This file only selects them.
dist_fetch_latest_minor_version() { _ocp_fetch_latest_minor_version "$@"; }
dist_fetch_all_versions() { _ocp_fetch_all_versions "$@"; }
dist_fetch_latest_version() { _ocp_fetch_latest_version "$@"; }
dist_fetch_latest_z_version() { _ocp_fetch_latest_z_version "$@"; }
dist_fetch_previous_version() { _ocp_fetch_previous_version "$@"; }
dist_fetch_older_version() { _ocp_fetch_older_version "$@"; }
dist_verify_release() { _ocp_verify_release "$@"; }

# OpenShift selects the release with a channel, not a digest pin.
dist_release_payload_ref() {
	return 1
}

# OpenShift does not invent a pull secret. The caller prints its own error.
# $1 is the file path.
dist_pull_secret_ensure() {
	return 1
}
