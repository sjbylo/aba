#!/bin/bash -ex
# This test installs a mirror reg. on the internal bastion (just for testing) and then
# treats that registry as an "existing registry" in the test internal workflow. 

# Required: 2 bastions (internal and external), for internal (no direct Internet) only yum works via a proxy. For external, the proxy is fully configured. 
# I.e. Internal bastion has no access to the Internet.  External has full access. 
# Ensure passwordless ssh access from bastion1 (external) to bastion2 (internal). Script uses tar+ssh to copy over the aba repo. 
# Be sure no mirror registries are installed on either bastion before running.  Internal bastion2 can be a fresh "minimal install" of RHEL8/9.

### sudo dnf remove make jq bind-utils nmstate net-tools skopeo python3-jinja2 python3-pyyaml openssl coreos-installer -y

### # FIXME: test for pre-existing rpms!  we don't want yum to run at all as it may error out
### sudo dnf install -y $(cat templates/rpms-internal.txt)
### sudo dnf install -y $(cat templates/rpms-external.txt)

cd `dirname $0`
cd ..  # Change into "aba" dir

rm -fr ~/.containers ~/.docker
rm -f ~/.aba.previous.backup


#bastion2=10.0.1.6
bastion2=registry2.example.com
ntp=10.0.1.8 # If available
rm -f ~/.aba.previous.backup

source scripts/include_all.sh && trap - ERR  # Not wanted during testing?
source test/include.sh

[ ! "$target_full" ] && targetiso=target=iso   # Default is to generate 'iso' only   # Default is to only create iso
mylog targetiso=$targetiso

mylog
mylog "===> Starting test $0"
mylog Test to integrate an existing reg. on registry2.example.com and save + copy + load images.  Install sno ocp and a test app. 
mylog

######################
# Set up test 

which make || sudo dnf install make -y

# clean up all, assuming reg. is not running (deleted)
test-cmd "make -C mirror distclean"
rm -rf sno compact standard 

v=4.14.14
rm -f aba.conf
vf=~/.vmware.conf.vc
test-cmd -m "Configure aba.conf for version $v and vmware $vf" ./aba --version $v --vmw $vf

mylog "Setting ask="
sed -i 's/^ask=[^ \t]\{1,\}\([ \t]\{1,\}\)/ask=\1/g' aba.conf

mylog "Setting ntp_server=$ntp" 
[ "$ntp" ] && sed -i "s/^ntp_server=\([^#]*\)#\(.*\)$/ntp_server=$ntp    #\2/g" aba.conf
source <(normalize-aba-conf)

# Be sure this file exists
test-cmd "make -C test mirror-registry.tar.gz"

#################################
# Copy and edit mirror.conf 
#cp -f templates/mirror.conf mirror/
### rpm -q python3 || rpm -q python36 || sudo dnf install python36 python3-jinja2 -y
rpm -q --quiet python3 || rpm -q --quiet python36 || sudo dnf install python3 -y 
make -C mirror mirror.conf
### scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf

## test the internal bastion (registry2.example.com) as mirror
mylog "Setting reg_host=registry2.example.com"
sed -i "s/registry.example.com/registry2.example.com/g" ./mirror/mirror.conf
#sed -i "s#reg_ssh_key=#reg_ssh_key=~/.ssh/id_rsa#g" ./mirror/mirror.conf

# Fetch the config
source <(cd mirror; normalize-mirror-conf)
mylog "Using container mirror at $reg_host:$reg_port and using reg_ssh_user=$reg_ssh_user reg_ssh_key=$reg_ssh_key"

make -C cli
source <(normalize-vmware-conf)
scripts/vmw-create-folder.sh /Datacenter/vm/test

