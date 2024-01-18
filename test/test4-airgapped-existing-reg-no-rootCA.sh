#!/bin/bash -ex
# This test installs a mirror reg. on the internal bastion (just for testing) and then
# treats that registry as an "existing registry" in the test internal workflow. 

# Required: 2 bastions (internal and external), for internal (no direct Internet) only yum works via a proxy. For external, the proxy is fully configured. 
# I.e. Internal bastion has no access to the Internet.  External has full access. 
# Ensure passwordless ssh access from bastion1 (external) to bastion2 (internal). Script uses rsync to copy over the aba repo. 
# Be sure no mirror registries are installed on either bastion before running.  Internal bastion2 can be a fresh "minimal install" of RHEL8/9.

# THIS TEST FAILS AS EXPECTED AT HOST BOOT SINCE ACCESS TO REGISTRY FAILS

cd `dirname $0`

# Be sure this file exists
make mirror-registry.tar.gz

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

######################
# Set up test 

bastion2=10.0.1.6
p=22222

cd ..  # Change into "aba" dir

### make distclean
### ./aba --version 4.13.27 --vmw ~/.vmware.conf

ver=$(cat ./target-ocp-version.conf)

# Set up internal mirror config to look for existing mirror on registry2.example.com
cp -f templates/mirror.conf mirror
sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ver/g" mirror/mirror.conf
## test for remote mirror
sed -i "s/registry.example.com/registry2.example.com/g" mirror/mirror.conf
#sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" mirror/mirror.conf
sed -i "s#tls_verify=true#tls_verify=     #g" mirror/mirror.conf   # No need for rootCA.pem
####cp mirror.conf mirror/

# Revert a snapshot and power on the internal bastion vm
### ( . vmware.conf; govc snapshot.revert -vm bastion2-internal-rhel8 Latest; sleep 8; govc vm.power -on bastion2-internal-rhel8; sleep 8; )
ssh $(whoami)@registry2.example.com -- "date" || sleep 3
ssh $(whoami)@registry2.example.com -- "date" || sleep 2

# Install 'existing' reg on bastion2
test/reg-test-install-remote.sh registry2.example.com

make save

# If the VM snapshot is reverted, as above, no need to delete old files
#ssh $(whoami)@$bastion2 -- "rm -rf ~/bin/* ~/aba"

cd

echo Configure bastion2 for testing

ssh $(whoami)@$bastion2 "rpm -q make  || sudo yum install make rsync -y"
ssh $(whoami)@$bastion2 "rpm -q rsync || sudo yum install make rsync -y"

# Set up on local 
rpm -q rsync || sudo yum install rsync -y 

time rsync --delete --progress --partial --times -avz \
	--exclude '*/.git*' \
	--exclude 'aba/cli/*' \
	--exclude 'aba/mirror/mirror-registry' \
	--exclude 'aba/mirror/*.tar' \
	--exclude 'aba/mirror/.rpms' \
		bin aba $(whoami)@10.0.1.6:

# Do not copy over .rpms since they also need to be installed on the internal bastion

echo Install the reg creds

##### NO NEED for this test ssh $(whoami)@$bastion2 -- "cp -v ~/quay-install/quay-rootCA/rootCA.pem ~/aba/mirror/regcreds/"  
ssh $(whoami)@$bastion2 -- "cp -v ~/.containers/auth.json ~/aba/mirror/regcreds/pull-secret-mirror.json"

######################
echo Runtest: START - airgap

ssh $(whoami)@$bastion2 -- "make -C aba load sno" 
ssh $(whoami)@$bastion2 -- "make -C aba/sno delete" 

######################
echo Cleanup test

cd aba
test/reg-test-uninstall-remote.sh

