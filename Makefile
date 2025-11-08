# Top level Makefile  # DO NOT remove this line!

# Make! Be silent, unless in debug mode
ifndef DEBUG_ABA
.SILENT:
endif

TEMPLATES = templates
SCRIPTS   = scripts
name     ?= standard
type     ?= standard

.PHONY: aba
aba:  ## Run aba in interactive mode, to set up 'aba.conf'
	aba --interactive

aba.conf:
	aba

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  aba \033[36mcommand\033[0m\n"} /^(\s|[a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

init: aba .init
.init: 
	@make -sC mirror rpms

###vmw: vmware.conf  ## Configure and use vSphere or ESXi to install OpenShift
###vmware.conf:
.PHONY: vmw
vmw:
	@make -sC cli govc
	$(SCRIPTS)/install-vmware.conf.sh

cli:  ## Download and install the CLI binaries into ~/bin
	@make -sC cli

download:  ## Download all required CLI install files without installing. 
	@make -sC cli download

#.PHONY: install
#mirror: install
#install: ## Set up the registry as per the settings in aba/mirror/mirror.conf. Place credential file(s) into aba/mirror/regcreds/ for existing registry.  See README.md.
#	@make -sC mirror install

#uninstall: ## Uninstall any previously installed mirror registry  
#	@make -sC mirror uninstall

.PHONY: catalog
# -s needed here 'cos the download runs in the background (called by aba) and we don't want any output
catalog: ## Render all the latest Operators into a helper file which can be used in an imageset config file. 
	@make -sC cli oc-mirror >/dev/null 2>&1
	@make -C mirror catalog bg=$(bg)

# These are the targets needed to create the 'bundle' archive
.PHONY: bundle
# Note: '@' used to ensure tar format is not corrupted when using out=-
bundle:  ## Create an install bundle to be tranferred into the air-gapped env. Example: aba bundle --out /path/to/archive/bundle or -
	@$(SCRIPTS)/make-bundle.sh $(out) $(force)

.PHONY: tar
tar:  ## Archive the full repo, e.g. aba tar --out /dev/path/to/thumbdrive. Default output is /tmp/aba-backup.tar. Use --out - to send tar output to stdout. Used by aba bundle.
	$(SCRIPTS)/backup.sh $(out)

# Note, the '@' is required for valid tar format output!
.PHONY: tarrepo
tarrepo:  ## Archive the full repo *excluding* the aba/mirror/mirror_*.tar files. Works in the same way as 'aba tar'.
	@$(SCRIPTS)/backup.sh --repo $(out)

#FIXME: Needed?
.PHONY: inc
inc:  ## (Deprecated) Create an incremental archive of the repo. The incremental files to include are based on the timestamp of the file ~/.aba.previous.backup. Works in the same way as 'aba tar'.
	$(SCRIPTS)/backup.sh --inc $(out)

.PHONY: save
save:
	@echo "Run: aba -d mirror save"

.PHONY: load
load:
	@echo "Run: aba -d mirror load"

.PHONY: sync
sync:
	@echo "Run: aba -d mirror sync"

.PHONY: verify
verify:
	@echo "Run: aba -d mirror verify"

#.PHONY: sno
#sno: aba.conf  ## (deprecated) Install a Single Node OpenShift cluster.  Use 'aba sno --step iso' to create the iso.
#	$(SCRIPTS)/setup-cluster.sh name=$@ type=$@ target=$(target) starting_ip=$(starting_ip) ports=$(ports) ingress_vip=$(ingress_vip) int_connection=$(int_connection) master_cpu_count=$(master_cpu_count) master_mem=$(master_mem) worker_cpu_count=$(worker_cpu_count) worker_mem=$(worker_mem) data_disk=$(data_disk) api_vip=$(api_vip)

#.PHONY: compact
#compact: aba.conf  ## (deprecated) Install a standard 3-node OpenShift cluster.  Use 'aba compact --step iso' to create the iso.
#	$(SCRIPTS)/setup-cluster.sh name=$@ type=$@ target=$(target) starting_ip=$(starting_ip) ports=$(ports) ingress_vip=$(ingress_vip) int_connection=$(int_connection) master_cpu_count=$(master_cpu_count) master_mem=$(master_mem) worker_cpu_count=$(worker_cpu_count) worker_mem=$(worker_mem) data_disk=$(data_disk) api_vip=$(api_vip)

#.PHONY: standard
#standard: aba.conf  ## (deprecated) Install a standard 3+3-node OpenShift cluster.  Use 'aba standard --step iso' to create the iso.
#	$(SCRIPTS)/setup-cluster.sh name=$@ type=$@ target=$(target) starting_ip=$(starting_ip) ports=$(ports) ingress_vip=$(ingress_vip) int_connection=$(int_connection) master_cpu_count=$(master_cpu_count) master_mem=$(master_mem) worker_cpu_count=$(worker_cpu_count) worker_mem=$(worker_mem) data_disk=$(data_disk) api_vip=$(api_vip)

.PHONY: cluster
cluster:  aba.conf  ## Initialize install dir and install OpenShift with your optional choice of topology (type), e.g. aba cluster --name mycluster [--type sno|compact|standard] [--step <step>] [--starting-ip <ip>] [--api-vip <ip>] [--ingress-vip <ip>] [--int-connection <proxy|direct>]
	$(SCRIPTS)/setup-cluster.sh name=$(name) type=$(type) target=$(target) starting_ip=$(starting_ip) ports=$(ports) ingress_vip=$(ingress_vip) int_connection=$(int_connection) master_cpu_count=$(master_cpu_count) master_mem=$(master_mem) worker_cpu_count=$(worker_cpu_count) worker_mem=$(worker_mem) data_disk=$(data_disk) api_vip=$(api_vip)

#FIXME: Remove?
.PHONY: ask
ask: ## Automatically accept the default answer to all prompts. Set 'ask' in aba.conf to 'true'.
	@[ ! -s aba.conf ] && cp templates/aba.conf . || true
	@[ -s aba.conf ] && sed -i "s/^ask=.*/ask=true/g" aba.conf && echo value ask has been set to true in aba.conf.
.PHONY: setask
setask: ask

#FIXME: Remove?
.PHONY: noask
noask:  ## Always prompt.  Set 'ask' in aba.conf to 'false'
	@[ ! -s aba.conf ] && cp templates/aba.conf . || true
	@[ -s aba.conf ] && sed -i "s/^ask=.*/ask=false/g" aba.conf && echo value ask has been set to false in aba.conf.
.PHONY: setnoask
setnoask: noask

.PHONY: clean
clean: ## Clean up all temporary files.
	make -sC mirror clean 
	make -sC test clean 
	rm -f ~/.aba.previous.backup
	rm -f ~/.aba.conf.created
	rm -f .aba.conf.seen

.PHONY: reset
reset: # Clean up *everything*.  Only use if you know what you are doing! Note that this does not run 'aba uninstall' to uninstall the mirror.
	$(SCRIPTS)/reset-gate.sh $(force)
	make clean
	test -f vmware.conf && mv vmware.conf vmware.conf.bk || true
	test -f aba.conf && mv aba.conf aba.conf.bk || true
	make -sC cli reset
	make -sC mirror reset 
	rm -f aba.conf ~/.aba.conf*

