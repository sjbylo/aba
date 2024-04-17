# Makefile to download and install oc, openshift-install, oc-mirror and govc 

include ../aba.conf
ocp_version := $(strip $(shell echo $(ocp_version)))

all: vercheck ../aba.conf ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror ~/bin/govc

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[\$\.\(\)\~\/a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.init: vercheck
	mkdir -p ~/bin
	touch .init

../aba.conf:
	../aba

ifeq ($(ocp_version),)
	$(error "ocp_version is empty. Please set ocp_version in aba.conf before continuing.")
endif

.PHONY: vercheck
vercheck:
	@echo "ocp_version set to '$(ocp_version)'"

# Be sure that the correct version is installed by creating .*installed flag file
########################################
#~/bin/oc: .init openshift-client-linux-$(ocp_version).tar.gz ## Install oc into ~/bin
~/bin/oc: .init .$(ocp_version)-openshift-client-linux-installed  ## Install oc into ~/bin
	tar -C ~/bin -xmzf openshift-client-linux-$(ocp_version).tar.gz oc kubectl

.$(ocp_version)-openshift-client-linux-installed: openshift-client-linux-$(ocp_version).tar.gz
	@rm -f .??*-openshift-client-linux-installed
	@touch .$(ocp_version)-openshift-client-linux-installed 

openshift-client-linux-$(ocp_version).tar.gz:  ## Downlaod oc tarball 
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_version)/openshift-client-linux-$(ocp_version).tar.gz


# Be sure that the correct version is installed by creating .*installed flag file
########################################
~/bin/openshift-install: .init .$(ocp_version)-openshift-install-linux-installed ## Install openshift-install into ~/bin
	tar -C ~/bin -xmzf openshift-install-linux-$(ocp_version).tar.gz openshift-install

.$(ocp_version)-openshift-install-linux-installed: openshift-install-linux-$(ocp_version).tar.gz
	@rm -f .??*-openshift-install-linux-installed
	@touch .$(ocp_version)-openshift-install-linux-installed 

openshift-install-linux-$(ocp_version).tar.gz:  ## Download openshift-install tarball
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_version)/openshift-install-linux-$(ocp_version).tar.gz

########################################
~/bin/oc-mirror: .init oc-mirror.tar.gz ~/bin/oc   ## Install oc-mirror into ~/bin
	tar -C ~/bin -xmzf oc-mirror.tar.gz oc-mirror
	chmod +x ~/bin/oc-mirror

# Version 4.14 has bug fixes 
oc-mirror.tar.gz: ## Download oc-mirror tarball ver 4.14.9 or higher 
	# Installing oc-mirror version 4.14.9 or higher
	../scripts/output_ver_lower_4.14.9.sh $(ocp_version) && curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/4.14.9/oc-mirror.tar.gz || curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_version)/oc-mirror.tar.gz 

########################################
~/bin/govc: .init govc_Linux_x86_64.tar.gz    ## Install govc into ~/bin
	tar -C ~/bin -xmzf govc_Linux_x86_64.tar.gz govc

govc_Linux_x86_64.tar.gz:   ## Download govc tarball
	curl -sL -O "https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz"


.PHONY: clean 
clean: ## Clean up installed binaries
	rm -f ~/bin/{oc,kubectl,oc-mirror,openshift-install,govc} .*installed

.PHONY: distclean
distclean: clean ## Clean up everything
	rm -f *.tar.gz

