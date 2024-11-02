#!/usr/bin/bash 
# Generate the mirror.conf file

[ -s mirror.conf ] && exit 0

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)

if [ ! "$ocp_version" -o ! "$domain" ]; then
	echo_red "Values 'domain' and/or 'ocp_version' missing in aba.conf."
	echo_red "Please see the README on how to get started!"  # Should never need to reach here

	exit 1
fi

# Input is 'domain' from aba.conf
scripts/j2 templates/mirror.conf.j2 > mirror.conf

edit_file mirror.conf "Configure your private mirror registry (mirror.conf)" || exit 1  # if edirot=none exit 0

exit 0

