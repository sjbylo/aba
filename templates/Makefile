debug    ?= 		# Set debug=1 for some commands 

-include ../aba.conf
platform := $(strip $(shell echo $(platform)))

# The next section is (unfortunatelly) needed because making a bare-metal cluster has a different flow, with interruptions!
# 1. Before iso creation, the Agent-based installer config files need to be changed: mac addresses added, disk hints ... etc.
# 2. And, after iso creation, the iso hosts need to be booted before 'make mon' target is run.
ifneq ($(platform),vmw)   # if platform is not 'vmw', i.e. bare-metal is assumed 
	ifeq ($(wildcard .bm-message),)
		# if .bm-message DOES NOT exists
   		# Only create the agent based config files and show next steps
		TARGET_DEPENDENCIES = check ../aba.conf install-config.yaml agent-config.yaml .bm-message
	else
		#.bm-message exists
		ifeq ($(wildcard .bm-nextstep),)
			# if .bm-nextstep DOES NOT exists
   			# Only create the iso file and show next steps
			TARGET_DEPENDENCIES = check ../aba.conf install-config.yaml agent-config.yaml             iso .bm-nextstep
		else
			# .bm-nextstep exists
   			# Do all steps, including mon
			TARGET_DEPENDENCIES = check ../aba.conf install-config.yaml agent-config.yaml             iso              mon
		endif
	endif
else  # If platform is 'vmw', all steps can be automated 
	# Create the agent based config files and the matching VMs
	TARGET_DEPENDENCIES = check ../aba.conf iso .autopoweroff .autoupload .autorefresh .finished
endif

# DEBUG # $(info TARGET_DEPENDENCIES = $(TARGET_DEPENDENCIES))

# The default target will build a cluster from scratch (for 'vmw' platform but not for bare-metal!) 
all: $(TARGET_DEPENDENCIES)


