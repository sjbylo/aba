#!/bin/bash -ex
# This test will install quay mirror registry in various ways onto a remote bastion or on the localhost. Then it will sync the images.

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

int_bastion=registry.example.com
bastion_vm=bastion-internal-rhel9

source scripts/include_all.sh && trap - ERR # We don't want this trap during testing.  Needed for below normalize fn() calls
source test/include.sh

### NN [ ! "$target_full" ] && default_target="target=iso"   # Default is to generate 'iso' only   # Default is to only create iso
### NN mylog default_target=$default_target

mylog ============================================================
mylog Starting test $(basename $0)
mylog ============================================================
mylog "Test to install registry onto remote host in varioous ways."
mylog

### NN ntp=10.0.1.8 # If available

which make || sudo dnf install make -y

# clean up all, assuming reg. is not running (deleted)
v=4.15.8
echo ocp_version=$v > aba.conf  # needed so distclean works without calling ../aba (interactive). aba.conf is created below. 
make distclean force=1=
#make clean

# Set up aba.conf properly
rm -f aba.conf
vf=~/.vmware.conf.vc
test-cmd -m "Configure aba.conf for version $v and vmware $vf" ./aba --version $v ### --vmw $vf

# Set up govc 
### NN cp $vf vmware.conf 

mylog "Setting 'ask='"
sed -i 's/^ask=[^ \t]\{1,\}\([ \t]\{1,\}\)/ask=\1/g' aba.conf

### NN mylog "Setting ntp_servers=$ntp" 
### NN [ "$ntp" ] && sed -i "s/^ntp_servers=\([^#]*\)#\(.*\)$/ntp_servers=$ntp    #\2/g" aba.conf

source <(normalize-aba-conf)

reg_ssh_user=$(whoami)

make -C cli
source <(normalize-vmware-conf)
##scripts/vmw-create-folder.sh /Datacenter/vm/test

mylog Revert internal bastion vm to snapshot and powering on ...
(
	govc snapshot.revert -vm $bastion_vm aba-test
	sleep 8
	govc vm.power -on $bastion_vm
	sleep 5
)
# Wait for host to come up
ssh $reg_ssh_user@$int_bastion -- "date" || sleep 2
ssh $reg_ssh_user@$int_bastion -- "date" || sleep 3
ssh $reg_ssh_user@$int_bastion -- "date" || sleep 8

# This file is not needed in a fully air-gapped env. 
ssh $reg_ssh_user@$bastion2 -- "rm -f ~/.pull-secret.json"

pub_key=$(cat ~/.ssh/id_rsa.pub)
u=testy
cat << END  | ssh $int_bastion -- sudo bash 
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
ssh testy@$int_bastion whoami


#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

mylog "Confgure mirror to install registry on internal (remote) $int_bastion"

# Create and edit mirror.conf 
make -C mirror mirror.conf

mylog "Setting 'reg_host' to '$int_bastion' in file 'mirror/mirror.conf'"
sed -i "s/^reg_host.*/reg_host=$int_bastion/g" ./mirror/mirror.conf	# Install on internal bastion

mylog "Setting 'reg_ssh_key=~/.ssh/id_rsa' for remote installation in file 'mirror/mirror.conf'" 
sed -i "s#.*reg_ssh_key=.*#reg_ssh_key=~/.ssh/id_rsa #g" ./mirror/mirror.conf	     	# Remote or localhost

mylog "Setting reg_root=~/my-quay-mirror"
sed -i "s#reg_root=#reg_root=~/my-quay-mirror#g" ./mirror/mirror.conf	     	# test other storage location

#sed -i "s#channel=.*#channel=fast          #g" ./mirror/mirror.conf	    	# test channel
#sed -i "s#reg_root=#reg_root=~/my-quay-mirror#g" ./mirror/mirror.conf	     	# test other storage location
#sed -i "s#reg_pw=.*#reg_pw=             #g" ./mirror/mirror.conf	    	# test random password 
### sed -i "s#tls_verify=true#tls_verify=            #g" ./mirror/mirror.conf  	# test tlsverify = false # sno install fails 
### sed -i "s#reg_port=.*#reg_pw=443             #g" ./mirror/mirror.conf	    	# test port change
#sed -i "s#reg_path=.*#reg_path=my/path             #g" ./mirror/mirror.conf	    	# test path

mylog "Setting reg_pw="
sed -i "s#reg_pw=.*#reg_pw=             #g" ./mirror/mirror.conf	    	# test random password 
### sed -i "s#tls_verify=true#tls_verify=            #g" ./mirror/mirror.conf  	# test tlsverify = false # sno install fails 

mylog "Setting reg_path=my/path"
sed -i "s#reg_path=.*#reg_path=my/path             #g" ./mirror/mirror.conf	    	# test path

mylog "Setting reg_ssh_user=testy for remote installation" 
sed -i "s#reg_ssh_user=.*#reg_ssh_user=testy#g" ./mirror/mirror.conf	     	# If remote, set user

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
# This will install mirror 
mylog "Installing Quay mirror registry at $reg_host:$reg_port"
test-cmd -r 99 3 -m "Install mirror registry" make -C mirror install

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

test-cmd -m "Uninstall mirror" make -C mirror uninstall 

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

rm -f mirror/mirror.conf
make -C mirror mirror.conf

## FIXME INSTALL FAILURE mylog "Configure mirror to install on internal (remote) bastion in '~/my-quay-mirror', with random password to '/my/path'"
mylog "Configure mirror to install on internal (remote) bastion in default dir, with random password to '/my/path'"

mylog "Setting 'reg_host' to '$int_bastion' in file 'mirror/mirror.conf'"
sed -i "s/^reg_host.*/reg_host=$int_bastion/g" ./mirror/mirror.conf	# Install on internal bastion

mylog "Setting 'reg_ssh_key=~/.ssh/id_rsa' for remote installation in file 'mirror/mirror.conf'" 
sed -i "s#reg_ssh_key=.*#reg_ssh_key=~/.ssh/id_rsa #g" ./mirror/mirror.conf	     	# Remote or localhost

## FIXME INSTALL FAILURE mylog "Setting reg_root=~/my-quay-mirror"
## FIXME INSTALL FAILURE sed -i "s#reg_root=#reg_root=~/my-quay-mirror#g" ./mirror/mirror.conf	     	# test other storage location

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

source <(cd mirror; normalize-mirror-conf)

mylog "Using container mirror at $reg_host:$reg_port and using reg_ssh_user=$reg_ssh_user reg_ssh_key=$reg_ssh_key"

######################
# This will install the reg. and sync the images
test-cmd -r 99 3 -m "Install quay internal mirror registry" make -C mirror install

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

#######################
#  This will save the images, install (the reg.) then load the images
test-cmd -r 99 3 -m "Saving and loading images into mirror" make -C mirror sync

## KEEP test-cmd -m "Uninstalling mirror registry" make -C mirror uninstall 

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

mylog
mylog "===> Completed test $0"
mylog
mylog SUCCESS 
mylog
