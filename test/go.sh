#!/bin/bash -ex
# Simple top level script to run all tests

# Clear the tmux screen buffer
[ "$TMUX" ] && s=$(echo $TMUX |cut -d, -f3) && tmux clear-history -t $s

#export VER_OVERRIDE=4.16.12 # Uncomment to use the 'latest' stable version of OCP
export internal_bastion_rhel_ver=rhel9  # rhel8 or rhel9

# This is for testing a specific branch ($1) directly from "git clone", otherwise it will test
# the local dir. ($PWD)
if [ "$1" ]; then
	# Used for testing from git
#	make -C mirror reset yes=1 # Remove old big tar files. Need all space on disk!
	rm -rf ~/testing && mkdir -p ~/testing
	cd ~/testing
	rm -rf aba
	git clone https://github.com/sjbylo/aba.git 
	cd aba
	git checkout $1
	#####git checkout 2fc137962da8c643724b09dca02a8e493c362f3c
fi

# Check no syntax errors in any scripts!
for f in */*.sh; do bash -n $f; done

export target_full=1   # Build vm+cluster
export target_full=    # Build only iso

echo "Removing all traces of images from this host!"
podman system prune --all --force && podman rmi --all && sudo rm -rf ~/.local/share/containers/storage

time (
	echo "=========================================================================="  	>> test/test.log
	echo "=========================================================================="  	>> test/test.log
	echo "Running: $0 $*                                                            "  	>> test/test.log
	echo "=========================================================================="  	>> test/test.log
	echo "START TESTS @ $(date)" 								>> test/test.log
	echo "==========================================================================" 	>> test/test.log
	time test/test2-airgapped-existing-reg.sh && \
	time test/test5-airgapped-install-local-reg.sh && \
	time test/test1-basic-sync-test-and-save-load-test.sh && \
	time test/test3-using-public-quay-reg.sh && \
	exit $? || exit $?
)
ret=$?
[ $ret -eq 0 ] && echo SUCCESS || echo FAILED | tee -a test/test.log

date 

