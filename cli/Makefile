# Makefile to download and install oc, openshift-install, oc-mirror and govc 

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

ifeq ($(shell echo "$(os_ver)" | grep -o -E "^8\."),8.)
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

ARCH := amd64
ifneq ($(arch),x86_64)
	ARCH := arm64
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

# Only if platform not "bm" we need govc for vmw or libvirt
ifneq ($(platform),bm)
	govc_bin := govc
	govc_tar_target := $(govc_tar_file)
endif

# Targets

# govc is optional, depends on platform != bm
install: oc openshift-install oc-mirror butane $(govc_bin)

# Force d/l of govc too
install-all: oc openshift-install oc-mirror butane govc

out-install:
	echo oc openshift-install oc-mirror butane $(govc_bin)

out-install-all:
	echo oc openshift-install oc-mirror butane govc

# For "reset" and "oc-mirror" and "govc" targets we DO NOT need to check for the target ocp version
# If 'reset' found in $MAKECMDGOALS, i.e. no reset target provided
ifneq ($(filter reset oc-mirror govc,$(MAKECMDGOALS)),)
  # reset not given
else
  ifeq ($(ocp_version),)
    # ocp_version is missing!
    $(error "Value 'ocp_version' not set in aba.conf! Run aba in the root of Aba's repository or read the README.md file on how to get started.")
  endif
