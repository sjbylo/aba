# bundles/v2/Makefile - Idempotent bundle creation pipeline
#
# Usage:
#   make VER=4.18.0 NAME=release
#   make VER=4.18.0 NAME=ocpv OP_SETS="ocp odf ocpv"
#   make clean VER=4.18.0 NAME=release

VER      ?=
NAME     ?=
OP_SETS  ?=

ifeq ($(VER),)
$(error VER is required. Example: make VER=4.18.0 NAME=release)
endif
ifeq ($(NAME),)
$(error NAME is required. Example: make VER=4.18.0 NAME=release)
endif

BUNDLE_NAME = $(VER)-$(NAME)
WORK_DIR    := $(shell bash -c 'source bundle.conf 2>/dev/null && echo $$WORK_DIR')
M            = $(WORK_DIR)/$(BUNDLE_NAME)/build

export VER NAME OP_SETS

.PHONY: all cleanup clean

all: $(M)/.done-07-upload

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

# Cleanup is a separate target: run after 'make all' succeeds
cleanup:
	bash -e scripts/08-cleanup-and-go-online.sh

# Create marker directory
$(M):
	@mkdir -p $@

clean:
	rm -f $(M)/.done-*
