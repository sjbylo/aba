#!/bin/bash -ex
# This test installs a mirror reg. on the internal bastion (just for testing) and then
# treats that registry as an "existing registry" in the test internal workflow. 

# Required: 2 bastions (internal and external), for internal (no direct Internet) only yum works via a proxy. For external, the proxy is fully configured. 
# I.e. Internal bastion has no access to the Internet.  External has full access. 
# Ensure passwordless ssh access from bastion1 (external) to bastion2 (internal). Script uses rsync to copy over the aba repo. 
# Be sure no mirror registries are installed on either bastion before running.  Internal bastion2 can be a fresh "minimal install" of RHEL8/9.

source scripts/include_all.sh
cd `dirname $0`
cd ..  # Change into "aba" dir
[ -f test/test.log ] && mv test/test.log test/test.log.bak

mylog() {
	echo $*
	echo $* >> test/test.log
}

mylog
mylog "===> Starting test $0"
mylog

#> test/test.log
set -x

######################
# Set up test 

> mirror/mirror.conf
#make distclean 
make -C mirror distclean 
rm -rf sno compact standard 
#make uninstall clean 

./aba --version 4.14.9 --vmw ~/.vmware.conf 
### ver=$(cat ./target-ocp-version.conf)
source <(normalize-aba-conf)
### [ -s mirror/mirror.conf ] && touch mirror/mirror.conf

# Be sure this file exists
make -C test mirror-registry.tar.gz

bastion2=10.0.1.6
p=22222

#################################
# Copy and edit mirror.conf 
#cp -f templates/mirror.conf mirror/
scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf
### sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ocp_version/g" ./mirror/mirror.conf

## test the internal bastion (registry2.example.com) as mirror
sed -i "s/registry.example.com/registry2.example.com/g" ./mirror/mirror.conf
#sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" ./mirror/mirror.conf
#################################

mylog Revert a snapshot and power on the internal bastion vm

(
	source <(normalize-vmware-conf)
	govc snapshot.revert -vm bastion2-internal-rhel8 Latest
	sleep 8
	govc vm.power -on bastion2-internal-rhel8
	sleep 5
)
# Wait for host to come up
ssh $(whoami)@registry2.example.com -- "date" || sleep 2
ssh $(whoami)@registry2.example.com -- "date" || sleep 3
ssh $(whoami)@registry2.example.com -- "date" || sleep 8

mylog Install 'existing' reg on bastion2
test/reg-test-install-remote.sh registry2.example.com

mylog Running make save
rm -rf mirror/save  
make save

# Smoke test!
[ ! -s mirror/save/mirror_seq1_000000.tar ] && echo "Aborting test as there is no save/mirror_seq1_000000.tar file" && exit 1

# If the VM snapshot is reverted, as above, no need to delete old files
ssh $(whoami)@$bastion2 -- "rm -rf ~/bin/* ~/aba"

mylog Configure bastion2 for testing, install make and rsync ...

ssh $(whoami)@$bastion2 "rpm -q make  || sudo yum install make rsync -y"
ssh $(whoami)@$bastion2 "rpm -q rsync || sudo yum install make rsync -y"

# Install rsync on localhost
rpm -q rsync || sudo yum install rsync -y 

# Sync files to instenal bastion
make rsync ip=$bastion2

# Do not copy over '.rpms' since they also need to be installed on the internal bastion

mylog "Install the reg creds, simulating a manual config" 
ssh $(whoami)@$bastion2 -- "cp -v ~/quay-install/quay-rootCA/rootCA.pem ~/aba/mirror/regcreds/"  
ssh $(whoami)@$bastion2 -- "cp -v ~/.containers/auth.json ~/aba/mirror/regcreds/pull-secret-mirror.json"

######################
mylog Runtest: START - airgap

mylog "Running 'make load sno' on internal bastion"
ssh $(whoami)@$bastion2 -- "make -C aba load" 
#ssh $(whoami)@$bastion2 -- "make -C aba/sno upload"   # Just test until iso upload
ssh $(whoami)@$bastion2 -- "rm -rf aba/sno" 
ssh $(whoami)@$bastion2 -- "make -C aba sno target=iso" 

#ssh $(whoami)@$bastion2 -- "make -C aba/sno cmd" 

mylog "===> Test 'air gapped' complete "

######################
# Now simulate adding more images to the mirror registry
######################

mylog Runtest: vote-app

mylog Edit imageset conf file test
cat >> mirror/save/imageset-config-save.yaml <<END
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi:latest
  - name: quay.io/sjbylo/flask-vote-app:latest
END

### echo "Install the reg creds on localhost, simulating a manual config" 
### scp $(whoami)@$bastion2:quay-install/quay-rootCA/rootCA.pem mirror/regcreds
### scp $(whoami)@$bastion2:aba/mirror/regcreds/pull-secret-mirror.json mirror/regcreds
### make -C mirror verify 

make -C mirror save 
make rsync ip=$bastion2
ssh $(whoami)@$bastion2 -- "make -C aba/mirror load"
ssh $(whoami)@$bastion2 -- "make -C aba/mirror verify"

######################

ssh $(whoami)@$bastion2 -- aba/test/deploy-test-app.sh

mylog "===> Test 'vote-app' complete "

mylog Runtest: operator

mylog Edit imageset conf file test
cat >> mirror/save/imageset-config-save.yaml <<END
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.14
    packages:
      - name: advanced-cluster-management
        channels:
        - name: release-2.9
END

mylog make save

make -C mirror save 

mylog make rsync to bastion2
make rsync ip=$bastion2

mylog make load
ssh $(whoami)@$bastion2 -- "make -C aba/mirror load"

mylog make verify
ssh $(whoami)@$bastion2 -- "make -C aba/mirror verify"

mylog "===> Test 'operator' complete "

mylog make delete 
ssh $(whoami)@$bastion2 -- "make -C aba/sno delete" 

######################
mylog Cleanup test

test/reg-test-uninstall-remote.sh

mylog "===> Test $0 complete "
