#!/bin/bash -e

# Rpms required for "internal" bastion
#rpms_int="podman make jq python3 python3-jinja2 python3-pyyaml openssl coreos-installer bind-utils nmstate net-tools skopeo"
rpms_int=$(cat templates/rpms-internal.txt)

# Rpms required for "external" bastion (or laptop) 
rpms_ext="podman make jq python3 python3-jinja2 python3-pyyaml"
rpms_ext="       make jq python3 python3-jinja2               "

rpms=$rpms_ext
[ "$1" = "internal" ] && rpms=$rpms_int

for rpm in $rpms
do
	rpm -q --quiet $rpm && continue

	echo "Ensuring rpms installed: $rpms ..."
	sudo dnf install $rpms -y >> .dnf-install.log 2>&1
	echo "Installed rpms"
	break 
done

