# bundles/v2/Makefile - Idempotent bundle creation pipeline
#
# Usage:
#   make VER=4.18.0 NAME=release
#   make VER=4.18.0 NAME=ocpv OP_SETS="ocp odf ocpv"
#   make clean VER=4.18.0 NAME=release   # clean one bundle
#   make clean                            # clean all bundles
#   make cleanwork                        # remove large tarballs + test-install dirs

VER      ?=
NAME     ?=
OP_SETS  ?=

WORK_DIR    := $(shell bash -c 'source bundle.conf 2>/dev/null && echo $$WORK_DIR')

# Validate required variables only for targets that need them (not clean-all)
ifeq ($(filter clean cleanwork,$(MAKECMDGOALS)),)
ifeq ($(VER),)
$(error VER is required. Example: make VER=4.18.0 NAME=release)
endif
ifeq ($(NAME),)
$(error NAME is required. Example: make VER=4.18.0 NAME=release)
endif
ifneq ($(NAME),release)
ifeq ($(strip $(OP_SETS)),)
$(error OP_SETS is required for non-release bundles. Example: make VER=4.18.0 NAME=opp OP_SETS="ocp odf sec acm")
endif
endif
endif

BUNDLE_NAME = $(VER)-$(NAME)
M            = $(WORK_DIR)/$(BUNDLE_NAME)/build

export VER NAME OP_SETS

.PHONY: all clean cleanwork

all: $(M)/.done-08-cleanup

$(M)/.done-00-setup: bundle.conf common.sh | $(M)
	bash -e scripts/00-setup-connectivity.sh
	@touch $@

$(M)/.done-01-install-aba: $(M)/.done-00-setup
	bash -e scripts/01-install-aba-from-git.sh
	@touch $@

$(M)/.done-02-configure: $(M)/.done-01-install-aba
	bash -e scripts/02-configure-aba-and-imageset.sh
	@touch $@

$(M)/.done-03-image-save: $(M)/.done-02-configure
	bash -e scripts/03-save-images-to-disk.sh
	@touch $@

$(M)/.done-04-bundle-tar: $(M)/.done-03-image-save
	bash -e scripts/04-create-bundle-tar.sh
	@touch $@

$(M)/.done-05-offline: $(M)/.done-04-bundle-tar
	bash -e scripts/05-go-offline-for-testing.sh
	@touch $@

$(M)/.done-06a-unpacked: $(M)/.done-05-offline
	bash -e scripts/06a-unpack-bundle-tar.sh
	@touch $@

$(M)/.done-06b-registry-installed: $(M)/.done-06a-unpacked
	bash -e scripts/06b-install-mirror-registry.sh
	@touch $@

$(M)/.done-06c-registry-loaded: $(M)/.done-06b-registry-installed
	bash -e scripts/06c-load-images-to-registry.sh
	@touch $@

$(M)/.done-06d-tests-passed: $(M)/.done-06c-registry-loaded
	bash -e scripts/06d-test-cluster-and-operators.sh
	@touch $@

$(M)/.done-07-upload: $(M)/.done-06d-tests-passed
	bash -e scripts/07-upload-bundle-to-cloud.sh
	@touch $@

$(M)/.done-08-cleanup: $(M)/.done-07-upload
	bash -e scripts/08-cleanup-and-go-online.sh
	@touch $@

# Create marker directory
$(M):
	@mkdir -p $@

clean:
ifeq ($(VER),)
	@echo "Cleaning all bundle build markers in $(WORK_DIR)/ ..."
	find $(WORK_DIR)/ -name '.done-*' -delete 2>/dev/null || true
else
	rm -f $(M)/.done-*
endif

# Emergency cleanup: remove large tarballs and test-install dirs to reclaim disk space
cleanwork:
	@echo "Removing ocp_* tarballs and test-install-* dirs from $(WORK_DIR)/ ..."
	find $(WORK_DIR)/ -maxdepth 2 -name 'ocp_*' -type f -delete 2>/dev/null || true
	find $(WORK_DIR)/ -maxdepth 1 -name 'test-install-*' -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "Done. Re-run 'make clean' then 'make' to rebuild."
