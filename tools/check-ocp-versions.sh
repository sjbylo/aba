#!/bin/bash -e
#
# Monitor for new OpenShift releases and notify on unseen versions.
# Tracks seen versions in ~/.ocp-new-ver/.
#
# Default: only the tip minor of each major (WINDOW=1), on stable + candidate.
# That covers (1) latest GA line e.g. 4.22.x and (2) latest pre-release e.g. 5.0.0.
#
# Usage: check-ocp-versions.sh [options]
#   -v, --verbose              Show probing progress
#   -w, --window N             Minors back from latest to check (default: 1)
#   --majors LIST              Comma-separated majors to probe (default: 4,5,6)
#   --channels LIST            Comma-separated channels (default: stable,candidate)
#                              Use stable,fast,candidate for the old full set
#
# Intended to run via cron, e.g.:
#   */30 * * * * /path/to/check-ocp-versions.sh 2>&1 | logger -t ocp-ver-check

verbose=
WINDOW=1
MAJORS=(4 5 6)
CHANNELS=("stable" "candidate")
BASE_URL="https://mirror.openshift.com/pub"
DB_DIR=~/.ocp-new-ver

usage() {
	sed -n '2,18p' "$0" | sed 's/^# \?//'
	exit "${1:-0}"
}

# Parse "a,b,c" or "a b c" into a bash array name passed as $1
_parse_list() {
	local -n _out=$1
	shift
	local raw="$*"
	raw="${raw//,/ }"
	# shellcheck disable=SC2206
	_out=($raw)
}

while [ $# -gt 0 ]; do
	case "$1" in
		-v|--verbose) verbose=1; shift ;;
		-w|--window)
			[ -n "${2:-}" ] || { echo "Error: $1 needs a value" >&2; exit 1; }
			WINDOW=$2
			shift 2
			;;
		--majors)
			[ -n "${2:-}" ] || { echo "Error: $1 needs a value" >&2; exit 1; }
			_parse_list MAJORS "$2"
			shift 2
			;;
		--channels)
			[ -n "${2:-}" ] || { echo "Error: $1 needs a value" >&2; exit 1; }
			_parse_list CHANNELS "$2"
			shift 2
			;;
		-h|--help) usage 0 ;;
		*)
			echo "Error: unknown option: $1" >&2
			usage 1
			;;
	esac
done

[[ "$WINDOW" =~ ^[0-9]+$ ]] && [ "$WINDOW" -ge 1 ] || {
	echo "Error: --window must be a positive integer (got '$WINDOW')" >&2
	exit 1
}
[ ${#MAJORS[@]} -gt 0 ] || { echo "Error: --majors list is empty" >&2; exit 1; }
[ ${#CHANNELS[@]} -gt 0 ] || { echo "Error: --channels list is empty" >&2; exit 1; }

[ "$verbose" ] && echo "Start $0 at $(date) (window=$WINDOW majors=${MAJORS[*]} channels=${CHANNELS[*]})"

[ -f ~/.proxy-set.sh ] && . ~/.proxy-set.sh

mkdir -p "$DB_DIR"

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

			avail_ver=$(curl --max-time 15 -f --retry 3 -sSL "$URL" 2>/dev/null | grep ^Name: | awk '{print $NF}') || true

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
