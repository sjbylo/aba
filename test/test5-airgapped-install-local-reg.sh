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

source test/include.sh

mylog
mylog "===> Starting test $0"
mylog

#> test/test.log

set -x

######################
# Set up test 

source <(normalize-aba-conf)
##scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf

> mirror/mirror.conf
#make distclean 
test-cmd "make -C mirror distclean" 
rm -rf sno compact standard 
#make uninstall clean 

v=4.14.9
./aba --version $v --vmw ~/.vmware.conf 
mylog aba..conf configured for $v and vmware.conf

# Be sure this file exists
test-cmd "make -C test mirror-registry.tar.gz"

bastion2=10.0.1.6
p=22222

#################################
# Copy and edit mirror.conf 

scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf

mylog "Test the internal bastion (registry2.example.com) as mirror"

sed -i "s/registry.example.com/registry2.example.com/g" ./mirror/mirror.conf
#sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" ./mirror/mirror.conf
#

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

mylog done

source <(cd mirror && normalize-mirror-conf)

test-cmd "make save"

# Smoke test!
[ ! -s mirror/save/mirror_seq1_000000.tar ] && echo "Aborting test as there is no save/mirror_seq1_000000.tar file" && exit 1

mylog Configure internal bastion with rsync and make

# If the VM snapshot is reverted, as above, no need to delete old files
remote-test-cmd $bastion2 "rm -rf ~/bin/* ~/aba"

mylog Configure bastion2 for testing, install make and rsync ...
ssh $(whoami)@$bastion2 "rpm -q make  || sudo yum install make rsync -y"
ssh $(whoami)@$bastion2 "rpm -q rsync || sudo yum install make rsync -y"

# Install rsync on localhost
rpm -q rsync || sudo yum install rsync -y 

mylog Tar+ssh files over to internal bastion: $bastion2 
make tar out=- | ssh $bastion2 -- tar xzvf -

### mylog rsync files to instenal bastion ...
### test-cmd make rsync ip=$bastion2

### echo "Install the reg creds, simulating a manual config" 
### ssh $(whoami)@$bastion2 -- "cp -v ~/quay-install/quay-rootCA/rootCA.pem ~/aba/mirror/regcreds/"  
### ssh $(whoami)@$bastion2 -- "cp -v ~/.containers/auth.json ~/aba/mirror/regcreds/pull-secret-mirror.json"

######################
mylog Runtest: START - airgap

mylog "Running 'make load' on internal bastion"

remote-test-cmd $bastion2 "sudo dnf install make -y" 
remote-test-cmd $bastion2 "make -C aba load" 

mylog "Running 'make sno' on internal bastion"

remote-test-cmd $bastion2 "rm -rf aba/sno" 

mylog Create the cluster iso only 
remote-test-cmd $bastion2 "make -C aba sno #target=iso" 

mylog Add vm memory
remote-test-cmd $bastion2 "sed -i 's/^master_mem=.*/master_mem=24/g' aba/sno/cluster.conf"

#ssh $(whoami)@$bastion2 -- "make -C aba/sno cmd" 

mylog "===> Test 'air gapped' complete "

######################
mylog Now simulate adding more images to the mirror registry
######################

mylog Runtest: vote-app

mylog Add ubi9 image to imageset conf file 
cat >> mirror/save/imageset-config-save.yaml <<END
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi:latest
END

mylog Save ubi image on external bastion
test-cmd "make -C mirror save"

mylog rsync save/ dir to internal bastion

### make rsync ip=$bastion2 # This copies over the whiole repo, incl. the mirror/.uninstalled flag file which causes workflow problems, e.g. make uninstall fails
rsync --progress --partial --times -avz mirror/save/ $bastion2:aba/mirror/save 

mylog Load ubi image on internal bastion
remote-test-cmd $bastion2 "make -C aba/mirror load"

####################

mylog Add vote-app image to imageset conf file 
cat >> mirror/save/imageset-config-save.yaml <<END
  - name: quay.io/sjbylo/flask-vote-app:latest
