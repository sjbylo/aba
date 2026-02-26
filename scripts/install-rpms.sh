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

# Note: python3 is NOT listed explicitly — it is pulled in automatically as a
# dependency of python3-jinja2 (requires python(abi) = 3.x, provided only by
# the python3 RPM). This holds for both RHEL 8 and 9.
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
