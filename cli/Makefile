# Makefile to download and install oc, openshift-install, oc-mirror, butane and govc (vmw only).
# Also provides optional "extra" CLIs (virtctl, kn, tkn, helm, opm, argocd, roxctl) for
# air-gap convenience — see download-extra-clis / install-extra-clis (NOT in download-all).
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

# govc is only needed for VMware platforms
ifeq ($(platform),vmw)
  _govc_download := download-govc
  _govc_install  := govc
  _govc_name     := govc
else
  _govc_download :=
  _govc_install  :=
  _govc_name     :=
endif

# OCP major version (e.g. "4" from "4.21.10") for CDN paths (openshift-v4/, openshift-v5/, etc.)
ocp_major := $(firstword $(subst ., ,$(ocp_version)))

# EC (engineering candidate) versions live under ocp-dev-preview/ on the CDN
ifneq ($(findstring -ec.,$(ocp_version)),)
  ocp_client_dir := ocp-dev-preview
else
  ocp_client_dir := ocp
endif

# Atomic download with retry: curl→tmp, verify sha256, retry once on ANY failure, mv→target.
# Usage: $(call atomic-download,DOWNLOAD_URL,SHA256SUM_URL)
# Uses $@ as the target name (for tmp file naming and sha256 lookup).
# PID in temp name prevents collision between concurrent make processes.
# On curl failure or checksum mismatch: retries once. On second failure: exits 1.
define atomic-download
	@_tmp=.$@.tmp.$$$$; \
	rm -f $$_tmp $$_tmp.sha256; \
	for _try in 1 2 3; do \
		curl -f --retry 8 $(CURL_PROGRESS) -o $$_tmp -L $(1) || \
			{ echo "[ABA] Download failed for $@"; rm -f $$_tmp; \
			  if [ "$$_try" = "3" ]; then exit 1; fi; \
			  echo "[ABA] Retrying download of $@ in 5s..."; sleep 5; continue; }; \
		echo -n "[ABA] Verifying checksum for $@: "; \
		curl -f --retry 8 -sL -o $$_tmp.sha256 $(2) && \
		_expected=$$(grep "  $@$$" $$_tmp.sha256 | awk '{print $$1}') && \
		_actual=$$(sha256sum $$_tmp | awk '{print $$1}') && \
		[ -n "$$_expected" ] && [ "$$_expected" = "$$_actual" ] && \
		echo "valid!" && rm -f $$_tmp.sha256 && break || \
		{ echo "FAILED!"; rm -f $$_tmp $$_tmp.sha256; \
		  if [ "$$_try" = "3" ]; then echo "[ABA] Checksum INVALID for $@!"; exit 1; fi; \
		  echo "[ABA] Retrying download of $@ in 5s..."; sleep 5; }; \
	done; \
	mv $$_tmp $@
endef

# Convenience-CLI download (extras: virtctl/kn/tkn/…).
# One-shot curl; verify checksum only if the download succeeded.
# SOFT_EXTRA=1 (bundle/save): on failure delete partials, warn, exit 0.
# Otherwise (direct aba -d cli download-extra-clis): fail hard.
# Usage: $(call optional-download,DOWNLOAD_URL,SHA256SUM_URL[,SUM_NAME])
# SUM_NAME defaults to $@; checksum lines may use an optional "./" prefix (RHACS).
define optional-download
	@_tmp=.$@.tmp.$$$$; \
	rm -f $$_tmp $$_tmp.sha256 $@; \
	if ! curl -f $(CURL_PROGRESS) -o $$_tmp -L $(1); then \
		echo "[ABA] Download failed for $@"; \
		rm -f $$_tmp; \
		if [ "$(SOFT_EXTRA)" = "1" ]; then echo "[ABA] Skipping (optional CLI)"; exit 0; fi; \
		exit 1; \
	fi; \
	echo -n "[ABA] Verifying checksum for $@: "; \
	if curl -f -sL -o $$_tmp.sha256 $(2) && \
	   _expected=$$(grep -E "[[:space:]](\./)?$(if $(3),$(3),$@)$$" $$_tmp.sha256 | awk '{print $$1}') && \
	   _actual=$$(sha256sum $$_tmp | awk '{print $$1}') && \
	   [ -n "$$_expected" ] && [ "$$_expected" = "$$_actual" ]; then \
		echo "valid!"; \
		rm -f $$_tmp.sha256; \
		mv $$_tmp $@; \
	else \
		echo "FAILED!"; \
		rm -f $$_tmp $$_tmp.sha256 $@; \
		if [ "$(SOFT_EXTRA)" = "1" ]; then echo "[ABA] Skipping (optional CLI)"; exit 0; fi; \
		exit 1; \
	fi
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
rhel9_oc_url      	:= https://mirror.openshift.com/pub/openshift-v$(ocp_major)/$(arch)/clients/$(ocp_client_dir)/$(ocp_version)/$(rhel9_oc_tar_file)