#################################
mylog Revert a snapshot and power on the internal bastion vm
(
	govc snapshot.revert -vm bastion2-internal-rhel8 Latest
	sleep 8
	govc vm.power -on bastion2-internal-rhel8
	sleep 5
)
# Wait for host to come up
ssh steve@registry2.example.com -- "date" || sleep 2
ssh steve@registry2.example.com -- "date" || sleep 3
ssh steve@registry2.example.com -- "date" || sleep 8
### TEST for when user installs all rpms in advance, should not call "dnf" as it may fail without network 
### ssh steve@registry2.example.com -- "sudo dnf install podman make python3-jinja2 python3-pyyaml jq bind-utils nmstate net-tools skopeo openssl coreos-installer -y"
#################################

uname -n | grep -qi ^fedora$ && sudo mount -o remount,size=6G /tmp   # Needed by oc-mirror ("make save") when Operators need to be saved!

# If the VM snapshot is reverted, as above, no need to delete old files
mylog Prepare internal bastion for testing, delete dirs and install make
ssh steve@$bastion2 "rm -rf ~/bin/* ~/aba"
ssh steve@$bastion2 "rpm -q make  || sudo yum install make -y"

mylog "Install 'existing' test mirror registry on internal bastion: registry2.example.com"
test-cmd test/reg-test-install-remote.sh registry2.example.com


################################
rm -rf mirror/save    # Better to test with 'make -C mirror clean'?
test-cmd -m "Cleaning mirror dir" make -C mirror clean
test-cmd -r 99 3 -m "Saving images to local disk on `hostname`" make save 

# Smoke test!
[ ! -s mirror/save/mirror_seq1_000000.tar ] && echo "Aborting test as there is no save/mirror_seq1_000000.tar file" && exit 1

mylog "'make tar' and ssh files over to internal bastion: steve@$bastion2"
make -s -C mirror tar out=- | ssh steve@$bastion2 -- tar xvf -

ssh steve@$bastion2 "cat aba/mirror/mirror.conf | grep reg_host | grep registry2.example.com" # FIXME

test-cmd -h steve@$bastion2 -m  "Loading images into mirror registry (without regcreds/ fails with 'Not a directory')" "make -C aba load" || true  # This user's action is expected to fail since there are no login credentials for the "existing reg."

ssh steve@$bastion2 "cat aba/mirror/mirror.conf | grep reg_host | grep registry2.example.com" # FIXME

# But, now regcreds/ is created...
mylog "Simulating a manual config of 'existing' registry login credentials into mirror/regcreds/ on host: steve@$bastion2"

ssh steve@$bastion2 "cat aba/mirror/mirror.conf | grep reg_host | grep registry2.example.com" # FIXME

ssh steve@$bastion2 "ls -l ~/aba/mirror"  
### ssh steve@$bastion2 "mkdir -p  ~/aba/mirror/regcreds"  
ssh steve@$bastion2 "cp -v ~/quay-install/quay-rootCA/rootCA.pem ~/aba/mirror/regcreds/"  
ssh steve@$bastion2 "cp -v ~/.containers/auth.json ~/aba/mirror/regcreds/pull-secret-mirror.json"

ssh steve@$bastion2 "cat aba/mirror/mirror.conf | grep reg_host | grep registry2.example.com" # FIXME

test-cmd -h steve@$bastion2 -m  "Verifying access to the mirror registry $reg_host:$reg_port now succeeds" "make -C aba/mirror verify"

######################

# Now, this works
test-cmd -h steve@$bastion2 -r 99 3 -m  "Loading images into mirror registry $reg_host:$reg_port" "make -C aba load" 

ssh steve@$bastion2 "rm -rf aba/compact" 
test-cmd -h steve@$bastion2 -m  "Install compact cluster with targetiso=[$targetiso]" "make -C aba compact $targetiso" 
test-cmd -h steve@$bastion2 -m  "Deleting cluster (if it exists)" "make -C aba/compact delete" 

### remote-test-cmd steve@$bastion2 "rm -rf aba/standard" 
### remote-test-cmd steve@$bastion2 "make -C aba standard $targetiso" 
### remote-test-cmd steve@$bastion2 "make -C aba/standard delete" 

ssh steve@$bastion2 "rm -rf aba/sno" 

