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

vers_track="21 20"

which notify.sh >/dev/null && NOTIFY=1 || NOTIFY=

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO_ROOT/test/lib.sh"

# Ensure internet access via the direct interface
int_up

echo "Starting $0 at $(date)"

# Define bundle types: name, operator sets
#   name        op_sets
arr_op_sets=();				arr_name=();
arr_op_sets+=(" ");			arr_name+=(release);
arr_op_sets+=("ocp");			arr_name+=(ocp);
arr_op_sets+=("ocp mesh3");		arr_name+=(mesh3);
arr_op_sets+=("ocp odf sec acm");	arr_name+=(opp);
arr_op_sets+=("ocp odf ocpv");		arr_name+=(ocpv);
arr_op_sets+=("ocp sec");		arr_name+=(sec);
arr_op_sets+=("ocp gpu ai");		arr_name+=(ai);

export OC_MIRROR_CACHE=$HOME
export PLAIN_OUTPUT=1

rm -vf ~/bin/{aba,butane,govc,kubectl,oc,oc-mirror,openshift-install}
rm -rf ~/.aba

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

	for i in "${!arr_name[@]}"
	do
		op_sets=${arr_op_sets[$i]}
		name=${arr_name[$i]}
		bundle_name="${ver}-$name"

		echo
		echo "Running: make VER=$ver NAME=$name OP_SETS=\"$op_sets\""
		sleep 1
		if ! time make VER="$ver" NAME="$name" OP_SETS="$op_sets"; then
			echo "##################################################" >&2
			echo "FAILED: bundle $bundle_name ($op_sets) at $(date)" >&2
			echo "##################################################" >&2
			echo "Showing last log lines:" >&2
			touch ~/tmp/bundle-go.out
			[ "$NOTIFY" ] && echo -e "Install bundle $bundle_name ($op_sets)\n$(tail -20 ~/tmp/bundle-go.out)" | tee >(notify.sh "FAILED: at $(date)") >&2
			echo "Quitting $0 at $(date)"
		fi

		# Run cleanup after each successful bundle (separate target)
		if ! make VER="$ver" NAME="$name" OP_SETS="$op_sets" cleanup; then
			echo "WARNING: cleanup failed for $bundle_name -- next run's 00-setup.sh will retry" >&2
		fi
	done
done

{
	date
	for d in /nas/redhat/aba-bundles-v2-test/4*; do
		[ -d "$d" ] && du -h -s "$d"
	done
	echo
} | tee -a ~/tmp/install-bundle-size.txt

[ "$NOTIFY" ] && echo "Completed at $(date)" | tee >(notify.sh "$0:")