rhel8_oc_tar_file	:= openshift-client-$(os)-$(ARCH)-rhel8-$(ocp_version).tar.gz
rhel8_oc_url		:= https://mirror.openshift.com/pub/openshift-v$(ocp_major)/$(arch)/clients/$(ocp_client_dir)/$(ocp_version)/$(rhel8_oc_tar_file)

openshift_install_file	:= openshift-install-$(os)-$(ocp_version).tar.gz
openshift_install_url	:= https://mirror.openshift.com/pub/openshift-v$(ocp_major)/$(arch)/clients/$(ocp_client_dir)/$(ocp_version)


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
# govc only included when platform=vmw.
.PHONY: download
download: .check-ocp-version download-oc download-oc-mirror download-openshift-install download-butane $(_govc_download)  ## Download all CLI tarballs

.PHONY: download-all
download-all: .check-ocp-version download-oc download-oc-mirror download-openshift-install download-butane $(_govc_download)  ## Download all CLI tarballs (same as download)

# Output logical tool names for cli-download-all.sh.
# Version suffix appended for tools that need ocp_version, so callers
# can construct version-dependent run_once task IDs.
.PHONY: out-download-all
out-download-all:
	@echo oc:$(ocp_version) oc-mirror openshift-install:$(ocp_version) butane $(_govc_name)

# Version-independent tools only (usable without ocp_version being set)
.PHONY: out-download-no-version
out-download-no-version:
	@echo oc-mirror butane $(_govc_name)

# Optional convenience CLIs for air-gap prep (bundle/save). NOT part of download-all.
# Auto-downloaded only via cli-download-all.sh --extra (make-bundle / reg-save).
# kn/tkn/helm CDN uses "darwin" (not "mac" like OpenShift client tarballs).
cdn_os := $(os)
ifeq ($(os),mac)
  cdn_os := darwin
endif
kn_tar_file := kn-$(cdn_os)-$(ARCH).tar.gz
tkn_tar_file := tkn-$(cdn_os)-$(ARCH).tar.gz
helm_tar_file := helm-$(cdn_os)-$(ARCH).tar.gz
opm_tar_rhel9 := opm-linux-rhel9.tar.gz
opm_tar_default := opm-linux.tar.gz
local_opm_tar := $(if $(filter rhel9,$(rhel_ver)),$(opm_tar_rhel9),$(opm_tar_default))
virtctl_file := virtctl-$(ARCH)
# OpenShift GitOps argocd CLI (RH Content Gateway). Always resolve newest stable at download time
# (no latest/ symlink on CGW). Local filename is unversioned like kn/tkn.
argocd_tar_file := argocd-$(cdn_os)-$(ARCH).tar.gz
argocd_cgw_index = https://mirror.openshift.com/pub/cgw/openshift-gitops/
# Remote CDN name is "roxctl" on amd64 and "roxctl-<arch>" elsewhere.
# Local artifact MUST NOT be named "roxctl" — that collides with the phony install
# target "roxctl" and creates a circular ~/bin/roxctl <-> roxctl dependency.
ifeq ($(ARCH),amd64)
  roxctl_remote := roxctl
else
  roxctl_remote := roxctl-$(ARCH)
endif
roxctl_file := roxctl-$(ARCH)

.PHONY: download-kn
download-kn: $(kn_tar_file)  ## Download kn (Serverless) tarball

.PHONY: download-tkn
download-tkn: $(tkn_tar_file)  ## Download tkn (Pipelines) tarball

