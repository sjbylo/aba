#!/bin/bash -ex
# Simple top level script to run all tests

# Clear the tmux screen buffer
#[ "$TMUX" ] && s=$(echo $TMUX |cut -d, -f3) && tmux clear-history -t $s
[ "$TMUX" ] && tmux clear-history 

export VER_OVERRIDE=4.14.30 # Uncomment to use the 'latest' stable version of OCP
export internal_bastion_rhel_ver=rhel8  # rhel8 or rhel9
export TEST_USER=root   # This can be any user or $(whoami) 

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

all_tests="\
test1 \
test3 \
test5 \
test2 \
"

all_tests=$(echo $all_tests| sed "s/ $//g")
echo all_tests=$all_tests

time (
	echo "=========================================================================="  	>> test/test.log
	echo "=========================================================================="  	>> test/test.log
	echo "Running: $0 $*                                                            "  	>> test/test.log
	echo "=========================================================================="  	>> test/test.log
	echo "START TESTS @ $(date)" 								>> test/test.log
	echo "==========================================================================" 	>> test/test.log

	echo $all_tests | notify.sh -i Starting tests:

	for t in $all_tests
	do
	# If any of these following scripts fail, then this section will exit 1
	#time test/test1-basic-sync-test-and-save-load-test.sh 	2>&1 | stdbuf -oL -eL tee -a test/output.log 	&& notify.sh "Success test1 (`date`)" && \
	#time test/test3-using-public-quay-reg.sh 		2>&1 | stdbuf -oL -eL tee -a test/output.log 	&& notify.sh "Success test3 (`date`)" && \
	#time test/test5-airgapped-install-local-reg.sh 		2>&1 | stdbuf -oL -eL tee -a test/output.log 	&& notify.sh "Success test5 (`date`)" && \
	#time test/test2-airgapped-existing-reg.sh 		2>&1 | stdbuf -oL -eL tee -a test/output.log	&& notify.sh "Success test2 (`date`)" && \
		eval time test/$t-*.sh 2>&1 | tee -a test/output.log && notify.sh "Success $t (`date`)" || exit 1
	#	true
	done
) ## 2>&1 | stdbuf -oL -eL tee -a test/output.log    # stdbuf tries to put tee into line buffer mode to ensure output is written to disk
##ret=${PIPESTATUS[0]}  # Catpure only the result of the first command in the previous pipeline, i.e. not the "tee" command
ret=$?
if [ $ret -eq 0 ]; then
	echo SUCCESS
	notify.sh "SUCCESS (`date`)" || true
else
	echo FAILED | tee -a test/test.log
	notify.sh "FAILED (`date`)" || true
fi

date 

