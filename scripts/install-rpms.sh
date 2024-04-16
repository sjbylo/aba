#!/bin/bash -e

# Note, rpms required for "internal" bastion
# rpms required for "external" bastion (or laptop) are fewer.

# Ensure python3 is installed.  RHEL8 only installs "python36"
rpm -q --quiet python3 || rpm -q --quiet python36 || sudo dnf install python3 -y >> .dnf-install.log 2>&1

[ "$1" = "internal" ] && rpms=$(cat templates/rpms-internal.txt) || rpms=$(cat templates/rpms-external.txt)

rpms_to_install=

for rpm in $rpms
do
	rpm -q --quiet $rpm || rpms_to_install="$rpms_to_install $rpm" 
done

if [ "$rpms_to_install" ]; then
	echo "Installing missing rpms:$rpms_to_install (logging to .dnf-install.log)"
	sudo dnf install $rpms -y >> .dnf-install.log 2>&1
fi

exit 0
