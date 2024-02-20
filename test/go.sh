set -ex
cd 
rm -rf aba-testing
git clone https://github.com/sjbylo/aba.git aba-testing
cd aba-testing
git checkout dev
#cd ~/aba
#export target_full=1   # Build vm
export target_full=    # Build only iso
rm -f [0-5]
(
	> test/test.log
	touch 0
	test/test1-basic-sync-test-and-save-load-test.sh && \
	touch 1 && \
	test/test2-airgapped-existing-reg.sh && \
	touch 2 && \
	test/test5-airgapped-install-local-reg.sh && \
	touch 3
) && echo SUCCESS | tee test/test.log || echo FAILED | tee test/test.log
