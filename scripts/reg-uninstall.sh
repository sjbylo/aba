#!/bin/bash -e

. scripts/include_all.sh

[ "$1" ] && set -x

./mirror-registry uninstall -v

echo Cleaning up files ...
rm -vf registry-creds.txt rootCA.pem 

