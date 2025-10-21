#!/bin/bash -ex
# Install mirror reg remotly but using ssh, simulating "existing reg." use-case.

cd `dirname $0`

cat > .ssh.conf <<END
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
ConnectTimeout=15
LogLevel=ERROR
END

reg_host=$1

reg_ssh_user=$TEST_USER

ssh -F .ssh.conf $reg_ssh_user@$reg_host "mkdir -p test"

ssh $reg_ssh_user@$reg_host "rpm -q rsync || sudo yum install make rsync -y"
rpm -q rsync || sudo yum install make rsync -y

# Copy needed files
rsync --progress --partial -avz reg-install.sh mirror-registry-amd64.tar.gz  $reg_ssh_user@$reg_host:test

ssh -F .ssh.conf $reg_ssh_user@$reg_host "bash -e test/reg-install.sh"

# FIXME: do this, but fix reg-test-uninstall-remote.sh
#ssh -F .ssh.conf $reg_ssh_user@$reg_host "rm -rf test"  # Just so we don't run out of disk space during tests! 
ssh -F .ssh.conf $reg_ssh_user@$reg_host "rm -vf test/*.tar test/*.gz"  # Just so we don't run out of disk space during tests! 

