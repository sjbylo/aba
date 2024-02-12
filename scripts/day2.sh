#!/bin/bash -e

source scripts/include_all.sh

[ "$1" ] && set -x

umask 077

#source <(normalize-aba-conf)
#source <(normalize-aba-conf)
source <(normalize-mirror-conf)

# Add registry CA to the cluster.  See workaround: https://access.redhat.com/solutions/5514331
if [ -s regcreds/rootCA.pem ]; then
	echo "Adding the trust CA of the registry ($reg_host) ..."
	export additional_trust_bundle=$(cat regcreds/rootCA.pem) 
	echo "Using root CA file at regcreds/rootCA.pem"

	# To fix https://access.redhat.com/solutions/5514331
	scripts/j2 templates/cm-additional-trust-bundle.j2 | oc apply -f -

	oc patch image.config.openshift.io cluster \
		--type='json' -p='[{"op": "add", "path": "/spec/additionalTrustedCA", "value": {"name": "registry-config"}}]'

else	
	echo "Warning: No file regcreds/rootCA.pem.  Assuming mirror registry is using http."
fi

