# bundles/v2/Makefile - Idempotent bundle creation pipeline
#
# Usage:
#   make VER=4.18.0 NAME=release
#   make VER=4.18.0 NAME=virt OP_SETS="ocp odf virt" TESTS="odf virt mtv"
#   make clean VER=4.18.0 NAME=release   # clean one bundle's markers
#   make clean                            # clean all markers (re-run from top)
#   make reset                            # full reset: uninstall registry, remove all state
#   make cleanwork                        # remove large tarballs + test-install dirs

VER      ?=
NAME     ?=
OP_SETS  ?=
TESTS    ?=

WORK_DIR    := $(shell bash -c 'source bundle.conf 2>/dev/null && echo $$WORK_DIR')

# Validate required variables only for targets that need them (not clean-all)
ifeq ($(filter clean cleanwork reset,$(MAKECMDGOALS)),)
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

export VER NAME OP_SETS TESTS BUNDLE_VENDOR

.PHONY: all clean cleanwork reset

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

$(M)/.done-06e-cluster-deleted: $(M)/.done-06d-tests-passed
	bash -e scripts/06e-delete-test-cluster.sh
	@touch $@

$(M)/.done-07-upload: $(M)/.done-06e-cluster-deleted
	bash -e scripts/07-upload-bundle-to-cloud.sh
	@touch $@

$(M)/.done-08-cleanup: $(M)/.done-07-upload
	bash -e scripts/08-cleanup-and-go-online.sh
#	@touch $@  # No need for this marker since the bundle is already deployed

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

# Full reset: uninstall registry via aba, remove all state, work dirs, tools — true fresh start.
reset:
	@echo ""
	@echo "WARNING: This will uninstall any mirror registry, remove ~/.aba, ~/bin tools,"
	@echo "         work dirs, and registry data. Everything will be rebuilt from scratch."
	@echo ""
	@read -p "Continue? (Y/n): " ans; \
	case "$$ans" in [nN]*) echo "Aborted."; exit 1;; esac
	@echo "Uninstalling mirror registry via aba ..."
	@aba_dir=$$(ls -d $(WORK_DIR)/test-install-*/aba 2>/dev/null | head -1); \
	if [ -n "$$aba_dir" ] && [ -d "$$aba_dir/mirror" ]; then \
		echo "  Using: $$aba_dir"; \
		(cd "$$aba_dir" && ./install 2>/dev/null; aba -d mirror uninstall -y) || \
			echo "  WARNING: aba uninstall failed — continuing with cleanup"; \
	elif command -v aba >/dev/null 2>&1; then \
		aba -d mirror uninstall -y 2>/dev/null || \
			echo "  WARNING: aba uninstall failed — continuing with cleanup"; \
	else \
		echo "  No aba installation found — skipping registry uninstall"; \
	fi
	@echo "Cleaning up residual registry state ..."
	@rm -f $(HOME)/.config/containers/systemd/quay.* 2>/dev/null || true
	@for svc in $$(systemctl --user list-unit-files --no-legend 'quay-*' 2>/dev/null | awk '{print $$1}'); do \
		echo "  Removing orphaned service: $$svc"; \
		systemctl --user stop "$$svc" 2>/dev/null || true; \
		systemctl --user disable "$$svc" 2>/dev/null || true; \
		rm -f "$(HOME)/.config/systemd/user/$$svc"; \
	done
	@systemctl --user daemon-reload 2>/dev/null || true
	@echo "Removing registry data dirs ..."
	rm -rf $(HOME)/quay-install $(HOME)/docker-reg $(HOME)/quay-mirror $(HOME)/omr
	@echo "Removing ABA state and CLI tools ..."
	rm -rf $(HOME)/.aba
	rm -vf $(HOME)/bin/{aba,butane,govc,kubectl,oc,oc-mirror,openshift-install}
	@echo "Cleaning build markers ..."
	find $(WORK_DIR)/ -name '.done-*' -delete 2>/dev/null || true
	@echo "Removing work dirs ..."
	rm -rf $(WORK_DIR)/test-install-* $(WORK_DIR)/aba
	@echo "Reset complete. Run 'make VER=... NAME=...' to start fresh."

# Emergency cleanup: remove large tarballs and test-install dirs to reclaim disk space
# Deletes test cluster VMs on vSphere before removing local dirs.
cleanwork:
	@echo ""
	@echo "WARNING: This will remove test-install dirs from $(WORK_DIR)/"
	@echo "         If test cluster VMs are still running on vSphere, they will be deleted first."
	@echo ""
	@read -p "Continue? (Y/n): " ans; \
	case "$$ans" in [nN]*) echo "Aborted."; exit 1;; esac
	@cluster_name=$$(bash -c 'source bundle.conf 2>/dev/null && echo $$CLUSTER_NAME'); \
	if [ -n "$$cluster_name" ]; then \
		for d in $(WORK_DIR)/test-install-*/aba; do \
			if [ -d "$$d/$$cluster_name" ]; then \
				echo "Deleting test cluster VMs: $$d/$$cluster_name"; \
				(cd "$$d" && aba --dir "$$cluster_name" delete) || true; \
			fi; \
		done; \
	fi
	@echo "Removing ocp_* tarballs and test-install-* dirs from $(WORK_DIR)/ ..."
	find $(WORK_DIR)/ -maxdepth 2 -name 'ocp_*' -type f -delete 2>/dev/null || true
	find $(WORK_DIR)/ -maxdepth 1 -name 'test-install-*' -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "Done. Re-run 'make clean' then 'make' to rebuild."