# Check cluster has been installed already and abort if it has
.PHONY: check
check:
	@../scripts/check-cluster-installed.sh

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[\.a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

# aba.conf should never be missing!
../aba.conf:
	@echo "aba.conf missing! Please read the README on how to get started!"
	@exit 1
	@#make -C .. aba.conf

init: .initialized
.initialized:
	@ln -fs ../templates
	@ln -fs ../scripts
	@ln -fs ../mirror
	@ln -fs ../mirror/regcreds 
	@ln -fs ../aba.conf
	make -C ../cli
	@touch .initialized
	@echo Initialized `pwd` successfully

mirror.conf: .initialized ## Set up the mirror.conf file.
	@ln -fs mirror/mirror.conf
	@touch mirror.conf
	@echo Using `pwd`/mirror.conf file 

vmware.conf: ## Use VMW vCenter or ESXi to create cluster.
	@make -C .. vmw
	@make -C ../cli ~/bin/govc
	@test -f ../vmware.conf && ln -fs ../vmware.conf || true

cluster.conf:  ## Set up the OpenShift cluster.conf file.
	scripts/create-cluster-conf.sh $(name) $(type)

agentconf: install-config.yaml agent-config.yaml  ## Convenient target to only generate the agent config files, so they can be edited. 

# Note that install-config.yaml can be configured with vSphere params (need 'vmware.conf')
install-config.yaml: .initialized vmware.conf cluster.conf mirror.conf  ## Create the agent-based config file based on the cluster.conf file.
	scripts/create-install-config.sh $(debug)

#agent-config.yaml: .initialized vmware.conf cluster.conf mirror.conf  ## Create the agent-based config file based on the cluster.conf file.
agent-config.yaml: .initialized             cluster.conf mirror.conf  ## Create the agent-based config file based on the cluster.conf file.
	scripts/create-agent-config.sh $(debug)

.bm-message:
	@echo
	@echo "Next steps:"
	@echo "1 cd <cluster name>"
	@echo "2 Check & edit the agent configuration files: "
	@echo "   - install-config.yaml:"
	@#echo "       Add proxy values, in case you want to use them."
	@echo "   - agent-config.yaml:"
	@echo "       You must modify the mac addresses to match your host's network interfaces."
	@echo "       Optionally, add drive & NIC hints, vlan tag and any other network configurations, if needed."
	@echo "3 Run 'make iso' to create the ISO file."
	@echo "4 Power on all your hosts and boot them with the ISO file."
	@echo "5 Run 'make mon' to monitor the installation progress."
	@echo 
	@touch .bm-message

# The following "auto" targets are meant just for the full end-to-end automation, to build a cluster
iso: iso-agent-based/agent.x86_64.iso ## Build the agent-based iso file.
iso-agent-based/agent.x86_64.iso: install-config.yaml agent-config.yaml   # Note that install-config.yaml can itself be dependent on vmware.conf params
	scripts/generate-image.sh $(debug)

ntp: .ntp ## Configure NTP time sync during bootstrap (day1) and day2. Useful if underlying platform/hardware does not support time sync.
.ntp: iso-agent-based/agent.x86_64.iso
	@scripts/add_ntp_ignition_to_iso.sh $(debug) 
	@touch .ntp

.bm-nextstep:
	@echo "Next steps:"
	@echo "  Boot your hosts with the ISO file and then run 'make mon' to monitor the installation progress."
	@touch .bm-nextstep
	@exit 0

.autopoweroff: .ntp
	@scripts/vmw-kill.sh $(debug) || true 
	@touch .autopoweroff

upload: .autoupload  ## Upload the ISO to the VMW platform to [Datastore] images/agent-<cluster-name>.iso
#.autoupload: vmware.conf .autorefresh
.autoupload: vmware.conf .autopoweroff
	@scripts/vmw-upload.sh $(debug) 
	@touch .autoupload


# The following targets are meant for interactive use only

# This target is a duplicate of .autorefresh below, except for the touch command.  'make refresh' is for interactive use and should always run.
.PHONY: refresh
refresh:  ## Delete & create the VMs. This will automatically start the cluster installation again which can be useful when your cluster is broken and you want to redeploy it.
	scripts/vmw-refresh.sh

# This target is the same as 'refresh' but should only run once.
.autorefresh: .initialized .autoupload vmware.conf 
	scripts/vmw-refresh.sh
	@touch .autorefresh

.PHONY: create
#create: vmware.conf iso  ## Create the VMs based on the 'agent-based' config files. Use 'make start' to start them. 
create: .initialized vmware.conf      ## Create the VMs based on the 'agent-based' config files. Use 'make start' to start them. 
	@scripts/vmw-exists.sh || scripts/vmw-create.sh $(debug) && exit 0

###ls: vmware.conf  ## List VMs and their power state.
.PHONY: ls
ls: .initialized vmware.conf                     agent-config.yaml ## List all VMs and their power state.
	@scripts/vmw-ls.sh || echo "No vm(s).  Try running 'make' or 'make refresh'."

.PHONY: shutdown 
shutdown: ## Trigger the cluster to gracefully shut itself down by draining all the nodes of pods and running shutdown command.
	@scripts/cluster-graceful-shutdown.sh 

.PHONY: startup
startup: ## Start all VMs and allow all pods to start (uncorden).  Start up your bare-metal servers and run this target.
	@scripts/cluster-startup.sh 

.PHONY: rescue
rescue: ## If a cluster does not start due to login/CSR issues, rescue the cluster using ssh, if available. 
	@scripts/cluster-rescue.sh 

.PHONY: stop
stop: .initialized vmware.conf                     agent-config.yaml ## Shut down all VMs gracefully. This will stop the cluster. Be warned that clusters don't always start up correctly again! Try using 'make shutdown' for graceful cluster shutdown.
	scripts/vmw-stop.sh $(debug)

.PHONY: start
start: .initialized vmware.conf                     agent-config.yaml ## Power on all VMs.  Use 'make startup' to ensure all nodes are uncordoned. 
	@scripts/vmw-start.sh $(debug) || exit 0

.PHONY: poweroff
poweroff: .initialized vmware.conf                     agent-config.yaml ## Power off all VMs immediately.  This will stop the cluster abruptly. 
	scripts/vmw-kill.sh $(debug) || exit 0

.PHONY: kill
kill:  .initialized vmware.conf                     agent-config.yaml ## Kill or power off the VMs immediately.  This will stop the cluster abruptly. 
	scripts/vmw-kill.sh $(debug) || exit 0

.PHONY: delete
delete: .initialized vmware.conf                     agent-config.yaml ## Delete all VMs. This will delete the cluster!
	@scripts/vmw-delete.sh $(debug) || exit 0

.finished: .autorefresh
	@scripts/monitor-install.sh $(debug)
	@touch .finished

.PHONY: mon
mon:  ## Monitor the agent-based installation of OpenShift.
	@scripts/monitor-install.sh $(debug)
	@touch .finished

.PHONY: login
login: 
	@scripts/show-cluster-login.sh

.PHONY: getco
getco: ## Run 'oc get co' command on the cluster.
	oc --kubeconfig iso-agent-based/auth/kubeconfig get co

.PHONY: cmd
cmd: ## Run any oc command on the cluster. Must provide command, e.g. cmd="oc get pods -A", default is 'oc get co'.
	@scripts/oc-command.sh $(cmd)

.PHONY: ssh
ssh: ## Open ssh to the rendezvous host (node 0) for troubleshooting
	@scripts/ssh-rendezvous.sh $(cmd)

.PHONY: shell   
shell:  ## Gain access to the installed cluster.  Run '. <(make -s shell)'
	@echo "export KUBECONFIG=$(PWD)/iso-agent-based/auth/kubeconfig"

.PHONY:
day2:  ## Set up OperatorHub, CatalogSources, imageContentSourcePolicy resources. Run this target after new Operators are loaded into the mirror registry. Requires access to 'mirror/.../oc-mirror-workspace' directory!
	@scripts/day2.sh $(debug)

.PHONY: vmw
vmw: ## Configure vCenter/ESXi API credentials in vmware.conf file.
	@[ ! -s ../vmware.conf ] && rm -f ../vmware.conf || true
	@make -C .. vmw

.PHONY: noask
noask:  ## Set 'ask' in aba.conf to 'false'.  Aba will assume all defaults and not prompt you for anything which allows for fully automated installations.
	@make -C .. noask

.PHONY: ask
ask: ## Set 'ask' in aba.conf to 'true'  Aba will prompt you for certain actions. 
	@make -C .. ask

.PHONY: clean
clean: ## Clean up files generated by 'aba', except your own configuration files. 'make clean && make' should re-build your cluster from scratch, using the same cluster.conf file. It is recommended to backup your important files first!
	rm -f scripts templates
	rm -f install-config.yaml agent-config.yaml 
	rm -rf iso-agent-based*
	@###rm -rf ~/.cache/agent 
	rm -f .??*
	rm -f mirror scripts templates
	rm -f mirror.conf regcreds vmware.conf
	rm -f aba.conf 

.PHONY: distclean
distclean: # Clean up all files.  Only use if you know what you're doing! Only used to re-distribute the repository.
	@[ -x scripts/distclean-gate.sh ] && scripts/distclean-gate.sh $(force) || true
	@make clean
	@#rm -rf ~/.cache/agent 
	rm -f cluster.conf mirror.conf vmware.conf
	@#rm -f cluster.conf aba.conf ~/.vmware.conf vmware.conf ../vmware.conf *.backup
	rm -f cluster.conf aba.conf                  vmware.conf                *.backup

