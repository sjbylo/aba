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

# On RHEL 8, `rpm -q python3` fails even after `dnf install python3`
# because the actual RPM is `python36` (or `python3.11`, etc.).
# DNF resolves the virtual provide, but rpm -q does not.
# Check for /usr/bin/python3 instead to avoid re-running dnf every time.
rpms_to_install=

for rpm in $rpms
do
	# Skip python3 RPM check if the binary already exists (RHEL 8 compat)
	[ "$rpm" = "python3" ] && [ -x /usr/bin/python3 ] && continue
	rpm -q --quiet $rpm || rpms_to_install="$rpms_to_install $rpm" 
done

if [ "$rpms_to_install" ]; then
	aba_info "Installing required rpm packages:$rpms_to_install (logging to .dnf-install.log). Please wait!"
	if ! $SUDO dnf install $rpms_to_install -y >> .dnf-install.log 2>&1; then
		echo_red "Warning: an error occured during rpm installation. See the logs at .dnf-install.log." >&2
		echo_red "If dnf cannot be used to install rpm packages, please install the following packages manually and try again!" >&2
		echo_magenta "$rpms_to_install" >&2

		exit 1
	fi
fi

exit 0
