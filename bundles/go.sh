#!/bin/bash -e

# -----------------------------------------------------------------------------
# Locking mechanism using `ln` for atomicity
# -----------------------------------------------------------------------------

LOCK_DIR="$HOME"
BASE_NAME=$(basename "$0")
BASE_FILE="$LOCK_DIR/.$BASE_NAME"
LOCK_FILE="$LOCK_DIR/.$BASE_NAME.lock"

# Release lock
release_lock() {
    [ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE"
}

# Acquire lock
acquire_lock() {
	touch $BASE_FILE
    if ln "$BASE_FILE" "$LOCK_FILE" 2>/dev/null; then
        trap 'release_lock' EXIT INT TERM HUP
        return 0
    else
        echo "❌ Another instance of $(basename "$0") is already running."
        exit 1
    fi
}

acquire_lock

cd $(dirname $0)

vers_track="20 19 18"

which notify.sh >/dev/null && NOTIFY=1 || NOTIFY=

. ~/.proxy-set.sh

##ps -ef | grep -v grep | grep $(basename $0) | wc -l | grep ^2$
#echo Checking if $0 is already running ...
#ps -ef | grep -v grep | grep "/bin/bash -.* .*$(basename $0)" 
#echo List of matching processes ...
#ps -ef | grep -v grep | grep "/bin/bash -.* .*$(basename $0)"  | wc -l 
#echo Matching processes count ...
#ps -ef | grep -v grep | grep "/bin/bash -.* $0" | wc -l
#ps -ef | grep -v grep | grep "/bin/bash -.* $0" | wc -l | grep ^2$ && echo "$0 already running ..." && exit 0

echo Starting $0 at $(date)

# Define the operator sets and subsets 
arr_op_set=();			arr_name=()
arr_op_set+=("ocp");		arr_name+=(ocp)
arr_op_set+=("ocp odf ocpv");	arr_name+=(ocpv)
arr_op_set+=("ai"); 		arr_name+=(ai)
#arr_op_set+=("ocp ai"); 	arr_name+=(ai)
#arr_op_set+=("ocp gpu ai"); 	arr_name+=(aiall)
arr_op_set+=("ocp mesh3");	arr_name+=(mesh3)
arr_op_set+=("ocp sec");	arr_name+=(sec)

export OC_MIRROR_CACHE=$HOME  # Set this so that multiple oc-mirror invocations can use the cache and we save time & bandwidth.
# Can also delete $OC_MIRROR_CACHE/.oc-mirror dir
export PLAIN_OUTPUT=1  # Supress curl progress bars and other color output

rm -rf ~/.oc-mirror/  # This is needed for "ai" bundle

# Discovered latest OCP versions
versions=()

# Fetch latest versions
for v in $vers_track
do
	ver=
	echo Checking for version stable-4.$v ...
	ver=$(curl -f --retry 2 -sSL https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/stable-4.$v/release.txt | grep ^Name: | awk '{print $NF}')
	[ ! "$ver" ] && echo "Cannot find release for $v at https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/stable-4.$v/release.txt" >&2 && continue
	versions+=("$ver")
done

list=$(echo ${versions[@]} | tr ' ' '\n')
echo "#######################"
echo -e "Creating install bundles for versions:\n$list"
[ "$NOTIFY" ] && echo -e "Creating install bundles for versions:\n$list" | notify.sh Creating install bundles:
echo "#######################"
echo

for ver in ${versions[@]}
do
	#bundle_name="${ver}-$name"
	echo
	echo Running: bundle-create-test.sh $ver base
	sleep 1
	if ./bundle-create-test.sh $ver base; then   # Create base bundle
		for i in ${!arr_op_set[@]}
		do
			op_sets=${arr_op_set[$i]}
			name=${arr_name[$i]}
			bundle_name="${ver}-$name"

			echo
			echo Running: bundle-create-test.sh $ver $name $op_sets
			sleep 1
			if ! ./bundle-create-test.sh $ver $name $op_sets; then
				echo "##################################################"
				echo "Failed: bundle $ver-$name ($op_sets) at $(date)" >&2
				echo "##################################################"
				[ "$NOTIFY" ] && echo -e "Install bundle $ver-$name ($op_sets)\n$(tail -20 ~/tmp/bundle-go.out)" | tee >(notify.sh Failed: at $(date)) >&2
				echo Quitting $0 at $(date)
				#exit 1
			fi
		done
	else
		[ "$NOTIFY" ] && echo -e "Install bundle $ver-base\n$(tail -20 ~/tmp/bundle-go.out)" | tee >(notify.sh Failed: at $(date)) >&2 
		echo Bundle create failed $0 at $(date)

		#exit 1   # If the base does not work, then give up for the rest of the bundle types
	fi
done

[ "$NOTIFY" ] && echo "Completed at $(date)" | tee >(notify.sh $0:) 

