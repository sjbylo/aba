#!/bin/bash -e

#[ ! "$1" ] && echo Usage: `basename $0` --dir directory && exit 1
#[ "$DEBUG_ABA" ] && set -x

#cd install-mirror

# ./mirror-registry uninstall --autoApprove -v

##source mirror.conf

mkdir -p deps install-quay
cd install-quay

./mirror-registry uninstall -v

echo Cleaning up files ...
##rm -vf ~/.registry-creds.txt rootCA.pem ~/.mirror.conf 

