#!/bin/bash -e
# refresh-catalog-indexes.sh -- Download fresh operator catalog indexes and
# update the shipped copies in catalogs/.
#
# INTENT:    Keep catalogs/ (committed to git) reasonably fresh so the TUI
#            has instant operator browsing on a fresh clone.
# CALLED BY: Developer (manually or via CI), never by ABA runtime.
# CWD:       ABA repo root
# REQUIRES:  podman, jq, curl; container auth for registry.redhat.io
# PRODUCES:  catalogs/{catalog}-index-v{ver} for each supported OCP version
# SIDE EFFECTS: Catalog images remain in podman graph storage (cache for future runs).
# IDEMPOTENT: Yes (re-running overwrites catalogs/ with fresh data)
#
# Usage:
#   tools/refresh-catalog-indexes.sh [--commit]
#     --commit   git add + commit + push the updated catalogs/
#
# Workflow:
#   On 'dev': run during release prep to refresh catalogs before tagging
#   On 'main': run periodically (cron or manual) to keep shipped catalogs fresh
#   Release tags are immutable -- never force-move them for catalog updates.

cd "$(dirname "$0")/.."

source scripts/include_all.sh

CATALOGS_DIR="catalogs"
INDEX_DIR=".index"
CATALOGS=(redhat-operator certified-operator community-operator)
MIN_OPERATORS=50
DEPTH=6

do_commit=false
do_force=false
do_yes=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--commit) do_commit=true; shift ;;
		--force)  do_force=true; shift ;;
		-y|--yes) do_yes=true; shift ;;
		-h|--help)
			echo "Usage: $0 [--force] [-y] [--commit]"
			echo "  --force    re-download all catalogs even if already present"
			echo "  -y|--yes   skip confirmation prompts"
			echo "  --commit   git add + commit + push updated catalogs/"
			echo "Covers the latest ${DEPTH} GA minor versions from the stable channel."
			exit 0
			;;
		*) echo "Unknown option: $1" >&2; exit 1 ;;
	esac
done

# Build version list using ABA's Cincinnati graph functions.
# Walks backwards from the latest GA minor in the stable channel.
detect_versions() {
	local versions=()
	local minor
	minor=$(fetch_latest_minor_version "stable")
	[[ -n "$minor" ]] || { echo "ERROR: cannot determine latest OCP minor" >&2; return 1; }

	local i
	for (( i = 0; i < DEPTH; i++ )); do
		[[ -n "$minor" ]] || break
		# Only include if the stable channel has at least one GA release
		if fetch_all_versions "stable" "$minor" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' 2>/dev/null; then
			versions+=("$minor")
		fi
		minor=$(_prev_minor "$minor")
	done

	# Return in ascending order
	printf '%s\n' "${versions[@]}" | sort -V
}

echo "=== Detecting supported OCP versions (last ${DEPTH} GA minors) ==="
mapfile -t VERSIONS < <(detect_versions)

