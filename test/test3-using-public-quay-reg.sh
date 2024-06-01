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
v=4.15.8
echo ocp_version=$v > aba.conf  # needed so distclean works without calling ../aba (interactive). aba.conf is created below. 
make distclean ask=
#make clean

# Set up aba.conf properly
rm -f aba.conf
vf=~/.vmware.conf.vc
test-cmd -m "Configure aba.conf for version $v and vmware $vf" ./aba --version $v ### --vmw $vf

# Set up govc 
cp $vf vmware.conf 

mylog "Setting 'ask='"
sed -i 's/^ask=[^ \t]\{1,\}\([ \t]\{1,\}\)/ask=\1 /g' aba.conf

mylog "Setting ntp_server=$ntp" 
[ "$ntp" ] && sed -i "s/^ntp_server=\([^#]*\)#\(.*\)$/ntp_server=$ntp    #\2/g" aba.conf

source <(normalize-aba-conf)

reg_ssh_user=$(whoami)

make -C cli
source <(normalize-vmware-conf)
##scripts/vmw-create-folder.sh /Datacenter/vm/test

### NOT NEEDED mylog Revert internal bastion vm to snapshot and powering on ...
### NOT NEEDED (
### NOT NEEDED 	govc snapshot.revert -vm $bastion_vm aba-test
### NOT NEEDED 	sleep 8
### NOT NEEDED 	govc vm.power -on $bastion_vm
### NOT NEEDED 	sleep 5
### NOT NEEDED )
### NOT NEEDED # Wait for host to come up
### NOT NEEDED ssh $reg_ssh_user@$bastion2 -- "date" || sleep 2
### NOT NEEDED ssh $reg_ssh_user@$bastion2 -- "date" || sleep 3
### NOT NEEDED ssh $reg_ssh_user@$bastion2 -- "date" || sleep 8


### NOT NEEDED pub_key=$(cat ~/.ssh/id_rsa.pub)
### NOT NEEDED u=testy
### NOT NEEDED cat << END  | ssh $bastion2 -- sudo bash 
### NOT NEEDED set -ex
### NOT NEEDED userdel $u -r -f || true
### NOT NEEDED useradd $u -p not-used
### NOT NEEDED mkdir ~$u/.ssh 
### NOT NEEDED chmod 700 ~$u/.ssh
### NOT NEEDED cp -p ~steve/.pull-secret.json ~$u 
### NOT NEEDED echo $pub_key > ~$u/.ssh/authorized_keys
### NOT NEEDED echo '$u ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$u
### NOT NEEDED chmod 600 ~$u/.ssh/authorized_keys
### NOT NEEDED chown -R $u.$u ~$u
### NOT NEEDED END
### NOT NEEDED ssh testy@$bastion2 whoami


#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

### NOT NEEDED mylog "Confgure mirror to install registry on internal (remote) $bastion2"

### NOT NEEDED # Create and edit mirror.conf 
### NOT NEEDED make -C mirror mirror.conf

### NOT NEEDED mylog "Setting 'reg_host' to '$bastion2' in file 'mirror/mirror.conf'"
### NOT NEEDED sed -i "s/registry.example.com/$bastion2 /g" ./mirror/mirror.conf	# Install on registry2 

### NOT NEEDED mylog "Setting 'reg_ssh_key=~/.ssh/id_rsa' for remote installation in file 'mirror/mirror.conf'" 
### NOT NEEDED sed -i "s#reg_ssh_key=#reg_ssh_key=~/.ssh/id_rsa #g" ./mirror/mirror.conf	     	# Remote or localhost

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

### NOT NEEDED source <(cd mirror; normalize-mirror-conf)

### NOT NEEDED echo
### NOT NEEDED echo mirror-conf:
### NOT NEEDED (cd mirror; normalize-mirror-conf)
### NOT NEEDED echo

### NOT NEEDED mylog "Using container mirror at $reg_host:$reg_port and using reg_ssh_user=$reg_ssh_user reg_ssh_key=$reg_ssh_key"

### NOT NEEDED ######################
### NOT NEEDED # This will install mirror and sync images
### NOT NEEDED mylog "Installing Quay mirror registry at $reg_host:$reg_port and then ..."
### NOT NEEDED test-cmd -r 99 3 -m "Syncing images from external network to internal mirror registry" make -C mirror sync

