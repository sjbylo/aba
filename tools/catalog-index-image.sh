#!/bin/bash
# Manage the public catalog-index OCI image on quay.io.
#
# Usage:
#   catalog-index-image.sh list                          # list all indexes in the image
#   catalog-index-image.sh view <catalog> <version>      # show operators for a catalog/version
#   catalog-index-image.sh build [versions...]           # build image (default: all in catalogs/)
#   catalog-index-image.sh push                          # push to quay.io
#   catalog-index-image.sh pull                          # pull and extract to stdout/tmpdir
#
# Examples:
#   catalog-index-image.sh view redhat-operator 4.22
#   catalog-index-image.sh build 4.22 4.23 5.0
#   catalog-index-image.sh push

set -eo pipefail

IMAGE="quay.io/sjbylo/aba-catalog-indexes:latest"
ABA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

_usage() {
	echo "Usage: $(basename "$0") <command> [args...]"
	echo
	echo "Commands:"
	echo "  list                         List all catalog indexes in the image"
	echo "  view <catalog> <version>     Show operators (e.g. view redhat-operator 4.22)"
	echo "  build [versions...]          Build image from catalogs/ (default: all versions)"
	echo "  push                         Push image to $IMAGE"
	echo "  pull [dir]                   Pull image and extract catalogs to dir (default: stdout)"
	exit 1
}

_pull_and_extract() {
	local outdir="$1"
	podman pull --quiet "$IMAGE" >/dev/null 2>&1 || { echo "Error: cannot pull $IMAGE" >&2; return 1; }
	local cid
	cid=$(podman create "$IMAGE" true 2>/dev/null)
	podman cp "$cid":/catalogs/. "$outdir" 2>/dev/null
	podman rm "$cid" >/dev/null 2>&1
}

cmd_list() {
	local tmpdir
	tmpdir=$(mktemp -d)
	trap "rm -rf $tmpdir" EXIT
	_pull_and_extract "$tmpdir"
	echo "Catalog indexes in $IMAGE:"
	echo
	printf "  %-25s %-8s %s\n" "CATALOG" "VERSION" "OPERATORS"
	printf "  %-25s %-8s %s\n" "-------" "-------" "---------"
	for f in "$tmpdir"/*-operator-index-v*; do
		[ -f "$f" ] || continue
		local name ver count
		name=$(basename "$f" | sed 's/-index-v.*//')
		ver=$(basename "$f" | sed 's/.*-index-v//')
		count=$(wc -l < "$f")
		printf "  %-25s %-8s %d\n" "$name" "$ver" "$count"
	done
}

cmd_view() {
	local catalog="$1" version="$2"
	[ -z "$catalog" ] || [ -z "$version" ] && { echo "Usage: $(basename "$0") view <catalog> <version>" >&2; exit 1; }

	local tmpdir
	tmpdir=$(mktemp -d)
	trap "rm -rf $tmpdir" EXIT
	_pull_and_extract "$tmpdir"

	local file="$tmpdir/${catalog}-index-v${version}"
	if [ ! -f "$file" ]; then
		echo "Error: no index for ${catalog} v${version}" >&2
		echo "Available:" >&2
		ls "$tmpdir" | sed 's/^/  /' >&2
		return 1
	fi
	cat "$file"
}

cmd_build() {
	local versions=("$@")
	local builddir
	builddir=$(mktemp -d)
	trap "rm -rf $builddir" EXIT

	mkdir -p "$builddir/catalogs"

	if [ ${#versions[@]} -eq 0 ]; then
		cp "$ABA_ROOT"/catalogs/*-operator-index-v* "$builddir/catalogs/"
	else
		for ver in "${versions[@]}"; do
			local found=0
			for f in "$ABA_ROOT"/catalogs/*-operator-index-v"${ver}"; do
				[ -f "$f" ] && cp "$f" "$builddir/catalogs/" && found=1
			done
			[ $found -eq 0 ] && echo "Warning: no catalogs found for version $ver" >&2
		done
	fi

	local count
	count=$(ls "$builddir/catalogs/" | wc -l)
	echo "Building $IMAGE with $count catalog index files..."

	cat > "$builddir/Containerfile" << 'EOF'
FROM scratch
COPY catalogs/ /catalogs/
EOF
	podman build -f "$builddir/Containerfile" -t "$IMAGE" "$builddir" 2>&1
	echo
	echo "Image size: $(podman image inspect "$IMAGE" --format '{{.Size}}' 2>/dev/null) bytes"
}

cmd_push() {
	echo "Pushing $IMAGE ..."
	podman push "$IMAGE" 2>&1
	echo "Done. Verify: skopeo inspect docker://$IMAGE"
}

cmd_pull() {
	local outdir="${1:-}"
	if [ -z "$outdir" ]; then
		local tmpdir
		tmpdir=$(mktemp -d)
		trap "rm -rf $tmpdir" EXIT
		_pull_and_extract "$tmpdir"
		ls "$tmpdir"
	else
		mkdir -p "$outdir"
		_pull_and_extract "$outdir"
		echo "Extracted to $outdir"
		ls "$outdir"
	fi
}

[ $# -eq 0 ] && _usage

case "$1" in
	list)  shift; cmd_list "$@" ;;
	view)  shift; cmd_view "$@" ;;
	build) shift; cmd_build "$@" ;;
	push)  shift; cmd_push "$@" ;;
	pull)  shift; cmd_pull "$@" ;;
	*)     _usage ;;
esac
