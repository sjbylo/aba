#!/bin/bash -e

. scripts/include_all.sh

[ "$1" ] && set -x

inst=
# not needed rpm -q --quiet nmstate|| inst=1
rpm -q --quiet podman     	|| inst=1
[ "$inst" ] && sudo dnf install podman -y >/dev/null 

. mirror.conf

echo Uninstalling $reg_host ...
./mirror-registry uninstall -v

echo Cleaning up files ...
rm -vf registry-creds.txt rootCA.pem deps/*

