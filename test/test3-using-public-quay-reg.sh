#!/bin/bash -x
# This test is for a connected bastion.  It will install registry on remote bastion and then sync images and install clusters, 
# ... then savd/load images and install clusters. 
# This test requires a valid ~/.vmware.conf file.

export INFO_ABA=1
export ABA_TESTING=1  # No usage reporting
[ ! "$TEST_CHANNEL" ] && export TEST_CHANNEL=stable
hash -r  # Forget all command locations in $PATH

### TEST for clean start with or without the rpms.  
if true; then
	# Assuming user will NOT install all rpms in advance and aba will install them.
	#sudo dnf remove make jq bind-utils nmstate net-tools skopeo python3-jinja2 python3-pyyaml openssl coreos-installer -y
	#sudo dnf remove git hostname make jq bind-utils nmstate net-tools skopeo python3-jinja2 python3-pyyaml openssl coreos-installer ncurses -y
	sudo dnf remove git hostname make jq bind-utils nmstate net-tools skopeo python3-jinja2 python3-pyyaml openssl coreos-installer         -y
else
	# FIXME: test for pre-existing rpms!  In this case we don't want yum to run *at all* as it may error out
	# Assuming user will install all rpms in advance.
	sudo dnf install -y $(cat templates/rpms-internal.txt)
	sudo dnf install -y $(cat templates/rpms-external.txt)
fi

[ ! "$TEST_USER" ] && export TEST_USER=$(whoami)

# Try to fix "out of space" error when generating the op. index
cat /etc/redhat-release | grep -q ^Fedora && sudo mount -o remount,size=20G /tmp && rm -rf /tmp/render-registry-*

cd `dirname $0`
cd ..

rm -fr ~/.containers ~/.docker
rm -f ~/.aba.previous.backup
rm -f ~/.ssh/quay_installer*

# Need this so this test script can be run standalone
[ ! "$VER_OVERRIDE" ] && #export VER_OVERRIDE=4.16.12 # Uncomment to use the 'latest' stable version of OpenShift
[ ! "$internal_bastion_rhel_ver" ] && export internal_bastion_rhel_ver=rhel9  # rhel8 or rhel9

###int_bastion_hostname=registry.example.com
###int_bastion_vm_name=bastion-internal-$internal_bastion_rhel_ver

source scripts/include_all.sh no-trap  # Need for below normalize fn() calls
source test/include.sh
trap - ERR # We don't want this trap during testing.  Needed for below normalize fn() calls

[ ! "$target_full" ] && default_target="iso"   # Default is to generate 'iso' only   # Default is to only create iso
mylog default_target=$default_target

mylog ============================================================
mylog Starting test $(basename $0)
mylog ============================================================
mylog "Test to install sno directly from public registry."
mylog

rm -rf ~/.cache/agent/*

rm -rf $HOME/*/.oc-mirror/.cache

# FIXME: Don't think we need this since test-cmd will loop on error unless -i is used
#set -ex

ntp_ip=10.0.1.8 # If available

##which make || sudo dnf install make -y

test-cmd -m "Installing aba" ./install 
#test-cmd -m "Activating shortcuts.conf" cp -f .shortcuts.conf shortcuts.conf

# clean up all, assuming reg. is not running (deleted)
v=4.16.3
### echo ocp_version=$v > aba.conf  # needed so reset works without calling aba (interactive). aba.conf is created below. 
aba --dir ~/aba reset --force
#####mv cli cli.m && mkdir -v cli && cp cli.m/Makefile cli && aba reset --force; rm -rf cli && mv cli.m cli
### aba -d cli reset --force  # Ensure there are no old and potentially broken binaries
### test-cmd -m "Show content of mirror/save" 'ls -l mirror mirror/save || true'
#aba clean

# Set up aba.conf properly
rm -f aba.conf
vf=~steve/.vmware.conf
[ ! "$VER_OVERRIDE" ] && VER_OVERRIDE=latest
[ ! "$oc_mirror_ver_override" ] && oc_mirror_ver_override=v2
test-cmd -m "Configure aba.conf for version '$VER_OVERRIDE' and vmware $vf" aba --platform vmw --channel $TEST_CHANNEL --version $VER_OVERRIDE ### --vmw $vf
#test-cmd -m "Configure aba.conf for version 'latest' and vmware $vf" aba --version latest ### --vmw $vf

