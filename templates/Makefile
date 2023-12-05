# Used, since no file exists to check timestamps
.PHONY: all clean cleanall delete create start stop kill mon refresh cmd ssh 

TEMPLATES = ../templates
SCRIPTS   = ../scripts
CMD      ?= "get co"
debug    ?= 
version := $(shell $(SCRIPTS)/fetch-ocp-stable-version.sh)

all: templates scripts mirror mirror.conf vmware.conf aba.conf install-config.yaml agent-config.yaml iso-agent-based/agent.x86_64.iso iso-agent-based/upload refresh-poweroff mon

templates:
	ln -s $(TEMPLATES) 

scripts: 
	ln -s $(SCRIPTS) 

mirror: 
	ln -s ../mirror

### Fixme
##pull-secret-mirror.json: 
##	#cp ~/.pull-secret.json  pull-secret.json
##	touch pull-secret-mirror.json

mirror.conf: ##mirror ###mirror/mirror.conf
	ln -s mirror/mirror.conf 

vmware.conf: ../vmware.conf 
	[ -s ../vmware.conf ] && cp ../vmware.conf .
	touch vmware.conf

../vmware.conf: templates 
	scripts/install-vmware.conf.sh

aba.conf: 
	cp $(TEMPLATES)/aba.conf .
	vi aba.conf

install-config.yaml: templates scripts aba.conf mirror.conf
	$(SCRIPTS)/create-install-config.sh $(debug)

agent-config.yaml: aba.conf mirror.conf templates scripts 
	$(SCRIPTS)/create-agent-config.sh $(debug)

iso-agent-based/agent.x86_64.iso: install-config.yaml agent-config.yaml 
	$(SCRIPTS)/generate-image.sh $(debug)

poweroff: iso-agent-based/agent.x86_64.iso
	$(SCRIPTS)/vmw-kill.sh $(debug)
	touch poweroff

#iso-agent-based/upload: iso-agent-based/agent.x86_64.iso
#	$(SCRIPTS)/vmw-upload.sh $(debug) 
#	touch iso-agent-based/upload

iso-agent-based/upload: poweroff
	$(SCRIPTS)/vmw-upload.sh $(debug) 
	touch iso-agent-based/upload

refresh-poweroff: poweroff
	$(SCRIPTS)/vmw-delete.sh $(debug)
	$(SCRIPTS)/vmw-create.sh --start $(debug) 
	touch refresh-poweroff

refresh: 
	$(SCRIPTS)/vmw-delete.sh $(debug)
	$(SCRIPTS)/vmw-create.sh $(debug)
	$(SCRIPTS)/vmw-start.sh --start $(debug)
	touch refresh

delete:
	$(SCRIPTS)/vmw-delete.sh $(debug)

create:
	$(SCRIPTS)/vmw-create.sh $(debug)

stop:
	$(SCRIPTS)/vmw-stop.sh $(debug)

start:
	$(SCRIPTS)/vmw-start.sh $(debug)

kill: 
	$(SCRIPTS)/vmw-kill.sh $(debug)

mon:
	$(SCRIPTS)/monitor-install.sh $(debug)

getco:
	oc --kubeconfig iso-agent-based/auth/kubeconfig get co

cmd:
	$(SCRIPTS)/command.sh $(CMD)

ssh:
	scripts/ssh-rendezvous.sh

clean:
	# Fixme
	rm -f install-config.yaml agent-config.yaml 
	rm -f ~/.cache/agent rootCA.pem 
	rm -f scripts templates
	rm -rf iso-agent-based 

distclean: clean
	rm -f aba.conf 
	rm -f mirror.conf vmware.conf 

