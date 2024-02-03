#!/bin/bash -e
# For testing, rsync all files to an internal test bastion 

[ ! "$1" ] && echo "Usage: `basename $0` <bastion ip>" && exit 1

# Copy over ~/bin and ~/aba
# Do not copy over '.rpms' since they also need to be installed on the internal bastion!
# Do not copy unneeded files, e.g. *.tar (unpacked from mirror-registry.tar.gz) and any unwanted iso files.

cd ..
rsync --progress --partial --times -avz \
        --exclude '*/.git*' \
        --exclude 'aba/cli/*' \
        --exclude 'aba/mirror/mirror-registry' \
        --exclude 'aba/mirror/*.tar' \
        --exclude "aba/mirror/.rpms" \
        --exclude 'aba/*/*/*.iso' \
                bin aba $(whoami)@$1:

