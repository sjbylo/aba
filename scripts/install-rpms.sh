#!/bin/bash -e

# Rpms required for "internal" bastion
#rpms_int="podman make jq python36 python3-jinja2 python3-pyyaml openssl coreos-installer bind-utils nmstate net-tools skopeo"
# rpms_int=$(cat templates/rpms-internal.txt)

# Rpms required for "external" bastion (or laptop) 
#rpms_ext="podman make jq python36 python3-jinja2 python3-pyyaml"
### rpms_ext="       make jq python36 python3-jinja2 python3-pyyaml"
# rpms_ext=$(cat templates/rpms-external.txt)

# Ensure python3 is installed.  RHEL8 only installs "python36"
rpm -q --quiet python3 || rpm -q --quiet python36 || sudo dnf install python3 -y >> .dnf-install.log 2>&1

[ "$1" = "internal" ] && rpms=$(cat templates/rpms-internal.txt) || rpms=$(cat templates/rpms-external.txt)

###echo "$rpms" | while read line
###do
	#### If at least one of the packages on each line exists then nothing to do, continue
	###exists=
	###for rpm in $line
	###do
		###rpm -q --quiet $rpm && exists=1
	###done
	###[ "$exists" ] && continue
###
	###rpm_aliases=$(echo "$rpms" | awk '{print $1}')  # Fetch just the common package names (aliases)
	###echo "Ensuring rpms installed: $rpms ..."
	######sudo dnf install $rpms -y >> .dnf-install.log 2>&1
	###sudo dnf install $rpm_aliases -y >> .dnf-install.log 2>&1
###
	###break
###done 
###exit 0

for rpm in $rpms
do
	rpm -q --quiet $rpm && continue

	echo FAILED rpm: $rpm
	exit 1

	echo "Ensuring rpms installed: $rpms ..."
	sudo dnf install $rpms -y >> .dnf-install.log 2>&1

	break 
done

