# No file exists to check timestamps
.PHONY: all init deps clean save sync load step1 step2 mirror.conf install

TEMPLATES = ../templates
SCRIPTS   = ../scripts
OCP_VER = 4.13.19
debug   ?=
#version := $(shell $(SCRIPTS)/fetch-ocp-stable-version.sh)
version := $(shell cat target-ocp-version.conf)

init: deps templates scripts mirror.conf mirror-registry

all: init registry install sync

# For air-gapped
step1: init save 
step2: init load

deps:
	mkdir -p deps 

templates: $(TEMPLATES)
	ln -s $(TEMPLATES) 

scripts: $(SCRIPTS)
	ln -s $(SCRIPTS) 

mirror-registry: mirror-registry.tar.gz
	tar xzf mirror-registry.tar.gz
	touch mirror-registry

mirror-registry.tar.gz:
	curl --progress-bar -OL https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/latest/mirror-registry.tar.gz

rootCA.pem: deps install ~/quay-install/quay-rootCA/rootCA.pem 
	cp ~/quay-install/quay-rootCA/rootCA.pem  deps

mirror.conf: ../mirror.conf
	cp ../mirror.conf .

../mirror.conf: templates/mirror.conf templates 
	$(SCRIPTS)/create-mirror-conf.sh -v $(version) $(debug)

install: init
	# Install Quay Mirror
	$(SCRIPTS)/reg-install.sh $(debug) 
	touch install

#uninstall: ###init mirror-registry
#init: deps templates scripts mirror.conf mirror-registry
uninstall: mirror-registry scripts templates
	# Uninstall Quay Mirror
	rm -f install
	$(SCRIPTS)/reg-uninstall.sh  $(debug)

save: init 
	$(SCRIPTS)/reg-save.sh  $(debug)

sync: init install
	# Add images to the mirror registry
	$(SCRIPTS)/reg-sync.sh  $(debug)
	
load: init save install
	# Add images to the mirror registry
	$(SCRIPTS)/reg-load.sh  $(debug)
	
clean: 
	rm -rf *.yaml *.sh save install oc-mirror-workspace .??*

distclean: uninstall clean
	rm -rf deps *.tar.gz *.tar scripts templates registry-creds.txt *.conf mirror-registry


