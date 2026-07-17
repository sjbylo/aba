#!/bin/bash
# Download and save the Docker registry image for air-gapped mirror installs.
#
# INTENT:    Pull the Docker registry container image and save it as a gzipped tarball.
# CALLED BY: mirror/Makefile (docker-reg-image.tgz target)
# CWD:       mirror/ (or any dir with ../scripts/ accessible)
# REQUIRES:  podman, include_all.sh (for try_cmd)
# ARGS:      <image> <output-file>
# PRODUCES:  <output-file> (gzipped podman-save archive), or nothing on pull failure
# SIDE EFFECTS: Pulls a container image into the local podman store
# IDEMPOTENT: Yes (overwrites output file)

# Resolve include path: works from repo root (scripts/) or from mirror/ (../scripts/ symlink)
_script_dir="$(cd "$(dirname "$0")" && pwd)"
source "$_script_dir/include_all.sh"

image="${1:?Usage: $0 <image> <output-file>}"
output="${2:?Usage: $0 <image> <output-file>}"

aba_debug "Starting: $0 $*"

if ! try_cmd -n 3 -d 10 -D 10 -m "Pull $image" -- podman pull "$image"; then
	aba_info "Could not pull $image. It will be pulled later when the mirror registry is installed."
	rm -f "$output"
	exit 0
fi

aba_info "Saving $image to $output ..."
if podman save "$image" | gzip > "${output}.tmp" && gzip -t "${output}.tmp"; then
	mv "${output}.tmp" "$output"
	aba_success "Saved $image to $output"
else
	rm -f "${output}.tmp" "$output"
	aba_abort "Failed to save Docker registry image (corrupted or interrupted)"
fi
