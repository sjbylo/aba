#!/bin/bash
# list-operators.sh -- List all operators in a Red Hat operator catalog
#
# INTENT:    Replacement for "oc-mirror list operators --catalog <url>".
#            Delegates to download-catalog-index.sh for the heavy lifting (pull,
#            extract, parse, cache) and outputs the resulting index to stdout.
# CALLED BY: make list-operators, aba list-operators, TUI operator browser
# CWD:       ABA repo root
# REQUIRES:  podman, jq; container auth for registry.redhat.io
# ARGS:      <ocp_version> [catalog_name]
#            ocp_version:   e.g. "4.21" (major.minor only)
#            catalog_name:  redhat-operator (default) | certified-operator | community-operator
# PRODUCES:  stdout -- whitespace-separated records:
#              PACKAGE_NAME DISPLAY_NAME DEFAULT_CHANNEL
# SIDE EFFECTS: Catalog image remains cached in podman storage; index cached in .index/.
# IDEMPOTENT: Yes (cached: ~2s content-layer probe; fresh: full download)
#
# Usage: list-operators.sh <version> [catalog]
# Example:
#   list-operators.sh 4.21
#   list-operators.sh 4.21 certified-operator
#   list-operators.sh 4.21 community-operator

set -eo pipefail

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

# ── Delegate to the central catalog download script ──────────────────
# download-catalog-index.sh handles: pull, flock serialization, podman cp
# retry, diagnostics, content-layer caching, FBC parsing, and validation.
# If the index is already cached and upstream hasn't changed, this is a
# ~2s no-op (content-layer probe only).
info "Fetching $catalog v$ocp_ver ..."
scripts/download-catalog-index.sh "$catalog" "$ocp_ver" \
	|| die "Failed to download catalog index for $catalog v$ocp_ver"

# ── Output the cached index ─────────────────────────────────────────
index_file=".index/${catalog}-index-v${ocp_ver}"
[ -s "$index_file" ] || die "Index file missing after download: $index_file"

cat "$index_file"

success "Done. Catalog: $catalog v$ocp_ver ($(wc -l < "$index_file") operators)"
