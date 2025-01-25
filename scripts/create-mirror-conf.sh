#!/usr/bin/bash 
# Generate the mirror.conf file

[ -s mirror.conf ] && exit 0

source scripts/include_all.sh

[ "$1" = "-f" ] && force=$2 && shift 2
[ "$1" ] && set -x

source <(normalize-aba-conf)

# $domain is used as input in below j2 command
if [ ! "$ocp_version" -o ! "$domain" ]; then
	echo_red "Values 'domain' and/or 'ocp_version' missing in aba/aba.conf." >&2
	echo_red "Please see the README.md on how to get started!" >&2  # Should never need to reach here

	exit 1
fi

# Input is 'domain' from aba.conf
scripts/j2 templates/mirror.conf.j2 > mirror.conf

# If no 'force' (or if in doubt) ask!
if [ "$force" != "yes" ]; then
	edit_file mirror.conf "Configure your private mirror registry (mirror.conf)" || exit 1  # if editor=none exit 0
fi

exit 0

