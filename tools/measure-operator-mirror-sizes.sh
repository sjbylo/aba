#!/bin/bash
# Measure the on-disk size of operators by mirroring several at a time.
#
# Each operator gets its own oc-mirror archive (no platform release images).
# The archive is kept so the size can be re-counted later. The oc-mirror
# working-dir is removed after a successful run; it duplicates the archive.
# Each worker has its own cache and oc-mirror port. A shared cache is not
# safe for concurrent oc-mirror processes, and they all default to port 55000.
#
# Resumes: an operator whose latest sizes.txt line is "ok" and whose archive
# is still on disk is skipped. Failed operators are retried.
#
# Default list: operators named in templates/operator-set-* that exist in
# the chosen catalog index. That is the whole list worth measuring.
# Certified and community are large; do not measure every operator there.
# The estimator guesses any operator that has no row. Large operators run
# last so a full disk stops the run after the smaller ones are recorded.
#
# Examples:
#   tools/measure-operator-mirror-sizes.sh
#   tools/measure-operator-mirror-sizes.sh --dry-run
#   tools/measure-operator-mirror-sizes.sh --limit 1 node-maintenance-operator
#   tools/measure-operator-mirror-sizes.sh --op-sets ocp mesh3
#   tools/measure-operator-mirror-sizes.sh --ops cincinnati-operator web-terminal
#   tools/measure-operator-mirror-sizes.sh --catalog certified-operator --op-sets gpu

set -u

usage() {
	cat <<'EOF'
Usage: measure-operator-mirror-sizes.sh [options] [operator ...]

  Mirror each operator with oc-mirror and record the archive size.
  With no operator names, use the names in templates/operator-set-*
  that are present in the catalog index.

Options:
  --catalog NAME   Catalog index prefix (default: redhat-operator)
  --version VER    OpenShift minor version (default: 4.22)
  --out DIR        Where archives and sizes.txt are written
                   (default: ~/aba-operator-mirror-sizes, on local disk)
  --op-sets, -P    Operator sets, any number of names (same as aba).
                   Example: --op-sets ocp mesh3
                   Names from another catalog are skipped.
  --ops, -O        Operators, any number of names (same as aba).
                   Example: --ops cincinnati-operator web-terminal
  --all            Every operator in the catalog index. Not for certified
                   or community; those catalogs are guessed except the sets
  --limit N        Stop after N operators that still need measuring
  --parallel N     How many operators to mirror at once (default: 4)
  --dry-run        Print the operator list and exit
  --index-blobs    Rebuild blobs.tsv from archives already on disk and exit.
                   Same as tools/index-operator-blobs.sh. Copy that file to
                   catalogs/sizes/<catalog>-v<version>-<arch>.blobs
  -h, --help       Show this help
EOF
}

catalog=redhat-operator
version=4.22
out=$HOME/aba-operator-mirror-sizes
all=
limit=0
parallel=4
dry_run=
index_blobs=
ops=()
sets=()

while [ $# -gt 0 ]; do
	case "$1" in
		--catalog) catalog=$2; shift 2 ;;
		--version) version=$2; shift 2 ;;
		--out) out=$2; shift 2 ;;
		--all) all=1; shift ;;
		--op-sets|-P)
			shift
			if [[ -z "${1:-}" || "$1" == -* ]]; then
				echo "missing argument after --op-sets" >&2
				exit 1
			fi
			while [[ -n "${1:-}" && "$1" != -* ]]; do
				IFS=',' read -ra _parts <<< "$1"
				for _p in "${_parts[@]}"; do
					[ -n "$_p" ] && sets+=("$_p")
				done
				shift
			done
			;;
		--ops|-O|-ops)
			shift
			if [[ -z "${1:-}" || "$1" == -* ]]; then
				echo "missing argument after --ops" >&2
				exit 1
			fi
			while [[ -n "${1:-}" && "$1" != -* ]]; do
				IFS=',' read -ra _parts <<< "$1"
				for _p in "${_parts[@]}"; do
					[ -n "$_p" ] && ops+=("$_p")
				done
				shift
			done
			;;
		--limit) limit=$2; shift 2 ;;
		--parallel) parallel=$2; shift 2 ;;
		--dry-run) dry_run=1; shift ;;
		--index-blobs) index_blobs=1; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
		*) ops+=("$1"); shift ;;
	esac
