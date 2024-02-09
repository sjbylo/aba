#!/bin/bash -e

rpms="podman make jq bind-utils nmstate net-tools skopeo python3 python3-jinja2 python3-pyyaml openssl"

for rpm in $rpms
do
	rpm -q --quiet $rpm && continue

	echo "Installing required rpms $rpms ..."
	sudo dnf install $rpms -y >> .dnf-install.log 2>&1
	echo "Installed rpms"
	break 
done

