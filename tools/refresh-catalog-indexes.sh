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
#
# Usage:
#   tools/refresh-catalog-indexes.sh [--commit] [--tag]
#     --commit   git add + commit + push the updated catalogs/
#     --tag      also move the latest release tag forward (implies --commit)

cd "$(dirname "$0")/.."

source scripts/include_all.sh

CATALOGS_DIR="catalogs"
INDEX_DIR=".index"
CATALOGS=(redhat-operator certified-operator community-operator)
MIN_OPERATORS=50
DEPTH=6

do_commit=false
do_tag=false
do_force=false
do_yes=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--commit) do_commit=true; shift ;;
		--tag)    do_tag=true; do_commit=true; shift ;;
		--force)  do_force=true; shift ;;
		-y|--yes) do_yes=true; shift ;;
		-h|--help)
			echo "Usage: $0 [--force] [-y] [--commit] [--tag]"
			echo "  --force    re-download all catalogs even if already present"
			echo "  -y|--yes   skip confirmation prompts"
			echo "  --commit   git add + commit + push updated catalogs/"
			echo "  --tag      move latest release tag forward (implies --commit)"
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

# Phase 1a: Parallel digest check to find which catalogs need re-downloading.
# Runs up to MAX_PARALLEL skopeo probes concurrently (~3s each).
MAX_PARALLEL=4
NEEDS_DOWNLOAD_DIR=$(mktemp -d)
trap "rm -rf '$NEEDS_DOWNLOAD_DIR'" EXIT

echo "=== Phase 1: Checking for upstream changes (${MAX_PARALLEL} parallel) ==="
skipped=0
running=0

_check_digest() {
	local catalog="$1" ver="$2"
	local index="${INDEX_DIR}/${catalog}-index-v${ver}"
	local remote_digest_file="${INDEX_DIR}/.${catalog}-index-v${ver}.remote-digest"
	local remote_ref="docker://registry.redhat.io/redhat/${catalog}-index:v${ver}"

	# --force: always re-download
	if [[ "$do_force" == true ]]; then
		touch "${NEEDS_DOWNLOAD_DIR}/${catalog}:${ver}"
		echo "--- ${catalog} v${ver} --- DOWNLOAD (--force)"
		return
	fi

	# No local index file: must download
	if [[ ! -s "$index" ]]; then
		touch "${NEEDS_DOWNLOAD_DIR}/${catalog}:${ver}"
		echo "--- ${catalog} v${ver} --- DOWNLOAD (no local index)"
		return
	fi

	# No saved remote digest: probe it now. If local index exists, save digest and skip.
	if [[ ! -f "$remote_digest_file" ]]; then
		if [[ -s "$index" ]]; then
			# Have a valid local file -- just need to save the digest for next time
			local remote_rd
			remote_rd=$(skopeo inspect --no-tags --format '{{.Digest}}' "$remote_ref" 2>/dev/null) || remote_rd=""
			if [[ -n "$remote_rd" ]]; then
				echo "$remote_rd" > "$remote_digest_file"
				echo "--- ${catalog} v${ver} --- SKIP (saved digest for next run)"
				return
			fi
			# skopeo failed but we have a local file -- skip anyway
			echo "--- ${catalog} v${ver} --- SKIP (local index exists, skopeo probe failed)"
			return
		fi
		# No local index at all: must download
		touch "${NEEDS_DOWNLOAD_DIR}/${catalog}:${ver}"
		echo "--- ${catalog} v${ver} --- DOWNLOAD (no local index or digest)"
		return
	fi

	# Probe remote digest
	local local_rd remote_rd
	local_rd=$(< "$remote_digest_file")
	remote_rd=$(skopeo inspect --no-tags --format '{{.Digest}}' "$remote_ref" 2>/dev/null) || remote_rd=""

	# skopeo failed (network/timeout)
	if [[ -z "$remote_rd" ]]; then
		touch "${NEEDS_DOWNLOAD_DIR}/${catalog}:${ver}"
		echo "--- ${catalog} v${ver} --- DOWNLOAD (skopeo probe failed)"
		return
	fi

	# Digest matches: upstream unchanged
	if [[ "$remote_rd" == "$local_rd" ]]; then
		echo "--- ${catalog} v${ver} --- SKIP (digest unchanged)"
		return
	fi

	# Digest changed: upstream has a new image
	touch "${NEEDS_DOWNLOAD_DIR}/${catalog}:${ver}"
	echo "--- ${catalog} v${ver} --- DOWNLOAD (upstream changed)"
}

for ver in "${VERSIONS[@]}"; do
	for catalog in "${CATALOGS[@]}"; do
		_check_digest "$catalog" "$ver" &
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
		remote_digest_file="${INDEX_DIR}/.${catalog}-index-v${ver}.remote-digest"

		echo "--- ${catalog} v${ver} ---"
		if scripts/download-catalog-index.sh "$catalog" "$ver"; then
			# Save remote digest for future idempotency checks
			rd=$(skopeo inspect --no-tags --format '{{.Digest}}' "$remote_ref" 2>/dev/null) || rd=""
			[[ -n "$rd" ]] && echo "$rd" > "$remote_digest_file"
			echo "  OK: downloaded ${catalog} v${ver}"
			downloaded=$((downloaded + 1))
		else
			echo "  FAIL: ${catalog} v${ver}" >&2
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
			printf "  v%-5s" "$ver"
			_prev_ver="$ver"
		fi
		# Short catalog name
		short="${catalog%-operator}"
		printf "  %s=%d/%d" "$short" "$count" "${expected:-$count}"
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
	git add "${CATALOGS_DIR}/"
	git commit -m "$(cat <<'EOF'
Update shipped catalog indexes

Refresh operator catalog index files for all supported OCP versions.
EOF
)"
	git push

	if [[ "$do_tag" == true ]]; then
		local_tag=$(git describe --tags --abbrev=0 2>/dev/null) || true
		if [[ -n "$local_tag" ]]; then
			echo "Moving tag ${local_tag} to HEAD..."
			git tag -f "$local_tag"
			git push -f origin "$local_tag"
		else
			echo "No existing tag found -- skipping --tag"
		fi
	fi
else
	echo ""
	echo "Changes detected in ${CATALOGS_DIR}/:"
	git diff --stat "${CATALOGS_DIR}/"
	echo "(use --commit to commit and push)"
fi

echo ""
echo "Done."
