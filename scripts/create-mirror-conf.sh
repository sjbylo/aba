#!/usr/bin/bash 

[ -s mirror.conf ] && echo mirror.conf already exists && exit 0

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)

if [ ! "$ocp_version" ]; then
	echo "Please run ./aba first!"
	exit 1
fi

##echo
##echo -n "===> Configure your private mirror registry? Hit ENTER to continue or Ctrl-C to abort: "
ask "===> Configure your private mirror registry? "

##read yn

scripts/j2 templates/mirror.conf.j2 > mirror.conf

[ "$ask" ] && $editor mirror.conf

exit 0

