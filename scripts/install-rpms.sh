#!/bin/bash -e

# Note, rpms required for "internal" bastion
# rpms required for "external" bastion (or laptop) are fewer.

# Ensure python3 is installed.  RHEL8 only installs "python36"
rpm -q --quiet python3 || rpm -q --quiet python36 || sudo dnf install python3 -y >> .dnf-install.log 2>&1

[ "$1" = "internal" ] && rpms=$(cat templates/rpms-internal.txt) || rpms=$(cat templates/rpms-external.txt)

for rpm in $rpms
do
	# Check if each rpm is already installed.  Don't run dnf unless we have to.
	rpm -q --quiet $rpm && continue

	echo "rpm '$rpm' missing. Ensuring all required rpms installed: $rpms ..."
	sudo dnf install $rpms -y >> .dnf-install.log 2>&1

	break 
done

exit 0
