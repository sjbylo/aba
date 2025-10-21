#!/bin/bash -e
# Install mirror reg remotly but using ssh, simulating "existing reg. use-case.

cat > .ssh.conf <<END
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
ConnectTimeout=15
LogLevel=ERROR
END

reg_host=$1

reg_ssh_user=$TEST_USER

ssh -F .ssh.conf $reg_ssh_user@$reg_host "cd test && ./mirror-registry uninstall --autoApprove"

