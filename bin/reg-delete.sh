#!/bin/bash -e

[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
[ "$DEBUG_ABA" ] && set -x


cd install-mirror
# Root is needed to uninstall
# ./mirror-registry uninstall --autoApprove -v
./mirror-registry uninstall -v

rm -f ~/.registry-creds.txt rootCA.pem