.PHONY: download-helm
download-helm: $(helm_tar_file)  ## Download helm tarball

.PHONY: download-opm
download-opm: $(opm_tar_default) $(opm_tar_rhel9)  ## Download opm tarballs

.PHONY: download-virtctl
download-virtctl: $(virtctl_file)  ## Download virtctl binary

.PHONY: download-argocd
download-argocd: $(argocd_tar_file)  ## Download argocd (OpenShift GitOps) tarball

.PHONY: download-roxctl
download-roxctl: $(roxctl_file)  ## Download roxctl (ACS) binary

.PHONY: download-extra-clis
download-extra-clis: download-virtctl download-kn download-tkn download-helm download-opm download-argocd download-roxctl  ## Download optional convenience CLIs (bundle/save)

.PHONY: out-download-extra-clis
out-download-extra-clis:
	@echo virtctl kn tkn helm opm argocd roxctl


########################################################################
##@ Tarball Recipes — bare curl + verify, no run_once
########################################################################

# oc tarballs: download both rhel9 and rhel8 variants.
# On download failure (e.g. 404 for an older rhel variant), create an empty
# placeholder so Make doesn't retry. Bundles need both variants.
# Special: these use HEAD check first, and create empty placeholder on 404 (not a hard error).
$(rhel9_oc_tar_file):
	@curl -sfkLI $(rhel9_oc_url) >/dev/null || { echo "[ABA] $@ not available (404)"; > $@; exit 0; }
	@echo [ABA] Downloading $(rhel9_oc_url)
	$(call atomic-download,$(rhel9_oc_url),$(openshift_install_url)/sha256sum.txt)

$(rhel8_oc_tar_file):
	@curl -sfkLI $(rhel8_oc_url) >/dev/null || { echo "[ABA] $@ not available (404)"; > $@; exit 0; }
	@echo [ABA] Downloading $(rhel8_oc_url)
	$(call atomic-download,$(rhel8_oc_url),$(openshift_install_url)/sha256sum.txt)

# openshift-install tarball
$(openshift_install_file):
	@echo [ABA] Downloading $(openshift_install_url)/$(openshift_install_file)
	$(call atomic-download,$(openshift_install_url)/$(openshift_install_file),$(openshift_install_url)/sha256sum.txt)

# oc-mirror download URL.
# oc-mirror is a version-independent tool — a single binary works with any OCP release.
# We pin to a tested stable channel rather than deriving from ocp_version, because
# oc-mirror must be well-tested before adoption.
#
# Logic:
#   - EC (engineering candidate): use the exact dev-preview path for that version
#     (EC builds may bundle an oc-mirror with unreleased features needed for that EC)
#   - OCP 5.x (non-EC): use stable-5.0 (first stable 5.x channel)
#   - OCP 4.x (non-EC): use stable-4.22 (tested, known-good)
#   - No version set: fall back to stable-4.22 (safe default for --no-version path)
#
# When a new oc-mirror version is tested and validated, bump the pin here.
ifneq ($(ocp_version),)
  ifneq ($(findstring -ec.,$(ocp_version)),)
    oc_mirror_base_url = https://mirror.openshift.com/pub/openshift-v$(ocp_major)/$(arch)/clients/ocp-dev-preview/$(ocp_version)
  else ifeq ($(ocp_major),5)
    oc_mirror_base_url = https://mirror.openshift.com/pub/openshift-v5/$(arch)/clients/ocp/stable-5.0
  else
    oc_mirror_base_url = https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/stable-4.22
  endif
else
  oc_mirror_base_url = https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/stable-4.22
endif
oc_mirror_sha256sum = $(oc_mirror_base_url)/sha256sum.txt

oc-mirror.tar.gz:
	@echo [ABA] Downloading $(oc_mirror_base_url)/$@
	$(call atomic-download,$(oc_mirror_base_url)/$@,$(oc_mirror_sha256sum))

oc-mirror.rhel9.tar.gz:
	@echo [ABA] Downloading $(oc_mirror_base_url)/$@
	$(call atomic-download,$(oc_mirror_base_url)/$@,$(oc_mirror_sha256sum))

