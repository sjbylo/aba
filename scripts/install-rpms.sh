#!/bin/bash -e

source scripts/include_all.sh

# Note, rpms required for "internal" bastion
# rpms required for "external" bastion (or laptop) are fewer.

[ "$1" = "internal" ] && rpms=$(cat templates/rpms-internal.txt) || rpms=$(cat templates/rpms-external.txt)

rpms_to_install=

# Ensure python3 is installed.  RHEL8 only installs "python36".  Needs special attention! 
rpm -q --quiet python3 || rpm -q --quiet python36 || if ! sudo dnf install python3 -y >> .dnf-install.log 2>&1; then
	echo_red "Warning: an error occured whilst trying to install 'python3', see the logs at .dnf-install.log."
	echo_red "If dnf cannot be used to install rpm packages, please install the following packages manually and try again!"
	echo_magenta $rpms

	exit 1
fi

for rpm in $rpms
do
	rpm -q --quiet $rpm || rpms_to_install="$rpms_to_install $rpm" 
done

if [ "$rpms_to_install" ]; then
	echo_cyan "Installing required rpms:$rpms_to_install (logging to .dnf-install.log). Please wait!"
	if ! sudo dnf install $rpms_to_install -y >> .dnf-install.log 2>&1; then
		echo_red "Warning: an error occured whilst trying to install RPMs, see the logs at .dnf-install.log."
		echo_red "If dnf cannot be used to install rpm packages, please install the following packages manually and try again!"
		echo_magenta $rpms

		exit 1
	fi
fi

exit 0
