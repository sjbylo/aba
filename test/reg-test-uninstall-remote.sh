#!/bin/bash -e
# Install mirror reg remotly but using ssh, simulating "existing reg. use-case.

cd `dirname $0`

cat > .ssh.conf <<END
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
ConnectTimeout=15
LogLevel=ERROR
END

reg_host=$1

reg_ssh_user=$TEST_USER

rsync --progress --partial -avz reg-install.sh mirror-registry-amd64.tar.gz  $reg_ssh_user@$reg_host:test

ssh -F .ssh.conf $reg_ssh_user@$reg_host tar -C test -xvzf test/mirror-registry-amd64.tar.gz

ssh -F .ssh.conf $reg_ssh_user@$reg_host "cd test && ./mirror-registry uninstall --autoApprove"

