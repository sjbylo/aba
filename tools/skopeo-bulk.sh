#!/bin/bash
# Save or load container images listed in a file using skopeo.
#
# Usage:
#   Save:  ./skopeo-bulk.sh save  -f images.txt -d /tmp/images --authfile ~/.pull-secret.json
#   Load:  ./skopeo-bulk.sh load  -d /tmp/images -r registry.example.com:8443 -p ocp4/openshift4 --authfile ~/mirror-pull-secret.json
#
# Image file format (one image per line, # comments and blank lines ignored):
#   registry.redhat.io/rhoai/odh-training-rocm62-torch24-py311-rhel9@sha256:c4d3fd3d...
#   registry.redhat.io/rhaii/vllm-cuda-rhel9@sha256:5800e12b...

set -euo pipefail

usage() {
	cat <<-'EOF'
	Usage:
	  skopeo-bulk.sh save  -f FILE -d DIR [--authfile FILE] [--remove-signatures]
	  skopeo-bulk.sh load  -d DIR -r REGISTRY [-p PREFIX] [--authfile FILE] [--tls-verify]

	Commands:
	  save   Pull images from source registries and store locally
	  load   Push locally stored images to a mirror registry

	Options:
	  -f FILE        File containing image references (one per line)
	  -d DIR         Local directory for saved images
	  -r REGISTRY    Destination registry host:port (load only)
	  -p PREFIX      Repository path prefix, e.g. ocp4/openshift4 (load only)
	  --authfile F   Auth file for registry credentials
	  --remove-signatures   Strip signatures during save
	  --tls-verify   Enable TLS verification for destination (default: disabled)
	  -h, --help     Show this help

	Examples:
	  # Save two RHOAI images to disk
	  cat > images.txt <<-LIST
	  registry.redhat.io/rhoai/odh-training-rocm62-torch24-py311-rhel9@sha256:c4d3...
	  registry.redhat.io/rhaii/vllm-cuda-rhel9@sha256:5800...
	  LIST
	  ./skopeo-bulk.sh save -f images.txt -d /tmp/saved-images --authfile ~/.pull-secret.json

	  # Load them into a mirror registry
	  ./skopeo-bulk.sh load -d /tmp/saved-images -r bundle.example.com:8443 \
	      -p ocp4/openshift4 --authfile ~/mirror-pull-secret.json
	EOF
	exit "${1:-0}"
}

_image_to_dirname() {
	echo "$1" | sed 's|/|__|g; s|@|_at_|g; s|:|-|g'
}

cmd_save() {
	local file="" dir="" authfile="" remove_sigs=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-f) file="$2"; shift 2 ;;
			-d) dir="$2"; shift 2 ;;
			--authfile) authfile="$2"; shift 2 ;;
			--remove-signatures) remove_sigs="--remove-signatures"; shift ;;
			*) echo "Unknown option: $1" >&2; usage 1 ;;
		esac
	done
	[[ -z "$file" || -z "$dir" ]] && { echo "Error: -f and -d are required for save" >&2; usage 1; }
	[[ -f "$file" ]] || { echo "Error: image file not found: $file" >&2; exit 1; }

	mkdir -p "$dir"
	local total=0 ok=0 fail=0
	local auth_flag=""
	[[ -n "$authfile" ]] && auth_flag="--src-authfile=$authfile"

	while IFS= read -r img; do
		img=$(echo "$img" | sed 's/#.*//' | xargs)
		[[ -z "$img" ]] && continue
		total=$((total + 1))

		local subdir="$dir/$(_image_to_dirname "$img")"
		mkdir -p "$subdir"
		echo "[$total] Saving: $img"
		echo "     -> $subdir"

		if skopeo copy --all \
			"docker://$img" \
			"dir:$subdir" \
			$auth_flag $remove_sigs; then
			echo "$img" > "$subdir/.source-image"
			ok=$((ok + 1))
			echo "     OK"
		else
			fail=$((fail + 1))
			echo "     FAILED" >&2
		fi
		echo
	done < "$file"

	echo "=== Save complete: $ok/$total succeeded, $fail failed ==="
	[[ $fail -gt 0 ]] && exit 1
	exit 0
}

cmd_load() {
	local dir="" registry="" prefix="" authfile="" tls_verify="false"
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-d) dir="$2"; shift 2 ;;
			-r) registry="$2"; shift 2 ;;
			-p) prefix="$2"; shift 2 ;;
			--authfile) authfile="$2"; shift 2 ;;
			--tls-verify) tls_verify="true"; shift ;;
			*) echo "Unknown option: $1" >&2; usage 1 ;;
		esac
	done
	[[ -z "$dir" || -z "$registry" ]] && { echo "Error: -d and -r are required for load" >&2; usage 1; }
	[[ -d "$dir" ]] || { echo "Error: directory not found: $dir" >&2; exit 1; }

	prefix="${prefix%/}"

	local auth_flag=""
	[[ -n "$authfile" ]] && auth_flag="--dest-authfile=$authfile"

	local total=0 ok=0 fail=0

	for subdir in "$dir"/*/; do
		[[ -d "$subdir" ]] || continue
		total=$((total + 1))

		local dest_repo=""
		if [[ -f "$subdir/.source-image" ]]; then
			local src_img
			src_img=$(cat "$subdir/.source-image")
			# Strip source registry host and digest/tag to get the repo path
			dest_repo=$(echo "$src_img" | sed 's|^[^/]*/||; s|@.*||; s|:.*||')
		else
			echo "     WARNING: no .source-image metadata in $(basename "$subdir"), skipping" >&2
			fail=$((fail + 1))
			continue
		fi

		local dest_ref="$registry"
		[[ -n "$prefix" ]] && dest_ref="$dest_ref/$prefix"
		dest_ref="$dest_ref/$dest_repo"

		echo "[$total] Loading: $(basename "$subdir")"
		echo "     -> docker://$dest_ref"

		if skopeo copy --all \
			"dir:${subdir%/}" \
			"docker://$dest_ref" \
			--dest-tls-verify="$tls_verify" \
			$auth_flag; then
			ok=$((ok + 1))
			echo "     OK"
		else
			fail=$((fail + 1))
			echo "     FAILED" >&2
		fi
		echo
	done

	echo "=== Load complete: $ok/$total succeeded, $fail failed ==="
	[[ $fail -gt 0 ]] && exit 1
	exit 0
}

# --- Main ---
[[ $# -lt 1 ]] && usage 1
case "$1" in
	save) shift; cmd_save "$@" ;;
	load) shift; cmd_load "$@" ;;
	-h|--help) usage 0 ;;
	*) echo "Unknown command: $1" >&2; usage 1 ;;
esac
