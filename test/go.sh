#!/bin/bash -ex
# Simple top level script to run all tests

# This is for testing a specific branch ($1) directly from "git clone", otherwise it will test
# the local dir. ($PWD)
if [ "$1" ]; then
	# Used for testing from git
	make -C mirror distclean yes=1 # Remove old big tar files. Need all space on disk!
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

time (
	echo "=========================================================================="  	 > test/test.log
	echo "START TESTS @ $(date)" 								>> test/test.log
	echo "==========================================================================" 	>> test/test.log
	time test/test1-basic-sync-test-and-save-load-test.sh
	time test/test2-airgapped-existing-reg.sh
	time test/test5-airgapped-install-local-reg.sh
) && ( echo SUCCESS  || echo FAILED ) | tee test/test.log

date 

