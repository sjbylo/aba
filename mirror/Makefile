TEMPLATES = ../templates
SCRIPTS   = ../scripts
debug   ?=

#version := $(shell $(SCRIPTS)/fetch-ocp-stable-version.sh)
##version := $(shell cat ../target-ocp-version.conf)

## This is the default.  Install mirror reg. (if needed), sync images from the Internet directly to the mirror. 
#.PHONY: all 
#all: sync

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

sync: install .synced ## Sync images from the Internet directly to an internal registry. 
.synced: 
	$(SCRIPTS)/reg-sync.sh  $(debug)
	touch .synced

.PHONY: syncclean
syncclean:
	rm .synced
	

save: init .saved ## Save images from the Internet to local disk
.saved: 
	$(SCRIPTS)/reg-save.sh  $(debug)
	touch .saved

.PHONY: saveclean
saveclean:
	rm .saved

.PHONY: testload
testload: save load install .loaded  # Test the save, install, load process on a connected host

load: install .loaded  ## Load the saved images into a registry on the internal bastion
.loaded: 
	$(SCRIPTS)/reg-load.sh  $(debug)
	touch .loaded

.PHONY: loadclean
loadclean:
	rm .loaded
	
# FIXME
../target-ocp-version.conf:
	../aba

init: deps templates scripts mirror.conf mirror-registry .initialized
.initialized: 
	touch .initialized

deps:
	mkdir deps 

templates:
	ln -s $(TEMPLATES) 

scripts: 
	ln -s $(SCRIPTS) 

mirror-registry: mirror-registry.tar.gz ## Extract the mirror-registry binary 
	tar xmvzf mirror-registry.tar.gz

mirror-registry.tar.gz: ## Download the mirror-registry tarball
	curl --progress-bar -OL \
	https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/latest/mirror-registry.tar.gz

mirror.conf: ../mirror.conf ## Set up the mirror.conf file. Note that aba/mirror.conf has priority over aba/mirror/mirror.conf.
	cp ../mirror.conf .

../mirror.conf: templates templates/mirror.conf ../target-ocp-version.conf ## Configure the mirror.conf file.
	$(SCRIPTS)/create-mirror-conf.sh $(debug)

install: init mirror-registry .installed ## Set up the registry as per the settings in mirror.conf. Place credential file(s) into deps/ for existing registry.  See README.md.
.installed: 
	# Install Quay Mirror
	$(SCRIPTS)/reg-install.sh $(debug) 
	rm -f .uninstalled 
	touch .installed

.PHONY: installclean
installclean:
	rm .installed

uninstall: init mirror-registry .uninstalled ## Uninstall the registry 
.uninstalled: 
	$(SCRIPTS)/reg-uninstall.sh  $(debug)
	rm -f .installed
	touch .uninstalled

.PHONY: uninstallclean
uninstallclean:
	rm .uninstalled

.PHONY: tidy 
tidy: ## Tidy large uncompressed files before copying the repo to the internal bastion 
	rm -rf *.tar mirror-registry  # 'dot' files must not be tidied as 'make load' needs them on the internal bastion

.PHONY: clean
clean: tidy ## Clean up files
	rm -rf save/ deps/* .??* 
	rm -rf *.sh templates scripts imageset*yaml oc-mirror-workspace

.PHONY: distclean
#distclean: uninstall clean
distclean: clean ## Clean up repo for distribution
	rm -rf *.tar.gz oc-mirror-workspace deps
	rm -f .registry-creds.txt *.conf *.yaml 

