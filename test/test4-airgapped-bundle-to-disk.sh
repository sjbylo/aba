#!/bin/bash -x
# This test installs a mirror reg. on the internal bastion (just for testing) and then
# treats that registry as an "existing registry" in the test internal workflow. 

export INFO_ABA=1
export ABA_TESTING=1  # No usage reporting
[ ! "$TEST_CHANNEL" ] && export TEST_CHANNEL=stable
hash -r  # Forget all command locations in $PATH

# Required: 2 bastions (internal and external), for internal (no direct Internet) only yum works via a proxy/NAT. For external, the proxy is fully configured. 
# I.e. Internal bastion has no access to the Internet.  External has full access. 
# Ensure passwordless ssh access from bastion1 (external) to int_bastion_hostname (internal). 
# Be sure no mirror registries are installed on either bastion before running.  Internal int_bastion_hostname can be a fresh "minimal install" of RHEL8/9.

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
cd ..  # Change into "aba" dir

rm -fr ~/.containers ~/.docker

source scripts/include_all.sh no-trap  # Need for below normalize fn() calls
source test/include.sh
trap - ERR # We don't want this trap during testing.  Needed for below normalize fn() calls

[ ! "$target_full" ] && default_target="iso"   # Default is to generate 'iso' only   # Default is to only create iso
#mylog default_target=$default_target

ntp_ip=10.0.1.8 # If available

cluster_type=sno  # Choose either sno, compact or standard

rm -f ~/.aba.previous.backup
rm -f ~/.ssh/quay_installer*

######################
# Set up test 

which make || sudo dnf install make -y

test-cmd -m "Installing aba" ./install 
#test-cmd -m "Activating shortcuts.conf" cp -f .shortcuts.conf shortcuts.conf

test-cmd -m "Cleaning up - aba reset --force" aba reset -f

####mv cli cli.m && mkdir cli && cp cli.m/Makefile cli && aba reset --force; rm -rf cli && mv cli.m cli
### aba -d cli reset --force  # Ensure there are no old and potentially broken binaries
### test-cmd -m "Show content of mirror/save" 'ls -l mirror mirror/save || true'
#test-cmd -m "Cleaning up mirror - clean" "aba -s -C mirror clean" 

rm -rf sno compact standard 

# Need this so this test script can be run standalone
##[ ! "$VER_OVERRIDE" ] && #export VER_OVERRIDE=4.16.12 # Uncomment to use the 'latest' stable version of OCP
[ ! "$internal_bastion_rhel_ver" ] && export internal_bastion_rhel_ver=rhel9  # rhel8 or rhel9

int_bastion_hostname=registry.example.com
int_bastion_vm_name=bastion-internal-$internal_bastion_rhel_ver
#export subdir=\~/subdir
export subdir=subdir

mylog ============================================================
mylog Starting test $(basename $0)
mylog ============================================================
mylog "Test to create an install bundle and save to disk."

rm -rf ~/.cache/agent/*

rm -f aba.conf  # Set it up next
vf=~steve/.vmware.conf
[ ! "$VER_OVERRIDE" ] && VER_OVERRIDE=p
export VER_OVERRIDE=p  # Must set to p since we do upgrade test below
[ ! "$oc_mirror_ver_override" ] && oc_mirror_ver_override=v2
test-cmd -m "Configure aba.conf for ocp_version '$VER_OVERRIDE'" aba --noask --platform vmw --channel $TEST_CHANNEL --version $VER_OVERRIDE
test-cmd -m "Show ocp_version in $PWD/aba.conf" "grep -o '^ocp_version=[^ ]*' aba.conf"

# for upgrade tests - reduce the version so it can be upgraded later (see below)
mylog Fetching ocp_version
source <(normalize-aba-conf)
echo ocp_channel=$ocp_channel
echo ocp_version=$ocp_version
ocp_version_desired=$ocp_version  # Get the version from aba.conf since that will be the "latest & previous" version.
mylog ocp_version_desired is $ocp_version_desired
ocp_version_major=$(echo $ocp_version_desired | cut -d\. -f1-2)
ocp_version_point=$(echo $ocp_version_desired | cut -d\. -f3)
mylog ocp_version_point is $ocp_version_point
## Reduce the version to create 'bundle' (below) with by about half
#ocp_version_older=$ocp_version_major.$(expr $ocp_version_point / 2 + 1)
#ocp_version_older_point=$(expr $ocp_version_point / 2 )  # can have too much image data involved - out of disk space during testing
ocp_version_older_point=$(expr $ocp_version_point - 1 )  # Change to one patch version lower
ocp_version_older=$ocp_version_major.$ocp_version_older_point
# Ensure the version is available! # No need, since we use "- 1" now
###make -C cli oc-mirror
#ver_list=$(~/bin/oc-mirror list releases --channel=$ocp_channel-$ocp_version_major)
#i=0
#until echo "$ver_list" | grep "^$ocp_version_older$"
#do
#	let ocp_version_older_point=$ocp_version_older_point+1
#	ocp_version_older=$ocp_version_major.$ocp_version_older_point
#	let i=$i+1
#	[ $i -gt 50 ] && echo "Can't find ocp_version_older_point to use ($ocp_version_older)!" && exit 1
#done
mylog ocp_version_older is $ocp_version_older

test-cmd -m "Setting version to install in aba.conf" aba -v $ocp_version_older
test-cmd -m "Show ocp_version in $PWD/aba.conf" "grep -o '^ocp_version=[^ ]*' aba.conf"
# for upgrade

test-cmd -m "Show setting of ask in $PWD/aba.conf" "grep -o '^ask=[^ ]*' aba.conf"

mylog "Setting oc_mirror_version=$oc_mirror_ver_override in aba.conf"
sed -i "s/^oc_mirror_version=.*/oc_mirror_version=$oc_mirror_ver_override /g" aba.conf

