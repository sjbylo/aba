# No file exists to check timestamps
.PHONY: all init deps clean save sync load step1 step2 mirror.conf install

TEMPLATES = ../templates
SCRIPTS   = ../scripts
OCP_VER = 4.13.19
debug   ?=

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
	#$(SCRIPTS)/create-mirror-conf.sh $(debug)
	cp ../mirror.conf .

../mirror.conf: templates/mirror.conf templates 
	$(SCRIPTS)/create-mirror-conf.sh $(debug)

.mirror-installed: mirror-registry
	$(SCRIPTS)/reg-install.sh $(debug) && touch .mirror-installed
	
install: init
	# Install Quay Mirror
	$(SCRIPTS)/reg-install.sh $(debug) && touch .mirror-installed

uninstall: init mirror-registry
	# Uninstall Quay Mirror
	$(SCRIPTS)/reg-uninstall.sh  $(debug)
	rm -f .mirror-installed

save: init 
	$(SCRIPTS)/reg-save.sh  $(debug)

sync: init .mirror-installed
	# Add images to the mirror registry
	$(SCRIPTS)/reg-sync.sh  $(debug)
	
load: init save .mirror-installed
	# Add images to the mirror registry
	$(SCRIPTS)/reg-load.sh  $(debug)
	
clean: uninstall 
	rm -rf deps *.yaml *.sh save .mirror-installed scripts templates registry-creds.txt oc-mirror-workspace

