#!/bin/bash -ex
# This test installs a mirror reg. on the internal bastion (just for testing) and then
# treats that registry as an "existing registry" in the test internal workflow. 

# Required: 2 bastions (internal and external), for internal (no direct Internet) only yum works via a proxy. For external, the proxy is fully configured. 
# I.e. Internal bastion has no access to the Internet.  External has full access. 
# Ensure passwordless ssh access from bastion1 (external) to bastion2 (internal). Script uses rsync to copy over the aba repo. 
# Be sure no mirror registries are installed on either bastion before running.  Internal bastion2 can be a fresh "minimal install" of RHEL8/9.

cd `dirname $0`
cd ..  # Change into "aba" dir

./aba --version 4.14.9 --vmw ~/.vmware.conf 
[ -s mirror/mirror.conf ] && touch mirror/mirror.conf

# Be sure this file exists
make -C test mirror-registry.tar.gz

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

set -x

#make -C mirror uninstall clean

ver=$(cat ./target-ocp-version.conf)

#################################
# Copy and edit mirror.conf 
cp -f templates/mirror.conf mirror/
sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ver/g" ./mirror/mirror.conf
## test the internal bastion (registry2.example.com) as mirror
sed -i "s/registry.example.com/registry2.example.com/g" ./mirror/mirror.conf
#sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" ./mirror/mirror.conf
#################################

# See if existing remote reg. is working, otherwise reset and re-install 
if ! ssh $(whoami)@registry2.example.com -- "cd aba/mirror && make verify"; then
	echo
	echo Revert a snapshot and power on the internal bastion vm
	echo
	( . vmware.conf; govc snapshot.revert -vm bastion2-internal-rhel8 Latest; sleep 8; govc vm.power -on bastion2-internal-rhel8; sleep 8; )
	ssh $(whoami)@registry2.example.com -- "date" || sleep 3
	ssh $(whoami)@registry2.example.com -- "date" || sleep 2

	echo
	echo Install 'existing' reg on bastion2
	echo
	test/reg-test-install-remote.sh registry2.example.com
fi

echo
echo Running make save
echo
rm -rf mirror/save  
make save

[ ! -s mirror/save/mirror_seq1_000000.tar ] && echo "Aborting test as there is no save/mirror_seq1_000000.tar file" && exit 1

# If the VM snapshot is reverted, as above, no need to delete old files
#ssh $(whoami)@$bastion2 -- "rm -rf ~/bin/* ~/aba"

echo Configure bastion2 for testing

ssh $(whoami)@$bastion2 "rpm -q make  || sudo yum install make rsync -y"
ssh $(whoami)@$bastion2 "rpm -q rsync || sudo yum install make rsync -y"

# Set up on local 
rpm -q rsync || sudo yum install rsync -y 

make rsync ip=$bastion2

# Do not copy over .rpms since they also need to be installed on the internal bastion

echo "Install the reg creds, simulating a manual config" 
ssh $(whoami)@$bastion2 -- "cp -v ~/quay-install/quay-rootCA/rootCA.pem ~/aba/mirror/regcreds/"  
ssh $(whoami)@$bastion2 -- "cp -v ~/.containers/auth.json ~/aba/mirror/regcreds/pull-secret-mirror.json"

# Verify registry working 
ssh $(whoami)@registry2.example.com -- "cd aba/mirror && make verify"

######################
echo Runtest: START - airgap

echo
echo Running make load sno # on internal bastion
echo
ssh $(whoami)@$bastion2 -- "make -C aba load sno" 
#ssh $(whoami)@$bastion2 -- "make -C aba/sno delete" 

######################
echo edit imageset conf file test
cat >> mirror/imageset-config.yaml <<END
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi:latest
  - name: quay.io/sjbylo/flask-vote-app:latest
END

echo "Install the reg creds on localhost, simulating a manual config" 
scp $(whoami)@$bastion2:quay-install/quay-rootCA/rootCA.pem mirror/regcreds
scp $(whoami)@$bastion2:aba/mirror/regcreds/pull-secret-mirror.json mirror/regcreds
make -C mirror verify 
make -C mirror save 
make -C mirror load

######################

ssh $(whoami)@$bastion2 -- "cd aba/sno && make cmd cmd='oc new-project demo'"
ssh $(whoami)@$bastion2 -- "cd aba/sno && make cmd cmd='oc new-app --insecure-registry=true --image registry2.example.com:8443/openshift4/sjbylo/flask-vote-app --name vote-app -n demo'" 
sleep 5
ssh $(whoami)@$bastion2 -- "cd aba/sno && make cmd cmd='oc rollout status deployment vote-app -n demo'" 

ssh $(whoami)@$bastion2 -- "make -C aba/sno delete" 

######################
echo Cleanup test

test/reg-test-uninstall-remote.sh