if [[ ${#VERSIONS[@]} -eq 0 ]]; then
	echo "ERROR: Could not detect any OCP versions" >&2
	exit 1
fi

echo "Found versions: ${VERSIONS[*]}"
echo ""

mkdir -p "$CATALOGS_DIR" "$INDEX_DIR"

# Phase 1a: Parallel content-layer check to find which catalogs need re-downloading.
# Instead of comparing the whole image digest (which changes on base-image security
# rebuilds), we compare the catalog content layer digest. FBC catalog images have a
# stable 5-layer structure where layers[-1] is the only catalog-specific layer
# (containing /configs + /tmp/cache). Layers 0-3 are shared base infrastructure.
# Same content = same SHA-256 layer digest, regardless of base image changes.
MAX_PARALLEL=4
NEEDS_DOWNLOAD_DIR=$(mktemp -d /tmp/.aba-catalog-refresh-XXXXXX)
trap "rm -rf '$NEEDS_DOWNLOAD_DIR'" EXIT

echo "=== Phase 1: Checking for upstream content changes (${MAX_PARALLEL} parallel) ==="
skipped=0
running=0

# Resolve manifest list → arch-specific manifest → extract content layer digest.
# Returns the digest of layers[-1] (the catalog-specific FBC data + cache layer).
# Verified: layers[-2] is shared base infrastructure across all catalog types;
# layers[-1] is the only layer unique per catalog (contains /configs + /tmp/cache).
_get_content_layer_digest() {
	local remote_ref="$1"

	# Resolve manifest list to amd64 architecture
	local arch_digest
	arch_digest=$(skopeo inspect --raw "$remote_ref" 2>/dev/null | \
		jq -r '.manifests[]? | select(.platform.architecture=="amd64") | .digest')

	# If not a manifest list (single-arch image), get manifest directly
	if [[ -z "$arch_digest" ]]; then
		local manifest
		manifest=$(skopeo inspect --raw "$remote_ref" 2>/dev/null)
		local layer_count
		layer_count=$(echo "$manifest" | jq '.layers | length' 2>/dev/null)
		if [[ "$layer_count" -ge 4 ]]; then
			echo "$manifest" | jq -r '.layers[-1].digest'
			return 0
		fi
		return 1
	fi

	# Get arch-specific manifest
	local base_ref="${remote_ref%:*}"
	local manifest
	manifest=$(skopeo inspect --raw "${base_ref}@${arch_digest}" 2>/dev/null)

	# Safety: expect at least 4 layers (standard FBC images have 5)
	local layer_count
	layer_count=$(echo "$manifest" | jq '.layers | length' 2>/dev/null)
	if [[ -z "$layer_count" ]] || [[ "$layer_count" -lt 4 ]]; then
		return 1
	fi

	echo "$manifest" | jq -r '.layers[-1].digest'
}

_check_content_change() {
	local catalog="$1" ver="$2"
	local index="${INDEX_DIR}/${catalog}-index-v${ver}"
	local layer_digest_file="${INDEX_DIR}/.${catalog}-index-v${ver}.content-layer-digest"
	local remote_ref="docker://registry.redhat.io/redhat/${catalog}-index:v${ver}"
	local _label
	printf -v _label "%-18s  v%-5s" "$catalog" "$ver"

	# --force: always re-download
	if [[ "$do_force" == true ]]; then
		touch "${NEEDS_DOWNLOAD_DIR}/${catalog}:${ver}"
		echo "  ${_label} DOWNLOAD (--force)"
		return
	fi

	# No local index file: must download
	if [[ ! -s "$index" ]]; then
		touch "${NEEDS_DOWNLOAD_DIR}/${catalog}:${ver}"
		echo "  ${_label} DOWNLOAD (no local index)"
		return
	fi

	# No saved content layer digest: no baseline to compare → must download.
	# We can't know if the local index is current without a previous digest.
	if [[ ! -f "$layer_digest_file" ]]; then
		touch "${NEEDS_DOWNLOAD_DIR}/${catalog}:${ver}"
		echo "  ${_label} DOWNLOAD (no stored digest)"
		return
	fi

	# Probe current content layer digest
	local stored_cld remote_cld
	stored_cld=$(< "$layer_digest_file")
	remote_cld=$(_get_content_layer_digest "$remote_ref") || remote_cld=""

	# Probe failed (network/timeout)
	if [[ -z "$remote_cld" ]]; then
		touch "${NEEDS_DOWNLOAD_DIR}/${catalog}:${ver}"
		echo "  ${_label} DOWNLOAD (layer probe failed)"
		return
	fi

	# Content layer digest matches: catalog operators haven't changed
	if [[ "$remote_cld" == "$stored_cld" ]]; then
		echo "  ${_label} SKIP (content unchanged)"
		return
	fi

	# Content layer changed: real operator updates
	touch "${NEEDS_DOWNLOAD_DIR}/${catalog}:${ver}"
	echo "  ${_label} DOWNLOAD (content changed)"
}

for ver in "${VERSIONS[@]}"; do
	for catalog in "${CATALOGS[@]}"; do
		_check_content_change "$catalog" "$ver" &
		running=$((running + 1))
		if (( running >= MAX_PARALLEL )); then
			wait -n 2>/dev/null || true
			running=$((running - 1))
		fi
	done
done
wait

# Count results
needs_download=()
for marker in "${NEEDS_DOWNLOAD_DIR}"/*; do
	[[ -f "$marker" ]] || continue
	needs_download+=("$(basename "$marker")")
done
skipped=$(( ${#VERSIONS[@]} * ${#CATALOGS[@]} - ${#needs_download[@]} ))

echo ""
echo "  Need download: ${#needs_download[@]}, Already current: ${skipped}"

# Prompt user to continue (skip if -y or nothing to download)
if [[ ${#needs_download[@]} -gt 0 && "$do_yes" != true ]]; then
	echo ""
	read -rp "Continue with download? (Y/n) " _answer
	if [[ "$_answer" =~ ^[Nn] ]]; then
		echo "Aborted by user."
		exit 0
	fi
fi

# Phase 1b: Download catalogs that changed (sequential -- podman can't overlap well)
failed=()
downloaded=0

if [[ ${#needs_download[@]} -gt 0 ]]; then
	echo ""
	echo "=== Downloading ${#needs_download[@]} catalog(s) ==="
	for entry in "${needs_download[@]}"; do
		catalog="${entry%%:*}"
		ver="${entry#*:}"
		remote_ref="docker://registry.redhat.io/redhat/${catalog}-index:v${ver}"
		layer_digest_file="${INDEX_DIR}/.${catalog}-index-v${ver}.content-layer-digest"
		#local _label
		printf -v _label "%-18s  v%-5s" "$catalog" "$ver"

		echo "  ${_label} ..."
		if scripts/download-catalog-index.sh "$catalog" "$ver"; then
			# Save content layer digest for future change detection
			cld=$(_get_content_layer_digest "$remote_ref") || cld=""
			[[ -n "$cld" ]] && echo "$cld" > "$layer_digest_file"
			echo "  ${_label} OK"
			downloaded=$((downloaded + 1))
		else
			echo "  ${_label} FAIL" >&2
			failed+=("${catalog}:${ver}")
		fi
	done
fi

echo ""
echo "  Downloaded: ${downloaded}, Skipped: ${skipped}, Failed: ${#failed[@]}"

if [[ ${#failed[@]} -gt 0 ]]; then
	echo ""
	echo "ERROR: ${#failed[@]} catalog(s) failed to download:" >&2
	printf "  %s\n" "${failed[@]}" >&2
	echo "Aborting -- catalogs/ not updated (all-or-nothing)." >&2
	exit 1
fi

# Drift check: new index must not differ from shipped version by >5% in BOTH size and line count.
# Catches corrupted downloads or drastic unexpected upstream changes.
MAX_DRIFT=5
drift_errors=()

if [[ ${#needs_download[@]} -gt 0 ]]; then
	for entry in "${needs_download[@]}"; do
		catalog="${entry%%:*}"
		ver="${entry#*:}"
		new_file="${INDEX_DIR}/${catalog}-index-v${ver}"
		old_file="${CATALOGS_DIR}/${catalog}-index-v${ver}"

		# Skip if no previous shipped version to compare against
		[[ -s "$old_file" ]] || continue
		[[ -s "$new_file" ]] || continue

		old_lines=$(wc -l < "$old_file")
		new_lines=$(wc -l < "$new_file")
		old_size=$(wc -c < "$old_file")
		new_size=$(wc -c < "$new_file")

		# Calculate drift percentages (avoid division by zero)
		line_drift=0
		size_drift=0
		(( old_lines > 0 )) && line_drift=$(( (new_lines - old_lines) * 100 / old_lines ))
		(( old_size > 0 )) && size_drift=$(( (new_size - old_size) * 100 / old_size ))
		# Absolute values
		(( line_drift < 0 )) && line_drift=$(( -line_drift ))
		(( size_drift < 0 )) && size_drift=$(( -size_drift ))

		if (( line_drift > MAX_DRIFT && size_drift > MAX_DRIFT )); then
			drift_errors+=("${catalog} v${ver}: lines ${old_lines}->${new_lines} (${line_drift}%), size ${old_size}->${new_size} (${size_drift}%)")
		fi
	done
fi

if [[ ${#drift_errors[@]} -gt 0 ]]; then
	echo ""
	echo "ERROR: ${#drift_errors[@]} catalog(s) differ by >${MAX_DRIFT}% in both size and line count:" >&2
	printf "  %s\n" "${drift_errors[@]}" >&2
	echo ""
	echo "This may indicate a corrupted download or unexpected upstream change." >&2
	echo "Investigate before updating catalogs/. Use --force to override." >&2
	exit 1
fi

# Phase 2: Verify all downloaded catalogs
echo ""
echo "=== Phase 2: Verifying catalogs ==="
verify_failed=()
_prev_ver=""

for ver in "${VERSIONS[@]}"; do
	for catalog in "${CATALOGS[@]}"; do
		index="${INDEX_DIR}/${catalog}-index-v${ver}"
		if [[ ! -s "$index" ]]; then
			echo "  FAIL: empty or missing: $index" >&2
			verify_failed+=("${catalog}:${ver}")
			continue
		fi

		count=$(wc -l < "$index")
		if (( count < MIN_OPERATORS )); then
			echo "  FAIL: ${catalog} v${ver} has only ${count} operators (min: ${MIN_OPERATORS})" >&2
			verify_failed+=("${catalog}:${ver}")
			continue
		fi

		# Format check: first line should have at least 2 whitespace-separated fields
		if ! head -1 "$index" | awk 'NF >= 2 {exit 0} {exit 1}'; then
			echo "  FAIL: ${catalog} v${ver} format check failed" >&2
			verify_failed+=("${catalog}:${ver}")
			continue
		fi

		# Verify all operators were extracted (expected-count comes from image directory count)
		ec_file="${INDEX_DIR}/.${catalog}-index-v${ver}.expected-count"
		if [[ -f "$ec_file" ]]; then
			expected=$(< "$ec_file")
			if (( count != expected )); then
				echo "  FAIL: ${catalog} v${ver} extracted ${count} but image has ${expected} operators" >&2
				verify_failed+=("${catalog}:${ver}")
				continue
			fi
		fi

		# Display name coverage
		has_display=$(awk '$2 != "-" {count++} END {print count+0}' "$index")
		pct=0
		[[ "$count" -gt 0 ]] && pct=$((has_display * 100 / count))

		# Group output by version
		if [[ "$ver" != "$_prev_ver" ]]; then
			[[ -n "$_prev_ver" ]] && echo ""
			printf "  v%-6s" "$ver"
			_prev_ver="$ver"
		fi
		# Short catalog name, padded for alignment
		short="${catalog%-operator}"
		printf "  %-11s=%3d/%-3d" "$short" "$count" "${expected:-$count}"
		(( pct < 100 )) && printf " [%d%% names]" "$pct"
	done
done
echo ""

if [[ ${#verify_failed[@]} -gt 0 ]]; then
	echo ""
	echo "ERROR: ${#verify_failed[@]} catalog(s) failed verification:" >&2
	printf "  %s\n" "${verify_failed[@]}" >&2
	echo "Aborting -- catalogs/ not updated (all-or-nothing)." >&2
	exit 1
fi

# Phase 3: Copy verified files to catalogs/
echo ""
echo "=== Phase 3: Updating catalogs/ ==="
for ver in "${VERSIONS[@]}"; do
	for catalog in "${CATALOGS[@]}"; do
		src="${INDEX_DIR}/${catalog}-index-v${ver}"
		dst="${CATALOGS_DIR}/${catalog}-index-v${ver}"
		cp "$src" "$dst"
		echo "  ${dst}"
	done
done

echo ""
echo "=== catalogs/ updated successfully ==="
echo "Files:"
ls -la "${CATALOGS_DIR}/"

if git diff --quiet "${CATALOGS_DIR}/" 2>/dev/null && git diff --quiet --cached "${CATALOGS_DIR}/" 2>/dev/null; then
	echo "No changes detected in ${CATALOGS_DIR}/ -- catalogs are up to date."
elif [[ "$do_commit" == true ]]; then
	echo ""
	echo "=== Changes detected -- committing and pushing ==="
	# This script legitimately runs on both 'main' (to keep shipped catalogs fresh
	# for users) and 'dev' (during development). Confirm the target branch so the
	# operator doesn't accidentally push to the wrong one.
	current_branch=$(git branch --show-current)
	if [[ "$do_yes" != true ]]; then
		read -rp "Commit and push to '${current_branch}'? (Y/n) " _answer
		if [[ "$_answer" =~ ^[Nn] ]]; then
			echo "Aborted -- changes NOT committed."
			echo "Changes detected in ${CATALOGS_DIR}/:"
			git diff --stat "${CATALOGS_DIR}/"
			exit 0
		fi
	fi
	git add "${CATALOGS_DIR}/"
	git commit -m "$(cat <<'EOF'
Update shipped catalog indexes

Refresh operator catalog index files for all supported OCP versions.
EOF
)"
	git push
else
	echo ""
	echo "Changes detected in ${CATALOGS_DIR}/:"
	git diff --stat "${CATALOGS_DIR}/"
	echo "(use --commit to commit and push)"
fi

echo ""
echo "Done."
