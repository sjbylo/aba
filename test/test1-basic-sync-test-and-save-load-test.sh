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

#uname -n | grep -qi ^fedora$ && sudo mount -o remount,size=16G /tmp

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
mylog "Test to install remote reg. on $bastion2 and then sync and save/load images.  Install sno ocp + test app."
mylog

ntp=10.0.1.8 # If available

which make || sudo dnf install make -y

# clean up all, assuming reg. is not running (deleted)
v=4.16.3
echo ocp_version=$v > aba.conf  # needed so distclean works without calling ../aba (interactive). aba.conf is created below. 
## this is wrong # make -C ~/aba distclean force=1
mv cli cli.m && mkdir cli && cp cli.m/Makefile cli && make distclean force=1; rm -rf cli && mv cli.m cli
#make clean

# Set up aba.conf properly
rm -f aba.conf
vf=~/.vmware.conf
[ ! "$VER_OVERRIDE" ] && VER_OVERRIDE=latest
test-cmd -m "Configure aba.conf for version '$VER_OVERRIDE' and vmware $vf" ./aba --version $VER_OVERRIDE ### --vmw $vf

# Set up govc 
cp $vf vmware.conf 
sed -i "s#^VC_FOLDER=.*#VC_FOLDER=/Datacenter/vm/abatesting#g" vmware.conf

mylog "Setting 'ask='"
sed -i 's/^ask=[^ \t]\{1,\}\([ \t]\{1,\}\)/ask=\1 /g' aba.conf

mylog "Setting ntp_server=$ntp" 
[ "$ntp" ] && sed -i "s/^ntp_server=\([^#]*\)#\(.*\)$/ntp_server=$ntp    #\2/g" aba.conf

mylog "Setting op_sets=\"abatest\" in aba.conf"
sed -i "s/^op_sets=.*/op_sets=\"abatest\" /g" aba.conf
echo kiali-ossm > templates/operator-set-abatest 

source <(normalize-aba-conf)

reg_ssh_user=$(whoami)

make -C cli ~/bin/govc
source <(normalize-vmware-conf)
echo GOVC_URL=$GOVC_URL
echo GOVC_DATASTORE=$GOVC_DATASTORE
echo GOVC_NETWORK=$GOVC_NETWORK
echo GOVC_DATACENTER=$GOVC_DATACENTER
echo GOVC_CLUSTER=$GOVC_CLUSTER
echo VC_FOLDER=$VC_FOLDER

##scripts/vmw-create-folder.sh /Datacenter/vm/test

mylog Revert internal bastion vm to snapshot and powering on ...
(
	govc snapshot.revert -vm $bastion_vm aba-test
	sleep 8
	govc vm.power -on $bastion_vm
	sleep 5
)
# Wait for host to come up
ssh $reg_ssh_user@$bastion2 -- "date" || sleep 2
ssh $reg_ssh_user@$bastion2 -- "date" || sleep 3
ssh $reg_ssh_user@$bastion2 -- "date" || sleep 8

# Delete images
ssh $reg_ssh_user@$bastion2 -- "sudo dnf install podman -y && podman system prune --all --force && podman rmi --all && sudo rm -rf ~/.local/share/containers/storage && rm -rf ~/test"
# This file is not needed in a fully air-gapped env. 
ssh $reg_ssh_user@$bastion2 -- "rm -fv ~/.pull-secret.json"
# Want to test fully disconnected 
ssh $reg_ssh_user@$bastion2 -- "sed -i 's|^source ~/.proxy-set.sh|# aba test # source ~/.proxy-set.sh|g' ~/.bashrc"
# Ensure home is empty!  Avoid errors where e.g. hidden files cause reg. install failing. 
ssh steve@$bastion2 -- "rm -rfv ~/*"

# Just be sure a valid govc config file exists on internal bastion
scp $vf steve@$bastion2: 