# govc tarball (from GitHub, not mirror.openshift.com)
govc_url = https://github.com/vmware/govmomi/releases/latest/download

$(govc_tar_file):
	@echo [ABA] Downloading $(govc_url)/$@
	$(call atomic-download,$(govc_url)/$@,$(govc_url)/checksums.txt)

# Butane binary is a shared client tool, hosted under openshift-v4/clients/ regardless of OCP major version
butane_binary_url = https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest
butane_binary_file_url = $(butane_binary_url)/$(butane_binary_file)
butane_binary_url_sha256sum = $(butane_binary_url)/sha256sum.txt

$(butane_binary_file):
	@echo [ABA] Downloading $(butane_binary_file_url)
	$(call atomic-download,$(butane_binary_file_url),$(butane_binary_url_sha256sum))
	@chmod +x $@

# --- Extra convenience CLIs (not in download-all) ---
# One-shot optional-download: never fails the Make target (bundle/save keep going).

kn_base_url = https://mirror.openshift.com/pub/openshift-v4/clients/serverless/latest
$(kn_tar_file):
	@echo [ABA] Downloading $(kn_base_url)/$@
	$(call optional-download,$(kn_base_url)/$@,$(kn_base_url)/sha256sum.txt)

tkn_base_url = https://mirror.openshift.com/pub/openshift-v4/clients/pipelines/latest
$(tkn_tar_file):
	@echo [ABA] Downloading $(tkn_base_url)/$@
	$(call optional-download,$(tkn_base_url)/$@,$(tkn_base_url)/sha256sum.txt)

helm_base_url = https://mirror.openshift.com/pub/openshift-v4/clients/helm/latest
$(helm_tar_file):
	@echo [ABA] Downloading $(helm_base_url)/$@
	$(call optional-download,$(helm_base_url)/$@,$(helm_base_url)/sha256sum.txt)

opm_base_url = https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/stable
opm_sha256sum = $(opm_base_url)/sha256sum.txt

$(opm_tar_default):
	@echo [ABA] Downloading $(opm_base_url)/$@
	$(call optional-download,$(opm_base_url)/$@,$(opm_sha256sum))

$(opm_tar_rhel9):
	@echo [ABA] Downloading $(opm_base_url)/$@
	$(call optional-download,$(opm_base_url)/$@,$(opm_sha256sum))

# virtctl: no RH CDN / no per-binary checksum — one-shot.
$(virtctl_file):
	@echo [ABA] Resolving kubevirt stable version for virtctl
	@_ver=$$(curl -f -sL https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt) || \
		{ echo "[ABA] Failed to resolve kubevirt stable version for $@"; \
		  if [ "$(SOFT_EXTRA)" = "1" ]; then echo "[ABA] Skipping (optional CLI)"; exit 0; fi; exit 1; }; \
	_url="https://github.com/kubevirt/kubevirt/releases/download/$$_ver/virtctl-$$_ver-linux-$(ARCH)"; \
	echo "[ABA] Downloading $$_url"; \
	_tmp=.$@.tmp.$$$$; rm -f $$_tmp $@; \
	if ! curl -f $(CURL_PROGRESS) -o $$_tmp -L $$_url || [ ! -s $$_tmp ]; then \
		echo "[ABA] Download failed for $@"; \
		rm -f $$_tmp; \
		if [ "$(SOFT_EXTRA)" = "1" ]; then echo "[ABA] Skipping (optional CLI)"; exit 0; fi; \
		exit 1; \
	fi; \
	chmod +x $$_tmp; \
	mv $$_tmp $@

