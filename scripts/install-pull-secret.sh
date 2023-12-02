#!/bin/bash

[ -s ~/.pull-secret.json ] && exit 0

echo -n "Paste the pull secret and then hit Ctrl-D: "
umask 077
cat > ~/.pull-secret.json

