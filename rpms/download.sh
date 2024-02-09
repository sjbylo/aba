#!/bin/bash -e

source <(cat /etc/os-release)

[ ! "$REDHAT_SUPPORT_PRODUCT_VERSION" ] && echo "Cannot determine the host OS version" && exit 1

rpm -q dnf-utils --quiet || sudo yum install yum-utils -y
sudo yumdownloader --releasever=$REDHAT_SUPPORT_PRODUCT_VERSION --resolve podman make jq bind-utils nmstate net-tools skopeo python3 python3-jinja2 python3-pyyaml openssl --destdir=.