# argocd: RH Content Gateway (newest stable). Inline (URL resolved at runtime).
$(argocd_tar_file):
	@echo [ABA] Resolving latest OpenShift GitOps CLI version
	@_ver=$$(curl -f -sL $(argocd_cgw_index) | \
		grep -oE '[0-9]+\.[0-9]+\.[0-9]+/' | tr -d '/' | sort -V | tail -1) || true; \
	if [ -z "$$_ver" ]; then \
		echo "[ABA] Failed to resolve latest OpenShift GitOps version for $@"; \
		if [ "$(SOFT_EXTRA)" = "1" ]; then echo "[ABA] Skipping (optional CLI)"; exit 0; fi; \
		exit 1; \
	fi; \
	_base="$(argocd_cgw_index)$$_ver"; \
	echo "[ABA] Downloading $$_base/$@"; \
	_tmp=.$@.tmp.$$$$; rm -f $$_tmp $$_tmp.sha256 $@; \
	if ! curl -f $(CURL_PROGRESS) -o $$_tmp -L "$$_base/$@"; then \
		echo "[ABA] Download failed for $@"; \
		rm -f $$_tmp; \
		if [ "$(SOFT_EXTRA)" = "1" ]; then echo "[ABA] Skipping (optional CLI)"; exit 0; fi; \
		exit 1; \
	fi; \
	echo -n "[ABA] Verifying checksum for $@: "; \
	if curl -f -sL -o $$_tmp.sha256 "$$_base/sha256sum.txt" && \
	   _expected=$$(grep "  $@$$" $$_tmp.sha256 | awk '{print $$1}') && \
	   _actual=$$(sha256sum $$_tmp | awk '{print $$1}') && \
	   [ -n "$$_expected" ] && [ "$$_expected" = "$$_actual" ]; then \
		echo "valid!"; \
		rm -f $$_tmp.sha256; \
		mv $$_tmp $@; \
	else \
		echo "FAILED!"; \
		rm -f $$_tmp $$_tmp.sha256 $@; \
		if [ "$(SOFT_EXTRA)" = "1" ]; then echo "[ABA] Skipping (optional CLI)"; exit 0; fi; \
		exit 1; \
	fi

roxctl_base_url = https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux
$(roxctl_file):
	@echo [ABA] Downloading $(roxctl_base_url)/$(roxctl_remote)
	$(call optional-download,$(roxctl_base_url)/$(roxctl_remote),$(roxctl_base_url)/sha256sum.txt,$(roxctl_remote))


########################################################################
##@ Install Targets (Extract) — tarball as prerequisite, simple extraction
########################################################################

# All extraction targets use atomic pattern: extract→tmpdir, validate, mv→target.
# Each process extracts to its own temp dir (.tmp.XXXXXX in CWD) — no collision
# between concurrent make processes. The target file appears atomically via mv (rename).
# CWD is used instead of /tmp to avoid filling /tmp with large binaries.

# oc: extract from the tarball matching this host's RHEL version.
# Self-healing: if tarball is corrupt, delete it and re-download.
.PHONY: oc
oc: ~/bin/oc  ## Install oc into ~/bin

~/bin/oc: .init $(local_oc_tar_file) | ~/bin
	@echo [ABA] Extracting $(local_oc_tar_file) to ~/bin/oc
	@_td=$$(mktemp -d ./.tmp.XXXXXX) && \
	tar -C $$_td --no-same-owner -xmzf $(local_oc_tar_file) oc kubectl || \
		{ echo "[ABA] Error: Corrupt tarball, re-downloading $(local_oc_tar_file)"; \
		  rm -rf $$_td; rm -f $(local_oc_tar_file); $(MAKE) $(local_oc_tar_file); \
		  _td=$$(mktemp -d ./.tmp.XXXXXX); \
		  tar -C $$_td --no-same-owner -xmzf $(local_oc_tar_file) oc kubectl || { rm -rf $$_td; exit 1; }; }; \
	$$_td/oc --help >/dev/null 2>&1 || { echo [ABA] "Error: oc binary invalid!"; rm -rf $$_td; exit 1; }; \
	mv $$_td/oc $@ && mv $$_td/kubectl ~/bin/kubectl; \
	rm -rf $$_td

# openshift-install: extract from tarball.
.PHONY: openshift-install
openshift-install: ~/bin/openshift-install  ## Install openshift-install into ~/bin

~/bin/openshift-install: .init $(openshift_install_file) | ~/bin
	@echo [ABA] Extracting $(openshift_install_file) to ~/bin/openshift-install
	@_td=$$(mktemp -d ./.tmp.XXXXXX) && \
	tar -C $$_td --no-same-owner -xmzf $(openshift_install_file) openshift-install || \
		{ echo "[ABA] Error: Corrupt tarball, re-downloading $(openshift_install_file)"; \
		  rm -rf $$_td; rm -f $(openshift_install_file); $(MAKE) $(openshift_install_file); \
		  _td=$$(mktemp -d ./.tmp.XXXXXX); \
		  tar -C $$_td --no-same-owner -xmzf $(openshift_install_file) openshift-install || { rm -rf $$_td; exit 1; }; }; \
	$$_td/openshift-install --help >/dev/null || { echo [ABA] "Error: openshift-install binary invalid!"; rm -rf $$_td; exit 1; }; \
	mv $$_td/openshift-install $@; \
	rm -rf $$_td

