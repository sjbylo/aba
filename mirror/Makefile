TEMPLATES = ../templates
SCRIPTS   = ../scripts
debug   ?=

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

init: .initialized regcreds
.initialized: 
	@ln -fs $(TEMPLATES) 
	@ln -fs $(SCRIPTS) 
	@ln -fs ../aba.conf 
	### @make -C ../cli      # Just to be sure
	@touch .initialized
	@echo Initialized `pwd`

# If aba.conf does not exist, then run the script to create it
../aba.conf:
	../aba

# If vmware.conf does not exist, then create it
../vmware.conf:
	make -C .. vmware.conf

.PHONY: sync
sync: init .rpmsint ~/.pull-secret.json install ../vmware.conf    ## Sync images from the Internet directly to an internal registry (as defined in 'mirror/mirror.conf')
	###
	### Upload images to the mirror registry from the Internet 
	###
	$(SCRIPTS)/reg-sync.sh  $(debug)

~/.pull-secret.json:
	$(SCRIPTS)/install-pull-secret.sh

# oc-mirror is idempotent so no need for 'dot' flag files here
.PHONY: save
# Note that for a connected laptop or bastion there is no need to install all the required packages (i.e. only 'rpmsext') 
# mirror-registry.tar.gz is downloaded *in case* the registry needs to be installed on the internal network (which we don't know yet)
save: init .rpmsext ~/.pull-secret.json mirror-registry.tar.gz ## Save images from the Internet to mirror/sav and download mirror-registry.tar.gz for installing mirror registry.
	###
	### Save images from the Internet to local disk 
	###
	$(SCRIPTS)/reg-save.sh  $(debug)

# oc-mirror is idempotent so no need for 'dot' flag files
.PHONY: load
load: init .rpmsint install ../vmware.conf  ## Load the saved images into a registry on the internal bastion (as defined in 'mirror/mirror.conf') 
	###
	### Load images from local disk to mirror registry
	###
	$(SCRIPTS)/reg-load.sh  $(debug)

.PHONY: testload
testload: save install load     # Test the save, install, load process on a connected host

rpms: .rpms  ## Install all rpms
.rpms: .rpmsint .rpmsext

.rpmsext: init
	@scripts/install-rpms.sh external
	@touch .rpmsext

.rpmsint: init
	@scripts/install-rpms.sh internal
	@touch .rpmsint

rpmsclean:
	@rm -f .rpms*

regcreds:
	mkdir regcreds 

mirror-registry: mirror-registry.tar.gz ## Extract the mirror-registry binary 
	tar xmvzf mirror-registry.tar.gz

mirror-registry.tar.gz: ## Download the mirror-registry tarball
	curl --progress-bar -OL \
	https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/latest/mirror-registry.tar.gz

# mirror,.conf no longer depeneds on aba.conf 
#mirror.conf:                                 ../aba.conf   ## Configure the mirror.conf file.
mirror.conf:                                               ## Configure the mirror.conf file.
	$(SCRIPTS)/create-mirror-conf.sh $(debug)

install: init .rpmsext mirror.conf mirror-registry .installed   ## Set up the registry as per the settings in mirror.conf. Place credential file(s) into regcreds/ for existing registry.  See README.md.
.installed: 
	#@test ! -f .uninstalled && exit 0
	$(SCRIPTS)/reg-install.sh $(debug) 
	@rm -f .uninstalled 
	@touch .installed

.PHONY: installclean
installclean:
	@rm -f .installed

.PHONY: verify
verify: init 
	$(SCRIPTS)/reg-verify.sh $(debug)
	@rm -f .uninstalled 
	@touch .installed

#uninstall: init mirror.conf mirror-registry .uninstalled ## Uninstall any previously installed registry  
uninstall: init             mirror-registry .uninstalled     ## Uninstall any previously installed registry  
.uninstalled: 
	#@test ! -f .installed && exit 0
	$(SCRIPTS)/reg-uninstall.sh  $(debug)
	@rm -f .installed
	@touch .uninstalled

.PHONY: uninstallclean
uninstallclean:
	@rm -f .uninstalled

.PHONY: inc
inc:   ## Create an incremental tar backup of the sync and/or save directories, after running 'make save' or 'make sync'
	@make -s -C .. inc

.PHONY: tidy 
tidy: ## Tidy large uncompressed files before copying the repo to the internal bastion 
	rm -rf *.tar mirror-registry .rpms* .installed .loaded .initialized

.PHONY: clean
clean: tidy ## Clean up files
	rm -rf                  .??* 
	rm -rf *.sh templates scripts ### oc-mirror-workspace
	rm -rf {save,sync}/oc-mirror-workspace {save,sync}/publish {save,sync}/*.tar  # keep the imageset config file
	rm -f mirror-registry.tar.gz

.PHONY: distclean
#distclean: uninstall clean ## Clean up repo for distribution
distclean:            clean ## Clean up repo for distribution
	rm -rf *.tar.gz oc-mirror-workspace regcreds
	rm -f .registry-creds.txt *.conf *.yaml 
	rm -rf save sync regcreds
	touch .uninstalled 