test-cmd -h steve@$bastion2 -m  "Install sno cluster with 'make -C aba sno $targetiso'" "make -C aba sno $targetiso" 


######################
# Now simulate adding more images to the mirror registry
######################

mylog Adding ubi images to imageset conf file on `hostname`

cat >> mirror/save/imageset-config-save.yaml <<END
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi:latest
  - name: quay.io/sjbylo/flask-vote-app:latest
END

### echo "Install the reg creds on localhost, simulating a manual config" 
### scp steve@$bastion2:quay-install/quay-rootCA/rootCA.pem mirror/regcreds
### scp steve@$bastion2:aba/mirror/regcreds/pull-secret-mirror.json mirror/regcreds
### make -C mirror verify 

test-cmd -r 99 3 -m "Saving ubi images to local disk" make -C mirror save 

### mylog "'make inc' and ssh files over to internal bastion: steve@$bastion2"
### make -s -C mirror inc out=- | ssh steve@$bastion2 -- tar xvf -
#
### mylog "'scp mirror/save/mirror_seq2.tar' file from `hostname` over to internal bastion: steve@$bastion2"
### scp -v mirror/save/mirror_seq2.tar steve@$bastion2 aba/mirror/save

mylog "Simulate an inc tar copy of 'mirror/save/mirror_seq2.tar' file from `hostname` over to internal bastion: steve@$bastion2"
mkdir -p ~/tmp
rm -f ~/tmp/file.tar
make -s -C mirror inc out=~/tmp/file.tar
scp ~/tmp/file.tar steve@$bastion2:
rm -f ~/tmp/file.tar
ssh steve@$bastion2 tar xvf file.tar   # This should unpack the file mirror/save/mirror_seq2.tar only
ssh steve@$bastion2 rm -f file.tar 

test-cmd -h steve@$bastion2 -m  "Verifying access to mirror registry $reg_host:$reg_port" "make -C aba/mirror verify"

test-cmd -h steve@$bastion2 -r 99 3 -m  "Loading images into mirror $reg_host:$reg_port" "make -C aba/mirror load" 

# FIXME: Might need to run:
# 'make -C mirror clean' here since we are re-installing another cluster *with the same mac addresses*! So, install might fail.
test-cmd -h steve@$bastion2 -m  "Installing sno cluster" "make -C aba/sno"

test-cmd -h steve@$bastion2 -m  "Checking cluster operator status on cluster sno" "make -C aba/sno cmd"

######################

test-cmd -h steve@$bastion2 -m  "Deploying vote-app on cluster" aba/test/deploy-test-app.sh

mylog Adding advanced-cluster-management operator images to imageset conf file on `hostname`

cat >> mirror/save/imageset-config-save.yaml <<END
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.14
    packages:
      - name: advanced-cluster-management
        channels:
        - name: release-2.10
END

test-cmd -r 99 3 -m "Saving advanced-cluster-management images to local disk" make -C mirror save 

### mylog Tar+ssh files from `hostname` over to internal bastion: steve@$bastion2 
### make -s -C mirror inc out=- | ssh steve@$bastion2 -- tar xvf -
mylog "'scp mirror/save/mirror_seq3.tar' file from `hostname` over to internal bastion: steve@$bastion2"
scp -v mirror/save/mirror_seq3*.tar steve@$bastion2:aba/mirror/save

test-cmd -h steve@$bastion2 -r 99 3 -m  "Loading images into mirror $reg_host:$reg_port" "make -C aba/mirror load" 

test-cmd -h steve@$bastion2 -m  "Verifying mirror registry access $reg_host:$reg_port" "make -C aba/mirror verify"

test-cmd -h steve@$bastion2 -m  "Deleting sno cluster" "make -C aba/sno delete" 

######################

test-cmd -m "Clean up 'existing' mirror registry on internal bastion" test/reg-test-uninstall-remote.sh

mylog
mylog "===> Completed test $0"
mylog

[ -f test/test.log ] && cp test/test.log test/test.log.bak

echo SUCCESS 
