#!/bin/bash -e
# Download the required rpms (which match *this hosts* version) to this directory.
# The version of your external and internal bastions needs to be the same for this to work
# Later, 'make tar' will include these rpm files into the archive, to be installed on the internal bastion
# Note, if the bastions are not identicle (same rpms installed) try using --alldeps option 

source /etc/os-release

[ ! "$REDHAT_SUPPORT_PRODUCT_VERSION" ] && echo "Cannot determine the host OS version" && exit 1

# Override the version here, if needed
#REDHAT_SUPPORT_PRODUCT_VERSION=8

rpm -q dnf-utils --quiet || sudo yum install yum-utils -y
sudo yumdownloader --releasever=$REDHAT_SUPPORT_PRODUCT_VERSION --resolve $(cat ../templates/rpms-internal.txt) --destdir=.
#sudo yumdownloader --alldeps --releasever=$REDHAT_SUPPORT_PRODUCT_VERSION --resolve $(cat ../templates/rpms-internal.txt) --destdir=.

