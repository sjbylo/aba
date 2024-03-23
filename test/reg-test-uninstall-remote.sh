#!/bin/bash -e
# Install mirror reg remotly but using ssh, simulating "existing reg. use-case.

cat > .ssh.conf <<END
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
ConnectTimeout=15
END

reg_host=10.0.1.6

reg_ssh_user=steve

ssh -F .ssh.conf $reg_ssh_user@$reg_host "cd test && ./mirror-registry uninstall --autoApprove"

