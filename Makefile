# No file exists to check timestamps
.PHONY: all cli clean mirror install sync sno save load test

TEMPLATES = templates
SCRIPTS   = scripts
ocp_target_ver   ?= 4.13.19
d        ?= 
DEBUG     = $d
out    ?= /tmp

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

#all: cli mirror ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror

.PHONY: aba
aba:
	./aba

init: aba .init
.init: 
	# Installing/checking needed packages
	sudo dnf install podman make jq bind-utils nmstate net-tools skopeo python3 python3-jinja2 python3-pyyaml openssl -y >> .dnf-install.log 2>&1

vmw: vmware.conf
vmware.conf:
	scripts/install-vmware.conf.sh

cli:
	make -C cli

##mirror:
##	#mkdir -p mirror
##	echo ocp_target_ver=$(ocp_target_ver) > mirror/openshift-version.conf

install: ## Set up the registry as per the settings in mirror/mirror.conf. Place credential file(s) into mirror/regcreds/ for existing registry.  See README.md.
	make -C mirror install

uninstall: ## Uninstall any previously installed registry  
	make -C mirror uninstall

sync: ## Sync images from the Internet directly to an internal registry (as defined in 'mirror/mirror.conf')
	make -C mirror sync

save: ## Save images from the Internet to mirror/save. 
	make -C mirror save 

.PHONY: tidy
tidy:
	make -C mirror tidy

.PHONY: tar
tar:  ## Tar the repo to move to internal network, e.g. make tar out=/dev/path/to/thumbdrive.  Default output is /tmp/aba-repo.tgz
	scripts/create-tarball.sh $(out)

#tar: ## Tar up the aba repo, ready to move to the internet network
	#make -C mirror tar 

load: ## Load the saved images into a registry on the internal bastion (as defined in 'mirror/mirror.conf') 
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

cluster: ## Install a cluster with your choice of topology, e.g. make cluster name=mycluster 
	scripts/setup-cluster.sh $(name) 

.PHONY: rsync
rsync:  ## Copy (rsync) all required files to internal bastion for testing purposes only.  ip=hostname is required. 
	scripts/test-airgapped.sh $(ip)

clean:
	rm -f vmware.conf target-ocp-version.conf
	make -C mirror clean 
	make -C cli clean 

distclean: uninstall 
	make -C mirror distclean 
	make -C cli distclean 
	rm -rf sno compact standard 
	rm -f *.conf 

