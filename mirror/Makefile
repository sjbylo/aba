ifndef DEBUG_ABA
.SILENT:
MAKEFLAGS += --no-print-directory
endif

TEMPLATES := ../templates
SCRIPTS   := ../scripts
##debug   ?=
force     ?= no
bg        ?=
##catalog-name   ?=

# Detect host architecture for mirror-registry download.
# Maps uname -m to the naming used by mirror.openshift.com:
#   x86_64 -> amd64, aarch64 -> arm64, s390x/ppc64le stay as-is.
# Note: arm64 build may not exist yet. The download rule handles that
# gracefully with a clear error and workaround suggestion.
arch   := $(strip $(shell uname -m))
ifeq ($(arch),x86_64)
  MR_ARCH := amd64
else ifeq ($(arch),aarch64)
  MR_ARCH := arm64
else
  MR_ARCH := $(arch)
endif
MR_TARBALL := mirror-registry-$(MR_ARCH).tar.gz

##########################
# Allow env variable to force plain output (e.g., PLAIN_OUTPUT=1)
# Otherwise auto-detect from TTY
ifeq ($(PLAIN_OUTPUT),1)
  IS_TTY := no
  HAS_COLORS := 0
else
  IS_TTY := yes
endif

# Pick curl option depending on plain/tty
ifeq ($(IS_TTY),yes)
  CURL_PROGRESS := "--progress-bar"
else
  CURL_PROGRESS := "-s"
endif
##########################

