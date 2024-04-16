#!/bin/bash -ex

#if false; then
if [ "1" ]; then
	# Used for testing from git
	make -C mirror distclean yes=1 # Remove old big tar files. Need all space on disk!
	rm -rf ~/testing && mkdir -p ~/testing && cd ~/testing
	git clone https://github.com/sjbylo/aba.git 
	cd aba
	git checkout dev
	#git checkout main
	#cd ~/testing/aba
fi

export target_full=1   # Build vm
export target_full=    # Build only iso

time (
	> test/test.log
	test/test1-basic-sync-test-and-save-load-test.sh && \
	test/test2-airgapped-existing-reg.sh && \
	test/test5-airgapped-install-local-reg.sh && \
) && ( echo SUCCESS  || echo FAILED ) | tee test/test.log
date 

