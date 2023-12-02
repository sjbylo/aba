# Used, since no file exists to check timestamps
.PHONY: all clean cleanall delete create start stop kill mon refresh cmd ssh 

TEMPLATES = ../templates
SCRIPTS   = ../scripts
CMD      ?= "get co"
debug    ?= 
version := $(shell $(SCRIPTS)/fetch-ocp-stable-version.sh)

all: mirror.conf templates scripts aba.conf install-config.yaml agent-config.yaml iso-agent-based/agent.x86_64.iso image-content-sources.yaml .iso-uploaded .refreshed mon

templates:
	ln -s $(TEMPLATES) 

scripts: 
	ln -s $(SCRIPTS) 

# Fixme
pull-secret-mirror.json: 
	#cp ~/.pull-secret.json  pull-secret.json
	touch pull-secret-mirror.json

mirror.conf: ../mirror/mirror.conf
	ln -s ../mirror/mirror.conf 

vmware.conf: ../vmware.conf 
	[ -s ../vmware.conf ] && cp ../vmware.conf .

../vmware.conf: templates 
	scripts/install-vmware.conf.sh

aba.conf: 
	cp $(TEMPLATES)/aba.conf .
	vi aba.conf

install-config.yaml: aba.conf imageset-config.yaml image-content-sources.yaml pull-secret-mirror.json templates scripts 
	$(SCRIPTS)/create-install-config.sh $(debug)

agent-config.yaml: aba.conf mirror.conf templates scripts 
	$(SCRIPTS)/create-agent-config.sh $(debug)

iso-agent-based/agent.x86_64.iso: install-config.yaml agent-config.yaml #  openshift-install
	$(SCRIPTS)/generate-image.sh $(debug)

.iso-uploaded: iso-agent-based/agent.x86_64.iso
	$(SCRIPTS)/vmw-upload.sh $(debug) 
	touch .iso-uploaded

.killed: .iso-uploaded
	$(SCRIPTS)/vmw-kill.sh $(debug)
	touch .killed

.refreshed: .killed
	$(SCRIPTS)/vmw-delete.sh $(debug)
	$(SCRIPTS)/vmw-create.sh --start $(debug) 
	touch .refreshed

refresh: 
	$(SCRIPTS)/vmw-delete.sh $(debug)
	$(SCRIPTS)/vmw-create.sh $(debug)
	$(SCRIPTS)/vmw-start.sh --start $(debug)
	touch .refreshed

#vmw: vmw-upload vmware.conf
#	$(SCRIPTS)/vmw-refresh.sh $(debug)

imageset-config.yaml:
	# FIXME
	touch imageset-config.yaml

image-content-sources.yaml: 
	scripts/create-image-content-sources.sh $(debug)

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
	rm -f ~/.cache/agent imageset.*.yaml rootCA.pem 
	rm -f scripts templates
	rm -rf iso-agent-based 

cleanall: clean
	rm -f aba.conf 
	rm -f mirror.conf vmware.conf 

