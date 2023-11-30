#!/bin/bash -e

. scripts/include_all.sh


[ "$1" = "-d" ] && set -x

umask 077

source mirror.conf

which j2 >/dev/null 2>&1 || pip3 install j2cli  >/dev/null 2>&1

echo Generating imageContentSourcePolicy.yaml ...
j2 ./templates/image-content-sources.yaml.j2 > ../deps/image-content-sources.yaml
ln -fs ../deps/image-content-sources.yaml

