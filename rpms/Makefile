all: download

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