# oc-mirror: extract from the tarball matching this host's RHEL version.
.PHONY: oc-mirror
oc-mirror: ~/bin/oc-mirror  ## Install oc-mirror into ~/bin

~/bin/oc-mirror: .init $(local_oc_mirror_tar) | ~/bin
	@echo [ABA] Extracting $(local_oc_mirror_tar) to ~/bin/oc-mirror
	@_td=$$(mktemp -d ./.tmp.XXXXXX) && \
	tar -C $$_td --no-same-owner -xmzf $(local_oc_mirror_tar) oc-mirror || \
		{ echo "[ABA] Error: Corrupt tarball, re-downloading $(local_oc_mirror_tar)"; \
		  rm -rf $$_td; rm -f $(local_oc_mirror_tar); $(MAKE) $(local_oc_mirror_tar); \
		  _td=$$(mktemp -d ./.tmp.XXXXXX); \
		  tar -C $$_td --no-same-owner -xmzf $(local_oc_mirror_tar) oc-mirror || { rm -rf $$_td; exit 1; }; }; \
	chmod a+rx $$_td/oc-mirror; \
	mv $$_td/oc-mirror $@; \
	rm -rf $$_td

# govc: extract from tarball.
.PHONY: govc
govc: ~/bin/govc  ## Install govc to ~/bin/govc

~/bin/govc: .init $(govc_tar_file) | ~/bin
	@echo [ABA] Extracting $(govc_tar_file) to ~/bin/govc
	@_td=$$(mktemp -d ./.tmp.XXXXXX) && \
	tar -C $$_td --no-same-owner -xmzf $(govc_tar_file) govc || \
		{ echo "[ABA] Error: Corrupt tarball, re-downloading $(govc_tar_file)"; \
		  rm -rf $$_td; rm -f $(govc_tar_file); $(MAKE) $(govc_tar_file); \
		  _td=$$(mktemp -d ./.tmp.XXXXXX); \
		  tar -C $$_td --no-same-owner -xmzf $(govc_tar_file) govc || { rm -rf $$_td; exit 1; }; }; \
	$$_td/govc --help >/dev/null 2>&1 || { echo [ABA] "Error: govc binary invalid"; rm -rf $$_td; exit 1; }; \
	chmod a+rx $$_td/govc; \
	mv $$_td/govc $@; \
	rm -rf $$_td

# butane: copy binary to ~/bin.
.PHONY: butane
butane: ~/bin/butane  ## Install butane to ~/bin/butane

~/bin/butane: $(butane_binary_file) | ~/bin
	@echo [ABA] Copying butane binary to $@
	@_td=$$(mktemp -d ./.tmp.XXXXXX) && \
	cp $(butane_binary_file) $$_td/butane; \
	chmod +x $$_td/butane; \
	$$_td/butane --help >/dev/null 2>&1 || \
		{ echo "[ABA] Error: Corrupt binary, re-downloading $(butane_binary_file)"; \
		  rm -rf $$_td; rm -f $(butane_binary_file); $(MAKE) $(butane_binary_file); \
		  _td=$$(mktemp -d ./.tmp.XXXXXX); \
		  cp $(butane_binary_file) $$_td/butane; chmod +x $$_td/butane; \
		  $$_td/butane --help >/dev/null 2>&1 || { rm -rf $$_td; exit 1; }; }; \
	mv $$_td/butane $@; \
	rm -rf $$_td

# install/install-all: extract all core tools.
# govc only included when platform=vmw. Extra CLIs: see install-extra-clis.
.PHONY: install
install: .check-ocp-version oc openshift-install oc-mirror butane $(_govc_install)  ## Install all CLI tools to ~/bin

