#!/bin/bash -e
# For testing, rsync all files to an internal test bastion 

[ ! "$1" ] && echo "Usage: `basename $0` <bastion ip>" && exit 1

cd ..
rsync --delete --progress --partial --times -avz \
        --exclude '*/.git*' \
        --exclude 'aba/cli/*' \
        --exclude 'aba/mirror/mirror-registry' \
        --exclude 'aba/mirror/*.tar' \
        --exclude "aba/mirror/.rpms" \
        --exclude 'aba/*/*/*.iso' \
                bin aba $(whoami)@$1:

