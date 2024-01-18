#!/bin/bash -ex
# Install mirror reg remotly but using ssh, simulating "existing reg." use-case.

cd `dirname $0`

cat > .ssh.conf <<END
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
ConnectTimeout=15
END

reg_host=$1

ssh -F .ssh.conf $(whoami)@$reg_host "mkdir -p test"

ssh $(whoami)@$reg_host "rpm -q rsync || sudo yum install make rsync -y"
rpm -q rsync || sudo yum install make rsync -y

# Copy needed files
rsync --progress --partial -avz reg-install.sh mirror-registry.tar.gz  $(whoami)@10.0.1.6:test

ssh -F .ssh.conf $(whoami)@$reg_host "bash -e test/reg-install.sh"

