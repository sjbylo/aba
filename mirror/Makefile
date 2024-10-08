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
	touch .initialized
	@##echo Initialized `pwd`

# If aba.conf does not exist, must abort!
../aba.conf:
	@echo "aba.conf missing! Please read the README on how to get started!"
	@exit 1

.PHONY: cli-download
cli-download:
	make -C ../cli download   #  needed so 'make load' works on internal bastion

# Only needed for 'make load'. 
.PHONY: cli-oc-mirror
cli-oc-mirror:
	make -C ../cli ~/bin/oc-mirror

## If vmware.conf does not exist, then create it
#../vmware.conf:
#	@make -C .. vmware.conf

# FIXME: is vmware.conf needed for 'load' and 'sync' or only needed during 'make cluster'?
.PHONY: sync
#sync: .initialized .rpmsint ~/.pull-secret.json install ../vmware.conf    ## Sync images from the Internet directly to an internal registry (as defined in 'mirror/mirror.conf')
sync: .initialized .rpmsint ~/.pull-secret.json index cli-download install                   ## Sync images from the Internet directly to an internal registry (as defined in 'mirror/mirror.conf') Use retry=# to retry after failure.
	###
	### Upload images to the mirror registry from the Internet 
	###
	$(SCRIPTS)/reg-sync.sh $(debug) $(retry)

~/.pull-secret.json:
	$(SCRIPTS)/install-pull-secret.sh

# oc-mirror is idempotent so no need for 'dot' flag files here
.PHONY: save
# Note that for a connected laptop or bastion there is no need to install all the required packages (i.e. only 'rpmsext') 
# mirror-registry.tar.gz is downloaded *in case* the registry needs to be installed on the internal network (which we don't know yet)
save: .initialized .rpmsext ~/.pull-secret.json index cli-download mirror-registry.tar.gz ## Save images from the Internet to mirror/save/ & download 'mirror-registry.tar.gz' for later installation into your private network. Use retry=# to retry after failure.
	###
	### Save images from the Internet to local disk 
	###
	$(SCRIPTS)/reg-save.sh $(debug) $(retry)

# oc-mirror is idempotent so no need for 'dot' flag files
.PHONY: load
load: .initialized cli-oc-mirror .rpmsint install  ## Load the saved images into a registry on the internal bastion (as defined in 'mirror/mirror.conf')  Use retry=# to retry after failure.
	###
	### Load images from local disk to mirror registry
	###
	$(SCRIPTS)/reg-load.sh $(debug) $(retry)

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
	https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/1.3.9/mirror-registry.tar.gz

# mirror.conf depends on aba.conf for the 'domain aalue
#mirror.conf:                                 ../aba.conf   ## Configure the mirror.conf file.
mirror.conf: .initialized                     ../aba.conf   ## Configure the mirror.conf file.
	@$(SCRIPTS)/create-mirror-conf.sh $(debug)

install: .installed
.installed: .initialized .rpmsext mirror.conf mirror-registry  ## Set up the registry as per the settings in mirror.conf. Place credential file(s) into regcreds/ for existing registry.  See README.md.
	@rm -f .uninstalled 
	$(SCRIPTS)/reg-install.sh $(debug) 
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
	@make -s -C .. tar $(out)

.PHONY: tarrepo
tarrepo:   ## Same as 'make tar' but excludes all 'mirror_seq*tar' files under mirror/save/.
	@make -s -C .. tarrepo $(out)

.PHONY: inc
inc:   ## Same as 'make tar' except a timestamp file is used to only backup files that have changed since the last 'make inc' was run.
	@make -s -C .. inc $(out)

.PHONY: index
index: init catalog

.PHONY: catalog
# -s needed here 'cos the download runs in the background (called by aba) and we don't want any output
catalog: ## Render all the latest Operators into a file which can be used in an imageset config file. 
	@make -s -C ../cli ~/bin/oc-mirror
	@scripts/download-operator-index.sh

#uninstall: .initialized mirror.conf mirror-registry .uninstalled ## Uninstall any previously installed registry  
uninstall: .initialized             mirror-registry .uninstalled     ## Uninstall any previously installed registry  
.uninstalled: 
	$(SCRIPTS)/reg-uninstall.sh  $(debug)
	@rm -f .installed
	@touch .uninstalled

.PHONY: checkversion
checkversion: init
	@scripts/check-version-mismatch.sh

# Note that 'mirror-registry.tar.gz' is needed to 'uninstall' the registry.
# Note that KEEP the imageset conf file IF user has made changes, otherwise delete it.
# Do not delete anyting that is "expensive", i.e. user edited config file, a large (or long time to) downlaod items, the installed registry.
.PHONY: clean
clean:  ## Clean up temporary files only, keeping your configuration files, e.g. mirror.conf.
	@[ -f .installed ] && echo "Important: to uninstall the registry, run 'make uninstall'!" || true
	rm -rf *.tar mirror-registry 
	rm -f templates scripts
	rm -f aba.conf  # remove link only
	rm -f .initialized 
	rm -f ~/.aba.previous.backup  # This is the 'timestamp' file used for incremental backups
	rm -f save-mirror.sh sync-mirror.sh load-mirror.sh # Only clean up the created scripts, not the script needed to uninstall the reg.
	@#rm -f *.sh  # Don't clean up the scripts, esp. the reg. "uninstall" script since the registry is still installed 
	@[ -d save ] && [ save/.created -nt save/imageset-config*yaml ] && rm -rf save || true  # Delete only if not edited
	@[ -d sync ] && [ sync/.created -nt sync/imageset-config*yaml ] && rm -rf sync || true  # Delete only if not edited
	@#rm -rf {save,sync}/oc-mirror-workspace {save,sync}/publish {save,sync}/*.tar  # keep this simple

# Note that reg-uninstall.sh script will delete registry and regcreds/ dir.
# Backup regcreds/ and anything that should not be lost
.PHONY: distclean
#distclean: .initialized  # Clean up all files. Only use if you know what you're doing! Only used to re-distribute the repository.
distclean:                # Clean up all files. Only use if you know what you're doing! Only used to re-distribute the repository.
	@[ -f .installed ] && echo "Important: to uninstall the registry, you must run 'make uninstall' first!" || true
	@[ -x scripts/distclean-gate.sh ] && scripts/distclean-gate.sh $(force) || true
	make clean
	@[ -d regcreds ] && rm -rf regcreds.bk && mv regcreds regcreds.bk && mv mirror.conf mirror.conf.bk && echo mirror config backed up to regcreds.bk and mirror.conf.bk || true
	@#rm -rf regcreds
	@#rm -f mirror.conf
	rm -rf *.tar.gz oc-mirror-workspace 
	rm -f *.conf *.yaml 
	rm -rf save sync 
	rm -f save-mirror.sh sync-mirror.sh load-mirror.sh
	rm -f *.log .*.log
	rm -f .ssh.conf
	rm -f .rpmsext .rpmsint
	rm -f .redhat-operator-index* 
	rm -f .initialized 