# Test with other use
rm -f ~/.ssh/testy_rsa*
ssh-keygen -t rsa -f ~/.ssh/testy_rsa -N ''
pub_key=$(cat ~/.ssh/testy_rsa.pub)   # This must be different key
u=testy
cat << END  | ssh $bastion2 -- sudo bash 
set -ex
userdel $u -r -f || true
useradd $u -p not-used
mkdir ~$u/.ssh 
chmod 700 ~$u/.ssh
#cp -p ~steve/.pull-secret.json ~$u 
echo $pub_key > ~$u/.ssh/authorized_keys
echo '$u ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$u
chmod 600 ~$u/.ssh/authorized_keys
chown -R $u.$u ~$u
END
ssh -i ~/.ssh/testy_rsa testy@$bastion2 whoami


#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

mylog "Confgure mirror to install registry on internal (remote) $bastion2"

# Create and edit mirror.conf 
make -C mirror mirror.conf

mylog "Setting 'reg_host' to '$bastion2' in file 'mirror/mirror.conf'"
sed -i "s/registry.example.com/$bastion2 /g" ./mirror/mirror.conf	# Install on registry2 

mylog "Setting 'reg_ssh_key=~/.ssh/id_rsa' for remote installation in file 'mirror/mirror.conf'" 
sed -i "s#reg_ssh_key=#reg_ssh_key=~/.ssh/id_rsa #g" ./mirror/mirror.conf	     	# Remote or localhost

mylog "Setting op_sets=\"abatest\" in mirror/mirror.conf"
sed -i "s/^.*op_sets=.*/op_sets=\"abatest\" /g" ./mirror/mirror.conf
echo kiali-ossm > templates/operator-set-abatest 

##mylog "Setting reg_root=~/my-quay-mirror"
##sed -i "s#reg_root=#reg_root=~/my-quay-mirror #g" ./mirror/mirror.conf	     	# test other storage location

#sed -i "s#channel=.*#channel=fast          #g" ./mirror/mirror.conf	    	# test channel
#sed -i "s#reg_root=#reg_root=~/my-quay-mirror #g" ./mirror/mirror.conf	     	# test other storage location
#sed -i "s#reg_pw=.*#reg_pw=             #g" ./mirror/mirror.conf	    	# test random password 
### sed -i "s#tls_verify=true#tls_verify=            #g" ./mirror/mirror.conf  	# test tlsverify = false # sno install fails 
### sed -i "s#reg_port=.*#reg_pw=443             #g" ./mirror/mirror.conf	    	# test port change
#sed -i "s#reg_path=.*#reg_path=my/path             #g" ./mirror/mirror.conf	    	# test path

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

source <(cd mirror; normalize-mirror-conf)

echo
echo mirror-conf:
(cd mirror; normalize-mirror-conf)
echo

mylog "Using container mirror at $reg_host:$reg_port and using reg_ssh_user=$reg_ssh_user reg_ssh_key=$reg_ssh_key"

######################
# This will install mirror and sync images
mylog "Installing Quay mirror registry at $reg_host:$reg_port and then ..."
test-cmd -r 99 3 -m "Syncing images from external network to internal mirror registry" make -C mirror sync

# Install yq for below test only!
which yq || (
	mylog Install yq
	curl --retry 3 -sSL -o - https://github.com/mikefarah/yq/releases/download/v4.41.1/yq_linux_amd64.tar.gz | tar -C ~/bin -xzf - ./yq_linux_amd64 && \
		mv ~/bin/yq_linux_amd64 ~/bin/yq && \
		chmod 755 ~/bin/yq
	)

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

######################
# This test creates the ABI (agent-based installer) config files to check they are valid

