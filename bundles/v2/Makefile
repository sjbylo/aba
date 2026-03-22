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

all: $(M)/.done-upload

$(M)/.done-setup: bundle.conf common.sh | $(M)
	bash -e phases/00-setup.sh
	@touch $@

$(M)/.done-install-aba: $(M)/.done-setup
	bash -e phases/01-install-aba.sh
	@touch $@

$(M)/.done-configure: $(M)/.done-install-aba
	bash -e phases/02-configure.sh
	@touch $@

$(M)/.done-image-save: $(M)/.done-configure
	bash -e phases/03-image-save.sh
	@touch $@

$(M)/.done-bundle-tar: $(M)/.done-image-save
	bash -e phases/04-bundle-tar.sh
	@touch $@

$(M)/.done-offline: $(M)/.done-bundle-tar
	bash -e phases/05-go-offline.sh
	@touch $@

$(M)/.done-unpacked: $(M)/.done-offline
	bash -e phases/06a-unpack-bundle.sh
	@touch $@

$(M)/.done-registry-installed: $(M)/.done-unpacked
	bash -e phases/06b-install-registry.sh
	@touch $@

$(M)/.done-registry-loaded: $(M)/.done-registry-installed
	bash -e phases/06c-load-registry.sh
	@touch $@

$(M)/.done-tests-passed: $(M)/.done-registry-loaded
	bash -e phases/06d-test-cluster.sh
	@touch $@

$(M)/.done-upload: $(M)/.done-tests-passed
	bash -e phases/07-upload.sh
	@touch $@

# Cleanup is a separate target: run after 'make all' succeeds
cleanup:
	bash -e phases/08-cleanup.sh

# Create marker directory
$(M):
	@mkdir -p $@

clean:
	rm -f $(M)/.done-*
