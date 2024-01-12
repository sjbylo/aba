#!/bin/bash -ex
# This test installs a mirror reg. on the internal bastion (just for testing) and then
# treats that registry as an "existing registry" in the test internal workflow. 

# Required: 2 bastions (internal and external), for internal only yum works via a proxy. For external, the proxy is fully configured. 
# Internal has no access to the Internet.  External has full access. 
# Ensure passwordless ssh access from bastion1 (external) to bastion2 (internal). Script uses rsync to copy over the aba repo. 
# Be sure no mirror registries are installed on either bastion before running.  Internal bastion2 can be a fresh "minimal install" of RHEL8/9.

dir=`dirname $0`
cd $dir/..

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

# uninstall added to end of test
##make -C mirror uninstall  
make distclean
./aba
#rm -f mirror/regcreds/*  # if forget to uninstall reg.

######################
ver=$(cat ./target-ocp-version.conf)

# Set up mirror config
cp -f templates/mirror.conf .
sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ver/g" ./mirror.conf

## test for remote mirror
sed -i "s/registry.example.com/registry2.example.com/g" ./mirror.conf
sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" ./mirror.conf
cp mirror.conf mirror

######################
echo Runtest: START - airgap

bastion2=10.0.1.6

# Have quay running somewhere that the internal bastion can reach (on the internal bastion) 
make -C mirror install    # Install quay on internal bastion (just for testing)
rm -f mirror/.installed   # Needed, since the install will normally only be run on the internal bastion
rm -f mirror/.loaded      # Remove to be sure this is not copied over 

make save
#make -C mirror tidy   # Remove some crud before copying 

#####
# 
#sudo yum install nmap-ncat -y 
#ssh $(whoami)@$bastion2 sudo yum install  nmap-ncat -y  
###ssh $(whoami)@$bastion2 -- "sudo firewall-cmd --add-port=$p/tcp --permanent && sudo firewall-cmd --reload"

p=22222

#ssh $(whoami)@$bastion2 -- "rm -rf ~/bin/* ~/aba"

cd
# Use one or the other copy command!
#time tar czf - `find bin aba -type f ! -path "aba/.git*" -a ! -path "aba/cli/*"` | ssh $(whoami)@$bastion2 tar xvzf -

# Configure for testing:
ssh $(whoami)@$bastion2 "rpm -q make  || sudo yum install make -y"
ssh $(whoami)@$bastion2 "rpm -q rsync || sudo yum install rsync -y"
rpm -q rsync || sudo yum install rsync -y 
time rsync --progress --partial --times -avz --exclude '*/.git*' --exclude 'aba/cli/*' --exclude 'aba/mirror/mirror-registry' --exclude 'aba/mirror/*.tar' bin aba $(whoami)@10.0.1.6:
#find bin aba -type f ! -path "aba/.git*" -a ! -path "aba/cli/*" -a ! -path "aba/mirror/mirror-registry" -a ! -path "aba/mirror/*.tar"
#########

ssh $(whoami)@$bastion2 -- "make -C aba/mirror loadclean"   #  This is needed, esp. on a 2nd run of this script, to ensure loading
ssh $(whoami)@$bastion2 -- "make -C aba load sno" 
#ssh $(whoami)@$bastion2 -- "make -C aba load" 
ssh $(whoami)@$bastion2 -- "make -C aba/sno delete" 

cd aba
rm -f mirror/mirror-registry   # This is needed so that the tarball is re-extracted to allow uninstall to work 
make uninstall 

