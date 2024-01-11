# No file exists to check timestamps
.PHONY: all cli clean mirror install sync sno save load test

TEMPLATES = templates
SCRIPTS   = scripts
ocp_target_ver   ?= 4.13.19
d        ?= 
DEBUG     = $d
dir    ?= /tmp

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

#all: cli mirror ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror

vmw: vmware.conf
vmware.conf:
	scripts/install-vmware.conf.sh

cli:
	make -C cli

##mirror:
##	#mkdir -p mirror
##	echo ocp_target_ver=$(ocp_target_ver) > mirror/openshift-version.conf

install: ## Install Quay mirror registry 
	make -C mirror install

uninstall: ## Uninstall Quay mirror registry 
	make -C mirror uninstall

sync: ## Synchonrise images from Red Hat's public registry to the Quay mirror registry 
	make -C mirror sync

save: ## Save images from Red Hat's public registry to the local filesystem
	make -C mirror save 

.PHONY: tidy
tidy:
	make -C mirror tidy

.PHONY: tar
tar: tidy  ## Tar the repo to move to internet network, e.g. make tar dir=/dev/path/to/thumbdrive.  Default dir is /tmp.
	scripts/create-tarball.sh $(dir)

#tar: ## Tar up the aba repo, ready to move to the internet network
	#make -C mirror tar 

load: ## Load images from the local filesystem to the Quay mirror registry
	make -C mirror load

sno:  ## Install Single Node OpenShift
	mkdir -p sno
	ln -fs ../$(TEMPLATES)/Makefile sno/Makefile
	cp $(TEMPLATES)/aba-sno.conf sno/aba.conf
	make -C sno

compact:  ## Install a compact 3-node OpenShift cluster 
	mkdir -p compact
	ln -fs ../$(TEMPLATES)/Makefile compact/Makefile
	cp $(TEMPLATES)/aba-compact.conf compact/aba.conf
	make -C compact

standard:  ## Install a standard 3+2-node OpenShift cluster 
	mkdir -p standard
	ln -fs ../$(TEMPLATES)/Makefile standard/Makefile
	cp $(TEMPLATES)/aba-standard.conf standard/aba.conf
	make -C standard

cluster: ## Install a cluster 
	scripts/setup-cluster.sh $(name) 

test:
	scripts/test.sh

clean:
	rm -f vmware.conf target-ocp-version.conf
	make -C mirror clean 
	make -C cli clean 

distclean:
	make -C mirror distclean 
	make -C cli distclean 
	rm -rf sno compact standard 
	rm *.conf 

