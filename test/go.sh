#!/bin/bash -ex
# Simple top level script to run all tests

echo $PWD | grep -q /testing/ && echo "Error: Exec tests from testing dir: $PWD" && exit 1

all_tests="\
test4 \
test2 \
test5 \
test1 \
test3 \
"

export ABA_TESTING=1  # This will disable tracking to api.counterapi.dev
hash -r  # Forget all command locations in $PATH

##sudo dnf autoremove ncurses -y

#export TEST_CHANNEL=fast
export TEST_CHANNEL=stable
#export TEST_CHANNEL=candidate  # This only works if e.g. 4.19.0 is available, does not yet work for release candidate versions e.g. 4.19.0.rc#

export VER_OVERRIDE=l # Uncomment to use the 'latest' version of OpenShift in the channel 
#export VER_OVERRIDE=p # Uncomment to use the 'previous' stable version of OpenShift
#export VER_OVERRIDE=4.16.30
#export VER_OVERRIDE=4.14.30

#export internal_bastion_rhel_ver=rhel10
export internal_bastion_rhel_ver=rhel9
#export internal_bastion_rhel_ver=rhel8

export DIS_SSH_USER=$(whoami)   # Test user on bastion.  This can be any user or $(whoami) 
#export DIS_SSH_USER=root   # This can be any user or $(whoami) 
#export DIS_SSH_USER=steve   # This can be any user or $(whoami) 

#export oc_mirror_ver_override=v1   # oc-mirror version to use (v1 now deprecated) 
export oc_mirror_ver_override=v2   # Default is no v2

# This is for testing a specific branch ($1) directly from "git clone", otherwise it will test
# the local dir. ($PWD)
if [ "$1" ]; then
	# Used for testing from git
#	make -C mirror reset yes=1 # Remove old big tar files. Need all space on disk!
	rm -rf ~/testing && mkdir -p ~/testing
	cd ~/testing
	rm -rf aba
	which git || sudo dnf install git -y 
	git clone https://github.com/sjbylo/aba.git 
	cd aba
	git checkout $1
	#####git checkout 2fc137962da8c643724b09dca02a8e493c362f3c
fi


# Clear the tmux screen buffer
#[ "$TMUX" ] && s=$(echo $TMUX |cut -d, -f3) && tmux clear-history -t $s
[ "$TMUX" ] && tmux clear-history 

# Check no syntax errors in any scripts!
for f in */*.sh; do bash -n $f; done

export target_full=1   # Build vm+cluster
export target_full=    # Build only iso

echo "Removing all traces of images from this host!"
podman system prune --all --force && podman rmi --all && sudo rm -rf ~/.local/share/containers/storage
rm -rf $(sudo find ~/ -type d -name .oc-mirror)

all_tests=$(echo $all_tests| sed "s/ $//g")

echo "=========================================================================="  	>> test/test.log
echo "=========================================================================="  	>> test/test.log
echo "Running: $0 $*                                                            "  	>> test/test.log
echo "=========================================================================="  	>> test/test.log
echo "START TESTS @ $(date)" 								>> test/test.log
echo "==========================================================================" 	>> test/test.log

echo Starting tests: $all_tests
echo "$all_tests [$TEST_CHANNEL] [$VER_OVERRIDE] [$internal_bastion_rhel_ver] [$(whoami) -> $DIS_SSH_USER] [$oc_mirror_ver_override]" | tee -a test/test.log | notify.sh Starting tests:

time for t in $all_tests
do
	ret=0
	set -o pipefail
	eval time test/$t-*.sh 2>&1 | tee -a test/output.log && notify.sh "Success $t (`date`)" || ret=1
	set +o pipefail
	[ $ret -ne 0 ] && echo Script $t exited with ret=$ret && break
done

if [ $ret -eq 0 ]; then
	git rev-parse HEAD  # Show the commit hash for this tested version
	echo SUCCESS
	notify.sh "SUCCESS (`date`)" || true
else
	echo FAILED | tee -a test/test.log
	notify.sh "FAILED (`date`)" || true
fi

date 

