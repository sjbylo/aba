# No file exists to check timestamps
.PHONY: all clean delete create save

TEMPLATES = ../templates
SCRIPTS   = ../scripts
OCP_VER = 4.13.19
debug   ?=

#all: templates scripts oc ~/bin/oc ~/bin/openshift-install install rootCA.pem mirror.conf 
#all: mirror.conf  templates scripts ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror install
all: deps mirror-registry templates scripts mirror.conf install sync

step1: deps mirror-registry templates scripts mirror.conf save 
step2: deps mirror-registry templates scripts mirror.conf load

deps:
	mkdir deps 

mirror-registry: mirror-registry.tar.gz
	tar xzf mirror-registry.tar.gz
	touch mirror-registry

mirror-registry.tar.gz:
	curl --progress-bar -OL https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/latest/mirror-registry.tar.gz

#rootCA.pem: ../deps/rootCA.pem 
#	ln -s ../deps/rootCA.pem 

templates: $(TEMPLATES)
	ln -s $(TEMPLATES) 

scripts: $(SCRIPTS)
	ln -s $(SCRIPTS) 

mirror.conf:
	$(SCRIPTS)/create-mirror-conf.sh $(debug)

install: mirror.conf
	# Install Quay Mirror
	$(SCRIPTS)/reg-install.sh  $(debug)

uninstall: mirror-registry
	# Uninstall Quay Mirror
	$(SCRIPTS)/reg-uninstall.sh  $(debug)

save:
	$(SCRIPTS)/reg-save.sh  $(debug)

sync:
	# Add images to the mirror registry
	$(SCRIPTS)/reg-sync.sh  $(debug)
	
load: 
	# Add images to the mirror registry
	$(SCRIPTS)/reg-load.sh  $(debug)
	
clean: uninstall 
	rm -rf deps *.yaml scripts templates *.sh save 
	#echo "Run 'make uninstall' to remove the mirror registry!"

