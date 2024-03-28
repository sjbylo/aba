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
	touch regcreds/.dummy  # Needed only so tar includes the regcreds dir
	touch .initialized
	@echo Initialized `pwd`

# If aba.conf does not exist, then run the script to create it
../aba.conf:
	../aba

# If vmware.conf does not exist, then create it
../vmware.conf:
	@make -C .. vmware.conf

.PHONY: sync
sync: .initialized .rpmsint ~/.pull-secret.json install ../vmware.conf    ## Sync images from the Internet directly to an internal registry (as defined in 'mirror/mirror.conf')
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
load: .initialized .rpmsint install ../vmware.conf  ## Load the saved images into a registry on the internal bastion (as defined in 'mirror/mirror.conf') 
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
verify: .initialized 
	$(SCRIPTS)/reg-verify.sh $(debug)
	@rm -f .uninstalled 
	@touch .installed

#uninstall: .initialized mirror.conf mirror-registry .uninstalled ## Uninstall any previously installed registry  
uninstall: .initialized             mirror-registry .uninstalled     ## Uninstall any previously installed registry  
.uninstalled: 
	$(SCRIPTS)/reg-uninstall.sh  $(debug)
	@rm -f .installed
	@touch .uninstalled

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

### .PHONY: tidy 
### tidy: ## Tidy large uncompressed files before copying the repo to the internal bastion 

# Note that 'mirror-registry.tar.gz' is needed to 'uninstall' registry in distclean!
# FIXME: Only delete the imageset conf file IF user has made changes, otherwise delete it?
.PHONY: clean
clean:  ## Clean up only, keeping configuration files: image set and mirror.conf. It is recommended to backup your important files. 
	rm -rf *.tar mirror-registry 
	rm -f  .initialized 
	rm -f  templates scripts
	rm -rf {save,sync}/oc-mirror-workspace {save,sync}/publish {save,sync}/*.tar  # keep the imageset config file
	rm -f ~/.aba.previous.backup
	rm -f aba.conf  # remove link
	rm -f *.sh
	@[ -d save ] && [ save/.created -nt save/imageset-config*yaml ] && rm -rfv save || true

# Note that reg-uninstall.sh script will delete registry and reg-uninstall.sh $ regcreds/ itself
.PHONY: distclean
distclean: clean  # Clean up all files. Only use if you know what you're doing! Only used to re-distribute the repository.
	@$(SCRIPTS)/ask.sh "Are you sure?"
	rm -rf *.tar.gz oc-mirror-workspace 
	rm -f *.conf *.yaml 
	rm -rf save sync 
	rm -f save-mirror.sh sync-mirror.sh load-mirror.sh
	rm -f .dnf-install.log
	rm -f mirror.conf
	rm -f .ssh.conf
	rm -f .rpmsext .rpmsint
	[ -d regcreds ] && rm -rf regcreds.bk && cp -rp regcreds regcreds.bk
	rm -rf regcreds

