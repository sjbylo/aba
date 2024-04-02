EDITOR   ?= vi      		# Set vi or nano or you fav. editor
TEMPLATES = ../templates
SCRIPTS   = ../scripts
#cmd      ?= "get co"    # The default command
debug    ?= 		# Set debug=1 for some commands 

# The default target will build a cluster from scratch 
all: iso .autopoweroff .autoupload .autorefresh .finished login

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[\.a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

###.PHONY: init
init: .initialized
.initialized:
	@ln -fs ../templates
	@ln -fs ../scripts
	@ln -fs ../mirror
	@ln -fs ../aba.conf
	@touch .initialized
	@echo Initialized `pwd` successfully

mirror.conf: .initialized ## Set up the mirror.conf file.
	@ln -fs mirror/mirror.conf
	@touch mirror.conf
	@echo Using `pwd`/mirror.conf file 

vmware.conf: ## Use VMW vCenter or ESXi to create cluster.
	@test -f ../vmware.conf && ln -s ../vmware.conf || true

cluster.conf:  ## Set up the cluster.conf file.
	scripts/create-cluster-conf.sh $(name) $(type)

# Note that install-config.yaml can be configured with vSphere params (vmware.conf)
install-config.yaml: .initialized vmware.conf cluster.conf mirror.conf  ## Create the agent-based config file based on the cluster.conf file.
	scripts/create-install-config.sh $(debug)

agent-config.yaml: .initialized vmware.conf cluster.conf mirror.conf  ## Create the agent-based config file based on the cluster.conf file.
	scripts/create-agent-config.sh $(debug)

# The following "auto" targets are meant just for the full end-to-end automation, to build a cluster
iso: iso-agent-based/agent.x86_64.iso ## Build the agent-based iso file.
iso-agent-based/agent.x86_64.iso: install-config.yaml agent-config.yaml   # Note that install-config.yaml can itself be dependent on vmware.conf params
	scripts/generate-image.sh $(debug)

ntp: .ntp ## Use NTP time sync during early installation. Required only if underlying platform/hardware does not support time sync.
.ntp: iso-agent-based/agent.x86_64.iso
	@scripts/add_ntp_ignition_to_iso.sh $(debug) 
	@touch .ntp

.autopoweroff: .ntp
	@scripts/vmw-on.sh && scripts/vmw-kill.sh $(debug) || echo "VM(s) already powered off"
	@touch .autopoweroff

upload: .autoupload  ## Upload the ISO to the VMW platform to [Datastore] images/agent-<cluster-name>.iso
#.autoupload: vmware.conf .autorefresh
.autoupload: vmware.conf .autopoweroff
	@scripts/vmw-upload.sh $(debug) 
	@touch .autoupload

# The following targets are meant for interactive use only

# This target is a duplicate of .autorefresh below, except for the touch command.  It's for interactive use. 
.PHONY: refresh
refresh:  ## Delete & create the VMs. This will automatically start the cluster installation again which can be useful when your cluster is broken and you want to redeploy it.
	# Refreshing VMs
	@scripts/vmw-delete.sh $(debug) || true
	# Createing VMs
	@scripts/vmw-create.sh --start $(debug) 

.autorefresh: .initialized .autoupload vmware.conf 
	# Refreshing VMs
	@scripts/vmw-delete.sh $(debug) || true
	# Createing VMs
	@scripts/vmw-create.sh --start $(debug) 
	@touch .autorefresh

.PHONY: create
create: vmware.conf iso  ## Create the VMs based on the 'agent-based' config files. Use 'make start' to start them. 
	@scripts/vmw-exists.sh || scripts/vmw-create.sh $(debug) && exit 0

.PHONY: ls
ls: vmware.conf  ## List VMs and their power state.
	@scripts/vmw-ls.sh || echo "No vm(s).  Try 'make create'."

.PHONY: stop
stop: vmware.conf ## Shut down all VM guests gracefully. This will stop the cluster. Be warned that clusters don't always start up correctly again!
	@scripts/vmw-on.sh && scripts/vmw-stop.sh $(debug) || exit 0

.PHONY: start
start: vmware.conf ## Start all the VMs.
	@scripts/vmw-on.sh || scripts/vmw-start.sh $(debug) || exit 0

.PHONY: poweroff
poweroff: vmware.conf ## Power off the VMs immediately.  This will stop the cluster abruptly. 
	@scripts/vmw-on.sh && scripts/vmw-kill.sh $(debug) || exit 0

.PHONY: kill
kill:  vmware.conf ## Kill or power off the VMs immediately.  This will stop the cluster abruptly. 
	@scripts/vmw-on.sh && scripts/vmw-kill.sh $(debug) || exit 0

.PHONY: delete
delete: vmware.conf ## Delete the VMs. This will delete the cluster. 
	@scripts/vmw-delete.sh $(debug) || exit 0

.finished: .autorefresh
	@scripts/monitor-install.sh $(debug)
	@touch .finished

.PHONY: mon
mon:  ## Monitor the agent-based installation of OpenShift.
	@scripts/monitor-install.sh $(debug)
	@touch .finished

.PHONY: mon
login: .finished 
	@scripts/show-cluster-login.sh

.PHONY: getco
getco: ## Run 'oc get co' command on the cluster.
	oc --kubeconfig iso-agent-based/auth/kubeconfig get co

.PHONY: cmd
cmd: ## Run any oc command on the cluster, must provide command, e.g. cmd="oc get pods -A", default is 'oc get co'.
	@scripts/oc-command.sh $(cmd)

.PHONY: ssh
ssh: ## Open ssh to the rendezvous host for troubleshooting
	@scripts/ssh-rendezvous.sh $(cmd)

.PHONY: shell   
shell:  ## Access to the installed cluster. Run '. <(make shell)' or '. <(make -s shell)'
	@echo "export KUBECONFIG=$(PWD)/iso-agent-based/auth/kubeconfig"

.PHONY:
day2:  ## Set up OperatorHub, CatalogSources, imageContentSourcePolicy resources. Run this target every time new Operators are loaded into the mirror registry.
	@scripts/day2.sh $(debug)

.PHONY: vmw
vmw: ## Configure VMW platform credentials.
	@make -C .. vmware.conf

.PHONY: noask
noask:  ## Set 'ask' in aba.conf to 'false'
	@make -C .. noask

.PHONY: ask
ask: ## Set 'ask' in aba.conf to 'true'
	@make -C .. ask

.PHONY: clean
clean: ## Clean up files generated by 'aba', except your own configuration files. 'make clean && make' should re-build your cluster from scratch, using the same config. It is recommended to backup your important files. 
	rm -f scripts templates
	rm -f install-config.yaml agent-config.yaml 
	rm -rf iso-agent-based*
	rm -rf ~/.cache/agent 
	rm -f .??*
	rm -f mirror scripts templates
	rm -f mirror.conf regcreds vmware.conf

.PHONY: distclean
distclean: # Clean up all files.  Only use if you know what you're doing! Only used to re-distribute the repository.
	@scripts/ask.sh "Are you sure you want to clean up everything?" && exit 1 || echo Cleaning all files ...
	@make clean
	rm -f cluster.conf mirror.conf vmware.conf

.PHONY: test
test: # Clean up all files.  Only use if you know what you're doing! Only used to re-distribute the repository.
	@scripts/ask.sh "Are you sure?" && exit 1 || echo y


