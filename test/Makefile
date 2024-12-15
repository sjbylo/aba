##@ Help-related tasks

.SILENT:

.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

# Having to add fix for "file not found using "latest" in the URL path!
mirror-registry.tar.gz: ## Download the mirror-registry tarball
	curl --progress-bar -OL \
	   https://developers.redhat.com/content-gateway/rest/mirror/pub/openshift-v4/clients/mirror-registry/latest/mirror-registry.tar.gz 
	file mirror-registry.tar.gz | grep "gzip compressed data" || \
	curl --progress-bar -OL \
	   https://developers.redhat.com/content-gateway/file/pub/openshift-v4/clients/mirror-registry/1.3.11/mirror-registry.tar.gz

# Note, don't clean up the test.log*
.PHONY: clean
clean: ## Clean up files
	rm -rf *.tar.gz

.PHONY: reset
reset: clean ## Clean up repo for distribution

