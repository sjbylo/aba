#!/bin/bash -ex
# This test installs a mirror reg. on the internal bastion (just for testing) and then
# treats that registry as an "existing registry" in the test internal workflow. 

# Required: 2 bastions (internal and external), for internal only yum works via a proxy. For external, the proxy is fully configured. 
# Internal has no access to the Internet.  External has full access. 
# Ensure passwordless ssh access from bastion1 (external) to bastion2 (internal). Script uses rsync to copy over the aba repo. 
# Be sure no mirror registries are installed on either bastion before running.  Internal bastion2 can be a fresh "minimal install" of RHEL8/9.

cd `dirname $0`

install_cluster() {
	rm -rf $1
	mkdir -p $1
	#ln -fs ../templates $1
	ln -fs ../templates/Makefile $1/Makefile
	cp templates/aba-$1.conf $1/aba.conf
	make -C $1
	echo $1 completed
}

install_all_clusters() {
	for c in $@
	do
		echo Runtest: creating cluster $c
		install_cluster $c
		make -C $c delete
	done
}

# Revert a snapshot and power on the internal bastion vm
( . ~/.vmware.conf; govc snapshot.revert -vm bastion2-internal-rhel8 Latest; sleep 8; govc vm.power -on bastion2-internal-rhel8; sleep 8; )
ssh $(whoami)@registry2.example.com -- "date" || sleep 2
ssh $(whoami)@registry2.example.com -- "date" || sleep 2

cd ..  # Change into "aba" dir
make distclean   # This will then skip trying to uninstall (which results in an error). 
./aba --version 4.13.27 --vmw ~/.vmware.conf

######################
ver=$(cat ./target-ocp-version.conf)

# Set up mirror config
cp -f templates/mirror.conf mirror
sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ver/g" mirror/mirror.conf

## test for remote mirror
sed -i "s/registry.example.com/registry2.example.com/g" mirror/mirror.conf
#sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" mirror/mirror.conf
###cp mirror.conf mirror

######################
echo Runtest: START - airgap

bastion2=10.0.1.6

# Have quay running somewhere that the internal bastion can reach (on the internal bastion) 
#make -C mirror install    # Install quay on internal bastion (just for testing)
#rm -f mirror/.installed   # Needed, since the install will normally only be run on the internal bastion
#rm -f mirror/.loaded      # Remove to be sure this is not copied over 

make save

#####
# 

p=22222

ssh $(whoami)@$bastion2 -- "rm -rf ~/bin/* ~/aba"

cd

# Configure for testing:
ssh $(whoami)@$bastion2 "rpm -q make  || sudo yum install make -y"
ssh $(whoami)@$bastion2 "rpm -q rsync || sudo yum install rsync -y"
rpm -q rsync || sudo yum install rsync -y 
time rsync --progress --partial --times -avz \
	--exclude '*/.git*' \
	--exclude 'aba/cli/*' \
	--exclude 'aba/mirror/mirror-registry' \
	--exclude 'aba/mirror/*.tar' \
	--exclude "aba/mirror/.rpms" \
	--exclude 'aba/*/*/*.iso' \
		bin aba $(whoami)@10.0.1.6:

#########

ssh $(whoami)@$bastion2 -- "make -C aba/mirror loadclean"   #  This is needed, esp. on a 2nd run of this script, to ensure loading
ssh $(whoami)@$bastion2 -- "make -C aba load sno" 
#ssh $(whoami)@$bastion2 -- "make -C aba load" 
ssh $(whoami)@$bastion2 -- "make -C aba/sno delete" 

cd aba
rm -f mirror/mirror-registry   # This is needed so that the tarball is re-extracted to allow uninstall to work 
ssh $(whoami)@$bastion2 -- "make -C aba/mirror uninstall" 