mylog Set up vmware.conf
test-cmd cp -v $vf vmware.conf 
sed -i "s#^VC_FOLDER=.*#VC_FOLDER=/Datacenter/vm/abatesting#g" vmware.conf
test-cmd -m "Checking vmware.conf" grep vm/abatesting vmware.conf

# Do not ask to delete things
test-cmd -m "Setting ask=false" aba --noask

test-cmd -m "Setting ntp_servers=$ntp_ip,ntp.example.com in $PWD/aba.conf" aba --ntp $ntp_ip ntp.example.com

echo kiali-ossm > templates/operator-set-abatest 
test-cmd -m "Setting op_sets=abatest in aba.conf" aba --op-sets abatest
# kiali is installed in later tests below

# Needed for $ocp_version below
source <(normalize-aba-conf)
mylog "Checking value of: ocp_version=$ocp_version"

# Be sure this file exists
test-cmd -r 1 30 -m "Init test: download mirror-registry-amd64.tar.gz" "aba --dir test mirror-registry-amd64.tar.gz"
##! tar tvf test/mirror-registry-amd64.tar.gz && [ -s ~/mirror-registry-amd64.tar.gz ] && cp -v ~/mirror-registry-amd64.tar.gz test

#################################
# Copy and edit mirror.conf 

# Simulate creation and edit of mirror.conf file
aba -d mirror mirror.conf
###scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf

mylog "Test the internal bastion ($int_bastion_hostname) as mirror"
make -sC mirror mirror.conf force=yes
#test-cmd -m "Setting reg_host=$int_bastion_hostname" aba -d mirror -H $int_bastion_hostname # This will INSTALL mirror!??? which we don't want yet! # FIXME?
sed -i "s/registry.example.com/$int_bastion_hostname /g" ./mirror/mirror.conf

# This is also a test that overriding vakues works ok, e.g. this is an override in the mirror.connf file, overriding from aba.conf file
#test-cmd -m "Setting op_sets='abatest' in mirror/mirror.conf" "sed -i 's/^.*op_sets=.*/op_sets=abatest /g' ./mirror/mirror.conf"
test-cmd -m "Setting op_sets='abatest' in mirror/mirror.conf" aba --op-sets abatest 
# kiali is installed in later tests below

# This is needed for below VM reset (init_bastion)!
#mylog "Fetching govc"
#aba --dir cli ~/bin/govc

source <(normalize-vmware-conf)
##scripts/vmw-create-folder.sh /Datacenter/vm/test

### NOTR NEEDED FOR THIS TEST ### init_bastion $int_bastion_hostname $int_bastion_vm_name aba-test $TEST_USER

#################################

source <(cd mirror && normalize-mirror-conf)

reg_ssh_user=$TEST_USER

#mylog "Using container mirror at $reg_host:$reg_port and using reg_ssh_user=$reg_ssh_user reg_ssh_key=$reg_ssh_key"

### CREATE BUNDLE & COPY TO BASTION ###

test-cmd mkdir -p ~/tmp
# Test split install bundle 
test-cmd rm -fv ~/tmp/delete-me*tar

test-cmd -r 3 3 -m "Creating bundle for channel $TEST_CHANNEL & version $ocp_version, with various operators and save to disk" "aba -f bundle --pull-secret '~/.pull-secret.json' --platform vmw --channel $TEST_CHANNEL --version $ocp_version --op-sets abatest --ops web-terminal yaks vault-secrets-operator flux --base-domain example.com -o ~/tmp/delete-me -y"

test-cmd -m "Show tar file" 	ls -l ~/tmp/delete-me*tar 
test-cmd -m "Show tar file GB" 	ls -lh ~/tmp/delete-me*tar 
test-cmd -m "Verify tar file"	tar tvf ~/tmp/delete-me*tar 
test-cmd -m "Delete tar file"	rm -fv ~/tmp/delete-me*tar 

# Test full install bundle 
test-cmd rm -fv /tmp/delete-me*tar

test-cmd -r 3 3 -m "Creating bundle for channel $TEST_CHANNEL & version $ocp_version, with various operators and save to disk" "aba -f bundle --pull-secret '~/.pull-secret.json' --platform vmw --channel $TEST_CHANNEL --version $ocp_version --op-sets --ops --base-domain example.com -o /tmp/delete-me -y"

test-cmd -m "Show tar file" 	ls -l /tmp/delete-me*tar 
test-cmd -m "Show tar file GB" 	ls -lh /tmp/delete-me*tar 
test-cmd -m "Verify tar file"	tar tvf /tmp/delete-me*tar 
test-cmd -m "Verify tar file"	tar tvf /tmp/delete-me*tar | grep mirror/save/mirror_000001.tar
test-cmd -m "Delete tar file"	rm -fv /tmp/delete-me*tar 

mylog "===> Completed test $0"

[ -f test/test.log ] && cp test/test.log test/test.log.bak || true

echo SUCCESS $0
