#!/bin/bash

if [ -s ~/.pull-secret.json ]; then
	if ! grep -q registry.redhat.io ~/.pull-secret.json; then
		echo "Was expecting to see the string 'registry.redhat.io' in your pull secret."
		echo "The format of your pull secret looks wrong, please fix it and try again!"
		exit 1
	else
		echo "Red Hat pull secret found at ~/.pull-secret.json"
		exit 0
	fi
fi

[ "$TERM" ] && tput setaf 1
echo
echo "Error: To download images from Red Hat's registry, a pull secret is required."
echo "       Please fetch your pull secret from https://console.redhat.com/openshift/downloads#tool-pull-secret"
echo "       and save it to the file ~/.pull-secret.json in your home directory."
[ "$TERM" ] && tput sgr0
echo

exit 1