mylog "Setting oc_mirror_version=$oc_mirror_ver_override in aba.conf"
sed -i "s/^oc_mirror_version=.*/oc_mirror_version=$oc_mirror_ver_override /g" aba.conf

mylog Set up vmware.conf
test-cmd cp -v $vf vmware.conf 
sed -i "s#^VC_FOLDER=.*#VC_FOLDER=/Datacenter/vm/abatesting#g" vmware.conf
test-cmd -m "Checking vmware.conf" grep vm/abatesting vmware.conf

test-cmd -m "Set ask to false" aba --noask

test-cmd -m "Setting ntp_servers=$ntp_ip,ntp.example.com in aba.conf" aba --ntp $ntp_ip ntp.example.com

source <(normalize-aba-conf)
echo Check aba.conf:
normalize-aba-conf

#reg_ssh_user=$(whoami)
reg_ssh_user=$TEST_USER

aba --dir cli ~/bin/govc
source <(normalize-vmware-conf)

test-cmd -m "Removing sno dir" rm -rf sno

test-cmd -m "Remove CLIs" aba -d cli reset -f

test-cmd -m "Testing direct internet config" aba cluster -n sno -t sno --starting-ip 10.0.1.201 --step cluster.conf -I direct
test-cmd -m "Creating agentconf" aba -d sno agentconf
test-cmd -m "Verifying direct internet config - 'registry.redhat.io' exists" 		"grep registry.redhat.io	sno/install-config.yaml"
test-cmd -m "Verifying direct internet config - 'cloud.openshift.com' exists" 		"grep cloud.openshift.com	sno/install-config.yaml"
test-cmd -m "Verifying direct internet config - 'sshKey:' exists" 			"grep sshKey:			sno/install-config.yaml"
test-cmd -m "Verifying direct internet config - ^proxy does not exist"			"! grep ^proxy			sno/install-config.yaml"
test-cmd -m "Verifying direct internet config - httpProxy does not exist" 		"! grep httpProxy		sno/install-config.yaml"
test-cmd -m "Verifying direct internet config - 'BEGIN CERTIFICATE' does not exist"	"! grep 'BEGIN CERTIFICATE'	sno/install-config.yaml"
test-cmd -m "Verifying direct internet config - 'ImageDigestSources' does not exist" 	"! grep ImageDigestSources	sno/install-config.yaml"
test-cmd -m "Verifying direct internet config - 'mirrors:' does not exist" 		"! grep mirrors:		sno/install-config.yaml"
test-cmd -m "Creating iso for 'int_connection=direct' SNO cluster" aba -d sno iso

test-cmd -m "Removing sno dir" rm -rf sno

test-cmd -m "Remove CLIs" aba -d cli reset -f

test-cmd -m "Set the proxy env vars" source ~/.proxy-set.sh
test-cmd -m "Creating sno/cluster.conf." aba cluster -n sno -t sno --starting-ip 10.0.1.201 --step cluster.conf -I proxy

# Note, this is NOT the same as "aba cluster -n sno -t sno --starting-ip 10.0.1.201" command
# aba cluster -n sno -t sno --starting-ip 10.0.1.201 will overwrite the cluster.conf file, but the other will not.
test-cmd -m "Installing SNO cluster from public registry, since no mirror registry available." "aba -d sno install"

test-cmd -m "Unset the proxy env vars" source ~/.proxy-unset.sh

test-cmd -m "Checking cluster operators" "aba --dir sno run"

# keep it #test-cmd -m "Deleting sno cluster" aba --dir sno delete
###test-cmd -m "Stopping sno cluster" "yes|aba --dir sno shutdown"
#test-cmd -m "If cluster up, stopping cluster" ". <(aba --dir sno shell) && . <(aba --dir sno login) && yes|aba --dir sno shutdown || echo cluster shutdown failure"

test-cmd -m "If cluster up, stopping cluster" "                                                      yes|aba --dir sno shutdown --wait"

#test-cmd "aba reset --force"
#aba --dir ~/aba reset --force
###mv cli cli.m && mkdir -v cli && cp cli.m/Makefile cli && aba reset --force; rm -rf cli && mv cli.m cli

mylog
mylog "===> Completed test $0"
mylog

[ -f test/test.log ] && cp test/test.log test/test.log.bak || true

echo SUCCESS $0
