EDITOR   ?= vi      		# Set vi or nano or you fav. editor
TEMPLATES = ../templates
SCRIPTS   = ../scripts
#cmd      ?= "get co"    # The default command
debug    ?= 		# Set debug=1 for some commands 

# The default target will build a cluster from scratch 
all: iso .autoupload .autorefresh mon

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[\.a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

init: .initialized
.initialized:
	@ln -s ../templates
	@ln -s ../scripts
	@ln -s ../mirror
	@touch .initialized
	@echo Initialized $(PWD) successfully

mirror.conf: .initialized ## Set up the mirror.conf file
	@ln -sf mirror/mirror.conf
	@touch mirror.conf
	@echo Using $(PWD)/mirror.conf file 

vmware.conf: ## Use VMW vCenter or ESXi to create cluster
	@[ -s ../vmware.conf ] && ln -s ../vmware.conf || true

aba.conf:  ## Create and edit the aba conf file
	cp templates/aba.conf .
	$(EDITOR) aba.conf

install-config.yaml: .initialized vmware.conf aba.conf mirror.conf  ## Create the agent-based config file based on the aba.conf file
	scripts/create-install-config.sh $(debug)

agent-config.yaml: .initialized vmware.conf aba.conf mirror.conf  ## Create the agent-based config file based on the aba.conf file
	scripts/create-agent-config.sh $(debug)

# The following "auto" targets are meant just for the full end-to-end automation, to build a cluster
iso: iso-agent-based/agent.x86_64.iso ## Build the agent-based iso file
iso-agent-based/agent.x86_64.iso: install-config.yaml agent-config.yaml   # Note that install-config.yaml can itself be dependent on vmware.conf params
	scripts/generate-image.sh $(debug)

.autopoweroff: iso-agent-based/agent.x86_64.iso
	scripts/vmw-kill.sh $(debug)
	@touch .autopoweroff

upload: .autoupload vmware.conf ## Upload the ISO to the VMW platform
.autoupload: .autopoweroff
	scripts/vmw-upload.sh $(debug) 
	@touch .autoupload

.autorefresh: .autoupload
	scripts/vmw-delete.sh $(debug)
	scripts/vmw-create.sh --start $(debug) 
	@touch .autorefresh

# The following tagets are for interactive use only
.PHONEY: refresh
refresh: init  vmware.conf ## Delete and re-create the VMs
	scripts/vmw-delete.sh $(debug)
	scripts/vmw-create.sh --start $(debug) 

.PHONEY: create
create: vmware.conf  ## Create the VMs based on the agent-based config files
	scripts/vmw-create.sh $(debug)

.PHONEY: stop
stop: vmware.conf ## Shut down the VM guest OS
	scripts/vmw-stop.sh $(debug)

.PHONEY: start
start: vmware.conf ## Start the VMs
	scripts/vmw-start.sh $(debug)

.PHONEY: poweroff
poweroff: vmware.conf ## Power off the VMs immediately
	scripts/vmw-kill.sh $(debug)

.PHONEY: kill
kill:  vmware.conf ## Kill or power off the VMs immediately
	scripts/vmw-kill.sh $(debug)

.PHONEY: delete
delete: vmware.conf ## Delete the VMs
	scripts/vmw-delete.sh $(debug)

.PHONEY: mon
mon: ## Monitor the agent-based installation of OpenShift 
	scripts/monitor-install.sh $(debug)

.PHONEY: getco
getco: ## Run 'oc get co' command on the cluster
	oc --kubeconfig iso-agent-based/auth/kubeconfig get co

.PHONEY: cmd
cmd: ## Run any oc command on the cluster, must provide command, e.g. cmd="oc get pods -A", default is 'oc get co'
	scripts/oc-command.sh $(cmd)

.PHONEY: ssh
ssh: ## Open ssh to the rendezvous host for troubleshooting
	scripts/ssh-rendezvous.sh $(cmd)

.PHONEY: shell 
shell:  ## Open a shell with access to the cluster
	KUBECONFIG=iso-agent-based/auth/kubeconfig bash

.PHONEY: vmw
vmw: ## Configure VMW platform credentials
	@make -C .. vmware.conf

.PHONEY: clean
clean: ## Clean up 
	rm -f scripts templates
	rm -f install-config.yaml agent-config.yaml 
	rm -rf iso-agent-based*
	rm -rf ~/.cache/agent 
	rm -f .??*
	rm -f mirror scripts templates
	rm -f mirror.conf regcreds vmware.conf

.PHONEY: distclean
distclean: clean ## Clean up everything
	rm -f aba.conf mirror.conf vmware.conf

