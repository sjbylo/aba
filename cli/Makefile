# Makefile to download and install oc, openshift-install, oc-mirror and govc 

.SILENT:

TEMPLATES = ../templates
SCRIPTS   = ../scripts

os     := $(strip $(shell uname -o))
arch   := $(strip $(shell uname -m))
os_ver := $(strip $(shell grep '^VERSION_ID=' /etc/os-release | cut -d '=' -f2 | tr -d '"' | grep -o -E "[0-9]+\.[0-9]+"))

# Check and set default version 'os_ver' variable, e.g. if Fedora version 40, then we want to convert "40" to 9.x
ifeq ($(os_ver),)
	os_ver := 9.4
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

#ifneq ($(filter distclean,$(MAKECMDGOALS)),)

# Include aba.conf if it exists
-include ../aba.conf
ocp_version := $(strip $(shell echo $(ocp_version)))

#endif

#all:             ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror ~/bin/govc ~/bin/butane
all:             oc openshift-install oc-mirror govc butane

test:
	echo os_ver=$(os_ver)
	$(abort)

# If 'distclean' found in $MAKECMDGOALS, i.e. no distclean provided
ifneq ($(filter distclean,$(MAKECMDGOALS)),)
  # distclean not given
else
  ifeq ($(ocp_version),)
    # ocp_version is empty!
    $(error "Value ocp_version not set in aba.conf!  Please set ocp_version in aba.conf and try again. Read the README on how to get started!")
#  else
#    # ocp_version ok
#    $(warning "MAKECMDGOALS = $(MAKECMDGOALS)")
  endif
endif

#download: openshift-client-$(os)-amd64-rhel8-$(ocp_version).tar.gz openshift-client-$(os)-amd64-rhel9-$(ocp_version).tar.gz openshift-client-$(os)-$(ocp_version).tar.gz openshift-install-$(os)-$(ocp_version).tar.gz oc-mirror.tar.gz oc-mirror.rhel9.tar.gz govc_Linux_x86_64.tar.gz butane-binary

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
	@echo "aba.conf missing! Please read the README on how to get started!"
	@exit 1

########################################

#SB oc: ~/bin/oc  ## Install oc into ~/bin
#SB # This will fall back on the older versions of oc without the 'amd64-rhel8'
#SB ~/bin/oc: .init .$(ocp_version)-openshift-client-$(os)-amd64-$(rhel_ver)-installed
# TIDY UP 	@echo Extracting openshift-client-$(os)-amd64-$(rhel_ver)-$(ocp_version).tar.gz to ~/bin/oc
# TIDY UP 	tar -C ~/bin -xmzf openshift-client-$(os)-amd64-$(rhel_ver)-$(ocp_version).tar.gz oc kubectl || tar -C ~/bin -xmzf openshift-client-$(os)-$(ocp_version).tar.gz oc kubectl
# TIDY UP 
# TIDY UP .$(ocp_version)-openshift-client-$(os)-amd64-$(rhel_ver)-installed: openshift-client-$(os)-amd64-$(rhel_ver)-$(ocp_version).tar.gz
# TIDY UP 	@rm -f .??*-openshift-client-$(os)-amd64-$(rhel_ver)-installed
# TIDY UP 	@touch .$(ocp_version)-openshift-client-$(os)-amd64-$(rhel_ver)-installed 
# TIDY UP 

# The preference to download the oc tar files is for rhel9, then rhel8 and then the generic taer file.

oc_tar_file       := openshift-client-$(os)-amd64-$(rhel_ver)-$(ocp_version).tar.gz
oc_url            := https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/$(oc_tar_file)
rhel9_oc_tar_file := openshift-client-$(os)-amd64-rhel9-$(ocp_version).tar.gz
rhel8_oc_tar_file := openshift-client-$(os)-amd64-rhel8-$(ocp_version).tar.gz
rhel9_oc_url      := https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/$(rhel9_oc_tar_file)
rhel8_oc_url      := https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/$(rhel8_oc_tar_file)
gen_oc_tar_file   := openshift-client-$(os)-$(ocp_version).tar.gz
gen_url           := https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/$(gen_oc_tar_file)

download: $(rhel9_oc_tar_file) $(rhel8_oc_tar_file) $(gen_oc_tar_file) openshift-install-$(os)-$(ocp_version).tar.gz oc-mirror.tar.gz oc-mirror.rhel9.tar.gz govc_Linux_x86_64.tar.gz butane-binary

########################################
# Extract the oc file with priority on the rhel8/9 version, then the generic version
oc: ~/bin/oc  ## Install oc into ~/bin
~/bin/oc: .init $(gen_oc_tar_file)
	@echo Extracting $(oc_tar_file) or $(gen_oc_tar_file) to ~/bin/oc
	@tar -C ~/bin -xmzf $(oc_tar_file) oc kubectl 2>/dev/null || tar -C ~/bin -xmzf $(gen_oc_tar_file) oc kubectl

