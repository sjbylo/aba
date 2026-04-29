#!/bin/bash -e
#
# Monitor for new OpenShift releases across major versions and channels.
# Auto-discovers the latest minor for each major; no hardcoded minor numbers.
# Tracks seen versions in ~/.ocp-new-ver/ and notifies on new ones.
#
# Usage: check-ocp-versions.sh [-v]
#   -v  verbose output (show probing progress)
#
# Intended to run via cron, e.g.:
#   */30 * * * * /path/to/check-ocp-versions.sh 2>&1 | logger -t ocp-ver-check

[ "$1" = "-v" ] && verbose=1

[ "$verbose" ] && echo "Start $0 at $(date)"

[ -f ~/.proxy-set.sh ] && . ~/.proxy-set.sh

DB_DIR=~/.ocp-new-ver
mkdir -p "$DB_DIR"

WINDOW=5                   # How many minors back from latest to check
MAJORS=(4 5 6)             # Probe these; non-existent ones are skipped
CHANNELS=("stable" "fast" "candidate")
BASE_URL="https://mirror.openshift.com/pub"

# Auto-discover the highest available minor for a given major version.
# Probes candidate first (may have RC for a newer minor), then fast, then stable.
# Validates the version's major matches to handle mirror aliasing (v5 mirrors v4 today).
discover_latest_minor() {
	local major=$1
	local latest_minor=0

	for ch in candidate fast stable; do
		local url="$BASE_URL/openshift-v${major}/amd64/clients/ocp/${ch}/release.txt"
		local ver
		ver=$(curl --max-time 10 -f --retry 2 -sSL "$url" 2>/dev/null | grep ^Name: | awk '{print $NF}') || continue
		[ -z "$ver" ] && continue

		local ver_major
		ver_major=$(echo "$ver" | cut -d. -f1)
		[ "$ver_major" != "$major" ] && continue

		local minor
		minor=$(echo "$ver" | cut -d. -f2)
		[ "$minor" -gt "$latest_minor" ] 2>/dev/null && latest_minor=$minor
	done

	[ "$latest_minor" -eq 0 ] && return 1
	echo "$latest_minor"
}

for major in "${MAJORS[@]}"; do
	[ "$verbose" ] && echo "Probing major version $major ..."

	latest_minor=$(discover_latest_minor "$major") || {
		[ "$verbose" ] && echo "  No releases found for v$major, skipping"
		continue
	}

	end_minor=$(( latest_minor - WINDOW + 1 ))
	[ "$end_minor" -lt 0 ] && end_minor=0

	[ "$verbose" ] && echo "  v$major: checking minors $latest_minor down to $end_minor"

	for v in $(seq "$latest_minor" -1 "$end_minor"); do
		for c in "${CHANNELS[@]}"; do
			CH_VER="$c-$major.$v"
			URL="$BASE_URL/openshift-v$major/amd64/clients/ocp/$CH_VER/release.txt"

			[ "$verbose" ] && echo "  Checking $CH_VER ..."

			avail_ver=$(curl --max-time 15 -f --retry 3 -sSL "$URL" 2>/dev/null | grep ^Name: | awk '{print $NF}')

			if [ -z "$avail_ver" ]; then
				continue
			fi

			if [ ! -f "$DB_DIR/$CH_VER/$avail_ver" ]; then
				echo ">>>> New version detected: $avail_ver ($c) <<<<"
				mkdir -p "$DB_DIR/$CH_VER"
				touch "$DB_DIR/$CH_VER/$avail_ver"

				if [ -x ~/bin/notify.sh ]; then
					~/bin/notify.sh "New OCP $major Release: $avail_ver ($c)"
				fi
			else
				[ "$verbose" ] && echo "  Already known: $avail_ver"
			fi
		done
	done
done

[ "$verbose" ] && echo "Done $0 at $(date)"
exit 0
