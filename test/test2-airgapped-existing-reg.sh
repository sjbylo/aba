#!/bin/bash -ex
# This test installs a mirror reg. on the internal bastion (just for testing) and then
# treats that registry as an "existing registry" in the test internal workflow. 

# Required: 2 bastions (internal and external), for internal (no direct Internet) only yum works via a proxy. For external, the proxy is fully configured. 
# I.e. Internal bastion has no access to the Internet.  External has full access. 
# Ensure passwordless ssh access from bastion1 (external) to bastion2 (internal). Script uses rsync to copy over the aba repo. 
# Be sure no mirror registries are installed on either bastion before running.  Internal bastion2 can be a fresh "minimal install" of RHEL8/9.

cd `dirname $0`
cd ..  # Change into "aba" dir

bastion2=10.0.1.6
rm -f ~/.aba.previous.backup

source scripts/include_all.sh
source test/include.sh

[ ! "$target_full" ] && targetiso=target=iso   # Default is to generate 'iso' only   # Default is to only create iso
mylog targetiso=$targetiso

mylog
mylog "===> Starting test $0"
mylog

######################
# Set up test 

> mirror/mirror.conf
test-cmd "make -C mirror distclean"
rm -rf sno compact standard 

v=4.14.12
### test-cmd ./aba --version $v --vmw ~/.vmware.conf 
test-cmd -m "Configure aba.conf for version $v and vmware vcenter" ./aba --version $v --vmw ~/.vmware.conf.vc
sed -i 's/^ask=[^ \t]\{1,\}\([ \t]\{1,\}\)/ask=\1/g' aba.conf
sed -i 's/^ntp_server=[^ \t]\{1,\}\([ \t]\{1,\}\)/ntp_server=10.0.1.8\1/g' aba.conf
source <(normalize-aba-conf)

### test-cmd 'make -C cli clean'
### test-cmd 'make -C cli'

# Be sure this file exists
test-cmd "make -C test mirror-registry.tar.gz"

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

sudo mount -o remount,size=6G /tmp   # Needed by oc-mirror ("make save") when Operators need to be saved!

# If the VM snapshot is reverted, as above, no need to delete old files
mylog Prepare insternal bastion for testing, delete dirs and install make
ssh $bastion2 "rm -rf ~/bin/* ~/aba"
ssh $bastion2 "rpm -q make  || sudo yum install make rsync -y"
ssh $bastion2 "rpm -q rsync || sudo yum install make rsync -y"

mylog "Install 'existing' test mirror registry on internal bastion"
test-cmd test/reg-test-install-remote.sh registry2.example.com


################################
### mylog make save
rm -rf mirror/save  
test-cmd -m "Saving images to local disk" make save

# Smoke test!
[ ! -s mirror/save/mirror_seq1_000000.tar ] && echo "Aborting test as there is no save/mirror_seq1_000000.tar file" && exit 1

mylog Tar+ssh files over to internal bastion: $bastion2 
make -s -C mirror inc out=- | ssh $bastion2 -- tar xzvf -

mylog "Install the reg creds, simulating a manual config of 'existing' registry" 
remote-test-cmd -m "Loading images into mirror registry" $bastion2 "make -C aba load" || true  # This user's action is expected to fail since there are no creds for the "existing reg."
# But, now regcreds/ is created...
ssh $bastion2 "cp -v ~/quay-install/quay-rootCA/rootCA.pem ~/aba/mirror/regcreds/"  
ssh $bastion2 "cp -v ~/.containers/auth.json ~/aba/mirror/regcreds/pull-secret-mirror.json"

######################

remote-test-cmd -m "Loading images into mirror" $bastion2 "make -C aba load"  # Now, this works

ssh $bastion2 "rm -rf aba/compact" 
remote-test-cmd -m "Install compact cluster with targetiso[$targetiso]" $bastion2 "make -C aba compact $targetiso" 
remote-test-cmd $bastion2 "make -C aba/compact delete" 

### remote-test-cmd $bastion2 "rm -rf aba/standard" 
### remote-test-cmd $bastion2 "make -C aba standard $targetiso" 
### remote-test-cmd $bastion2 "make -C aba/standard delete" 

ssh $bastion2 "rm -rf aba/sno" 

remote-test-cmd -m "Install sno cluster with targetiso[$targetiso]" $bastion2 "make -C aba sno $targetiso" 


######################
# Now simulate adding more images to the mirror registry
######################

mylog Adding ubi images to imageset conf file 

cat >> mirror/save/imageset-config-save.yaml <<END
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi:latest
  - name: quay.io/sjbylo/flask-vote-app:latest
END

### echo "Install the reg creds on localhost, simulating a manual config" 
### scp $(whoami)@$bastion2:quay-install/quay-rootCA/rootCA.pem mirror/regcreds
### scp $(whoami)@$bastion2:aba/mirror/regcreds/pull-secret-mirror.json mirror/regcreds
### make -C mirror verify 

test-cmd -m "Saving ubi images to local disk" make -C mirror save 

### mylog make rsync
### test-cmd make rsync ip=$bastion2
mylog Tar+ssh files over to internal bastion: $bastion2 
make -s -C mirror inc out=- | ssh $bastion2 -- tar xzvf -

remote-test-cmd -m "Verifying access to mirror registry" $bastion2 "make -C aba/mirror verify"

remote-test-cmd -m "Loading images into mirror" $bastion2 "make -C aba/mirror load"

# FIXME: Might need to run:
# 'make -C mirror clean' here since we are installing another cluster *with the same mac addresses*! So, install might fail.
remote-test-cmd -m "Installing sno cluster" $bastion2 "make -C aba/sno"

remote-test-cmd -m "Checking cluster operator status on cluster sno" $bastion2 "make -C aba/sno cmd"

######################

remote-test-cmd -m "Deploying vote-app on cluster" $bastion2 aba/test/deploy-test-app.sh

mylog Adding advanced-cluster-management operator iomages to imageset conf file

cat >> mirror/save/imageset-config-save.yaml <<END
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.14
    packages:
      - name: advanced-cluster-management
        channels:
        - name: release-2.9
END

test-cmd -m "Saving advanced-cluster-management images to local disk" make -C mirror save 

mylog Tar+ssh files over to internal bastion: $bastion2 
make -s -C mirror inc out=- | ssh $bastion2 -- tar xzvf -

remote-test-cmd -m "Loading images into mirror" $bastion2 "make -C aba/mirror load"

remote-test-cmd -m "Verifying miror registry access" $bastion2 "make -C aba/mirror verify"

remote-test-cmd -m "Deleting sno cluster" $bastion2 "make -C aba/sno delete" 

######################

test-cmd -m "Clean up 'existing' mirror registry on internal bastion" test/reg-test-uninstall-remote.sh

mylog
mylog "===> Completed test $0"
mylog

[ -f test/test.log ] && cp test/test.log test/test.log.bak
