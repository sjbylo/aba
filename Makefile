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
	./aba

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

.PHONY: sync
sync: ## Sync images from the Internet directly to an internal registry (as defined in 'mirror/mirror.conf')
	make -C mirror sync

.PHONY: save
save: ## Save images from the Internet to mirror/save. 
	make -C mirror save 

.PHONY: tidy
tidy:
	make -C mirror tidy

.PHONY: tar
tar:  ## Archive the full repo, e.g. make tar out=/dev/path/to/thumbdrive. Default output is /tmp/aba-backup.tar. Use out=- to send tar output to stdout.
	@scripts/backup.sh $(out)

.PHONY: tarrepo
tarrepo:  ## Archive the full repo *excluding* the mirror/mirror_seq*tar files. Works in the same way as 'make tar'.
	@scripts/backup.sh --repo $(out)

.PHONY: inc
inc:  ## Create an incremental archive of the repo. The incremental files to include are based on the timestamp of the file ~/.aba.previous.backup. Works in the same way as 'make tar'.
	@scripts/backup.sh --inc $(out)

## .PHONY: increpo
## increpo:  ## Create an incremental archive of the repo, e.g. make inc out=/dev/path/to/thumbdrive.  Default output is /tmp/aba-backup.tar. Can also use out=- to send tar data to stdout.  The incremental files to include are based on the timestamp of the file ~/.aba.previous.backup
## 	@scripts/backup.sh --inc --repo $(out)

.PHONY: load
load: ## Load the saved images into a registry on the internal bastion (as defined in 'mirror/mirror.conf') 
	make -C mirror load

.PHONY: sno
sno:  ## Install a standard 3+2-node OpenShift cluster 
	@scripts/create-cluster-conf.sh $@

.PHONY: compact
compact:  ## Install a standard 3+2-node OpenShift cluster 
	@scripts/create-cluster-conf.sh $@

.PHONY: standard
standard:  ## Install a standard 3+2-node OpenShift cluster 
	@scripts/create-cluster-conf.sh $@

.PHONY: cluster
cluster: ## Install an OpenShift cluster with your choice of topology, e.g. make cluster name=mycluster 
	@scripts/create-cluster-conf.sh $(name)

.PHONY: rsync
rsync:  ## Copy (rsync) all required files to internal bastion for testing purposes only.  ip=hostname is required. 
	scripts/test-airgapped.sh $(ip)

.PHONY: clean
clean: ## Clean up 
	make -C mirror clean 
	make -C test clean 
	rm -f ~/.aba.previous.backup

.PHONY: distclean
distclean: clean ## Clean up *everything*
	rm -f vmware.conf
	make -C mirror distclean 
	make -C cli distclean 
	rm -rf sno compact standard 

