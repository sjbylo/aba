#!/bin/bash -ex

cd 
rm -rf testing
mkdir -p testing
cd testing
git clone https://github.com/sjbylo/aba.git 
cd aba
git checkout dev
cd ~/aba

#export target_full=1   # Build vm
export target_full=    # Build only iso

rm -f test/[0-9]-stage

time (
	> test/test.log
	touch test/0-stage
	test/test1-basic-sync-test-and-save-load-test.sh && \
	touch test/1-stage && \
	test/test2-airgapped-existing-reg.sh && \
	touch test/2-stage && \
	test/test5-airgapped-install-local-reg.sh && \
	touch test/3-stage
) && echo SUCCESS | tee test/test.log || echo FAILED | tee test/test.log
date 

