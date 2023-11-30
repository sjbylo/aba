#!/bin/bash

curl -s https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/release.txt | egrep -o "Version: +[0-9]+\.[0-9]+\.[0-9]+"| awk '{print $2}'