### NOT NEEDED # Install yq for below test only!
### NOT NEEDED which yq || (
	### NOT NEEDED mylog Install yq
	### NOT NEEDED curl -sSL -o - https://github.com/mikefarah/yq/releases/download/v4.41.1/yq_linux_amd64.tar.gz | tar -C ~/bin -xzf - ./yq_linux_amd64 && \
		### NOT NEEDED mv ~/bin/yq_linux_amd64 ~/bin/yq && \
		### NOT NEEDED chmod 755 ~/bin/yq
	### NOT NEEDED )

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

######################
# This test creates the ABI (agent-based installer) config files to check they are valid

### NOT NEEDED for cname in sno compact standard
### NOT NEEDED do
### NOT NEEDED	mkdir -p test/$cname
### NOT NEEDED
### NOT NEEDED        mylog "Agent-config file generation test for cluster type '$cname'"
### NOT NEEDED
### NOT NEEDED        rm -rf $cname
### NOT NEEDED
### NOT NEEDED	test-cmd -m "Creating cluster.conf for $cname cluster with 'make $cname target=cluster.conf'" "make $cname target=cluster.conf"
### NOT NEEDED        sed -i "s#mac_prefix=.*#mac_prefix=88:88:88:88:88:#g" $cname/cluster.conf   # make sure all mac addr are the same, not random
### NOT NEEDED        test-cmd -m "Creating install-config.yaml for $cname cluster" "make -C $cname install-config.yaml"
### NOT NEEDED        test-cmd -m "Creating agent-config.yaml for $cname cluster" "make -C $cname agent-config.yaml"
### NOT NEEDED
### NOT NEEDED	# There are only run on the very first run to generate the valis files
### NOT NEEDED	# Note that the files test/{sno,compact,standrd}/{install,agent}-config.yaml.example have all been committed into git 
### NOT NEEDED        ### NOT NEEDED [ ! -f test/$cname/install-config.yaml.example ] && cat $cname/install-config.yaml | yq 'del(.additionalTrustBundle,.platform.vsphere.vcenters,.pullSecret)' > test/$cname/install-config.yaml.example
### NOT NEEDED        ### NOT NEEDED [ ! -f test/$cname/agent-config.yaml.example ]   && cat $cname/agent-config.yaml   > test/$cname/agent-config.yaml.example
### NOT NEEDED
### NOT NEEDED	# Remove some of the params which either change or cannot be placed into git (FIXME: specify the VC password exactly) 
### NOT NEEDED	cat $cname/install-config.yaml | yq 'del(.additionalTrustBundle,.platform.vsphere.vcenters,.pullSecret)' > test/$cname/install-config.yaml
### NOT NEEDED	cat $cname/agent-config.yaml                                                                             > test/$cname/agent-config.yaml
### NOT NEEDED
### NOT NEEDED        # Check if the files DO NOT match (are different)
### NOT NEEDED        if ! diff test/$cname/install-config.yaml test/$cname/install-config.yaml.example; then
### NOT NEEDED		cp test/$cname/install-config.yaml test/$cname/install-config.yaml.failed
### NOT NEEDED		mylog "Config mismatch! See file test/$cname/install-config.yaml.failed"
### NOT NEEDED                exit 1
### NOT NEEDED        fi
### NOT NEEDED
### NOT NEEDED        if ! diff test/$cname/agent-config.yaml   test/$cname/agent-config.yaml.example; then
### NOT NEEDED		cp test/$cname/agent-config.yaml test/$cname/agent-config.yaml.failed
### NOT NEEDED		mylog "Config mismatch! See file test/$cname/agent-config.yaml.failed"
### NOT NEEDED                exit 1
### NOT NEEDED        fi
### NOT NEEDED
### NOT NEEDED        test-cmd -m "Generate iso file for cluster type '$cname'" "make -C $cname iso"
### NOT NEEDEDdone

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

######################
rm -rf sno
test-cmd -m "Installing SNO cluster from public registry with 'make sno" make sno
test-cmd -m "Deleting sno cluster (if it was created)" make -C sno delete 

### NOT NEEDED#######################
### NOT NEEDED#  This will save the images, install (the reg.) then load the images
### NOT NEEDEDtest-cmd -r 99 3 -m "Saving and then loading cluster images into mirror" "make -C mirror save load" 

### NOT NEEDEDrm -rf sno
### NOT NEEDEDtest-cmd -m "Installing sno cluster with 'make sno $default_target'" make sno $default_target
### NOT NEEDEDtest-cmd -m "Delete cluster (if needed)" make -C sno delete 
### NOT NEEDEDtest-cmd -m "Uninstall mirror" make -C mirror uninstall 

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

mylog
mylog "===> Completed test $0"
mylog

[ -f test/test.log ] && cp test/test.log test/test.log.bak

echo SUCCESS 
