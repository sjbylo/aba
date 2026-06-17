#!/bin/bash -e
# go.sh - Orchestrate bundle creation for multiple OCP versions and bundle types

mkdir -p ~/tmp

# Locking mechanism using ln for atomicity
LOCK_DIR="$HOME"
BASE_NAME=$(basename "$0")
BASE_FILE="$LOCK_DIR/.$BASE_NAME"
LOCK_FILE="$LOCK_DIR/.$BASE_NAME.lock"

release_lock() {
	[ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE"
}

acquire_lock() {
	touch "$BASE_FILE"
	if ln "$BASE_FILE" "$LOCK_FILE" 2>/dev/null; then
		trap 'release_lock' EXIT INT TERM HUP
		return 0
	else
		echo "Another instance of $(basename "$0") is already running."
		exit 1
	fi
}

acquire_lock

cd "$(dirname "$0")"

source bundle.conf

vers_track="21 20"

which notify.sh >/dev/null && NOTIFY=1 || NOTIFY=

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/test/lib.sh"

# Ensure internet access via the direct interface
int_up

echo "Starting $0 at $(date)"

# Define bundle types: name, operator sets, tests to run
#   op_sets                          name       tests (space-separated test module names)
arr_op_sets=();				arr_name=();	arr_tests=();
arr_op_sets+=(" ");			arr_name+=(release);	arr_tests+=("");
arr_op_sets+=("ocp");			arr_name+=(ocp);	arr_tests+=("ocp");
arr_op_sets+=("ocp mesh3");		arr_name+=(mesh3);	arr_tests+=("ocp mesh3");
arr_op_sets+=("ocp odf sec acm");	arr_name+=(opp);	arr_tests+=("odf acm acs");
arr_op_sets+=("ocp odf virt");		arr_name+=(virt);	arr_tests+=("odf virt mtv");
#arr_op_sets+=("ocp odf sec");		arr_name+=(sec);	arr_tests+=("odf acs");
arr_op_sets+=("ocp gpu ai");		arr_name+=(ai);		arr_tests+=("ai");

export OC_MIRROR_CACHE=$HOME
export PLAIN_OUTPUT=1
export BATCH=1

# CLI tools and ~/.aba state are NOT cleaned here -- use 'make clean' for a fresh start.
# This allows go.sh to be re-run idempotently after a failure (make resumes from markers).

# Discover latest OCP versions
versions=()

for v in $vers_track
do
	ver=
	echo "Checking for version stable-4.$v ..."
	ver=$(curl -f --retry 8 -sSL "https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/stable-4.$v/release.txt" | grep ^Name: | awk '{print $NF}')
	[ ! "$ver" ] && echo "Cannot find release for $v" >&2 && continue
	versions+=("$ver")
done

list=$(echo "${versions[@]}" | tr ' ' '\n')
echo "#######################"
echo -e "Creating install bundles for versions:\n$list"
echo "#######################"
echo

for ver in "${versions[@]}"
do
	# Clear oc-mirror cache between OCP versions to reclaim disk space
	rm -rf ~/.oc-mirror/

	# Sort bundle types so the oldest (or missing) bundles are built first.
	# For each type, find the current patch version in CLOUD_DIR.
	# Missing/incomplete bundles get -1, so they're built before stale ones.
	major_ver=$(echo "$ver" | cut -d. -f1,2)
	build_order=()
	for i in "${!arr_name[@]}"; do
		_bname=${arr_name[$i]}
		current_patch=-1
		for d in "$CLOUD_DIR/${major_ver}".*-"${_bname}"; do
			if [ -d "$d" ] && [ -f "$d/README.txt" ] && [ ! -f "$d/INSTALL-BUNDLE-UPLOADING-OR-INCOMPLETE.txt" ]; then
				p=$(basename "$d" | sed "s/^${major_ver}\.\([0-9]*\)-.*/\1/")
				[ "$p" -gt "$current_patch" ] 2>/dev/null && current_patch=$p
			fi
		done
		build_order+=("$current_patch:$i")
	done
	IFS=$'\n' sorted=($(sort -t: -k1,1n <<<"${build_order[*]}")); unset IFS

	echo "Build order for $ver (oldest first): $(for e in "${sorted[@]}"; do echo -n "${arr_name[${e#*:}]}(${e%%:*}) "; done)"

	for entry in "${sorted[@]}"
	do
		i=${entry#*:}
		op_sets=${arr_op_sets[$i]}
		name=${arr_name[$i]}
		tests=${arr_tests[$i]}
		bundle_name="${ver}-$name"

		echo
		# Skip if bundle already exists and is complete in cloud dir
		# (To force a rebuild, delete or rename the cloud dir first)
		cloud_bundle="$CLOUD_DIR/$bundle_name"
		if [ -d "$cloud_bundle" ] && [ ! -f "$cloud_bundle/INSTALL-BUNDLE-UPLOADING-OR-INCOMPLETE.txt" ] && [ -f "$cloud_bundle/README.txt" ]; then
			echo "Install bundle already exists: $cloud_bundle -- skipping"
			continue
		fi

		echo "Running: make VER=$ver NAME=$name OP_SETS=\"$op_sets\" TESTS=\"$tests\""
		sleep 1
		if ! time make VER="$ver" NAME="$name" OP_SETS="$op_sets" TESTS="$tests"; then
			echo "##################################################" >&2
			echo "FAILED: bundle $bundle_name ($op_sets) at $(date)" >&2
			echo "##################################################" >&2
			_build_log="$WORK_DIR/bundle-build.log"
			echo "Showing last 20 log lines:" >&2
			tail -20 "$_build_log" 2>/dev/null >&2
			[ "$NOTIFY" ] && echo -e "FAILED: bundle $bundle_name ($op_sets)\n\n$(tail -20 "$_build_log" 2>/dev/null)" | notify.sh "Bundle FAILED: $bundle_name at $(date)"
			echo "Quitting $0 at $(date)"
			exit 1
		fi

		# Run cleanup after each successful bundle (separate target)
		if ! make VER="$ver" NAME="$name" OP_SETS="$op_sets" TESTS="$tests" clean; then
			echo "WARNING: cleanup failed for $bundle_name -- next run's 00-setup.sh will retry" >&2
		fi
	done
done

{
	date
	for d in "$CLOUD_DIR"/4*; do
		[ -d "$d" ] && du -h -s "$d"
	done
	echo
} | tee -a ~/tmp/install-bundle-size.txt

[ "$NOTIFY" ] && echo "Completed at $(date)" | tee >(notify.sh "$0:")
