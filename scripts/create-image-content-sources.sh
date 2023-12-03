#!/bin/bash -e

. scripts/include_all.sh

[ "$1" = "-d" ] && set -x

umask 077

install_rpm python3-pip
install_pip j2cli

source mirror.conf

echo Generating imageContentSourcePolicy.yaml ...
j2 ./templates/image-content-sources.yaml.j2 > ../deps/image-content-sources.yaml
ln -fs ../deps/image-content-sources.yaml