endif

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  aba \033[36mcommand\033[0m\n"} /^(\s|[\$\.\(\)\~\/a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

# Keep this like it is, otherwise the deps don't work!
.init:
	mkdir -p ~/bin
	ln -fs ../scripts
	touch .init

# aba.conf should never be missing!
../aba.conf:
	@echo "[ABA] aba/aba.conf missing! Run 'aba' for interactive mode or read the README.md file on how to get started!"
	@exit 1

# The preference to download the oc CLI tar files is: rhel9, then rhel8 

# See:
# https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/4.18.9/ 
# Example x86:
#openshift-client-linux-amd64-rhel9-4.18.9.tar.gz
#openshift-client-linux-amd64-rhel8-4.18.9.tar.gz
# Example ARM:
#openshift-client-linux-arm64-rhel8-4.18.9.tar.gz
#openshift-client-linux-arm64-rhel9-4.18.9.tar.gz

# This is the tarball that's needed for this local host OS
loacl_oc_tar_file	:= openshift-client-$(os)-$(ARCH)-$(rhel_ver)-$(ocp_version).tar.gz
#full_oc_url		:= https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/$(loacl_oc_tar_file)

# Generic oc binary 
#gen_oc_tar_file		:= openshift-client-$(os)-$(ocp_version).tar.gz
#gen_oc_url		:= https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/$(gen_oc_tar_file)

rhel9_oc_tar_file	:= openshift-client-$(os)-$(ARCH)-rhel9-$(ocp_version).tar.gz
rhel9_oc_url      	:= https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/$(rhel9_oc_tar_file)

rhel8_oc_tar_file	:= openshift-client-$(os)-$(ARCH)-rhel8-$(ocp_version).tar.gz
rhel8_oc_url		:= https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/$(rhel8_oc_tar_file)


openshift_install_file	:= openshift-install-$(os)-$(ocp_version).tar.gz
# 	Example:
# 	openshift-install-linux-4.20.8.tar.gz   #amd64
# 	openshift-install-linux-arm64-4.20.8.tar.gz

# Download *all* the install files that might be use in the disconnected env, both rhel9 and rhel8.
download = $(rhel9_oc_tar_file) $(rhel8_oc_tar_file) $(openshift_install_file) oc-mirror.tar.gz oc-mirror.rhel9.tar.gz $(butane_binary_file) $(govc_tar_target)
# This is the same as download but with govc added 
download_all = $(download) $(govc_tar_file)

download: $(download)

download-all: $(download_all)

out-download:
	echo $(download)

out-download-all:
	echo $(download_all)


########################################
# Extract the oc file with priority for the rhel8/9 version, then the generic version (fallback)
oc: ~/bin/oc  ## Install oc into ~/bin
~/bin/oc: .init $(loacl_oc_tar_file)
	file $(loacl_oc_tar_file) | grep -q "gzip compressed data"
	@echo [ABA] Extracting $(loacl_oc_tar_file) to ~/bin/oc
	tar -C ~/bin -xmzf $(loacl_oc_tar_file) oc kubectl || { echo [ABA] Extracting $(gen_oc_tar_file) instead to ~/bin/oc; tar -C ~/bin -xmzf $(gen_oc_tar_file) oc kubectl; } || { echo [ABA] Error: Invalid files: $(loacl_oc_tar_file) or $(gen_oc_tar_file); exit 1; }
	~/bin/oc --help >/dev/null 2>&1

# Download just the oc tar files
octars: $(rhel9_oc_tar_file) $(rhel8_oc_tar_file)

openshift_install_url := https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)

# Ensure all possible tarballs are downloaded
$(rhel9_oc_tar_file):  ## Downlaod oc tarball for rhel9, if available
	curl -sfkLI $(rhel9_oc_url) >/dev/null # Check connection only
	echo [ABA] Downloading $(rhel9_oc_url)
	curl -f $(CURL_PROGRESS) -OL $(rhel9_oc_url) || { echo [ABA] $(rhel9_oc_tar_file) failed download; > $(rhel9_oc_tar_file); }
	curl -f --retry 8 -sL $(CURL_PROGRESS) -o openshift-client-rhel9-sha256sum.txt $(openshift_install_url)/sha256sum.txt && cs=`sha256sum $@` && grep -q "$$cs" openshift-client-rhel9-sha256sum.txt || { echo [ABA] "Error: file $@ checksum invalid!"; exit 1; }
	echo [ABA] "File $(rhel9_oc_tar_file) checksum valid!"  # Be sure it's valid

# Ensure all possible tarballs are downloaded
$(rhel8_oc_tar_file):  ## Downlaod oc tarball for rhel8, if available
	curl -sfkLI $(rhel8_oc_url) >/dev/null # Check connection only
	echo [ABA] Downloading $(rhel8_oc_url)
	curl -f $(CURL_PROGRESS) -OL $(rhel8_oc_url) || { echo [ABA] $(rhel8_oc_tar_file) failed download; > $(rhel8_oc_tar_file); }
	curl -f --retry 8 -sL $(CURL_PROGRESS) -o openshift-client-rhel8-sha256sum.txt $(openshift_install_url)/sha256sum.txt && cs=$$(sha256sum $@) && grep -q "$$cs" openshift-client-rhel8-sha256sum.txt || { echo [ABA] "Error: file $@ checksum invalid!"; exit 1; }
	echo [ABA] "File $(rhel8_oc_tar_file) checksum valid!"  # Be sure it's valid


########################################

openshift-install: ~/bin/openshift-install ## Install openshift-install into ~/bin
~/bin/openshift-install: .init $(openshift_install_file)
	@echo [ABA] Extracting  $(openshift_install_file) to $@
	tar -C ~/bin -xmzf $(openshift_install_file) openshift-install
	$@ --help >/dev/null || { echo [ABA] "Error: file $@ invalid!"; exit 1; }

$(openshift_install_file):  ## Download openshift-install tarball
	@echo [ABA] Downloading $(openshift_install_url)/$@
	curl -f --retry 8 $(CURL_PROGRESS) -OL https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/$@
	curl -f --retry 8 -sL $(CURL_PROGRESS) -o openshift-install-sha256sum.txt $(openshift_install_url)/sha256sum.txt && cs=`sha256sum $@` && grep -q "$$cs" openshift-install-sha256sum.txt || { echo [ABA] "Error: file $@ checksum invalid!"; exit 1; }
	echo [ABA] "File $@ checksum valid!"


########################################
oc-mirror: ~/bin/oc-mirror  ## Install oc-mirror into ~/bin
~/bin/oc-mirror: .init oc-mirror.tar.gz oc-mirror.rhel9.tar.gz
	@echo $(os_ver) | grep -q "^9\." && echo [ABA] Extracting oc-mirror.rhel9.tar.gz to ~/bin/oc-mirror	|| echo [ABA] Extracting oc-mirror.tar.gz to ~/bin/oc-mirror
	@echo $(os_ver) | grep -q "^9\." && tar -C ~/bin -xmzf oc-mirror.rhel9.tar.gz oc-mirror		|| tar -C ~/bin -xmzf oc-mirror.tar.gz oc-mirror
	chmod +x ~/bin/oc-mirror
	~/bin/oc-mirror --help >/dev/null 2>&1 || { echo [ABA] "Error: ~/bin/oc-mirror failed to execute"; exit 1; }

# Check here for any updated versions: https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/ 

oc_mirror_url = https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/latest/oc-mirror.tar.gz
oc_mirror_sha256sum = https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/latest/sha256sum.txt
oc-mirror.tar.gz: ## Download oc-mirror tarball
	echo [ABA] Downloading $(oc_mirror_url)
	curl -f --retry 8 $(CURL_PROGRESS) -OL $(oc_mirror_url)
#	file $@ | grep -q "gzip compressed data" || { rm -f $@; exit 1; } # in case of 5xx errors!
#	tar tvf $@ >/dev/null|| { rm -f $@; exit 1; } # in case of 5xx errors!  # Be sure it's valid
	curl -f --retry 8 -sL $(CURL_PROGRESS) -o oc-mirror-sha256sum.txt $(oc_mirror_sha256sum) && cs=`sha256sum $@` && grep -q "$$cs" oc-mirror-sha256sum.txt || { echo [ABA] "Error: file $@ checksum invalid!"; exit 1; }
	echo [ABA] "File $@ checksum valid!"

oc_mirror_url_rhel9 = https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/latest/oc-mirror.rhel9.tar.gz
oc_mirror_url_rhel9_sha256sum = https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/latest/sha256sum.txt
oc-mirror.rhel9.tar.gz: ## Download oc-mirror tarball for rhel9
	echo [ABA] Downloading $(oc_mirror_url_rhel9)
	curl -f --retry 8 $(CURL_PROGRESS) -OL $(oc_mirror_url_rhel9)
#	file oc-mirror.rhel9.tar.gz | grep -q "gzip compressed data" || { rm -f oc-mirror.rhel9.tar.gz; exit 1; } # in case of 5xx errors!
#	tar tvf oc-mirror.rhel9.tar.gz >/dev/null|| { rm -f oc-mirror.rhel9.tar.gz; exit 1; } # in case of 5xx errors!  # Be sure it's valid
	curl -f --retry 8 -sL $(CURL_PROGRESS) -o oc-mirror-rhel9-sha256sum.txt $(oc_mirror_url_rhel9_sha256sum) && cs=`sha256sum $@` && grep -q "$$cs" oc-mirror-rhel9-sha256sum.txt || { echo [ABA] "Error: file $@ checksum invalid!"; exit 1; }
	echo [ABA] "File $@ checksum valid!"


########################################
# Use either x86_64 or arm64 
govc: ~/bin/govc  ## Install govc to ~/bin/govc
~/bin/govc: .init $(govc_tar_file)
	@echo [ABA] Extracting $(govc_tar_file) to ~/bin/govc
	tar -C ~/bin -xmzf $(govc_tar_file) govc
	~/bin/govc --help >/dev/null 2>&1

govc_url = https://github.com/vmware/govmomi/releases/latest/download
govc_tar_url_sha256sum = $(govc_url)/checksums.txt
govc_tar_file_sha256sum = $(govc_tar_file)-sha256sum.txt
$(govc_tar_file):   ## Download govc tarball
	echo [ABA] Downloading $(govc_url)/$@
	curl -f --retry 8 -sL $(CURL_PROGRESS) -O "$(govc_url)/$@"
	curl -f --retry 8 -sL $(CURL_PROGRESS) -o $(govc_tar_file_sha256sum) $(govc_tar_url_sha256sum) && cs=`sha256sum $@` && grep -q "$$cs" $(govc_tar_file_sha256sum) || { echo [ABA] "Error: file $@ checksum invalid!"; mv $(govc_tar_file) .$(govc_tar_file); exit 1; }
	echo [ABA] "File $@ checksum valid!"

# Use either amd64 or aarch64 
.PHONY: butane
butane: ~/bin/butane ## Install butane to ~/bin/butane
~/bin/butane: $(butane_binary_file)
	@echo [ABA] Copying butane binary to $@
	cp $(butane_binary_file) $@
	chmod +x $@
	$@ --help >/dev/null 2>&1 || { echo [ABA] "Error: $@ binary invalid"; exit 1; }  # Be sure it's valid

butane_binary_url = https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest
butane_binary_file_url = $(butane_binary_url)/$(butane_binary_file)
butane_binary_url_sha256sum = $(butane_binary_url)/sha256sum.txt

$(butane_binary_file): ## Download butane binary 
	echo [ABA] Downloading $(butane_binary_file_url)
	curl -f --retry 8 $(CURL_PROGRESS) -sL -o $@ --connect-timeout 30 $(butane_binary_file_url)
	chmod +x $@
	curl -f --retry 8 $(CURL_PROGRESS) -sL -o $(butane_binary_file)-sha256sum.txt $(butane_binary_url_sha256sum) && cs=`sha256sum $@` && grep -q "$$cs" $(butane_binary_file)-sha256sum.txt || { echo [ABA] "Error: file $@ checksum invalid!"; exit 1; }
	echo [ABA] "File $@ checksum valid!"


########################################
.PHONY: clean 
clean: ## Clean up installed binaries
	@../scripts/cli-install-all.sh --reset
	@rm -f ~/bin/{oc,kubectl,oc-mirror,openshift-install,govc,butane} *sha256sum.txt
#	This should be just: run_once -r -i "cli:install" # to reset all downloads in cli dir

.PHONY: reset
reset: clean # Clean up everything. Only use if you know what you are doing!
	@../scripts/cli-download-all.sh --reset
	@rm -f *.tar.gz .init butane* #.*-download
#	bash -lc 'source ../scripts/include_all.sh; run_once -r -i "download_all_cli"'
#	This should be just: run_once -r -i "cli:download" # to reset all downloads in cli dir

