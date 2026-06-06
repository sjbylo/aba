# Makefile to download and install oc, openshift-install, oc-mirror, govc and butane
#
# This is PURE MAKE -- no run_once inside recipes. run_once wraps Make from
# OUTSIDE (cli-download-all.sh, ensure_*() functions). A user running
# 'make oc' directly gets standard serial Make behavior -- no background
# processes, no races. See ADR-002 and devel/01-SPEC.md for the pattern.

# Delete target files when a recipe fails (prevents partial/corrupt downloads
# from being considered "up to date" on the next run)
.DELETE_ON_ERROR:

ifndef DEBUG_ABA
.SILENT:
MAKEFLAGS += --no-print-directory
endif

TEMPLATES = ../templates
SCRIPTS   = ../scripts

os     := $(strip $(shell uname -o))
arch   := $(strip $(shell uname -m))
os_ver := $(strip $(shell grep '^VERSION_ID=' /etc/os-release | cut -d '=' -f2 | tr -d '"' | grep -o -E "[0-9]+\.[0-9]+"))

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

# Check and set default version 'os_ver' variable, e.g. if Fedora version 40, then we want to convert "40" to 9.x
# If os_ver empty
ifeq ($(os_ver),)
	os_ver := 9.5
endif

# Map OS major version to the RHEL binary flavour available on the OCP mirror.
# RHEL 10+/Fedora: use rhel9 binaries (no rhel10-specific tarballs published yet).
os_major := $(firstword $(subst ., ,$(os_ver)))
ifeq ($(os_major),8)
	rhel_ver := rhel8
else
	rhel_ver := rhel9
endif

# Normalize 'os' variable
ifeq ($(os),GNU/Linux)
	os := linux
else ifeq ($(os),Darwin)
	os := mac
endif

# Normalize 'arch' variable for macOS
ifeq ($(os),mac)
	ifeq ($(arch),arm64)
		arch := aarch64
	endif
endif

# Map uname -m to OpenShift download architecture names used in tarball filenames.
# x86_64 -> amd64, aarch64 -> arm64, s390x/ppc64le stay as-is (OpenShift uses raw names).
# Note: $(arch) is used in the URL *path* (e.g. .../s390x/clients/ocp/...),
#       $(ARCH) is used in the tarball *filename* (e.g. openshift-client-linux-s390x-...).
ifeq ($(arch),x86_64)
	ARCH := amd64
else ifeq ($(arch),aarch64)
	ARCH := arm64
else
	ARCH := $(arch)
endif

butane_arch := $(arch)
ifeq ($(arch),x86_64)
	butane_arch := amd64
endif

butane_binary_file = butane-$(butane_arch)

govc_arch := $(arch)
ifeq ($(arch),aarch64)
	govc_arch := arm64
endif

govc_tar_file := govc_Linux_$(govc_arch).tar.gz

# Include aba.conf if it exists
-include ../aba.conf
ocp_version := $(strip $(shell echo $(ocp_version)))
platform := $(strip $(shell echo $(platform)))

# OCP major version (e.g. "4" from "4.21.10") for CDN paths (openshift-v4/, openshift-v5/, etc.)
ocp_major := $(firstword $(subst ., ,$(ocp_version)))

# Verify SHA256 checksum of a downloaded file.
# Usage: $(call verify-sha256,FILE,SHA256SUM_URL)
# On failure: removes the file so Make retries from scratch next time.
define verify-sha256
	@echo -n "[ABA] Verifying checksum for $(1): "
	@curl -f --retry 8 -sL -o $(1).sha256 $(2) && \
		grep "  $(notdir $(1))$$" $(1).sha256 | sha256sum --check --status && \
		echo "valid!" || \
		{ echo "INVALID or checksum unavailable! Removing $(1)."; rm -f $(1) $(1).sha256; exit 1; }
endef


########################################################################
##@ Help & Initialization
########################################################################

