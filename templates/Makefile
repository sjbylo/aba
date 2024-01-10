# Used, since no file exists to check timestamps
#.PHONY: all clean cleanall delete create start stop kill mon refresh cmd ssh iso

EDITOR   ?= vi      		# Set vi or nano or you fav. editor
TEMPLATES = ../templates
SCRIPTS   = ../scripts
CMD      ?= "get co"
debug    ?= 
####version := $(shell ../scripts/fetch-ocp-stable-version.sh)

# The default target will build a cluster from scratch 
all: iso .autoupload .autorefresh mon

# Add links, just for convenience 
templates:
	ln -s ../templates

scripts: 
	ln -s ../scripts

mirror: 
	ln -s ../mirror

mirror.conf: mirror 
	ln -s mirror/mirror.conf
	#touch mirror.conf

vmware.conf: ## Make use of any existring vmware.conf file
	[ -s ../vmware.conf ] && ln -s ../vmware.conf || true

aba.conf: 
	cp templates/aba.conf .
	$(EDITOR) aba.conf

install-config.yaml: templates scripts aba.conf mirror.conf
	scripts/create-install-config.sh $(debug)

agent-config.yaml: templates scripts aba.conf mirror.conf
	scripts/create-agent-config.sh $(debug)

# The following "auto" targets are meant just for the full end-to-end automation, to build a cluster
iso: iso-agent-based/agent.x86_64.iso
iso-agent-based/agent.x86_64.iso: install-config.yaml agent-config.yaml 
	scripts/generate-image.sh $(debug)

.autopoweroff: vmware.conf iso-agent-based/agent.x86_64.iso
	scripts/vmw-kill.sh $(debug)
	touch .autopoweroff

.autoupload: vmware.conf .autopoweroff iso-agent-based/agent.x86_64.iso
	scripts/vmw-upload.sh $(debug) 
	touch .autoupload

.autorefresh: vmware.conf .autoupload
	scripts/vmw-delete.sh $(debug)
	scripts/vmw-create.sh --start $(debug) 
	touch .autorefresh

# The following tagets are for interactive use 
.PHONEY: upload
upload: vmware.conf 
	scripts/vmw-upload.sh $(debug) 

.PHONEY: refresh
refresh:  vmware.conf
	scripts/vmw-delete.sh $(debug)
	scripts/vmw-create.sh --start $(debug) 

.PHONEY: poweroff
poweroff: vmware.conf 
	scripts/vmw-kill.sh $(debug)

.PHONEY: delete
delete: vmware.conf
	scripts/vmw-delete.sh $(debug)

.PHONEY: create
create: vmware.conf
	scripts/vmw-create.sh $(debug)

.PHONEY: stop
stop: vmware.conf
	scripts/vmw-stop.sh $(debug)

.PHONEY: start
start: vmware.conf
	scripts/vmw-start.sh $(debug)

.PHONEY: kill
kill:  vmware.conf
	scripts/vmw-kill.sh $(debug)

.PHONEY: mon
mon:
	scripts/monitor-install.sh $(debug)

.PHONEY: getco
getco:
	oc --kubeconfig iso-agent-based/auth/kubeconfig get co

.PHONEY: cmd
cmd:
	scripts/command.sh $(CMD)

.PHONEY: ssh
ssh:
	scripts/ssh-rendezvous.sh

.PHONEY: vmw
vmw:
	make -C .. vmware.conf

.PHONEY: clean
clean:
	rm -f scripts templates
	rm -f install-config.yaml agent-config.yaml 
	rm -rf iso-agent-based 
	rm -rf ~/.cache/agent 
	rm -f .??*

.PHONEY: distclean
distclean: clean
	rm -f aba.conf mirror.conf vmware.conf

