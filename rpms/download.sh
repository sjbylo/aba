#!/bin/bash -e

source /etc/os-release

[ ! "$REDHAT_SUPPORT_PRODUCT_VERSION" ] && echo "Cannot determine the host OS version" && exit 1

#REDHAT_SUPPORT_PRODUCT_VERSION=8

rpm -q dnf-utils --quiet || sudo yum install yum-utils -y
sudo yumdownloader --releasever=$REDHAT_SUPPORT_PRODUCT_VERSION --resolve $(cat ../templates/rpms-internal.txt) --destdir=.
