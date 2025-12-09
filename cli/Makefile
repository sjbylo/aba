# Makefile to download and install oc, openshift-install, oc-mirror and govc 

ifndef DEBUG_ABA
.SILENT:
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

govc_arch := $(arch)
ifeq ($(arch),aarch64)
	govc_arch := arm64
endif

# Include aba.conf if it exists
-include ../aba.conf
ocp_version := $(strip $(shell echo $(ocp_version)))

install: oc openshift-install oc-mirror govc butane

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
	touch .init

# aba.conf should never be missing!
../aba.conf:
	@echo "aba/aba.conf missing! Run 'aba' for interactive mode or read the README.md file on how to get started!"
	@exit 1

# The preference to download the oc CLI tar files is: rhel9, then rhel8 and then the generic tar file.

# See:
# https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/4.18.9/ 
# Example x86:
#openshift-client-linux-amd64-rhel9-4.18.9.tar.gz
#openshift-client-linux-amd64-rhel8-4.18.9.tar.gz
# Example ARM:
#openshift-client-linux-arm64-rhel8-4.18.9.tar.gz
#openshift-client-linux-arm64-rhel9-4.18.9.tar.gz

full_oc_tar_file	:= openshift-client-$(os)-$(ARCH)-$(rhel_ver)-$(ocp_version).tar.gz
full_oc_url		:= https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/$(full_oc_tar_file)

# Generic oc binary 
gen_oc_tar_file		:= openshift-client-$(os)-$(ocp_version).tar.gz
gen_oc_url		:= https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/$(gen_oc_tar_file)

rhel9_oc_tar_file	:= openshift-client-$(os)-$(ARCH)-rhel9-$(ocp_version).tar.gz
rhel9_oc_url      	:= https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/$(rhel9_oc_tar_file)

rhel8_oc_tar_file	:= openshift-client-$(os)-$(ARCH)-rhel8-$(ocp_version).tar.gz
rhel8_oc_url		:= https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/$(rhel8_oc_tar_file)

# Download *all* the tar files that might be use in the disconnected env, both rhel9 and rhel8.
download: .$(rhel9_oc_tar_file)-download .$(rhel8_oc_tar_file)-download $(gen_oc_tar_file) openshift-install-$(os)-$(ocp_version).tar.gz oc-mirror.tar.gz oc-mirror.rhel9.tar.gz govc_Linux_$(govc_arch).tar.gz butane-binary


########################################
# Extract the oc file with priority for the rhel8/9 version, then the generic version (fallback)
oc: ~/bin/oc  ## Install oc into ~/bin
~/bin/oc: .init $(full_oc_tar_file)
#	@(file $(full_oc_tar_file) | grep -q "gzip compressed data" && echo Extracting $(full_oc_tar_file) to ~/bin/oc ... && tar -C ~/bin -xmzf $(full_oc_tar_file) oc kubectl) || (file $(gen_oc_tar_file) | grep -q "gzip compressed data" && echo Extracting $(gen_oc_tar_file) to ~/bin/oc ... 
	file $(full_oc_tar_file) | grep -q "gzip compressed data"
	@echo Extracting $(full_oc_tar_file) to ~/bin/oc ... 
	tar -C ~/bin -xmzf $(full_oc_tar_file) oc kubectl || { echo Extracting $(gen_oc_tar_file) instead to ~/bin/oc ...; tar -C ~/bin -xmzf $(gen_oc_tar_file) oc kubectl; } || { echo ERROR: Invalid files: $(full_oc_tar_file) or $(gen_oc_tar_file); exit 1; }
	~/bin/oc --help >/dev/null 2>&1

# Download just the oc tar files
octars: $(gen_oc_tar_file) .$(rhel9_oc_tar_file)-download .$(rhel8_oc_tar_file)-download

# Download
$(full_oc_tar_file):  ## Downlaod oc tarball for this hosts rhel version, otherwise download the fallback tarball.
#	@curl -sfkLI $(full_oc_url) >/dev/null && echo Downloading $(full_oc_url) ... && curl -f $(CURL_PROGRESS) -O -L $(full_oc_url) || (echo "Downloading fallback file $(gen_oc_url) ..."; curl $(CURL_PROGRESS) -O -L $(gen_oc_url))
	@curl -sfkLI $(full_oc_url) >/dev/null
	echo Downloading $(full_oc_url) ... 
	#curl -f $(CURL_PROGRESS) -O -L $(full_oc_url) || { echo "Downloading fallback file $(gen_oc_url) ..."; curl -f $(CURL_PROGRESS) -O -L $(gen_oc_url); }
	curl -f $(CURL_PROGRESS) -O -L $(full_oc_url) || make -s $(gen_oc_tar_file)
	tar tzvf $(full_oc_tar_file) >/dev/null || { rm -f $(full_oc_tar_file); exit 1; }
	echo "File $(full_oc_tar_file) is valid!"  # Be sure it's valid
	touch $(full_oc_tar_file)

