#!/bin/bash 

which govc >/dev/null 2>&1 && exit 0

mkdir -p ~/bin

curl --connect-timeout 10 --retry 8 -sL -o - "https://github.com/vmware/govmomi/releases/latest/download/govc_$(uname -s)_$(uname -m).tar.gz" | tar -C ~/bin -xmvzf - govc