all: install

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  aba \033[36mcommand\033[0m\n"} /^(\s|[a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

init: .init 
.init: ../aba.conf
	ln -fs $(TEMPLATES) 
	ln -fs $(SCRIPTS) 
	ln -fs ../cli
	ln -fs ../aba.conf 
	mkdir -p regcreds
	touch regcreds/.dummy  # Needed only so tar includes the *empty* regcreds dir
	touch .init

# If aba.conf does not exist, must abort!
../aba.conf:
	echo [ABA] "aba/aba.conf file missing! Please read the README.md on how to get started!"
	@exit 1

#.PHONY: cli-download
#cli-download:
#	@make -sC ../cli download 

## Only needed for 'make load'. 
#.PHONY: cli-oc-mirror
#cli-oc-mirror:
#	@make -sC ../cli ~/bin/oc-mirror

imagesetconf: sync/imageset-config-sync.yaml save/imageset-config-save.yaml ## Create the initial image set config file with all provided values and operators
isconf: imagesetconf ## Same as imagesetconf

sync/imageset-config-sync.yaml: ../aba.conf catalogs-download catalogs-wait
	$(SCRIPTS)/reg-create-imageset-config-sync.sh

save/imageset-config-save.yaml: ../aba.conf catalogs-download catalogs-wait
	$(SCRIPTS)/reg-create-imageset-config-save.sh


# FIXME: is vmware.conf needed for 'load' and 'sync' or only needed during 'make cluster'?
.PHONY: sync
sync: .init .rpmsint ~/.pull-secret.json                     install verify sync/imageset-config-sync.yaml ## Sync images from the Internet directly to an internal registry (as defined in 'aba/mirror/mirror.conf') Use --retry [count] to retry after failure.
	$(SCRIPTS)/reg-sync.sh          $(retry)

~/.pull-secret.json:
	$(SCRIPTS)/install-pull-secret.sh

.PHONY: save
# Note that for a connected workstation or bastion there is no need to install all the required packages, only 'rpmsext' is needed.
# For 'save' (mirrorToDisk) we need to download ALL CLI binaries because we don't know which OS will be used (RHEL8 or 9) internally. 
# Note: catalogs-download dependency ensures catalogs start downloading; imageset config will wait for completion
# Registry binaries are downloaded best-effort (non-fatal) so the bundle includes them if possible.
save: .init .rpmsext ~/.pull-secret.json                                                     save/imageset-config-save.yaml  ## Save images from the Internet to aba/mirror/save/mirror_000001.tar. Use --retry [count] to retry after failure.
	@$(MAKE) download-registries 2>&1 || echo "[ABA] Warning: Registry binary download failed (non-fatal). You can download it later or use a Docker registry."
	$(SCRIPTS)/reg-save.sh          $(retry)

# oc-mirror is idempotent so no need for 'dot' flag files
.PHONY: load
load: .init               .rpmsint install verify  ## Load the saved images into a registry on the internal bastion (as defined in 'aba/mirror/mirror.conf')  Use --retry [count] to retry after failure.
	$(SCRIPTS)/reg-load.sh          $(retry)

.PHONY: testload
testload: save install load     # Test the save, install, load process on a connected host

.rpmsext: .init
	$(SCRIPTS)/install-rpms.sh external
	@touch .rpmsext

.rpmsint: .init
	$(SCRIPTS)/install-rpms.sh internal
	@touch .rpmsint

rpmsclean:
	@rm -f .rpms*

mirror-registry: $(MR_TARBALL) ## Extract the mirror-registry binary 
	@echo [ABA] Extracting $(MR_TARBALL) into $$PWD
	tar xmvzf $(MR_TARBALL)

.PHONY: download-registries
download-registries: $(MR_TARBALL) docker-reg-image.tgz

mirror_registry_url = https://mirror.openshift.com/pub/cgw/mirror-registry/latest

$(MR_TARBALL): ## Download the mirror-registry tarball for $(MR_ARCH)
	echo [ABA] "Downloading $(mirror_registry_url)/$(MR_TARBALL) ..."
ifeq ($(arch),aarch64)
	curl -f $(CURL_PROGRESS) -OL $(mirror_registry_url)/$(MR_TARBALL) || { \
		echo "[ABA] ERROR: Failed to download $(MR_TARBALL)" ; \
		echo "[ABA] The mirror-registry binary for arm64 may not be available yet." ; \
		echo "[ABA] Check $(mirror_registry_url) for available builds." ; \
		echo "[ABA] Workaround: use a Docker registry instead -- run 'aba -d mirror install-docker-registry'" ; \
		exit 1 ; \
	}
else
	curl -f $(CURL_PROGRESS) -OL $(mirror_registry_url)/$(MR_TARBALL)
endif
	file $(MR_TARBALL) | grep -q "gzip compressed data"
	@echo -n "[ABA] Verifying checksum for $(@): "
	curl -f --retry 8 -sL $(CURL_PROGRESS) -o mirror-registry-sha256sum.txt $(mirror_registry_url)/sha256sum.txt && cs=`sha256sum $@` && grep -q "$$cs" mirror-registry-sha256sum.txt || { echo [ABA] "invalid!!"; exit 1; }
	echo "valid!"

# Store the docker registry image so it can be used in air-gapped env. (if docker.io reachable) Note: Docker available as arm64 image!
# Ignore any errors, since docker.io may not be whitelisted
DOCKER_REG_IMAGE := docker.io/library/registry:latest
DOCKER_REG_FILE  := docker-reg-image.tgz
$(DOCKER_REG_FILE):
	@echo [ABA] "Checking availability of $(DOCKER_REG_IMAGE)..."
	@if podman pull $(DOCKER_REG_IMAGE); then \
		echo [ABA] "Pull successful. Saving to $(DOCKER_REG_FILE)..."; \
		podman save $(DOCKER_REG_IMAGE) | gzip > $(DOCKER_REG_FILE); \
	else \
		echo [ABA] "Could not reach $(DOCKER_REG_IMAGE). Skipping fallback creation."; \
		rm -f $(DOCKER_REG_FILE); \
	fi

.PHONY: install-docker-registry
install-docker-registry:
	@$(SCRIPTS)/run-once.sh -w -m "Waiting for Docker registry image download" -i mirror:download:docker-reg-image.tgz -- make -sC . docker-reg-image.tgz
	@podman load -i $(DOCKER_REG_FILE)
	@$(SCRIPTS)/reg-docker-install.sh
	@rm -f .uninstalled 
	@touch .installed

uninstall-docker-registry: 
	@$(SCRIPTS)/reg-docker-uninstall.sh
	@touch .uninstalled
	@rm -f .installed 

# mirror.conf depends on aba.conf for the 'domain' value
mirror.conf: ../aba.conf .init                        ## Create the mirror.conf file.
	$(SCRIPTS)/create-mirror-conf.sh -f $(force)

install: .installed
.installed: .init .rpmsext mirror.conf  ## Set up the registry as per the settings in mirror.conf. Place credential file(s) into regcreds/ for existing registry.  See README.md.
	@$(SCRIPTS)/ensure-cli.sh quay-registry
	$(SCRIPTS)/reg-install.sh
	$(SCRIPTS)/reg-verify.sh
	@rm -f .uninstalled 
	@touch .installed

.PHONY: installclean
installclean:
	@rm -f .installed

.PHONY: password pw
password: pw
pw: 
	$(SCRIPTS)/reg-existing-create-pull-secret.sh

.PHONY: verify
verify: .init ## Using the credential files in 'aba/mirror/regcreds' dir and the values in 'aba/mirror/mirror.conf', verify access to the registry. 
	@$(SCRIPTS)/reg-verify.sh
	@rm -f .uninstalled 
	@touch .installed

#.PHONY: uninstallclean
#uninstallclean:
#	@rm -f .uninstalled

.PHONY: tar
tar:   ## Create a full tar backup of ~/aba & ~/bin, ready to be transported to your private network.
	@make -sC .. tar $(out)

.PHONY: tarrepo
tarrepo:   ## Same as 'make tar' but excludes all 'mirror_000*.tar' files under aba/mirror/save/.
	@make -sC .. tarrepo $(out)

# This will be deprecated!
.PHONY: inc
inc:   ## Same as 'make tar' except a timestamp file is used to only backup files that have changed since the last 'make inc' was run.
	@make -sC .. inc $(out)

# Catalog download targets (new run_once-based mechanism)
.PHONY: catalogs-download
catalogs-download: init     ## Start operator catalog downloads in background (non-blocking)
	$(SCRIPTS)/download-catalogs-start.sh

.PHONY: catalogs-wait
catalogs-wait:              ## Wait for operator catalog downloads to complete (blocking)
	$(SCRIPTS)/download-catalogs-wait.sh

# Legacy index target for backward compatibility (downloads and waits)
.PHONY: index
index: init catalogs-download catalogs-wait

# Deprecated: Use catalogs-download instead
.PHONY: catalog
catalog: catalogs-download
	@echo "[ABA] Warning: 'make catalog' is deprecated, use 'make catalogs-download' instead" >&2

uninstall: .init mirror-registry .uninstalled     ## Uninstall any previously installed registry  
.uninstalled: 
	$(SCRIPTS)/reg-uninstall.sh
	@rm -f .installed
	@touch .uninstalled

.PHONY: checkversion
checkversion: init
	$(SCRIPTS)/check-version-mismatch.sh

.PHONY: cluster
cluster:
	@echo [ABA] "Run: 'aba cluster ...' from Aba's top-level directory" >&2

.PHONY: tidy
tidy:    # Tidy up so that this repo can be (re-)used to install/configure a registry again (assuming aba bundle repo on USB stick).
	rm -f  .installed
	rm -f  mirror.conf
	rm -rf regcreds
	rm -f  reg-uninstall.sh 
	rm -f  .rpms* 
	rm -f  save/oc-mirror-workspace 
	rm -f  save/publish 

# Note that the mirror-registry tarball ($(MR_TARBALL)) is needed to 'uninstall' the registry.
# Note that KEEP the imageset conf file IF user has made changes, otherwise delete it.
# Do not delete anyting that is "expensive", i.e. user edited config file, a large (or long time to) downlaod items, the installed registry.
.PHONY: clean
clean:  ## Clean up temporary files only, keeping your configuration files, e.g. mirror.conf.
	@[ -f .installed ] && echo [ABA] "Important: to uninstall the registry, run 'aba -d mirror uninstall'!" || true
	rm -rf *.tar mirror-registry
	# Reset run_once state for mirror-registry extraction (since we just deleted the binary)
	@$(SCRIPTS)/run-once.sh -r -i "mirror:reg:install" 2>/dev/null || true
	rm -f templates scripts
	rm -f aba.conf  # remove link only
	rm -f .init 
	rm -rf .index
	rm -f imageset-config-*.yaml
	rm -f ~/.aba.previous.backup  # This is the 'timestamp' file used for incremental backups
	rm -f save-mirror.sh sync-mirror.sh load-mirror.sh # Only clean up the created scripts, not the script needed to uninstall the reg.
	@#rm -f *.sh  # Don't clean up the scripts, esp. the reg. "uninstall" script since the registry is still installed 
	@[ -d save ] && [ save/.created -nt "save/imageset-config-save.yaml" ] && rm -rf save || true  # Delete only if not edited
	@[ -d sync ] && [ sync/.created -nt "sync/imageset-config-sync.yaml" ] && rm -rf sync || true  # Delete only if not edited
	rm -f .cmd.out
	rm -f *sha256sum.txt


# Note that reg-uninstall.sh script will delete registry and regcreds/ dir.
# Backup regcreds/ and anything that should not be lost
.PHONY: reset
reset:                # Clean up all files. Only use if you know what you're doing! Only used to re-distribute the repository.
	@[ -f .installed ] && echo [ABA] "Important: to uninstall the registry, you must run 'aba -d mirror uninstall' first!" || true
	make clean
	@[ -d regcreds ] && rm -rf regcreds.bk && mv regcreds regcreds.bk && echo [ABA] aba/mirror/regcreds backed up to regcreds.bk || true
	@[ -f mirror.conf ] && mv mirror.conf mirror.conf.bk && echo [ABA] aba/mirror/mirror.conf backed up to mirror.conf.bk || true
	@#rm -rf *.tar.gz oc-mirror-workspace   # Leave this so the mirror can be uninstalled with reg-uninstall.sh 
	rm -rf          oc-mirror-workspace 
	rm -f $(DOCKER_REG_FILE)
	rm -rf mirror-registry-*.tar.gz
	# Reset run_once state for mirror-registry and docker-reg downloads (since we just deleted the tarballs)
	@$(SCRIPTS)/run-once.sh -r -i "mirror:reg:download" 2>/dev/null || true
	@$(SCRIPTS)/run-once.sh -r -i "mirror:download:docker-reg-image.tgz" 2>/dev/null || true
	rm -f *.conf *.yaml 
	rm -rf save sync 
	rm -f save-mirror.sh sync-mirror.sh load-mirror.sh
	rm -f *.log .*.log
	rm -f .ssh.conf
	rm -f .rpmsext .rpmsint
	rm -f .redhat-operator-index* 
	rm -f .init 

