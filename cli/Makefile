# Makefile to download and install oc, openshift-install, oc-mirror and govc 

.PHONY: clean distclean

ocp_target_ver  := $(shell cat ../target-ocp-version.conf)

all: ../target-ocp-version.conf ~/bin ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror ~/bin/govc

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.init:
	mkdir ~/bin

#~/bin:
#	mkdir ~/bin

../target-ocp-version.conf:
	../aba

########################################
# oc
~/bin/oc: .init openshift-client-linux-$(ocp_target_ver).tar.gz                                           ## Install oc into ~/bin
	tar -C ~/bin -xmzf openshift-client-linux-$(ocp_target_ver).tar.gz oc

openshift-client-linux-$(ocp_target_ver).tar.gz:                                           ## Downlaod oc tarball 
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_target_ver)/openshift-client-linux-$(ocp_target_ver).tar.gz


########################################
# openshift-install
~/bin/openshift-install: .init openshift-install-linux-$(ocp_target_ver).tar.gz                ## Install openshift-install into ~/bin
	tar -C ~/bin -xmzf openshift-install-linux-$(ocp_target_ver).tar.gz openshift-install

openshift-install-linux-$(ocp_target_ver).tar.gz:                                           ## Download openshift-install tarball
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_target_ver)/openshift-install-linux-$(ocp_target_ver).tar.gz


########################################
# oc-mirror
~/bin/oc-mirror: .init oc-mirror.tar.gz ~/bin/oc                                                ## Install oc-mirror into ~/bin
	tar -C ~/bin -xmzf oc-mirror.tar.gz oc-mirror
	chmod +x ~/bin/oc-mirror

oc-mirror.tar.gz: ## Download oc-mirror tarball
	#curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_target_ver)/oc-mirror.tar.gz
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/4.14.8/oc-mirror.tar.gz   # This has bug fixes 


########################################
# Govc
~/bin/govc: .init                                           ## Install govc into ~/bin
	tar -C ~/bin -xmzf govc_Linux_x86_64.tar.gz govc

govc_Linux_x86_64.tar.gz:                                           ## Download govc tarball
	curl -sL -O "https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz"


clean: ## Clean up installed binaries
	rm -f ~/bin/{oc,oc-mirror,openshift-install,govc} 

distclean: clean ## Clean up everything
	rm -f *.tar.gz