for cname in sno compact standard
do
	mkdir -p test/$cname

        mylog "Agent-config file generation test for cluster type '$cname'"

        rm -rf $cname

	test-cmd -m "Creating cluster.conf for $cname cluster with 'make $cname target=cluster.conf'" "make $cname target=cluster.conf"
        sed -i "s#mac_prefix=.*#mac_prefix=88:88:88:88:88:#g" $cname/cluster.conf   # make sure all mac addr are the same, not random
        test-cmd -m "Creating install-config.yaml for $cname cluster" "make -C $cname install-config.yaml"
        test-cmd -m "Creating agent-config.yaml for $cname cluster" "make -C $cname agent-config.yaml"

	# There are only run on the very first run to generate the valis files
	# Note that the files test/{sno,compact,standrd}/{install,agent}-config.yaml.example have all been committed into git 
        ### NOT NEEDED [ ! -f test/$cname/install-config.yaml.example ] && cat $cname/install-config.yaml | yq 'del(.additionalTrustBundle,.platform.vsphere.vcenters,.pullSecret)' > test/$cname/install-config.yaml.example
        ### NOT NEEDED [ ! -f test/$cname/agent-config.yaml.example ]   && cat $cname/agent-config.yaml   > test/$cname/agent-config.yaml.example

	# Remove some of the params which either change or cannot be placed into git (FIXME: specify the VC password exactly) 
	cat $cname/install-config.yaml | yq 'del(.additionalTrustBundle,.platform.vsphere.vcenters,.pullSecret)' > test/$cname/install-config.yaml
	cat $cname/agent-config.yaml                                                                             > test/$cname/agent-config.yaml

        # Check if the files DO NOT match (are different)
        if ! diff test/$cname/install-config.yaml test/$cname/install-config.yaml.example; then
		cp test/$cname/install-config.yaml test/$cname/install-config.yaml.failed
		mylog "Config mismatch! See file test/$cname/install-config.yaml.failed"
                exit 1
        fi

        if ! diff test/$cname/agent-config.yaml   test/$cname/agent-config.yaml.example; then
		cp test/$cname/agent-config.yaml test/$cname/agent-config.yaml.failed
		mylog "Config mismatch! See file test/$cname/agent-config.yaml.failed"
                exit 1
        fi

        test-cmd -m "Generate iso file for cluster type '$cname'" "make -C $cname iso"
done

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

######################
rm -rf sno
test-cmd -m "Installing SNO cluster with 'make sno $default_target'" make sno $default_target
test-cmd -m "Deleting sno cluster (if it was created)" make -C sno delete || true

#######################
#  This will save the images, install (the reg.) then load the images
test-cmd -r 99 3 -m "Saving and then loading cluster images into mirror" "make -C mirror save load" 

rm -rf sno
test-cmd -m "Installing sno cluster with 'make sno $default_target'" make sno $default_target
test-cmd -m "Delete cluster (if needed)" make -C sno delete 
test-cmd -m "Uninstall mirror" make -C mirror uninstall 
test-cmd -h steve@$bastion2 -m "Verify mirror uninstalled" podman ps 
test-cmd -h steve@$bastion2 -m "Deleting all podman images" "podman system prune --all --force && podman rmi --all && sudo rm -rf ~/.local/share/containers/storage && rm -rf ~/test"

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

## FIXME INSTALL FAILURE mylog "Configure mirror to install on internal (remote) bastion in '~/my-quay-mirror', with random password to '/my/path'"
mylog "Configure mirror to install on internal (remote) bastion in default dir, with random password to '/my/path'"

#sed -i "s/registry.example.com/$bastion2 /g" ./mirror/mirror.conf	# Install on registry2 
#sed -i "s#reg_ssh_key=#reg_ssh_key=~/.ssh/id_rsa #g" ./mirror/mirror.conf	     	# Remote or localhost

## FIXME INSTALL FAILURE mylog "Setting reg_root=~/my-quay-mirror"
## FIXME INSTALL FAILURE sed -i "s#reg_root=#reg_root=~/my-quay-mirror #g" ./mirror/mirror.conf	     	# test other storage location

mylog "Setting reg_pw="
sed -i "s#reg_pw=.*#reg_pw=             #g" ./mirror/mirror.conf	    	# test random password 
### sed -i "s#tls_verify=true#tls_verify=            #g" ./mirror/mirror.conf  	# test tlsverify = false # sno install fails 

mylog "Setting reg_path=my/path"
sed -i "s#reg_path=.*#reg_path=my/path             #g" ./mirror/mirror.conf	    	# test path

