# No file exists to check timestamps
.PHONY: all cli clean mirror install sync sno save load test

TEMPLATES = templates
SCRIPTS   = scripts
ocp_target_ver   ?= 4.13.19
d        ?= 
DEBUG     = $d
#version  ?= 4.14.2
version := $(shell $(SCRIPTS)/fetch-ocp-stable-version.sh)

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

#all: cli mirror ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror

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

load: ## Load images from the local filesystem to the Quay mirror registry
	make -C mirror load

sno:  ## Install Single Node OpenShift
	mkdir -p sno
	ln -fs ../$(TEMPLATES)/Makefile sno/Makefile
	make -C sno

compact:  ## Install a compact 3-node OpenShift cluster 
	mkdir -p compact
	ln -fs ../$(TEMPLATES)/Makefile compact/Makefile
	make -C compact

standard:  ## Install a standard 3+2-node OpenShift cluster 
	mkdir -p standard
	ln -fs ../$(TEMPLATES)/Makefile standard/Makefile
	make -C standard

ocp:
	[ ! "$(dir)" ] && echo "Must specify dir=newdir, e.g. make ocp dir=mycluster" && exit 1
	mkdir -p $(dir)
	ln -fs templates/Makefile $(dir)/Makefile
	ln -fs ../templates $(dir)
	cp test/aba-sno.conf $(dir)/aba.conf
	make -C $(dir) 

test:
	scripts/test.sh

clean:
	make -C mirror clean 
	make -C cli clean 

distclean:
	make -C mirror distclean 
	make -C cli distclean 
	rm -rf sno compact standard 
	rm *.conf 