END

mylog Save vote-app image on external bastion
test-cmd "make -C mirror save"

mylog rsync save/ dir to internal bastion
rsync --progress --partial --times -avz mirror/save/ $bastion2:aba/mirror/save 

mylog Load vote-app image on internal bastion
remote-test-cmd $bastion2 "make -C aba/mirror load"

mylog Install the cluster proper now
remote-test-cmd $bastion2 "make -C aba/sno"

######################

remote-test-cmd $bastion2 "aba/test/deploy-test-app.sh"

mylog "Test 'vote-app' complete"

mylog Runtest: operator

mylog Append operators to imageset conf

cat >> mirror/save/imageset-config-save.yaml <<END
  - name: quay.io/kiali/demo_travels_cars:v1
  - name: quay.io/kiali/demo_travels_control:v1
  - name: quay.io/kiali/demo_travels_discounts:v1
  - name: quay.io/kiali/demo_travels_flights:v1
  - name: quay.io/kiali/demo_travels_hotels:v1
  - name: quay.io/kiali/demo_travels_insurances:v1
  - name: quay.io/kiali/demo_travels_mysqldb:v1
  - name: quay.io/kiali/demo_travels_portal:v1
  - name: quay.io/kiali/demo_travels_travels:v1
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.14
    packages:
      - name: servicemeshoperator
        channels:
        - name: stable
      - name: kiali-ossm
        channels:
        - name: stable
#      - name: jaeger-product
#        channels:
#        - name: stable
#      - name: advanced-cluster-management
#        channels:
#        - name: release-2.9
END

mylog Save the mesh images on external bastion

test-cmd "make -C mirror save"

mylog rsync save/ dir to internal bastion
rsync --progress --partial --times -avz mirror/save/ $bastion2:aba/mirror/save 

remote-test-cmd $bastion2 "make -C aba/mirror load"
remote-test-cmd $bastion2 "make -C aba/sno day2"

cat >> mirror/save/imageset-config-save.yaml <<END
      - name: jaeger-product
        channels:
        - name: stable
END

mylog Save the jaeger-product images on external bastion
test-cmd "make -C mirror save"


mylog Download mesh demo into test/mesh, for use by deploy script
(
	rm -rf test/mesh && mkdir test/mesh && cd test/mesh && git clone https://github.com/sjbylo/openshift-service-mesh-demo.git && \
	cd openshift-service-mesh-demo && \
	sed -i "s/quay\.io/$reg_host:$reg_port\/$reg_path/g" */*.yaml */*/*.yaml */*/*/*.yaml &&
	sed -i "s/source: .*/source: cs-redhat-operator-index/g" operators/* 
) 

### make rsync ip=$bastion2  # This copies over the mirror/.uninstalled flag file which causes workflow problems, e.g. make uninstall fails
mylog rsync save/ dir to internal bastion
pwd
rsync --progress --partial --times -avz mirror/save/ $bastion2:aba/mirror/save 
rm -f test/mirror-registry.tar.gz  # No need to copy this over!
rsync --progress --partial --times -avz test   $bastion2:aba
### ssh $(whoami)@$bastion2 -- "make -C aba/mirror verify"

mylog Run make load on internal bastion
remote-test-cmd $bastion2 "make -C aba/mirror load"

test-cmd sleep 20
remote-test-cmd $bastion2 "make -C aba/sno day2"   # Install CA cert and activate local op. hub
test-cmd sleep 60
remote-test-cmd $bastion2 "aba/test/deploy-mesh.sh"

mylog "Test: 'operator' complete "

remote-test-cmd $bastion2 "make -C aba/sno delete" 

######################
mylog Cleanup test

mylog "make -C aba/mirror uninstall"
remote-test-cmd $bastion2 "make -C aba/mirror uninstall"

mylog "===> Test $0 complete "

[ -f test/test.log ] && cp test/test.log test/test.log.bak

