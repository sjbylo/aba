#!/bin/bash 

. scripts/include_all.sh

[ "$1" ] && set -x

umask 077

source mirror.conf

install_rpm podman  python3-jinja2  python3

export ocp_ver=$ocp_target_ver
export ocp_ver_major=$(echo $ocp_target_ver | cut -d. -f1-2)

echo Generating imageset-config.yaml to save images to local disk ...
scripts/j2 ./templates/imageset-config-save.yaml.j2 > imageset-config-save.yaml 

./scripts/create-containers-auth.sh

echo 
echo "Saving images from the external network (Internet) to mirror/save/."
echo "Ensure there is enough disk space under $PWD/save.  "
echo "This can take 10-20 mins to complete!"
echo 

# Set up script to help for manual re-sync
echo "oc mirror --config=./imageset-config-save.yaml file://save" > save-mirror.sh && chmod 700 save-mirror.sh 
cat ./save-mirror.sh
./save-mirror.sh

