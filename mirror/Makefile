# No file exists to check timestamps
.PHONY: all clean distclean loadclean syncclean saveclean uninstallclean installclean

TEMPLATES = ../templates
SCRIPTS   = ../scripts
###OCP_VER = 4.13.19
debug   ?=
#version := $(shell $(SCRIPTS)/fetch-ocp-stable-version.sh)
version := $(shell cat target-ocp-version.conf)

# This is the default.  Install mirror reg. (if needed), sync images from the Internety directloy to the mirror. 
all: sync

##fetch-ocp-stable-version.sh:
##	echo "Stop!  Be sure to run ../aba first"
##	exit 1

init: .initialized
.initialized: deps templates scripts mirror.conf mirror-registry 
	touch .initialized

deps:
	mkdir deps 

templates:
	ln -s $(TEMPLATES) 

scripts: 
	ln -s $(SCRIPTS) 

mirror-registry: mirror-registry.tar.gz
	tar xmzf mirror-registry.tar.gz

mirror-registry.tar.gz:
	curl --progress-bar -OL \
	https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/latest/mirror-registry.tar.gz

deps/rootCA.pem: deps install ~/quay-install/quay-rootCA/rootCA.pem 
	cp ~/quay-install/quay-rootCA/rootCA.pem deps/

mirror.conf: ../mirror.conf
	cp ../mirror.conf .

../mirror.conf: templates templates/mirror.conf ###target-ocp-version.conf
	$(SCRIPTS)/create-mirror-conf.sh -v $(version) $(debug)

install: init .installed
.installed: 
	# Install Quay Mirror
	$(SCRIPTS)/reg-install.sh $(debug) 
	rm -f .uninstalled 
	touch .installed

installclean:
	rm .installed

uninstall: init .uninstalled
.uninstalled: 
	$(SCRIPTS)/reg-uninstall.sh  $(debug)
	rm -f .installed
	touch .uninstalled
uninstallclean:
	rm .uninstalled

save: init .saved 
.saved: 
	$(SCRIPTS)/reg-save.sh  $(debug)
	touch .saved
saveclean:
	rm .saved

sync: init install .synced 
.synced: 
	# Add images to the mirror registry
	$(SCRIPTS)/reg-sync.sh  $(debug)
	touch .synced
syncclean:
	rm .synced
	
load: init save install .loaded
.loaded: 
	# Add images to the mirror registry
	$(SCRIPTS)/reg-load.sh  $(debug)
	touch .loaded
loadclean:
	rm .loaded
	
clean: 
	rm -rf *.yaml *.sh save oc-mirror-workspace .??*

distclean: uninstall clean
	rm -rf deps *.tar.gz *.tar scripts templates registry-creds.txt *.conf mirror-registry


