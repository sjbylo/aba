#!/bin/bash -ex
# This test is for a connected bastion.  It will install registry on remote bastion and then sync images and install clusters, 
# ... then savd/load images and install clusters. 
# This test requires a valid ~/.vmware.conf file.

### TEST for clean start with or without the rpms.  
if false; then
	# Assuming user will NOT install all rpms in advance and aba will install them.
	sudo dnf remove make jq bind-utils nmstate net-tools skopeo python3-jinja2 python3-pyyaml openssl coreos-installer -y
else
	# FIXME: test for pre-existing rpms!  In this case we don't want yum to run *at all* as it may error out
	# Assuming user will install all rpms in advance.
	sudo dnf install -y $(cat templates/rpms-internal.txt)
	sudo dnf install -y $(cat templates/rpms-external.txt)
fi

# Try to fix "out of space" error when generating the op. index
cat /etc/redhat-release | grep -q ^Fedora && sudo mount -o remount,size=20G /tmp && rm -rf /tmp/render-registry-*

cd `dirname $0`
cd ..

rm -fr ~/.containers ~/.docker
rm -f ~/.aba.previous.backup

bastion2=registry.example.com
bastion_vm=bastion-internal-rhel9

source scripts/include_all.sh && trap - ERR # We don't want this trap during testing.  Needed for below normalize fn() calls
source test/include.sh

[ ! "$target_full" ] && default_target="target=iso"   # Default is to generate 'iso' only   # Default is to only create iso
mylog default_target=$default_target

mylog ============================================================
mylog Starting test $(basename $0)
mylog ============================================================
mylog "Test to install sno directly from public registry."
mylog

ntp=10.0.1.8 # If available

which make || sudo dnf install make -y

# clean up all, assuming reg. is not running (deleted)
v=4.16.3
echo ocp_version=$v > aba.conf  # needed so distclean works without calling ../aba (interactive). aba.conf is created below. 
### wrong # make -C ~/aba distclean force=1
mv cli cli.m && mkdir cli && cp cli.m/Makefile cli && make distclean force=1; rm -rf cli && mv cli.m cli
#make clean

# Set up aba.conf properly
rm -f aba.conf
vf=~/.vmware.conf
[ ! "$VER_OVERRIDE" ] && VER_OVERRIDE=latest
test-cmd -m "Configure aba.conf for version '$VER_OVERRIDE' and vmware $vf" ./aba --channel fast --version $VER_OVERRIDE ### --vmw $vf
#test-cmd -m "Configure aba.conf for version 'latest' and vmware $vf" ./aba --version latest ### --vmw $vf

# Set up govc 
cp $vf vmware.conf 
sed -i "s#^VC_FOLDER=.*#VC_FOLDER=/Datacenter/vm/abatesting#g" vmware.conf

mylog "Setting 'ask='"
sed -i 's/^ask=[^ \t]\{1,\}\([ \t]\{1,\}\)/ask=\1 /g' aba.conf

mylog "Setting ntp_server=$ntp" 
[ "$ntp" ] && sed -i "s/^ntp_server=\([^#]*\)#\(.*\)$/ntp_server=$ntp    #\2/g" aba.conf

source <(normalize-aba-conf)
echo Check aba.conf:
normalize-aba-conf

reg_ssh_user=$(whoami)

make -C cli ~/bin/govc
source <(normalize-vmware-conf)

rm -rf sno
test-cmd -m "Creating sno/cluster.conf." make sno target=cluster.conf
test-cmd -m "Adding proxy=auto to sno/cluster.conf" "sed -i 's/^proxy=.*/proxy=auto/g' sno/cluster.conf"

test-cmd -m "Installing SNO cluster from public registry, since no registry available." make sno 
# keep it #test-cmd -m "Deleting sno cluster" make -C sno delete || true
###test-cmd -m "Stopping sno cluster" "yes|make -C sno shutdown"
test-cmd -m "If cluster up, stopping cluster" ". <(make -sC sno shell) && . <(make -sC sno login) && yes|make -C sno shutdown || echo cluster not up"

#test-cmd "make distclean force=1"
#make -C ~/aba distclean force=1
###mv cli cli.m && mkdir cli && cp cli.m/Makefile cli && make distclean force=1; rm -rf cli && mv cli.m cli

mylog
mylog "===> Completed test $0"
mylog

[ -f test/test.log ] && cp test/test.log test/test.log.bak

echo SUCCESS 
