#!/bin/bash -ex
# Install mirror reg remotly but using ssh, simulating "existing reg." use-case.

cd `dirname $0`

mkdir -p ~/.aba

cat > ~/.aba/ssh.conf <<END
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
ConnectTimeout=15
PreferredAuthentications=publickey
PasswordAuthentication=no
LogLevel=ERROR
END

reg_host=${1:?Usage: $0 REGISTRY_HOST}

reg_ssh_user=${DIS_SSH_USER:-steve}

ssh -F ~/.aba/ssh.conf $reg_ssh_user@$reg_host "mkdir -p test"

ssh $reg_ssh_user@$reg_host "rpm -q rsync || sudo yum install make rsync -y"
rpm -q rsync || sudo yum install make rsync -y

# Copy needed files
rsync --progress --partial -avz reg-install.sh mirror-registry-amd64.tar.gz  $reg_ssh_user@$reg_host:test

ssh -F ~/.aba/ssh.conf $reg_ssh_user@$reg_host "bash -e test/reg-install.sh $reg_host"

# Clean up large files to save disk space. Also remove the mirror-registry
# binary so the next run re-extracts everything from the tarball cleanly.
ssh -F ~/.aba/ssh.conf $reg_ssh_user@$reg_host "rm -vf test/*.tar test/*.gz test/mirror-registry"