mylog "Setting reg_ssh_user=testy for remote installation" 
sed -i "s#reg_ssh_user=[^ \t]*#reg_ssh_user=testy   #g" ./mirror/mirror.conf	     	# If remote, set user

mylog "Setting reg_ssh_key=~/.ssh/testy_rsa for remote installation" 
sed -i "s#reg_ssh_key=.*#reg_ssh_key=~/.ssh/testy_rsa #g" ./mirror/mirror.conf	     	# Remote or localhost

# FIXME: no need? or use 'make clean' or?
rm -rf mirror/save   # The process will halt, otherwise with "You already have images saved on local disk"

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

source <(cd mirror; normalize-mirror-conf)

mylog "Using container mirror at $reg_host:$reg_port and using reg_ssh_user=$reg_ssh_user reg_ssh_key=$reg_ssh_key"

######################
# This will install the reg. and sync the images
test-cmd -r 99 3 -m "Syncing images from external network to internal mirror registry" make -C mirror sync 

make -C sno clean # This should clean up the cluster and make should start from scratch next time. Instead of running "rm -rf sno"
rm sno/cluster.conf   # This should 100% reset the cluster and make should start from scratch next time

mylog "Testing install with smaller CIDR 10.0.1.128/25 with start ip 201"
test-cmd -m "Configuring SNO cluster with 'make sno target=cluster.conf" make sno target=cluster.conf
mylog "Setting CIDR 10.0.1.128/25"
sed -i "s/^machine_network=[^ \t]*/machine_network=10.0.1.128 /g" sno/cluster.conf
sed -i "s/^prefix_length=[^ \t]*/prefix_length=25 /g" sno/cluster.conf

mylog "Setting starting_ip=201"
sed -i "s/^starting_ip=[^ \t]*/starting_ip=201 /g" sno/cluster.conf
test-cmd -m "Installing sno cluster" make sno

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

#######################
#  This will save the images, install (the reg.) then load the images
test-cmd -r 99 3 -m "Saving and loading images into mirror" make -C mirror save load 

make -C sno clean # This should clean up the cluster and make should start from scratch next time. Instead of running "rm -rf sno"
test-cmd -m "Installing sno cluster with 'make sno $default_target'" make sno $default_target

### Let it be ## test-cmd -m "Deleting cluster" make -C sno delete 
test-cmd -m "If cluster up, stopping cluster" ". <(make -sC sno shell) && . <(make -sC sno login) && yes|make -C sno shutdown || true"

### FIXME mylog "Removing vmware config file to simulate 'bare metal' and iso creation"
mylog "Bare-metal simulation: Changing 'platform' to non-vmware in 'aba.conf' file to simulate 'bare metal' and iso creation"

# FIXME
sed -i "s/^platform=.*/platform=bm/g" aba.conf
####> vmware.conf
rm -rf standard   # Needs to be 'standard' as there was a bug for iso creation in this topology
####test-cmd -m "Creating standard iso file with 'make standard target=iso'" make standard target=iso # Since we're simulating bare-metal, only create iso
test-cmd -m "Bare-metal simulation: Creating agent config files" make standard   	# Since we're simulating bare-metal, this will only create agent configs
test-cmd -m "Bare-metal simulation: Creating iso file" make -C standard iso || true	# Since we're simulating bare-metal, only create iso

#test-cmd -m "Uninstalling mirror registry" make -C mirror uninstall 
#test-cmd -h steve@$bastion2 -m "Verify mirror uninstalled" podman ps 
#test-cmd -h steve@$bastion2 -m "Deleting all podman images" "podman system prune --all --force && podman rmi --all && sudo rm -rf ~/.local/share/containers/storage && rm -rf ~/test"

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

# Must remove the old files under mirror/save 
##make distclean force=1
# keep it # mv cli cli.m && mkdir cli && cp cli.m/Makefile cli && make distclean force=1; rm -rf cli && mv cli.m cli

mylog
mylog "===> Completed test $0"
mylog

[ -f test/test.log ] && cp test/test.log test/test.log.bak

echo SUCCESS 
