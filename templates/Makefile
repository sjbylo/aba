# Used, since no file exists to check timestamps
.PHONY: all clean cleanall delete create start stop kill mon refresh cmd ssh 

EDITOR   ?= vi      		# Set vi or nano or you fav. editor
TEMPLATES = ../templates
SCRIPTS   = ../scripts
CMD      ?= "get co"
debug    ?= 
version := $(shell ../scripts/fetch-ocp-stable-version.sh)

#all: mirror.conf vmware.conf aba.conf install-config.yaml agent-config.yaml iso-agent-based/agent.x86_64.iso upload force-refresh mon
all: vmware.conf iso-agent-based/agent.x86_64.iso upload force-refresh mon

templates:
	ln -s ../templates

scripts: 
	ln -s ../scripts

mirror: 
	ln -s ../mirror

mirror.conf: mirror 
	ln -s mirror/mirror.conf 
	touch mirror.conf

vmware.conf: ../vmware.conf 
	#[ -s ../vmware.conf ] && cp ../vmware.conf .
	cp ../vmware.conf .
	touch vmware.conf

../vmware.conf: templates scripts
	scripts/install-vmware.conf.sh
	touch ../vmware.conf

aba.conf: 
	cp templates/aba.conf .
	$(EDITOR) aba.conf

install-config.yaml: templates scripts aba.conf mirror.conf
	scripts/create-install-config.sh $(debug)

agent-config.yaml: aba.conf mirror.conf templates scripts 
	scripts/create-agent-config.sh $(debug)

iso-agent-based/agent.x86_64.iso: install-config.yaml agent-config.yaml 
	scripts/generate-image.sh $(debug)

poweroff: iso-agent-based/agent.x86_64.iso vmware.conf
	scripts/vmw-kill.sh $(debug)
	touch poweroff

upload: poweroff vmware.conf
	scripts/vmw-upload.sh $(debug) 
	touch upload

force-refresh: poweroff vmware.conf
	scripts/vmw-delete.sh $(debug)
	scripts/vmw-create.sh --start $(debug) 
	touch force-refresh

refresh:  vmware.conf
	scripts/vmw-delete.sh $(debug)
	scripts/vmw-create.sh --start $(debug) 
	touch refresh

delete: vmware.conf
	scripts/vmw-delete.sh $(debug)

create: vmware.conf
	scripts/vmw-create.sh $(debug)

stop: vmware.conf
	scripts/vmw-stop.sh $(debug)

start: vmware.conf
	scripts/vmw-start.sh $(debug)

kill:  vmware.conf
	scripts/vmw-kill.sh $(debug)

mon:
	scripts/monitor-install.sh $(debug)

getco:
	oc --kubeconfig iso-agent-based/auth/kubeconfig get co

cmd:
	scripts/command.sh $(CMD)

ssh:
	scripts/ssh-rendezvous.sh

clean:
	# Fixme
	rm -f scripts templates
	rm -f install-config.yaml agent-config.yaml 
	rm -rf ~/.cache/agent poweroff refresh refresh-poweroff
	rm -rf iso-agent-based 

distclean: clean
	rm -f aba.conf 
	rm -f mirror.conf vmware.conf 