.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  aba \033[36mcommand\033[0m\n"} /^(\s|[\$\.\(\)\~\/a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

# Keep this like it is, otherwise the deps don't work!
# ~/bin may be removed externally (e.g. E2E cleanup) while .init sentinel persists,
# so every ~/bin/* target also depends on the ~/bin directory via order-only prerequisite.
.init:
	mkdir -p ~/bin
	ln -fs ../scripts
	touch .init

~/bin:
	mkdir -p ~/bin

# aba.conf should never be missing!
../aba.conf:
	@echo "[ABA] aba/aba.conf missing! Run 'aba' for interactive mode or read the README.md file on how to get started!"
	@exit 1

# Only oc and openshift-install need ocp_version (their URLs contain it).
# govc, oc-mirror, butane do NOT — they come from version-independent URLs.
# Instead of a global gate with a fragile exemption list, check per-target.
.PHONY: .check-ocp-version
.check-ocp-version:
	@if [ -z "$(ocp_version)" ]; then \
		echo "[ABA] Error: ocp_version not set in aba.conf!"; \
		echo "[ABA] Run 'aba --version <x.y.z>' or edit aba.conf to set ocp_version."; \
		echo "[ABA] See README.md for getting started."; \
		exit 1; \
	fi


########################################################################
##@ Tarball Filenames & URLs (must precede rules that reference them)
########################################################################

# The preference to download the oc CLI tar files is: rhel9, then rhel8

# See: https://mirror.openshift.com/pub/openshift-v$(ocp_major)/$(arch)/clients/ocp/4.18.9/
# Example x86:    openshift-client-linux-amd64-rhel9-4.18.9.tar.gz
# Example ARM:    openshift-client-linux-arm64-rhel9-4.18.9.tar.gz
# Example s390x:  openshift-client-linux-s390x-rhel9-4.18.9.tar.gz
# Example ppc64le: openshift-client-linux-ppc64le-rhel9-4.18.9.tar.gz

local_oc_tar_file	:= openshift-client-$(os)-$(ARCH)-$(rhel_ver)-$(ocp_version).tar.gz
local_oc_mirror_tar	:= $(if $(filter rhel9,$(rhel_ver)),oc-mirror.rhel9.tar.gz,oc-mirror.tar.gz)

rhel9_oc_tar_file	:= openshift-client-$(os)-$(ARCH)-rhel9-$(ocp_version).tar.gz
rhel9_oc_url      	:= https://mirror.openshift.com/pub/openshift-v$(ocp_major)/$(arch)/clients/ocp/$(ocp_version)/$(rhel9_oc_tar_file)

rhel8_oc_tar_file	:= openshift-client-$(os)-$(ARCH)-rhel8-$(ocp_version).tar.gz
rhel8_oc_url		:= https://mirror.openshift.com/pub/openshift-v$(ocp_major)/$(arch)/clients/ocp/$(ocp_version)/$(rhel8_oc_tar_file)

openshift_install_file	:= openshift-install-$(os)-$(ocp_version).tar.gz
openshift_install_url	:= https://mirror.openshift.com/pub/openshift-v$(ocp_major)/$(arch)/clients/ocp/$(ocp_version)


########################################################################
##@ Download Targets
########################################################################

# Logical download targets — group tarballs by tool.
# Callers use these names: download-oc, download-govc, etc.

.PHONY: download-oc
download-oc: $(rhel9_oc_tar_file) $(rhel8_oc_tar_file)  ## Download oc tarballs (rhel9 + rhel8)

.PHONY: download-oc-mirror
download-oc-mirror: oc-mirror.tar.gz oc-mirror.rhel9.tar.gz  ## Download oc-mirror tarballs

.PHONY: download-openshift-install
download-openshift-install: $(openshift_install_file)  ## Download openshift-install tarball

.PHONY: download-butane
download-butane: $(butane_binary_file)  ## Download butane binary

.PHONY: download-govc
download-govc: $(govc_tar_file)  ## Download govc tarball

# Download all CLI tarballs.
# Always TRY govc (error handling for non-vmw platforms is done in the caller).
.PHONY: download
download: .check-ocp-version download-oc download-oc-mirror download-openshift-install download-butane download-govc  ## Download all CLI tarballs

.PHONY: download-all
download-all: .check-ocp-version download-oc download-oc-mirror download-openshift-install download-butane download-govc  ## Download all CLI tarballs (same as download)

# Output logical tool names for cli-download-all.sh.
# Version suffix appended for tools that need ocp_version, so callers
# can construct version-dependent run_once task IDs.
.PHONY: out-download-all
out-download-all:
	@echo oc:$(ocp_version) oc-mirror openshift-install:$(ocp_version) butane govc

# Version-independent tools only (usable without ocp_version being set)
.PHONY: out-download-no-version
out-download-no-version:
	@echo oc-mirror butane govc


########################################################################
##@ Tarball Recipes — bare curl + verify, no run_once
########################################################################

# oc tarballs: download both rhel9 and rhel8 variants.
# On download failure (e.g. 404 for an older rhel variant), create an empty
# placeholder so Make doesn't retry. Bundles need both variants.
$(rhel9_oc_tar_file):
	@curl -sfkLI $(rhel9_oc_url) >/dev/null
	@echo [ABA] Downloading $(rhel9_oc_url)
	curl -f $(CURL_PROGRESS) -OL $(rhel9_oc_url) || { echo [ABA] $(rhel9_oc_tar_file) failed download; > $(rhel9_oc_tar_file); }
	$(call verify-sha256,$(rhel9_oc_tar_file),$(openshift_install_url)/sha256sum.txt)

$(rhel8_oc_tar_file):
	@curl -sfkLI $(rhel8_oc_url) >/dev/null
	@echo [ABA] Downloading $(rhel8_oc_url)
	curl -f $(CURL_PROGRESS) -OL $(rhel8_oc_url) || { echo [ABA] $(rhel8_oc_tar_file) failed download; > $(rhel8_oc_tar_file); }
	$(call verify-sha256,$(rhel8_oc_tar_file),$(openshift_install_url)/sha256sum.txt)

# openshift-install tarball
$(openshift_install_file):
	@echo [ABA] Downloading $(openshift_install_url)/$(openshift_install_file)
	curl -f --retry 8 $(CURL_PROGRESS) -OL $(openshift_install_url)/$(openshift_install_file)
	$(call verify-sha256,$(openshift_install_file),$(openshift_install_url)/sha256sum.txt)

# oc-mirror pin: stable-4.21 is intentional -- new oc-mirror versions must be tested before adoption.
# Hardcoded to openshift-v4 (NOT parameterized) because oc-mirror is version-independent
# and must be well-tested before any upgrade. The --no-version download path also requires
# this URL to work without ocp_version being set.
oc_mirror_base_url = https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/stable-4.21
oc_mirror_sha256sum = $(oc_mirror_base_url)/sha256sum.txt

oc-mirror.tar.gz:
	@echo [ABA] Downloading $(oc_mirror_base_url)/oc-mirror.tar.gz
	curl -f --retry 8 $(CURL_PROGRESS) -OL $(oc_mirror_base_url)/oc-mirror.tar.gz
	$(call verify-sha256,oc-mirror.tar.gz,$(oc_mirror_sha256sum))

oc-mirror.rhel9.tar.gz:
	@echo [ABA] Downloading $(oc_mirror_base_url)/oc-mirror.rhel9.tar.gz
	curl -f --retry 8 $(CURL_PROGRESS) -OL $(oc_mirror_base_url)/oc-mirror.rhel9.tar.gz
	$(call verify-sha256,oc-mirror.rhel9.tar.gz,$(oc_mirror_sha256sum))

# govc tarball (from GitHub, not mirror.openshift.com)
govc_url = https://github.com/vmware/govmomi/releases/latest/download

$(govc_tar_file):
	@echo [ABA] Downloading $(govc_url)/$(govc_tar_file)
	curl -f --retry 8 -sL $(CURL_PROGRESS) -O "$(govc_url)/$(govc_tar_file)"
	$(call verify-sha256,$(govc_tar_file),$(govc_url)/checksums.txt)

# Butane binary is a shared client tool, hosted under openshift-v4/clients/ regardless of OCP major version
butane_binary_url = https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest
butane_binary_file_url = $(butane_binary_url)/$(butane_binary_file)
butane_binary_url_sha256sum = $(butane_binary_url)/sha256sum.txt

$(butane_binary_file):
	@echo [ABA] Downloading $(butane_binary_file_url)
	curl -f --retry 8 $(CURL_PROGRESS) -sL -o $(butane_binary_file) --connect-timeout 30 $(butane_binary_file_url)
	chmod +x $(butane_binary_file)
	$(call verify-sha256,$(butane_binary_file),$(butane_binary_url_sha256sum))


########################################################################
##@ Install Targets (Extract) — tarball as prerequisite, simple extraction
########################################################################

# oc: extract from the tarball matching this host's RHEL version.
# Self-healing: if tarball is corrupt, delete it and re-download.
.PHONY: oc
oc: ~/bin/oc  ## Install oc into ~/bin

~/bin/oc: .init $(local_oc_tar_file) | ~/bin
	@echo [ABA] Extracting $(local_oc_tar_file) to ~/bin/oc
	tar -C ~/bin -xmzf $(local_oc_tar_file) oc kubectl || \
		{ echo "[ABA] Error: Corrupt tarball, re-downloading $(local_oc_tar_file)"; \
		  rm -f $(local_oc_tar_file); $(MAKE) $(local_oc_tar_file); \
		  tar -C ~/bin -xmzf $(local_oc_tar_file) oc kubectl || exit 1; }
	~/bin/oc --help >/dev/null 2>&1

# openshift-install: extract from tarball.
.PHONY: openshift-install
openshift-install: ~/bin/openshift-install  ## Install openshift-install into ~/bin

~/bin/openshift-install: .init $(openshift_install_file) | ~/bin
	@echo [ABA] Extracting $(openshift_install_file) to ~/bin/openshift-install
	tar -C ~/bin -xmzf $(openshift_install_file) openshift-install || \
		{ echo "[ABA] Error: Corrupt tarball, re-downloading $(openshift_install_file)"; \
		  rm -f $(openshift_install_file); $(MAKE) $(openshift_install_file); \
		  tar -C ~/bin -xmzf $(openshift_install_file) openshift-install || exit 1; }
	~/bin/openshift-install --help >/dev/null || { echo [ABA] "Error: file ~/bin/openshift-install invalid!"; exit 1; }

# oc-mirror: extract from the tarball matching this host's RHEL version.
.PHONY: oc-mirror
oc-mirror: ~/bin/oc-mirror  ## Install oc-mirror into ~/bin

~/bin/oc-mirror: .init $(local_oc_mirror_tar) | ~/bin
	@echo [ABA] Extracting $(local_oc_mirror_tar) to ~/bin/oc-mirror
	tar -C ~/bin -xmzf $(local_oc_mirror_tar) oc-mirror || { echo [ABA] Error: Failed to extract $(local_oc_mirror_tar); exit 1; }
	chmod +x ~/bin/oc-mirror

# govc: extract from tarball.
.PHONY: govc
govc: ~/bin/govc  ## Install govc to ~/bin/govc

~/bin/govc: .init $(govc_tar_file) | ~/bin
	@echo [ABA] Extracting $(govc_tar_file) to ~/bin/govc
	tar -C ~/bin -xmzf $(govc_tar_file) govc || { echo [ABA] Error: Failed to extract $(govc_tar_file); exit 1; }
	~/bin/govc --help >/dev/null 2>&1

# butane: copy binary to ~/bin.
.PHONY: butane
butane: ~/bin/butane  ## Install butane to ~/bin/butane

~/bin/butane: $(butane_binary_file) | ~/bin
	@echo [ABA] Copying butane binary to $@
	cp $(butane_binary_file) $@
	chmod +x $@
	$@ --help >/dev/null 2>&1 || { echo [ABA] "Error: $@ binary invalid"; exit 1; }

# install/install-all: extract all tools.
# Always includes govc (error handling for non-vmw is in the caller).
.PHONY: install
install: .check-ocp-version oc openshift-install oc-mirror butane govc  ## Install all CLI tools to ~/bin

.PHONY: install-all
install-all: .check-ocp-version oc openshift-install oc-mirror butane govc  ## Install all CLI tools (same as install)

# Output targets for scripts to query which tools exist.
.PHONY: out-install
out-install:
	@echo oc openshift-install oc-mirror butane govc

.PHONY: out-install-all
out-install-all:
	@echo oc openshift-install oc-mirror butane govc


########################################################################
##@ Cleanup
########################################################################

.PHONY: clean
clean: ## Clean up installed binaries
	@../scripts/cli-install-all.sh --reset
	@rm -f ~/bin/{oc,kubectl,oc-mirror,openshift-install,govc,butane} *sha256sum.txt *.sha256

.PHONY: reset
reset: clean  ## Clean up everything (tarballs + binaries). Only use if you know what you are doing!
	@../scripts/cli-download-all.sh --reset
	@rm -f *.tar.gz .init butane*
	@rm -f scripts
