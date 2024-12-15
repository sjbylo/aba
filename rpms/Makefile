all: download

##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[\$\.\(\)\~\/a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

PHONY: download
download:  ## Download all required rpms into aba/rpms dir
	./download.sh

PHONY: install
install: ## Install all rpms in aba/rpms dir
	./install.sh

.PHONY: clean 
clean: ## Clean up 
	rm -f *.rpm

.PHONY: reset
reset: clean ## Clean up everything

