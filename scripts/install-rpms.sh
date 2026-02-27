#!/bin/bash -e

# Ensure we're in aba root (script is in scripts/ subdirectory)
# Use pwd -P to resolve symlinks (important when called via cluster-dir/scripts/ symlink)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
cd "$SCRIPT_DIR/.." || exit 1

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

# Note, rpms required for "internal" bastion
# rpms required for "external" bastion (or laptop) are fewer.

[ "$1" = "internal" ] && rpms=$(cat templates/rpms-internal.txt) || rpms=$(cat templates/rpms-external.txt)

# Note: python3 must be listed explicitly in the rpm lists.  On RHEL 8,
# python3-jinja2 depends on python(abi) = 3.6 which is satisfied by
# platform-python (/usr/libexec/platform-python), so python3 (which
# provides /usr/bin/python3) is NOT pulled in automatically.
rpms_to_install=

for rpm in $rpms
do
	rpm -q --quiet $rpm || rpms_to_install="$rpms_to_install $rpm" 
done

if [ "$rpms_to_install" ]; then
	aba_info "Installing required rpm packages:$rpms_to_install (logging to .dnf-install.log). Please wait!"
	if ! $SUDO dnf install $rpms_to_install -y >> .dnf-install.log 2>&1; then
		echo_red "Warning: an error occured during rpm installation. See the logs at .dnf-install.log." >&2
		echo_red "If dnf cannot be used to install rpm packages, please install the following packages manually and try again!" >&2
		echo_magenta "$rpms_to_install"

		exit 1
	fi
fi

exit 0