.PHONY: install-all
install-all: .check-ocp-version oc openshift-install oc-mirror butane $(_govc_install)  ## Install all CLI tools (same as install)

# Output targets for scripts to query which tools exist.
.PHONY: out-install
out-install:
	@echo oc openshift-install oc-mirror butane $(_govc_name)

.PHONY: out-install-all
out-install-all:
	@echo oc openshift-install oc-mirror butane $(_govc_name)

# --- Extra CLI install (optional; not in install-all) ---

.PHONY: kn
kn: ~/bin/kn  ## Install kn to ~/bin

~/bin/kn: $(kn_tar_file) | ~/bin
	@echo [ABA] Extracting $(kn_tar_file) to ~/bin/kn
	@_td=$$(mktemp -d ./.tmp.XXXXXX) && \
	tar -C $$_td --no-same-owner -xmzf $(kn_tar_file) || { rm -rf $$_td; exit 1; }; \
	_bin=$$(find $$_td -type f -name 'kn*' ! -name '*.tar.gz' | head -1); \
	[ -n "$$_bin" ] || { echo "[ABA] Error: kn binary not found in $(kn_tar_file)"; rm -rf $$_td; exit 1; }; \
	chmod +x $$_bin; \
	$$_bin --help >/dev/null 2>&1 || { echo "[ABA] Error: kn binary invalid"; rm -rf $$_td; exit 1; }; \
	mv $$_bin $@; \
	rm -rf $$_td

.PHONY: tkn
tkn: ~/bin/tkn  ## Install tkn to ~/bin

~/bin/tkn: $(tkn_tar_file) | ~/bin
	@echo [ABA] Extracting $(tkn_tar_file) to ~/bin/tkn
	@_td=$$(mktemp -d ./.tmp.XXXXXX) && \
	tar -C $$_td --no-same-owner -xmzf $(tkn_tar_file) tkn || { rm -rf $$_td; exit 1; }; \
	chmod +x $$_td/tkn; \
	$$_td/tkn --help >/dev/null 2>&1 || { echo "[ABA] Error: tkn binary invalid"; rm -rf $$_td; exit 1; }; \
	mv $$_td/tkn $@; \
	rm -rf $$_td

.PHONY: helm
helm: ~/bin/helm  ## Install helm to ~/bin

~/bin/helm: $(helm_tar_file) | ~/bin
	@echo [ABA] Extracting $(helm_tar_file) to ~/bin/helm
	@_td=$$(mktemp -d ./.tmp.XXXXXX) && \
	tar -C $$_td --no-same-owner -xmzf $(helm_tar_file) || { rm -rf $$_td; exit 1; }; \
	_bin=$$(find $$_td -type f -name 'helm*' ! -name '*.tar.gz' | head -1); \
	[ -n "$$_bin" ] || { echo "[ABA] Error: helm binary not found in $(helm_tar_file)"; rm -rf $$_td; exit 1; }; \
	chmod +x $$_bin; \
	$$_bin version --short >/dev/null 2>&1 || $$_bin --help >/dev/null 2>&1 || \
		{ echo "[ABA] Error: helm binary invalid"; rm -rf $$_td; exit 1; }; \
	mv $$_bin $@; \
	rm -rf $$_td

.PHONY: opm
opm: ~/bin/opm  ## Install opm to ~/bin

~/bin/opm: $(local_opm_tar) | ~/bin
	@echo [ABA] Extracting $(local_opm_tar) to ~/bin/opm
	@_td=$$(mktemp -d ./.tmp.XXXXXX) && \
	tar -C $$_td --no-same-owner -xmzf $(local_opm_tar) || { rm -rf $$_td; exit 1; }; \
	_bin=$$(find $$_td -type f \( -name 'opm' -o -name 'opm-*' \) | head -1); \
	[ -n "$$_bin" ] || { echo "[ABA] Error: opm binary not found in $(local_opm_tar)"; rm -rf $$_td; exit 1; }; \
	chmod +x $$_bin; \
	$$_bin --help >/dev/null 2>&1 || { echo "[ABA] Error: opm binary invalid"; rm -rf $$_td; exit 1; }; \
	mv $$_bin $@; \
	rm -rf $$_td