$(oc_tar_file):  ## Downlaod oc tarball for "this" host, otherwise the fallback tar file
	@echo Downlaoding $(oc_url) or $(gen_url) ...
	@curl -sfkLI $(oc_url) >/dev/null && curl --f --progress-bar -O -L $(oc_url) || (echo "Downloading fallback file $(gen_url) ..."; curl --progress-bar -O -L $(gen_url))
	touch $(oc_tar_file)

octars: $(gen_oc_tar_file) $(rhel9_oc_tar_file) $(rhel8_oc_tar_file)
$(gen_oc_tar_file):  ## Downlaod fallback oc tar file, if available
	@echo Downlaoding $(gen_url) ...
	@curl -sfkLI $(gen_url) >/dev/null && curl -f --progress-bar -O -L $(gen_url) || > $(gen_oc_tar_file)

# Ensure all possible tarballs are downloaded
$(rhel9_oc_tar_file):  ## Downlaod oc tarball for rhel9, if available
	@echo Downloading $(rhel9_oc_url)
	@curl -sfkLI $(rhel9_oc_url) >/dev/null && curl -f --progress-bar -OL $(rhel9_oc_url) || > $(rhel9_oc_tar_file)

# Ensure all possible tarballs are downloaded
$(rhel8_oc_tar_file):  ## Downlaod oc tarball for rhel8, if available
	@echo Downloading $(rhel8_oc_url)
	@curl -sfkLI $(rhel8_oc_url) >/dev/null && curl -f --progress-bar -OL $(rhel8_oc_url) || > $(rhel8_oc_tar_file)


########################################
# Be sure that the correct version is installed by creating .*installed flag file # FIXME as no need!

openshift-install: ~/bin/openshift-install
~/bin/openshift-install: .init .$(ocp_version)-openshift-install-$(os)-installed ## Install openshift-install into ~/bin
	@echo Extracting  openshift-install-$(os)-$(ocp_version).tar.gz to ~/bin/openshift-install
	tar -C ~/bin -xmzf openshift-install-$(os)-$(ocp_version).tar.gz openshift-install

.$(ocp_version)-openshift-install-$(os)-installed: openshift-install-$(os)-$(ocp_version).tar.gz
	@rm -f .??*-openshift-install-$(os)-installed
	@touch .$(ocp_version)-openshift-install-$(os)-installed 

openshift-install-$(os)-$(ocp_version).tar.gz:  ## Download openshift-install tarball
	@echo Downlaoding openshift-install-$(os)-$(ocp_version).tar.gz
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/$(ocp_version)/openshift-install-$(os)-$(ocp_version).tar.gz

########################################
oc-mirror: ~/bin/oc-mirror
~/bin/oc-mirror: .init oc-mirror.tar.gz oc-mirror.rhel9.tar.gz ~/bin/oc   ## Install oc-mirror into ~/bin
	@####grep -oP '(?<=VERSION_ID=")[^"]+' /etc/os-release | grep "^9\." && tar -C ~/bin -xmzf oc-mirror.rhel9.tar.gz oc-mirror || tar -C ~/bin -xmzf oc-mirror.tar.gz oc-mirror
	@echo Extracting oc-mirror.tar.gz to ~bin/oc-mirror
	@echo $(os_ver) | grep -q "^9\." && tar -C ~/bin -xmzf oc-mirror.rhel9.tar.gz oc-mirror || tar -C ~/bin -xmzf oc-mirror.tar.gz oc-mirror
	chmod +x ~/bin/oc-mirror

oc-mirror.tar.gz: ## Download oc-mirror tarball
	echo Downlaoding oc-mirror.tar.gz
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/latest/oc-mirror.tar.gz	

oc-mirror.rhel9.tar.gz: ## Download oc-mirror tarball for rhel9
	echo Downlaoding oc-mirror.rhel9.tar.gz
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/$(arch)/clients/ocp/latest/oc-mirror.rhel9.tar.gz

########################################
govc: ~/bin/govc
~/bin/govc: .init govc_Linux_x86_64.tar.gz    ## Install govc into ~/bin
	@echo Extracting govc_Linux_x86_64.tar.gz to ~/bin/govc
	tar -C ~/bin -xmzf govc_Linux_x86_64.tar.gz govc

govc_Linux_x86_64.tar.gz:   ## Download govc tarball
	echo Downlaoding govc_Linux_x86_64.tar.gz
	curl --progress-bar -sL -O "https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz"

butane: ~/bin/butane
~/bin/butane: butane-binary
	@echo Copying butane-binary to ~/bin/butane
	cp butane-binary ~/bin/butane
	chmod +x ~/bin/butane

butane-binary:
	curl -s --connect-timeout 10 --retry 3 https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest/butane --output butane-binary


.PHONY: clean 
clean: ## Clean up installed binaries
	rm -f ~/bin/{oc,kubectl,oc-mirror,openshift-install,govc,butane} .*installed

.PHONY: distclean
distclean: clean # Clean up everything. Only use if you know what you are doing!
	rm -f *.tar.gz .init butane-binary

