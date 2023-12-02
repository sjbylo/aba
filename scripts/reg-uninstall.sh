#!/bin/bash -e

source scripts/include_all.sh

[ "$1" ] && set -x

install_rpm podman 

source mirror.conf

echo Uninstalling mirror registry from host $reg_host ...
./mirror-registry uninstall -v || true

