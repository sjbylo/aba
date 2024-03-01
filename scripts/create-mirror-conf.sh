#!/usr/bin/bash 

source scripts/include_all.sh

[ "$1" ] && set -x

source <(normalize-aba-conf)
### ver=$(cat ../target-ocp-version.conf)

if [ ! "$ocp_version" ]; then
	echo "Please run ./aba first!"
	exit 1
fi

echo
echo -n "===> Configure your private mirror registry? Hit ENTER to continue or Ctrl-C to abort: "

read yn

### cp -f templates/mirror.conf .
scripts/j2 templates/mirror.conf.j2 > mirror.conf

$editor mirror.conf

exit 0

