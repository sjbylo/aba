# Used, since no file exists to check timestamps
.PHONY: all clean cleanall delete create start stop kill mon refresh cmd ssh

TEMPLATES = ../templates
SCRIPTS   = ../scripts
CMD      ?= "get co"
debug    ?= 
version := $(shell $(SCRIPTS)/fetch-ocp-stable-version.sh)

#all: mirror.conf templates scripts id_rsa.pub rootCA.pem aba.conf vmware.conf install-config.yaml agent-config.yaml iso-agent-based/agent.x86_64.iso image-content-sources.yaml .iso-uploaded .refreshed mon
all: mirror.conf templates scripts            aba.conf vmware.conf install-config.yaml agent-config.yaml iso-agent-based/agent.x86_64.iso image-content-sources.yaml .iso-uploaded .refreshed mon

#rootCA.pem: ../deps/rootCA.pem
#	ln -fs ../deps/rootCA.pem  

#id_rsa.pub: ~/.ssh/id_rsa.pub
#	ln -fs ~/.ssh/id_rsa.pub 

templates: $(TEMPLATES)
	ln -s $(TEMPLATES) 

scripts: $(SCRIPTS)
	ln -s $(SCRIPTS) 

pull-secret-mirror.json: 
	#cp ~/.pull-secret.json  pull-secret.json
	touch pull-secret-mirror.json

aba.conf: 
	cp $(TEMPLATES)/aba.conf .
	vi aba.conf

mirror.conf: ../mirror/mirror.conf
	ln -s ../mirror/mirror.conf 

vmware.conf:
	# copy and edit vmware.conf
	[ -s ../vmware.conf ] && ln -s ../vmware.conf || cp $(TEMPLATES)/vmware.conf .
	vi vmware.conf
	##cp -f vmware.conf ..

#install-config.yaml: aba.conf rootCA.pem id_rsa.pub imageset-config.yaml image-content-sources.yaml pull-secret-mirror.json templates scripts 
install-config.yaml: aba.conf                        imageset-config.yaml image-content-sources.yaml pull-secret-mirror.json templates scripts 
	$(SCRIPTS)/create-install-config.sh $(debug)

# depends on mirror in case the ocp version changes 
agent-config.yaml: aba.conf mirror.conf templates scripts 
	$(SCRIPTS)/create-agent-config.sh $(debug)

#work/iso: path-to-cached-iso-file openshift-install 
iso-agent-based/agent.x86_64.iso: install-config.yaml agent-config.yaml #  openshift-install
	$(SCRIPTS)/generate-image.sh $(debug)

#oc:
#	$(SCRIPTS)/install-oc.sh $(debug)

openshift-install: oc oc-mirror
	$(SCRIPTS)/install-openshift-install.sh $(debug)

oc-mirror:
	$(SCRIPTS)/install-oc-mirror.sh $(debug)

# Depends on the binary version of openshift-install
#agent-iso: install-config.yaml agent-config.yaml openshift-install
#	$(SCRIPTS)/build-iso.sh $(debug)

.iso-uploaded: vmware.conf iso-agent-based/agent.x86_64.iso
	$(SCRIPTS)/vmw-kill.sh $(debug)
	$(SCRIPTS)/vmw-upload.sh $(debug) && touch .iso-uploaded

vmw: vmw-upload vmware.conf
	$(SCRIPTS)/vmw-refresh.sh $(debug)

.refreshed: iso-agent-based/agent.x86_64.iso vmware.conf
	$(SCRIPTS)/vmw-delete.sh $(debug)
	$(SCRIPTS)/vmw-create.sh --start $(debug) 
	touch .refreshed

refresh: vmware.conf
	$(SCRIPTS)/vmw-delete.sh $(debug)
	$(SCRIPTS)/vmw-create.sh $(debug)
	$(SCRIPTS)/vmw-start.sh --start $(debug)
	touch .refreshed

imageset-config.yaml:
	# FIXME
	touch imageset-config.yaml

#image-content-sources.yaml: ../deps/image-content-sources.yaml
image-content-sources.yaml: 
	scripts/create-image-content-sources.sh $(debug)

delete: vmware.conf
	$(SCRIPTS)/vmw-delete.sh $(debug)

create: vmware.conf
	$(SCRIPTS)/vmw-create.sh $(debug)

stop: vmware.conf
	$(SCRIPTS)/vmw-stop.sh $(debug)

start: vmware.conf
	$(SCRIPTS)/vmw-start.sh $(debug)

kill: vmware.conf
	$(SCRIPTS)/vmw-kill.sh $(debug)

mon:
	$(SCRIPTS)/monitor-install.sh $(debug)

cleanall: clean
	rm -f aba.conf 
	rm -f mirror.conf vmware.conf 

getco:
	oc --kubeconfig iso-agent-based/auth/kubeconfig get co

cmd:
	$(SCRIPTS)/command.sh $(CMD)

ssh:
	scripts/ssh-rendezvous.sh

clean:
	# Fixme
	rm -f install-config.yaml agent-config.yaml 
	rm -f path-to-cached-iso-file imageset.yaml rootCA.pem 
	rm -f scripts templates
	rm -rf work iso-agent-based 

