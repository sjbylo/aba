# Makefile to download and install oc, openshift-install, oc-mirror and govc 

.SILENT:

TEMPLATES = ../templates
SCRIPTS   = ../scripts

-include ../aba.conf
ocp_version := $(strip $(shell echo $(ocp_version)))

#all: ../aba.conf ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror ~/bin/govc
all:             ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror ~/bin/govc ~/bin/butane

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

download: openshift-client-linux-$(ocp_version).tar.gz openshift-install-linux-$(ocp_version).tar.gz oc-mirror.tar.gz oc-mirror.rhel9.tar.gz govc_Linux_x86_64.tar.gz butane-binary

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[\$\.\(\)\~\/a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

# Keep this like it is, otherwise the deps don't work!
.init:
	mkdir -p ~/bin
	touch .init

# aba.conf should never be missing!
../aba.conf:
	@echo "aba.conf missing! Please read the README on how to get started!"
	@exit 1

#../aba.conf:
#	@#../aba --version latest
#	@# This is only needed becase it gets executed for some reason
#	echo ocp_version=4.16.10 > ../aba.conf

# Be sure that the correct version is installed by creating .*installed flag file
########################################
#~/bin/oc: .init openshift-client-linux-$(ocp_version).tar.gz ## Install oc into ~/bin
~/bin/oc: .init .$(ocp_version)-openshift-client-linux-installed  ## Install oc into ~/bin
	tar -C ~/bin -xmzf openshift-client-linux-$(ocp_version).tar.gz oc kubectl

.$(ocp_version)-openshift-client-linux-installed: openshift-client-linux-$(ocp_version).tar.gz
	@rm -f .??*-openshift-client-linux-installed
	@touch .$(ocp_version)-openshift-client-linux-installed 

openshift-client-linux-$(ocp_version).tar.gz:  ## Downlaod oc tarball 
	echo Downlaoding openshift-client-linux-$(ocp_version).tar.gz
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_version)/openshift-client-linux-$(ocp_version).tar.gz


# Be sure that the correct version is installed by creating .*installed flag file
########################################
~/bin/openshift-install: .init .$(ocp_version)-openshift-install-linux-installed ## Install openshift-install into ~/bin
	tar -C ~/bin -xmzf openshift-install-linux-$(ocp_version).tar.gz openshift-install

.$(ocp_version)-openshift-install-linux-installed: openshift-install-linux-$(ocp_version).tar.gz
	@rm -f .??*-openshift-install-linux-installed
	@touch .$(ocp_version)-openshift-install-linux-installed 

openshift-install-linux-$(ocp_version).tar.gz:  ## Download openshift-install tarball
	echo Downlaoding openshift-install-linux-$(ocp_version).tar.gz
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_version)/openshift-install-linux-$(ocp_version).tar.gz

########################################
~/bin/oc-mirror: .init oc-mirror.tar.gz oc-mirror.rhel9.tar.gz ~/bin/oc   ## Install oc-mirror into ~/bin
	@grep -oP '(?<=VERSION_ID=")[^"]+' /etc/os-release | grep "^9\." && tar -C ~/bin -xmzf oc-mirror.rhel9.tar.gz oc-mirror || tar -C ~/bin -xmzf oc-mirror.tar.gz oc-mirror
	chmod +x ~/bin/oc-mirror

# Version 4.14 has bug fixes 
oc-mirror.tar.gz: ## Download oc-mirror tarball
	echo Downlaoding oc-mirror.tar.gz
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest/oc-mirror.tar.gz	

oc-mirror.rhel9.tar.gz: ## Download oc-mirror tarball for rhel9
	echo Downlaoding oc-mirror.rhel9.tar.gz
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest/oc-mirror.rhel9.tar.gz

########################################
~/bin/govc: .init govc_Linux_x86_64.tar.gz    ## Install govc into ~/bin
	tar -C ~/bin -xmzf govc_Linux_x86_64.tar.gz govc

govc_Linux_x86_64.tar.gz:   ## Download govc tarball
	echo Downlaoding govc_Linux_x86_64.tar.gz
	curl -sL -O "https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz"

~/bin/butane: butane-binary
	cp butane-binary ~/bin/butane
	chmod +x ~/bin/butane

butane-binary:
	curl -s --connect-timeout 10 --retry 3 https://mirror.openshift.com/pub/openshift-v4/clients/butane/latest/butane --output butane-binary


.PHONY: clean 
clean: ## Clean up installed binaries
	rm -f ~/bin/{oc,kubectl,oc-mirror,openshift-install,govc} .*installed

.PHONY: distclean
distclean: clean # Clean up everything. Only use if you know what you are doing!
	rm -f *.tar.gz .init

