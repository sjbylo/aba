cd ~/aba
#export target_full=1   # Build vm
export target_full=    # Build only iso
rm -f [0-9]-stage
(
	> test/test.log
	make distclean
	touch test/0-stage
	test/test1-basic-sync-test-and-save-load-test.sh && \
	touch test/1-stage && \
	test/test2-airgapped-existing-reg.sh && \
	touch test/2-stage && \
	test/test5-airgapped-install-local-reg.sh && \
	touch test/3-stage
) && echo SUCCESS | tee test/test.log || echo FAILED | tee test/test.log