# Download
$(gen_oc_tar_file):  ## Downlaod fallback oc tarball, if available
	@curl -sfkLI $(gen_oc_url) >/dev/null 
	echo Downloading $(gen_oc_url) ... 
	curl -f $(CURL_PROGRESS) -O -L $(gen_oc_url) || { echo $(gen_oc_tar_file) failed download; > $(gen_oc_tar_file); }
	[ -s $(gen_oc_tar_file) ]
	tar tvzf $(gen_oc_tar_file) >/dev/null || { rm -f $(gen_oc_tar_file); exit 1; }  # Validate tar file!
	echo "File $(gen_oc_tar_file) is valid!"  # Be sure it's valid

# Ensure all possible tarballs are downloaded
.$(rhel9_oc_tar_file)-download:  ## Downlaod oc tarball for rhel9, if available
	curl -sfkLI $(rhel9_oc_url) >/dev/null # Check connection only
	echo Downloading $(rhel9_oc_url) ...
	curl -f $(CURL_PROGRESS) -OL $(rhel9_oc_url) || { echo $(rhel9_oc_tar_file) failed download; > $(rhel9_oc_tar_file); }
	tar tvzf $(rhel9_oc_tar_file) >/dev/null || { rm -f $(rhel9_oc_tar_file); exit 1; }  # Validate tar file!
	echo "File $(rhel9_oc_tar_file) is valid!"  # Be sure it's valid
	touch .$(rhel9_oc_tar_file)-download

# Ensure all possible tarballs are downloaded
.$(rhel8_oc_tar_file)-download:  ## Downlaod oc tarball for rhel8, if available
#	@curl -sfkLI $(rhel8_oc_url) >/dev/null && echo Downloading $(rhel8_oc_url) ... && curl -f $(CURL_PROGRESS) -OL $(rhel8_oc_url) || (echo $(rhel8_oc_tar_file) failed download; > $(rhel8_oc_tar_file))
	curl -sfkLI $(rhel8_oc_url) >/dev/null # Check connection only
	echo Downloading $(rhel8_oc_url) ...
	curl -f $(CURL_PROGRESS) -OL $(rhel8_oc_url) || { echo $(rhel8_oc_tar_file) failed download; > $(rhel8_oc_tar_file); }
	tar tvzf $(rhel8_oc_tar_file) >/dev/null || { rm -f $(rhel8_oc_tar_file); exit 1; }  # Validate tar file!
	echo "File $(rhel8_oc_tar_file) is valid!"  # Be sure it's valid
	touch .$(rhel8_oc_tar_file)-download 


########################################
# Be sure that the correct version is installed by creating .*installed flag file

openshift-install: ~/bin/openshift-install ## Install openshift-install into ~/bin
~/bin/openshift-install: .init .$(ocp_version)-openshift-install-$(os)-installed
	@file openshift-install-$(os)-$(ocp_version).tar.gz | grep -q "gzip compressed data" || { echo ERROR: Invalid file: openshift-install-$(os)-$(ocp_version).tar.gz; exit 1;}
	@echo Extracting  openshift-install-$(os)-$(ocp_version).tar.gz to ~/bin/openshift-install
	tar -C ~/bin -xmzf openshift-install-$(os)-$(ocp_version).tar.gz openshift-install
	~/bin/openshift-install --help >/dev/null 2>&1

.$(ocp_version)-openshift-install-$(os)-installed: openshift-install-$(os)-$(ocp_version).tar.gz
	@rm -f .??*-openshift-install-$(os)-installed
	@touch .$(ocp_version)-openshift-install-$(os)-installed 

openshift-install-$(os)-$(ocp_version).tar.gz:  ## Download openshift-install tarball
	@echo Downloading https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/openshift-install-$(os)-$(ocp_version).tar.gz
	curl -f --retry 8 $(CURL_PROGRESS) -OL https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/openshift-install-$(os)-$(ocp_version).tar.gz
	file openshift-install-$(os)-$(ocp_version).tar.gz | grep -q "gzip compressed data" || { rm -f openshift-install-$(os)-$(ocp_version).tar.gz; exit 1; } # in case of 5xx errors!
	tar tvf openshift-install-$(os)-$(ocp_version).tar.gz >/dev/null|| { rm -f openshift-install-$(os)-$(ocp_version).tar.gz; exit 1; } # in case of 5xx errors!  # Be sure it's valid
	echo "File openshift-install-$(os)-$(ocp_version).tar.gz is valid!"


