#!/usr/bin/bash 
# Generate the mirror.conf file

[ -s mirror.conf ] && exit 0

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)

if [ ! "$ocp_version" ]; then
	echo "Please run ./aba first!"  # Should never need to reach here

	exit 1
fi

scripts/j2 templates/mirror.conf.j2 > mirror.conf

edit_file mirror.conf "Configure your private mirror registry (mirror.conf)"

exit 0

