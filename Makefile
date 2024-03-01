# No file exists to check timestamps
###.PHONY: all clean install sync sno save load test

TEMPLATES = templates
SCRIPTS   = scripts
ocp_target_ver   ?= 4.13.19
d        ?= 
DEBUG     = $d
out    ?= /tmp

.PHONY: aba
aba:
	scripts/aba.sh 

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

init: aba .init
.init: 
	make -C mirror rpms

vmw: vmware.conf  ## Configure and use vSphere or ESXi to install OpenShift
vmware.conf:
	scripts/install-vmware.conf.sh

cli:  ## Download and install the CLI binaries into ~/bin
	make -C cli

install: ## Set up the registry as per the settings in mirror/mirror.conf. Place credential file(s) into mirror/regcreds/ for existing registry.  See README.md.
	make -C mirror install

uninstall: ## Uninstall any previously installed mirror registry  
	make -C mirror uninstall

sync: ## Sync images from the Internet directly to an internal registry (as defined in 'mirror/mirror.conf')
	make -C mirror sync

save: ## Save images from the Internet to mirror/save. 
	make -C mirror save 

.PHONY: tidy
tidy:
	make -C mirror tidy

.PHONY: tar
tar:  ## Archive the whole repo in order to move it to the internal network, e.g. make tar out=/dev/path/to/thumbdrive.  Default output is /tmp/aba-repo.tgz. Can also use out=-
	@scripts/create-tarball.sh $(out)

.PHONY: inc
inc:  ## Create an incremental archive of the repo in order to move it to the internal network, e.g. make inc out=/dev/path/to/thumbdrive.  Default output is /tmp/aba-repo.tgz. Can also use out=-
	@scripts/inc-backup.sh $(out)

load: ## Load the saved images into a registry on the internal bastion (as defined in 'mirror/mirror.conf') 
	make -C mirror load


.PHONY: sno
sno:  ## Install Single Node OpenShift
	@mkdir sno || ( echo "Directory 'sno' already exists!" && exit 1 )
	@ln -fs ../$(TEMPLATES)/Makefile sno/Makefile
	@make -C sno init
	scripts/create-cluster-conf.sh sno
	@make -C sno $(target)

.PHONY: compact
compact:  ## Install a compact 3-node OpenShift cluster 
	@mkdir compact || ( echo "Directory 'compact' already exists!" && exit 1 )
	@ln -fs ../$(TEMPLATES)/Makefile compact/Makefile
	@make -C compact init
	@scripts/create-cluster-conf.sh compact
	@make -C compact $(target)

.PHONY: standard
standard:  ## Install a standard 3+2-node OpenShift cluster 
	@mkdir standard || ( echo "Directory 'standard' already exists!" && exit 1 )
	@ln -fs ../$(TEMPLATES)/Makefile standard/Makefile
	@make -C standard init
	@scripts/create-cluster-conf.sh standard
	@make -C standard $(target)

.PHONY: cluster
cluster: ## Install an OpenShift cluster with your choice of topology, e.g. make cluster name=mycluster 
	scripts/setup-cluster.sh $(name) 

.PHONY: rsync
rsync:  ## Copy (rsync) all required files to internal bastion for testing purposes only.  ip=hostname is required. 
	scripts/test-airgapped.sh $(ip)

.PHONY: clean
clean: ## Clean up 
	make -C mirror clean 
	make -C cli clean 

.PHONY: distclean
distclean: uninstall ## Clean up *everything*
	rm -f vmware.conf target-ocp-version.conf
	make -C mirror distclean 
	make -C cli distclean 
	rm -rf sno compact standard 