########################################
oc-mirror: ~/bin/oc-mirror  ## Install oc-mirror into ~/bin
~/bin/oc-mirror: .init oc-mirror.tar.gz oc-mirror.rhel9.tar.gz # ~/bin/oc # is this really needed for oc-mirror - no!
	@echo $(os_ver) | grep -q "^9\." && echo Extracting oc-mirror.rhel9.tar.gz to ~/bin/oc-mirror || echo Extracting oc-mirror.tar.gz to ~/bin/oc-mirror
	@echo $(os_ver) | grep -q "^9\." && tar -C ~/bin -xmzf oc-mirror.rhel9.tar.gz oc-mirror || tar -C ~/bin -xmzf oc-mirror.tar.gz oc-mirror
	chmod +x ~/bin/oc-mirror
	~/bin/oc-mirror --help >/dev/null 2>&1

# Check here for any updated versions: https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/ 

oc_mirror_url = https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/latest/oc-mirror.tar.gz
oc-mirror.tar.gz: ## Download oc-mirror tarball
	echo Downloading $(oc_mirror_url)
	curl -f --retry 8 $(CURL_PROGRESS) -OL $(oc_mirror_url)
	file oc-mirror.tar.gz | grep -q "gzip compressed data" || { rm -f oc-mirror.tar.gz; exit 1; } # in case of 5xx errors!
	tar tvf oc-mirror.tar.gz >/dev/null|| { rm -f oc-mirror.tar.gz; exit 1; } # in case of 5xx errors!  # Be sure it's valid
	echo "File oc-mirror.tar.gz is valid!"

oc_mirror_url_rhel9 = https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/latest/oc-mirror.rhel9.tar.gz
oc-mirror.rhel9.tar.gz: ## Download oc-mirror tarball for rhel9
	echo Downloading $(oc_mirror_url_rhel9)
	curl -f --retry 8 $(CURL_PROGRESS) -OL $(oc_mirror_url_rhel9)
	file oc-mirror.rhel9.tar.gz | grep -q "gzip compressed data" || { rm -f oc-mirror.rhel9.tar.gz; exit 1; } # in case of 5xx errors!
	tar tvf oc-mirror.rhel9.tar.gz >/dev/null|| { rm -f oc-mirror.rhel9.tar.gz; exit 1; } # in case of 5xx errors!  # Be sure it's valid
	echo "File oc-mirror.rhel9.tar.gz is valid!"


########################################
# Use either x86_64 or arm64 
govc: ~/bin/govc  ## Install govc to ~/bin/govc
~/bin/govc: .init govc_Linux_$(govc_arch).tar.gz
	@echo Extracting govc_Linux_$(govc_arch).tar.gz to ~/bin/govc
	tar -C ~/bin -xmzf govc_Linux_$(govc_arch).tar.gz govc
	~/bin/govc --help >/dev/null 2>&1

govc_Linux_$(govc_arch).tar.gz:   ## Download govc tarball
	echo Downloading https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_$(govc_arch).tar.gz
	curl --retry 8 -f $(CURL_PROGRESS) -L -O "https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_$(govc_arch).tar.gz"
	file govc_Linux_$(govc_arch).tar.gz | grep -q "gzip compressed data" || { rm -f govc_Linux_$(govc_arch).tar.gz; exit 1; } # in case of 5xx errors!
	tar tvf govc_Linux_$(govc_arch).tar.gz >/dev/null|| { rm -f govc_Linux_$(govc_arch).tar.gz; exit 1; } # in case of 5xx errors!  # Be sure it's valid
	echo "File govc_Linux_$(govc_arch).tar.gz is valid!"

# Use either amd64 or aarch64 
butane: ~/bin/butane ## Install butane to ~/bin/butane
~/bin/butane: butane-binary
	@echo Copying butane-binary to ~/bin/butane
	cp butane-binary ~/bin/butane
	chmod +x ~/bin/butane
	~/bin/butane --help >/dev/null 2>&1  # Be sure it's valid

butane-binary: ## Download butane binary 
	echo Downloading https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest/butane-$(butane_arch)
	curl -f --retry 8 $(CURL_PROGRESS) -f -L -o butane-binary --connect-timeout 30 https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest/butane-$(butane_arch)
	chmod +x butane-binary
	file butane-binary | grep -q -e "executable" -e "dynamically linked" || { rm -f butane-binary; exit 1; } # in case of 5xx errors!
	./butane-binary --help >/dev/null 2>&1  # Be sure it's valid
	echo "File butane-binary is valid!"


########################################
.PHONY: clean 
clean: ## Clean up installed binaries
	rm -f ~/bin/{oc,kubectl,oc-mirror,openshift-install,govc,butane} .*installed

.PHONY: reset
reset: clean # Clean up everything. Only use if you know what you are doing!
	rm -f *.tar.gz .init butane-binary .*-download

