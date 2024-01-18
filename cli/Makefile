# No file exists to check timestamps
.PHONY: all clean distclean

ocp_target_ver  := $(shell cat ../target-ocp-version.conf)

all: ../target-ocp-version.conf ~/bin ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror ~/bin/govc

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

~/bin:
	mkdir ~/bin

../target-ocp-version.conf:
	../aba

# oc
~/bin/oc: ~/bin openshift-client-linux-$(ocp_target_ver).tar.gz ## Install oc into ~/bin
	tar -C ~/bin -xmzf openshift-client-linux-$(ocp_target_ver).tar.gz oc

openshift-client-linux-$(ocp_target_ver).tar.gz: ## Downlaod oc tarball 
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_target_ver)/openshift-client-linux-$(ocp_target_ver).tar.gz


# openshift-install
~/bin/openshift-install: ~/bin openshift-install-linux-$(ocp_target_ver).tar.gz  ## Install openshift-install into ~/bin
	tar -C ~/bin -xmzf openshift-install-linux-$(ocp_target_ver).tar.gz openshift-install

openshift-install-linux-$(ocp_target_ver).tar.gz: ## Download openshift-install tarball
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_target_ver)/openshift-install-linux-$(ocp_target_ver).tar.gz


# oc-mirror
~/bin/oc-mirror: ~/bin oc-mirror.tar.gz ~/bin/oc ## Install oc-mirror into ~/bin
	tar -C ~/bin -xmzf oc-mirror.tar.gz oc-mirror
	chmod +x ~/bin/oc-mirror

oc-mirror.tar.gz: ## Download oc-mirror tarball
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_target_ver)/oc-mirror.tar.gz


~/bin/govc: ~/bin ## Install govc into ~/bin
	curl -sL -o - "https://github.com/vmware/govmomi/releases/latest/download/govc_`uname -s`_`uname -m`.tar.gz" | tar -C ~/bin -xvzf - govc

#~/.pull-secret.json:
#	$(SCRIPTS)/install-pull-secret.sh 

clean: ## Clean up installed binaries
	rm -f ~/bin/{oc,oc-mirror,openshift-install,govc} 

distclean: clean ## Clean up everything
	rm -f *.tar.gz

