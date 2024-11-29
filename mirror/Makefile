.SILENT:

TEMPLATES = ../templates
SCRIPTS   = ../scripts
debug   ?=

all: mirror

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  aba \033[36mcommand\033[0m\n"} /^(\s|[a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

init: .init 
.init: ../aba.conf
	ln -fs $(TEMPLATES) 
	ln -fs $(SCRIPTS) 
	ln -fs ../aba.conf 
	mkdir -p regcreds
	touch regcreds/.dummy  # Needed only so tar includes the *empty* regcreds dir
	touch .init
	@##echo Initialized `pwd`

# If aba.conf does not exist, must abort!
../aba.conf:
	@echo "aba.conf missing! Please read the README on how to get started!"
	@exit 1

.PHONY: cli-download
cli-download:
	@make -sC ../cli download 

# Only needed for 'make load'. 
.PHONY: cli-oc-mirror
cli-oc-mirror:
	@make -sC ../cli ~/bin/oc-mirror

imagesetconf: sync/imageset-config-sync.yaml save/imageset-config-save.yaml ## Create the intial image set config file with all provided values and operators
isconf: imagesetconf ## Same as imagesetconf

sync/imageset-config-sync.yaml: ../aba.conf
	$(SCRIPTS)/reg-create-imageset-config-sync.sh

save/imageset-config-save.yaml: ../aba.conf
	$(SCRIPTS)/reg-create-imageset-config-save.sh

## If vmware.conf does not exist, then create it
#../vmware.conf:
#	@make -sC .. vmware.conf

# FIXME: is vmware.conf needed for 'load' and 'sync' or only needed during 'make cluster'?
.PHONY: sync
#sync: .init .rpmsint ~/.pull-secret.json install ../vmware.conf    ## Sync images from the Internet directly to an internal registry (as defined in 'mirror/mirror.conf')
sync: .init .rpmsint ~/.pull-secret.json index cli-download install sync/imageset-config-sync.yaml ## Sync images from the Internet directly to an internal registry (as defined in 'mirror/mirror.conf') Use retry=# to retry after failure.
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
save: .init .rpmsext ~/.pull-secret.json index cli-download mirror-registry.tar.gz save/imageset-config-save.yaml  ## Save images from the Internet to mirror/save/ & download 'mirror-registry.tar.gz' for later installation into your private network. Use retry=# to retry after failure.
	###
	### Save images from the Internet to local disk 
	###
	$(SCRIPTS)/reg-save.sh $(debug) $(retry)

# oc-mirror is idempotent so no need for 'dot' flag files
.PHONY: load
load: .init cli-oc-mirror .rpmsint install  ## Load the saved images into a registry on the internal bastion (as defined in 'mirror/mirror.conf')  Use retry=# to retry after failure.
	###
	### Load images from local disk to mirror registry
	###
	$(SCRIPTS)/reg-load.sh $(debug) $(retry)

.PHONY: testload
testload: save install load     # Test the save, install, load process on a connected host

.rpmsext: .init
	$(SCRIPTS)/install-rpms.sh external
	@touch .rpmsext

.rpmsint: .init
	$(SCRIPTS)/install-rpms.sh internal
	@touch .rpmsint

rpmsclean:
	@rm -f .rpms*

### regcreds:
###	@mkdir regcreds 

mirror-registry: mirror-registry.tar.gz ## Extract the mirror-registry binary 
	tar xmvzf mirror-registry.tar.gz

mirror-registry.tar.gz: ## Download the mirror-registry tarball
	echo "Downloading mirror-registry.tar.gz ..."
	$(SCRIPTS)/download-mirror-registry.sh
	@#ver=`curl -skL https://mirror.openshift.com/pub/openshift-v4/clients/mirror-registry/ | grep -oP '>(\d+\.\d+(\.\d+)?)<' | grep -oP '\d+\.\d+(\.\d+)?' | sort -V | tail -n 1`
	@#curl --progress-bar -OL https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/$ver/mirror-registry.tar.gz

# mirror.conf depends on aba.conf for the 'domain aalue
#mirror.conf:                                 ../aba.conf   ## Configure the mirror.conf file.
#mirror.conf: .init                     ../aba.conf   ## Configure the mirror.conf file.
mirror.conf: ../aba.conf .init                        ## Configure the mirror.conf file.
	@$(SCRIPTS)/create-mirror-conf.sh $(debug)

mirror: install
install: .installed
.installed: .init .rpmsext mirror.conf mirror-registry  ## Set up the registry as per the settings in mirror.conf. Place credential file(s) into regcreds/ for existing registry.  See README.md.
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
verify: .init ## Using the credential files in 'mirror/regcreds' dir and the values in 'mirror/mirror.conf', verify access to the registry. 
	$(SCRIPTS)/reg-verify.sh $(debug)
	@rm -f .uninstalled 
	@touch .installed

.PHONY: uninstallclean
uninstallclean:
	@rm -f .uninstalled

.PHONY: tar
tar:   ## Create a full tar backup of ~/aba & ~/bin, ready to be transported to your private network.
	@make -sC .. tar $(out)

.PHONY: tarrepo
tarrepo:   ## Same as 'make tar' but excludes all 'mirror_seq*tar' files under mirror/save/.
	@make -sC .. tarrepo $(out)

.PHONY: inc
inc:   ## Same as 'make tar' except a timestamp file is used to only backup files that have changed since the last 'make inc' was run.
	@make -sC .. inc $(out)

.PHONY: index
index: init catalog

.PHONY: catalog
# -s needed here 'cos the download runs in the background (called by aba) and we don't want any output
catalog: ## Render all the latest Operators into a file which can be used in an imageset config file. 
	@make -sC ../cli ~/bin/oc-mirror
	@$(SCRIPTS)/download-operator-index.sh

#uninstall: .init mirror.conf mirror-registry .uninstalled ## Uninstall any previously installed registry  
uninstall: .init             mirror-registry .uninstalled     ## Uninstall any previously installed registry  
.uninstalled: 
	$(SCRIPTS)/reg-uninstall.sh  $(debug)
	@rm -f .installed
	@touch .uninstalled

.PHONY: checkversion
checkversion: init
	@$(SCRIPTS)/check-version-mismatch.sh

# Note that 'mirror-registry.tar.gz' is needed to 'uninstall' the registry.
# Note that KEEP the imageset conf file IF user has made changes, otherwise delete it.
# Do not delete anyting that is "expensive", i.e. user edited config file, a large (or long time to) downlaod items, the installed registry.
.PHONY: clean
clean:  ## Clean up temporary files only, keeping your configuration files, e.g. mirror.conf.
	@[ -f .installed ] && echo "Important: to uninstall the registry, run 'make uninstall'!" || true
	rm -rf *.tar mirror-registry 
	rm -f templates scripts
	rm -f aba.conf  # remove link only
	rm -f .init 
	rm -f ~/.aba.previous.backup  # This is the 'timestamp' file used for incremental backups
	rm -f save-mirror.sh sync-mirror.sh load-mirror.sh # Only clean up the created scripts, not the script needed to uninstall the reg.
	@#rm -f *.sh  # Don't clean up the scripts, esp. the reg. "uninstall" script since the registry is still installed 
	@[ -d save ] && [ save/.created -nt save/imageset-config*yaml ] && rm -rf save || true  # Delete only if not edited
	@[ -d sync ] && [ sync/.created -nt sync/imageset-config*yaml ] && rm -rf sync || true  # Delete only if not edited
	@#rm -rf {save,sync}/oc-mirror-workspace {save,sync}/publish {save,sync}/*.tar  # keep this simple

# Note that reg-uninstall.sh script will delete registry and regcreds/ dir.
# Backup regcreds/ and anything that should not be lost
.PHONY: distclean
#distclean: .init  # Clean up all files. Only use if you know what you're doing! Only used to re-distribute the repository.
distclean:                # Clean up all files. Only use if you know what you're doing! Only used to re-distribute the repository.
	@[ -f .installed ] && echo "Important: to uninstall the registry, you must run 'make uninstall' first!" || true
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
	rm -f .init 