.PHONY: virtctl
virtctl: ~/bin/virtctl  ## Install virtctl to ~/bin

~/bin/virtctl: $(virtctl_file) | ~/bin
	@echo [ABA] Installing virtctl to ~/bin/virtctl
	@_td=$$(mktemp -d ./.tmp.XXXXXX) && \
	cp $(virtctl_file) $$_td/virtctl && chmod +x $$_td/virtctl; \
	$$_td/virtctl --help >/dev/null 2>&1 || \
		{ echo "[ABA] Error: virtctl binary invalid"; rm -rf $$_td; exit 1; }; \
	mv $$_td/virtctl $@; \
	rm -rf $$_td

.PHONY: argocd
argocd: ~/bin/argocd  ## Install argocd to ~/bin

~/bin/argocd: $(argocd_tar_file) | ~/bin
	@echo [ABA] Extracting $(argocd_tar_file) to ~/bin/argocd
	@_td=$$(mktemp -d ./.tmp.XXXXXX) && \
	tar -C $$_td --no-same-owner -xmzf $(argocd_tar_file) || { rm -rf $$_td; exit 1; }; \
	_bin=$$(find $$_td -type f \( -name 'argocd' -o -name 'argocd-linux-*' \) | head -1); \
	[ -n "$$_bin" ] || { echo "[ABA] Error: argocd binary not found in $(argocd_tar_file)"; rm -rf $$_td; exit 1; }; \
	chmod +x $$_bin; \
	$$_bin version --client >/dev/null 2>&1 || $$_bin --help >/dev/null 2>&1 || \
		{ echo "[ABA] Error: argocd binary invalid"; rm -rf $$_td; exit 1; }; \
	mv $$_bin $@; \
	rm -rf $$_td

.PHONY: roxctl
roxctl: ~/bin/roxctl  ## Install roxctl to ~/bin

~/bin/roxctl: $(roxctl_file) | ~/bin
	@echo [ABA] Installing roxctl to ~/bin/roxctl
	@_td=$$(mktemp -d ./.tmp.XXXXXX) && \
	cp $(roxctl_file) $$_td/roxctl && chmod +x $$_td/roxctl; \
	$$_td/roxctl --help >/dev/null 2>&1 || \
		{ echo "[ABA] Error: roxctl binary invalid"; rm -rf $$_td; exit 1; }; \
	mv $$_td/roxctl $@; \
	rm -rf $$_td

.PHONY: install-extra-clis
install-extra-clis: virtctl kn tkn helm opm argocd roxctl  ## Install optional convenience CLIs to ~/bin

.PHONY: out-install-extra-clis
out-install-extra-clis:
	@echo virtctl kn tkn helm opm argocd roxctl

# Echo only extra tools whose download artifacts already exist (no download).
.PHONY: out-install-extra-available
out-install-extra-available:
	@[ -s "$(virtctl_file)" ] && echo -n "virtctl " || true
	@[ -s "$(kn_tar_file)" ] && echo -n "kn " || true
	@[ -s "$(tkn_tar_file)" ] && echo -n "tkn " || true
	@[ -s "$(helm_tar_file)" ] && echo -n "helm " || true
	@[ -s "$(local_opm_tar)" ] && echo -n "opm " || true
	@[ -s "$(argocd_tar_file)" ] && echo -n "argocd " || true
	@[ -s "$(roxctl_file)" ] && echo -n "roxctl " || true
	@echo


########################################################################
##@ Cleanup
########################################################################

.PHONY: clean
clean: ## Clean up installed binaries
	@../scripts/cli-install-all.sh --reset
	@rm -f ~/bin/{oc,kubectl,oc-mirror,openshift-install,govc,butane,virtctl,kn,tkn,helm,opm,argocd,roxctl} *sha256sum.txt *.sha256
	@rm -rf .tmp.*

.PHONY: reset
reset: clean  ## Clean up everything (tarballs + binaries). Only use if you know what you are doing!
	@../scripts/cli-download-all.sh --reset
	@../scripts/cli-download-all.sh --reset --extra || true
	@rm -f *.tar.gz .init butane* virtctl-* roxctl-* .*.tmp .*.tmp.sha256
	@rm -rf .tmp.*
	@rm -f scripts
