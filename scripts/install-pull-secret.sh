#!/bin/bash

[ -s ~/.pull-secret.json ] && echo "Red Hat pull secret found at ~/.pull-secret.json" && exit 0

echo
echo "Warning: Please write your Red Hat registry pull secret to the file ~/.pull-secret.json."
echo "         Fetch your secret key from https://console.redhat.com/openshift/downloads#tool-pull-secret"
echo

exit 1

# FIXME: Should we rather do this? ...
#echo -n "Paste the pull secret and then hit Ctrl-D: "
#umask 077
#cat > ~/.pull-secret.json

