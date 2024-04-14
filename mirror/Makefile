TEMPLATES = ../templates
SCRIPTS   = ../scripts
debug   ?=

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

init: .initialized 
.initialized: 
	ln -fs $(TEMPLATES) 
	ln -fs $(SCRIPTS) 
	ln -fs ../aba.conf 
	mkdir -p regcreds
	touch regcreds/.dummy  # Needed only so tar includes the *empty* regcreds dir
	make -C ../cli 
	touch .initialized
	@echo Initialized `pwd`

# If aba.conf does not exist, then run the script to create it
../aba.conf:
	../aba

## If vmware.conf does not exist, then create it
#../vmware.conf:
#	@make -C .. vmware.conf

.PHONY: sync
#sync: .initialized .rpmsint ~/.pull-secret.json install ../vmware.conf    ## Sync images from the Internet directly to an internal registry (as defined in 'mirror/mirror.conf')
sync: .initialized .rpmsint ~/.pull-secret.json install                   ## Sync images from the Internet directly to an internal registry (as defined in 'mirror/mirror.conf')
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
save: .initialized .rpmsext ~/.pull-secret.json mirror-registry.tar.gz ## Save images from the Internet to mirror/save/ & download 'mirror-registry.tar.gz' for later installation into your private network.
	###
	### Save images from the Internet to local disk 
	###
	$(SCRIPTS)/reg-save.sh  $(debug)

# oc-mirror is idempotent so no need for 'dot' flag files
.PHONY: load
#load: .initialized .rpmsint install ../vmware.conf  ## Load the saved images into a registry on the internal bastion (as defined in 'mirror/mirror.conf') 
load: .initialized .rpmsint install                 ## Load the saved images into a registry on the internal bastion (as defined in 'mirror/mirror.conf') 
	###
	### Load images from local disk to mirror registry
	###
	$(SCRIPTS)/reg-load.sh  $(debug)

.PHONY: testload
testload: save install load     # Test the save, install, load process on a connected host

.rpmsext: .initialized
	$(SCRIPTS)/install-rpms.sh external
	@touch .rpmsext

.rpmsint: .initialized
	$(SCRIPTS)/install-rpms.sh internal
	@touch .rpmsint

rpmsclean:
	@rm -f .rpms*

### regcreds:
###	@mkdir regcreds 

mirror-registry: mirror-registry.tar.gz ## Extract the mirror-registry binary 
	tar xmvzf mirror-registry.tar.gz

mirror-registry.tar.gz: ## Download the mirror-registry tarball
	# Downloading 'mirror-registry.tar.gz' for later installation.
	curl --progress-bar -OL \
	https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/latest/mirror-registry.tar.gz

# mirror,.conf no longer depends on aba.conf 
#mirror.conf:                                 ../aba.conf   ## Configure the mirror.conf file.
mirror.conf: .initialized                                               ## Configure the mirror.conf file.
	@$(SCRIPTS)/create-mirror-conf.sh $(debug)

install: .installed
.installed: .initialized .rpmsext mirror.conf mirror-registry  ## Set up the registry as per the settings in mirror.conf. Place credential file(s) into regcreds/ for existing registry.  See README.md.
	$(SCRIPTS)/reg-install.sh $(debug) 
	@rm -f .uninstalled 
	@touch .installed

.PHONY: installclean
installclean:
	@rm -f .installed

.PHONEY: password pw
password: pw
pw: 
	$(SCRIPTS)/reg-existing-create-pull-secret.sh $(debug)

.PHONY: verify
verify: .initialized ## Using the credential files in 'mirror/regcreds' dir and the values in 'mirror/mirror.conf', verify access to the registry. 
	$(SCRIPTS)/reg-verify.sh $(debug)
	@rm -f .uninstalled 
	@touch .installed

.PHONY: uninstallclean
uninstallclean:
	@rm -f .uninstalled

.PHONY: tar
tar:   ## Create a full tar backup of ~/aba & ~/bin, ready to be transported to your private network.
	@make -s -C .. tar

.PHONY: tarrepo
tarrepo:   ## Same as 'make tar' but excludes all 'mirror_seq*tar' files under mirror/save/.
	@make -s -C .. tarrepo

.PHONY: inc
inc:   ## Same as 'make tar' except a timestamp file is used to only backup files that have changed since the last 'make inc' was run.
	@make -s -C .. inc

.PHONY: catalog
catalog: ## Render all the latest Operators into a file which can be used in an imageset config file. 
	scripts/fetch-operator-catalog.sh

#uninstall: .initialized mirror.conf mirror-registry .uninstalled ## Uninstall any previously installed registry  
uninstall: .initialized             mirror-registry .uninstalled     ## Uninstall any previously installed registry  
.uninstalled: 
	$(SCRIPTS)/reg-uninstall.sh  $(debug)
	@rm -f .installed
	@touch .uninstalled

# Note that 'mirror-registry.tar.gz' is needed to 'uninstall' registry in distclean!
# Note that KEEP the imageset conf file IF user has made changes, otherwise delete it.
.PHONY: clean
clean:  ## Clean up temporary files only, keeping your configuration files, e.g. mirror.conf.
	@echo "Note: to uninstall the registry, run 'make uninstall'" 
	rm -rf *.tar mirror-registry 
	rm -f  .initialized 
	rm -f  templates scripts
	rm -rf {save,sync}/oc-mirror-workspace {save,sync}/publish {save,sync}/*.tar  # keep the imageset config file
	rm -f ~/.aba.previous.backup  # This is the 'timestamp' file used for incremental backups
	rm -f aba.conf  # remove link only
	rm -f save-mirror.sh sync-mirror.sh load-mirror.sh # Only clean up the created scripts, not the script needed to uninstall the reg.
	@#rm -f *.sh  # Don't clean up the scripts, esp. the reg. "uninstall" script since the registry is still installed 
	@[ -d save ] && [ save/.created -nt save/imageset-config*yaml ] && rm -rfv save || true  # Delete only if not edited

# Note that reg-uninstall.sh script will delete registry and regcreds/ dir.
.PHONY: distclean
distclean: .initialized  # Clean up all files. Only use if you know what you're doing! Only used to re-distribute the repository.
	@echo "Note: to uninstall the registry, run 'make uninstall'" 
	@test "$(ask)" && $(SCRIPTS)/ask.sh -n "Are you sure?" && echo "Not running 'make distclean' in $(PWD)" && exit 1 || true
	@make clean
	@[ -d regcreds ] && rm -rf regcreds.bk && mv regcreds regcreds.bk && mv mirror.conf mirror.conf.bk && echo mirror config backed up to regcreds.bk and mirror.conf.bk || true
	@#rm -rf regcreds
	@#rm -f mirror.conf
	rm -rf *.tar.gz oc-mirror-workspace 
	rm -f *.conf *.yaml 
	rm -rf save sync 
	rm -f save-mirror.sh sync-mirror.sh load-mirror.sh
	rm -f .dnf-install.log
	rm -f .ssh.conf
	rm -f .rpmsext .rpmsint

.PHONY: testask
testask:
	@test "$(ask)" && $(SCRIPTS)/ask.sh -n "Are you sure?" && echo "stop..." && exit 1 || true
	@echo cont...

