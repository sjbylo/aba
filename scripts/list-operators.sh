#!/bin/bash
# list-operators.sh -- List all operators in a Red Hat operator catalog
#
# INTENT:    Replacement for "oc-mirror list operators --catalog <url>".
#            Pulls the catalog image, extracts FBC metadata, and lists operators
#            with display names and default channels. No oc-mirror dependency.
# CALLED BY: make list-operators, aba list-operators, TUI operator browser
# CWD:       ABA repo root
# REQUIRES:  podman, jq; container auth for registry.redhat.io
# ARGS:      <ocp_version> [catalog_name]
#            ocp_version:   e.g. "4.21" (major.minor only)
#            catalog_name:  redhat-operator (default) | certified-operator | community-operator
# PRODUCES:  stdout -- whitespace-separated records:
#              PACKAGE_NAME DISPLAY_NAME DEFAULT_CHANNEL
# SIDE EFFECTS: Catalog image remains in podman graph storage (cache for future runs).
# IDEMPOTENT: Yes (read-only extraction, no state files)
#
# Usage: list-operators.sh <version> [catalog]
# Example:
#   list-operators.sh 4.21
#   list-operators.sh 4.21 certified-operator
#   list-operators.sh 4.21 community-operator

set -eo pipefail
source scripts/include_all.sh

# ── Local output helpers (tool-specific [INFO]/[OK]/[ERROR] style) ────
if [ -t 1 ]; then
	_LO_RED='\033[0;31m'; _LO_GREEN='\033[0;32m'; _LO_BLUE='\033[0;34m'; _LO_NC='\033[0m'
else
	_LO_RED=''; _LO_GREEN=''; _LO_BLUE=''; _LO_NC=''
fi
info()    { echo -e "${_LO_BLUE}[INFO]${_LO_NC} $*" >&2; }
success() { echo -e "${_LO_GREEN}[OK]${_LO_NC} $*"   >&2; }
die()     { echo -e "${_LO_RED}[ERROR]${_LO_NC} $*"   >&2; exit 1; }

# ── Parse arguments ──────────────────────────────────────────────────
usage() {
	echo "Usage: $(basename "$0") <ocp_version> [catalog_name]"
	echo "  ocp_version   : e.g. 4.20, 4.21"
	echo "  catalog_name  : redhat-operator (default), certified-operator, community-operator"
	exit 1
}

ocp_ver="${1:?$(usage)}"
echo "$ocp_ver" | grep -qE '^[0-9]+\.[0-9]+$' || { echo "Error: version must be X.Y (e.g. 4.21)" >&2; usage; }
catalog="${2:-redhat-operator}"
catalog_url="registry.redhat.io/redhat/${catalog}-index:v${ocp_ver}"

# ── Prerequisites ────────────────────────────────────────────────────
command -v podman >/dev/null 2>&1 || die "podman is required"
command -v jq     >/dev/null 2>&1 || die "jq is required"

# ── Setup ────────────────────────────────────────────────────────────
container_name="list-ops-${catalog}-v${ocp_ver}-$$"
tmp_dir=$(mktemp -d "$ABA_TMP/list-ops-XXXXXX")
trap 'podman rm -f "$container_name" >/dev/null 2>&1; rm -rf "$tmp_dir"' EXIT INT TERM

# ── Pull image ───────────────────────────────────────────────────────
if ! try_cmd -n 3 -d 10 -D 5 -m "Pull $catalog_url" -- \
	podman pull -q "$catalog_url"; then
	die "Failed to pull $catalog_url — check credentials / network"
fi

# ── Extract /configs ─────────────────────────────────────────────────
info "Extracting catalog data ..."
podman create -q --name "$container_name" "$catalog_url" >/dev/null 2>&1 \
	|| die "Failed to create container"
podman cp "$container_name:/configs" "$tmp_dir/configs" 2>/dev/null \
	|| die "Failed to copy /configs from container"
podman rm -f "$container_name" >/dev/null 2>&1

# ── Parse each operator directory (same extract as download-catalog-index) ──
info "Parsing operators from $catalog v$ocp_ver ..."

source scripts/catalog-extract-functions.sh
_extract_catalog_dir "$tmp_dir/configs" "$tmp_dir/index"
cat "$tmp_dir/index"

success "Done. Catalog: $catalog v$ocp_ver"