done
while [ $# -gt 0 ]; do
	ops+=("$1")
	shift
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
index="$ROOT/catalogs/${catalog}-index-v${version}"
base="$out/${catalog}-v${version}"
sizes="$base/sizes.txt"
cache="$out/cache"
# Far-back --since forces a complete archive. Without it, oc-mirror writes
# only blobs it considers new since the previous save.
since=2000-01-01
# Stop before filling the filesystem. One large operator can still overshoot.
min_free=$((100 * 1024 * 1024 * 1024))
# These dominate a mirror. Run them after the rest.
defer_re='^(rhods-operator|kubevirt-hyperconverged|odf-operator|odf-dependencies|lightspeed-operator|devspaces|serverless-operator|amq-broker-rhel9|amq-broker-rhel8|mtv-operator|advanced-cluster-management|multicluster-engine|businessautomation-operator|datagrid)$'

# Walk each kept archive and record unique registry blob digests.
# A failed operator is skipped so a partial tar cannot enter the index.
index_existing_blobs() {
	if [ ! -d "$base" ]; then
		echo "No archive directory: $base" >&2
		return 1
	fi
	"$ROOT/tools/index-operator-blobs.sh" --archives "$base" --sizes "$sizes" --out "$base/blobs.tsv"
}


if [ ! -f "$index" ]; then
	echo "Catalog index not found: $index" >&2
	exit 1
fi
if [ "$index_blobs" = 1 ]; then
	index_existing_blobs
	exit $?
fi
if ! command -v oc-mirror >/dev/null 2>&1; then
	echo "oc-mirror is not on PATH" >&2
	exit 1
fi
authfile=$HOME/.docker/config.json
if [ ! -s "$authfile" ]; then
	echo "No pull secret at $authfile" >&2
	exit 1
fi

in_index() {
	awk -v op="$1" '$1 == op { found = 1 } END { exit !found }' "$index"
}

channel_of() {
	awk -v op="$1" '$1 == op { print $NF; exit }' "$index"
}

# Read operator names from one set file. Names not in this catalog are skipped.
add_set_file() {
	local setf=$1
	local name
	while read -r name _; do
		[ -n "$name" ] || continue
		case "$name" in \#*) continue ;; esac
		case "$seen" in *" $name "*) continue ;; esac
		if ! in_index "$name"; then
			[ ${#sets[@]} -gt 0 ] && echo "Skipping $name: not in $catalog $version" >&2
			continue
		fi
		ops+=("$name")
		seen="$seen$name "
	done < "$setf"
}

if [ "$all" ] && { [ ${#sets[@]} -gt 0 ] || [ ${#ops[@]} -gt 0 ]; }; then
	echo "--all cannot be combined with --op-sets or --ops" >&2
	exit 1
fi

# --ops names are explicit. --op-sets are added as well. Neither means every set.
named=()
if [ ${#ops[@]} -gt 0 ]; then
	named=("${ops[@]}")
fi
ops=()
seen=" "

if [ "$all" ]; then
	while read -r name _; do
		[ -n "$name" ] || continue
		case "$name" in \#*) continue ;; esac
		ops+=("$name")
	done < "$index"
else
	for name in "${named[@]+"${named[@]}"}"; do
		case "$seen" in *" $name "*) continue ;; esac
		if ! in_index "$name"; then
			echo "Skipping $name: not in $catalog $version" >&2
			continue
		fi
		ops+=("$name")
		seen="$seen$name "
	done
	if [ ${#sets[@]} -gt 0 ]; then
		for set in "${sets[@]}"; do
			case "$set" in
				*[!a-zA-Z0-9._-]*)
					echo "Unsafe operator set name: $set" >&2
					exit 1
					;;
			esac
			setf="$ROOT/templates/operator-set-$set"
			if [ ! -f "$setf" ]; then
				echo "Operator set not found: $setf" >&2
				echo -n "Available operator sets are: " >&2
				for _f in "$ROOT"/templates/operator-set-*; do
					[ -f "$_f" ] && echo -n "${_f##*operator-set-} "
				done >&2
				echo >&2
				exit 1
			fi
			add_set_file "$setf"
		done
	elif [ ${#named[@]} -eq 0 ]; then
		for setf in "$ROOT"/templates/operator-set-*; do
			[ -f "$setf" ] || continue
			add_set_file "$setf"
		done
	fi
fi

if [ ${#ops[@]} -eq 0 ]; then
	echo "No operators to measure" >&2
	exit 1
fi

# Stable order: everything else, then the large ones.
early=()
late=()
for op in "${ops[@]}"; do
	case "$op" in
		*[!a-zA-Z0-9._-]*)
			echo "Skipping unsafe operator name: $op" >&2
			continue
			;;
	esac
	if [[ "$op" =~ $defer_re ]]; then
		late+=("$op")
	else
		early+=("$op")
	fi
done
ops=("${early[@]}" "${late[@]+"${late[@]}"}")

if [ "$dry_run" ]; then
	echo "catalog=$catalog version=$version count=${#ops[@]} out=$base"
	for op in "${ops[@]}"; do
		printf '%s\t%s\n' "$op" "$(channel_of "$op")"
	done
	exit 0
fi

mkdir -p "$base" "$cache" "$out/tmp"
exec 9>"$out/measure.lock"
if ! flock -n 9; then
	echo "Another measurement is already running (lock $out/measure.lock)" >&2
	exit 1
fi

log() {
	flock 8
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$base/measure.log"
	flock -u 8
} 8>>"$base/log.lock"

append_sizes() {
	flock 6
	printf '%s\n' "$1" >> "$sizes"
	flock -u 6
} 6>>"$base/sizes.lock"

# Pop the next operator. Workers share this queue.
pop_op() {
	local op
	flock 7
	op=$(head -n 1 "$base/queue" 2>/dev/null || true)
	if [ -z "$op" ]; then
		flock -u 7
		return 1
	fi
	tail -n +2 "$base/queue" > "$base/queue.next"
	mv "$base/queue.next" "$base/queue"
	flock -u 7
	printf '%s\n' "$op"
} 7>>"$base/queue.lock"

free_bytes() {
	df -B1 --output=avail "$out" | awk 'NR==2 { print $1 }'
}

latest_status() {
	awk -F '\t' -v op="$1" '$1 == op { st = $3 } END { print st }' "$sizes" 2>/dev/null
}

archive_bytes() {
	local dest=$1 bytes=0 f s
	bytes=0
	for f in "$dest"/mirror_*.tar; do
		[ -f "$f" ] || continue
		s=$(stat -c %s "$f")
		bytes=$((bytes + s))
	done
	echo "$bytes"
}

# Move archives out of working-dir before that directory is deleted.
collect_archives() {
	local dest=$1 f
	find "$dest" -name 'mirror_*.tar' -print | while read -r f; do
		case "$f" in
			"$dest"/mirror_*.tar) ;;
			*) mv "$f" "$dest/" ;;
		esac
	done
}

measure_one() {
	local op=$1 slot=$2 channel dest rc bytes avail port cache_dir
	port=$((55100 + slot))
	cache_dir="$out/cache/slot-$slot"
	mkdir -p "$cache_dir" "$out/tmp/slot-$slot"
	channel=$(channel_of "$op")
	if [ -z "$channel" ]; then
		log "skip $op: not in $index"
		return 0
	fi
	dest="$base/$op"
	if [ "$(latest_status "$op")" = "ok" ] && [ -n "$(find "$dest" -maxdepth 1 -name 'mirror_*.tar' -print -quit 2>/dev/null)" ]; then
		log "skip $op: archive already measured"
		return 1
	fi

	avail=$(free_bytes)
	if [ "$avail" -lt "$min_free" ]; then
		log "stop: $((avail / 1024 / 1024 / 1024)) GiB free, under the 100 GiB floor"
		return 2
	fi

	log "start $op channel=$channel slot=$slot port=$port"
	rm -rf "$dest"
	mkdir -p "$dest"
	cat > "$dest/imageset-config.yaml" <<EOF
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: registry.redhat.io/redhat/${catalog}-index:v${version}
    packages:
    - name: ${op}
      channels:
      - name: "${channel}"
EOF

	rc=0
	TMPDIR="$out/tmp/slot-$slot" oc-mirror --v2 \
		--config "$dest/imageset-config.yaml" \
		"file://${dest}" \
		--since "$since" \
		--authfile "$authfile" \
		--cache-dir "$cache_dir" \
		--port "$port" \
		--image-timeout 40m \
		--parallel-images 4 \
		--retry-times 2 \
		--retry-delay 2s \
		> "$dest/oc-mirror.log" 2>&1 || rc=$?

	collect_archives "$dest"
	bytes=$(archive_bytes "$dest")
	if [ "$rc" -eq 0 ] && [ "$bytes" -gt 0 ]; then
		rm -rf "$dest/working-dir"
		append_sizes "$(printf '%s\t%s\tok\t%s\t%s' "$op" "$bytes" "$channel" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
		log "ok $op bytes=$bytes"
		return 0
	fi

	append_sizes "$(printf '%s\t%s\tfail\t%s\t%s' "$op" "$bytes" "$channel" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
	log "fail $op exit=$rc bytes=$bytes (see $dest/oc-mirror.log)"
	return 0
}

worker() {
	local slot=$1 op rc
	while op=$(pop_op); do
		[ -f "$base/stop" ] && break
		measure_one "$op" "$slot"
		rc=$?
		if [ "$rc" -eq 2 ]; then
			touch "$base/stop"
			break
		fi
	done
}

case "$parallel" in
	''|*[!0-9]*) echo "--parallel must be a positive number" >&2; exit 1 ;;
esac
if [ "$parallel" -lt 1 ]; then
	echo "--parallel must be a positive number" >&2
	exit 1
fi

rm -f "$base/stop"
: > "$base/queue"
queued=0
for op in "${ops[@]}"; do
	dest="$base/$op"
	if [ "$(latest_status "$op")" = "ok" ] && [ -n "$(find "$dest" -maxdepth 1 -name 'mirror_*.tar' -print -quit 2>/dev/null)" ]; then
		continue
	fi
	printf '%s\n' "$op" >> "$base/queue"
	queued=$((queued + 1))
	if [ "$limit" -gt 0 ] && [ "$queued" -ge "$limit" ]; then
		break
	fi
done

log "measuring $queued operators parallel=$parallel catalog=$catalog version=$version out=$base"
if [ "$queued" -eq 0 ]; then
	index_existing_blobs || log "blob index failed"
	log "finished"
	exit 0
fi
if [ "$parallel" -gt "$queued" ]; then
	parallel=$queued
fi

slot=0
while [ "$slot" -lt "$parallel" ]; do
	worker "$slot" &
	slot=$((slot + 1))
done
wait
index_existing_blobs || log "blob index failed"
log "finished"
