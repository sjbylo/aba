# Used, since no file exists to check timestamps
.PHONY: all clean cleanall delete create start stop kill mon refresh cmd

TEMPLATES = ../templates
SCRIPTS   = ../scripts
CMD      ?= "get co"

all: templates scripts id_rsa.pub rootCA.pem aba.conf mirror.conf vmware.conf install-config.yaml agent-config.yaml agent-based/agent.x86_64.iso image-content-sources.yaml .iso-uploaded .refreshed mon

rootCA.pem: ../deps/rootCA.pem
	ln -fs ../deps/rootCA.pem  

id_rsa.pub: ~/.ssh/id_rsa.pub
	ln -fs ~/.ssh/id_rsa.pub 

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

mirror.conf:
	# copy and edit mirror.conf
	cp $(TEMPLATES)/mirror.conf .
	vi mirror.conf

vmware.conf:
	# copy and edit vmware.conf
	cp $(TEMPLATES)/vmware.conf .
	vi vmware.conf

install-config.yaml: aba.conf rootCA.pem id_rsa.pub imageset-config.yaml image-content-sources.yaml pull-secret-mirror.json templates scripts 
	$(SCRIPTS)/create-install-config.sh 

# depends on mirror in case the ocp version changes 
agent-config.yaml: aba.conf mirror.conf templates scripts 
	$(SCRIPTS)/create-agent-config.sh 

#work/iso: path-to-cached-iso-file openshift-install 
agent-based/agent.x86_64.iso: install-config.yaml agent-config.yaml #  openshift-install
	$(SCRIPTS)/generate-image.sh 

#oc:
#	$(SCRIPTS)/install-oc.sh 

openshift-install: oc oc-mirror
	$(SCRIPTS)/install-openshift-install.sh 

oc-mirror:
	$(SCRIPTS)/install-oc-mirror.sh 

# Depends on the binary version of openshift-install
#agent-iso: install-config.yaml agent-config.yaml openshift-install
#	$(SCRIPTS)/build-iso.sh 

.iso-uploaded: agent-based/agent.x86_64.iso
	$(SCRIPTS)/vmw-kill.sh
	$(SCRIPTS)/vmw-upload.sh && touch .iso-uploaded

vmw: vmw-upload
	$(SCRIPTS)/vmw-refresh.sh

.refreshed: agent-based/agent.x86_64.iso
	$(SCRIPTS)/vmw-delete.sh
	$(SCRIPTS)/vmw-create.sh --start
	touch .refreshed

refresh: 
	$(SCRIPTS)/vmw-delete.sh
	$(SCRIPTS)/vmw-create.sh
	$(SCRIPTS)/vmw-start.sh --start

imageset-config.yaml:
	# FIXME
	touch imageset-config.yaml

image-content-sources.yaml: ../deps/image-content-sources.yaml
	ln -s ../deps/image-content-sources.yaml

delete:
	$(SCRIPTS)/vmw-delete.sh

create:
	$(SCRIPTS)/vmw-create.sh

stop:
	$(SCRIPTS)/vmw-stop.sh

start:
	$(SCRIPTS)/vmw-start.sh 

kill:
	$(SCRIPTS)/vmw-kill.sh

mon:
	$(SCRIPTS)/monitor-install.sh

cleanall: clean
	rm -f aba.conf 
	rm -f mirror.conf vmware.conf 

getco:
	oc --kubeconfig agent-based/auth/kubeconfig get co

cmd:
	$(SCRIPTS)/command.sh $(CMD)

clean:
	# Fixme
	rm -f install-config.yaml agent-config.yaml 
	rm -f path-to-cached-iso-file imageset.yaml rootCA.pem 
	rm -f scripts templates
	rm -rf work 

