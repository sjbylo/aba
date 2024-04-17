#!/bin/bash -ex
# This test installs a mirror reg. on the internal bastion (just for testing) and then
# treats that registry as an "existing registry" in the test internal workflow. 

# Required: 2 bastions (internal and external), for internal (no direct Internet) only yum works via a proxy. For external, the proxy is fully configured. 
# I.e. Internal bastion has no access to the Internet.  External has full access. 
# Ensure passwordless ssh access from bastion1 (external) to bastion2 (internal). Script uses rsync to copy over the aba repo. 
# Be sure no mirror registries are installed on either bastion before running.  Internal bastion2 can be a fresh "minimal install" of RHEL8/9.

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
cd ..  # Change into "aba" dir

rm -fr ~/.containers ~/.docker

source scripts/include_all.sh && trap - ERR
source test/include.sh

[ ! "$target_full" ] && targetiso=target=iso   # Default is to generate 'iso' only   # Default is to only create iso
mylog targetiso=$targetiso

mylog
mylog "===> Starting test $0"
mylog Test to install a local reg. on registry2.example.com and save + copy + load images.  Install sno ocp and a test app and svc mesh.
mylog

ntp=10.0.1.8 # If available

rm -f ~/.aba.previous.backup

######################
# Set up test 

which make || sudo dnf install make -y

> mirror/mirror.conf
test-cmd -m "Cleaning up mirror - distclean" "make -C mirror distclean ask=" 
#test-cmd -m "Cleaning up mirror - clean" "make -C mirror clean" 
rm -rf sno compact standard 

subdir=~/
#subdir=~/subdir

v=4.14.14
rm -f aba.conf  # Set it up next
vf=~/.vmware.conf.vc
test-cmd -m "Configure aba.conf for version $v and vmware $vf" ./aba --version $v ## --vmw $vf
# Set up govc 
cp $vf vmware.conf 

# Do not ask to delete things
mylog "Setting ask="
sed -i 's/^ask=[^ \t]\{1,\}\([ \t]\{1,\}\)/ask=\1/g' aba.conf

mylog "Setting ntp_server=$ntp" 
[ "$ntp" ] && sed -i "s/^ntp_server=\([^#]*\)#\(.*\)$/ntp_server=$ntp    #\2/g" aba.conf

source <(normalize-aba-conf)

# Be sure this file exists
test-cmd -m "Init test: download mirror-registry.tar.gz" "make -C test mirror-registry.tar.gz"

bastion2=10.0.1.6

#################################
# Copy and edit mirror.conf 

##sudo dnf install python36 python3-jinja2 -y
rpm -q --quiet python3 || rpm -q --quiet python36 || sudo dnf install python3 -y 
scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf

mylog "Test the internal bastion (registry2.example.com) as mirror"

mylog "Setting reg_host=registry2.example.com"
sed -i "s/registry.example.com/registry2.example.com/g" ./mirror/mirror.conf
#sed -i "s#reg_ssh_key=#reg_ssh_key=~/.ssh/id_rsa#g" ./mirror/mirror.conf

make -C cli
source <(normalize-vmware-conf)
##scripts/vmw-create-folder.sh /Datacenter/vm/test

#################################
mylog Revert vm snapshot of the internal bastion vm and power on
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

# Just be sure a valid govc config file exists
scp ~/.vmware.conf steve@registry2.example.com: 

#################################

source <(cd mirror && normalize-mirror-conf)
#### [ ! "$reg_ssh_user" ] && reg_ssh_user=$(whoami)

mylog "Using container mirror at $reg_host:$reg_port and using reg_ssh_user=$reg_ssh_user reg_ssh_key=$reg_ssh_key"

test-cmd -r 99 3 -m "Saving images to local disk" "make save" 

# Smoke test!
[ ! -s mirror/save/mirror_seq1_000000.tar ] && echo "Aborting test as there is no save/mirror_seq1_000000.tar file" && exit 1

# If the VM snapshot is reverted, as above, no need to delete old files
test-cmd -h $reg_ssh_user@$bastion2 -m  "Clean up home dir on internal bastion" "rm -rf ~/bin/* ~/aba"

ssh $reg_ssh_user@$bastion2 "rpm -q make  || sudo yum install make -y"

mylog "Use 'make tarrepo' to copy tar+ssh archive plus seq1 tar file to internal bastion"
###make -s -C mirror inc out=- | ssh $reg_ssh_user@$bastion2 -- tar xvf -
make -s -C mirror tarrepo out=- | ssh $reg_ssh_user@$bastion2 -- tar xvf -
scp -v mirror/save/mirror_seq1_000000.tar $reg_ssh_user@$bastion2:aba/mirror/save

### echo "Install the reg creds, simulating a manual config" 
### ssh $reg_ssh_user@$bastion2 -- "cp -v ~/quay-install/quay-rootCA/rootCA.pem ~/aba/mirror/regcreds/"  
### ssh $reg_ssh_user@$bastion2 -- "cp -v ~/.containers/auth.json ~/aba/mirror/regcreds/pull-secret-mirror.json"

######################
mylog Runtest: START - airgap

test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m  "Loading cluster images into mirror on internal bastion" "make -C aba load" 

mylog "Running 'make sno' on internal bastion"

test-cmd -h $reg_ssh_user@$bastion2 -m  "Tidying up internal bastion" "rm -rf aba/sno" 

[ "$targetiso" ] && mylog Creating the cluster iso only 
test-cmd -h $reg_ssh_user@$bastion2 -m  "Installing sno/iso with 'make -C aba sno $targetiso'" "make -C aba sno $targetiso" 

test-cmd -h $reg_ssh_user@$bastion2 -m  "Setting master memory to 24" "sed -i 's/^master_mem=.*/master_mem=24/g' aba/sno/cluster.conf"

######################
mylog Now adding more images to the mirror registry
######################

mylog Runtest: vote-app

mylog 
mylog Add ubi9 image to imageset conf file 
cat >> mirror/save/imageset-config-save.yaml <<END
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi:latest
END

test-cmd -r 99 3 -m "Saving ubi images to local disk on `hostname`" "make -C mirror save" 

mylog Copy tar+ssh archives to internal bastion
## make -s -C mirror inc out=- | ssh $reg_ssh_user@$bastion2 -- tar xvf -
make -s -C mirror tarrepo out=- | ssh $reg_ssh_user@$bastion2 -- tar xvf -
scp -v mirror/save/mirror_seq2_000000.tar $reg_ssh_user@$bastion2:aba/mirror/save

test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m  "Loading UBI images into mirror" "make -C aba/mirror load" 

mylog 
mylog Add vote-app image to imageset conf file 
cat >> mirror/save/imageset-config-save.yaml <<END
  - name: quay.io/sjbylo/flask-vote-app:latest
END

test-cmd -r 99 3 -m "Saving vote-app image to local disk" " make -C mirror save" 

mylog Copy repo to internal bastion
##make -s -C mirror inc out=- | ssh $reg_ssh_user@$bastion2 -- tar xvf -
make -s -C mirror tarrepo out=- | ssh $reg_ssh_user@$bastion2 -- tar xvf -
scp -v mirror/save/mirror_seq3_000000.tar $reg_ssh_user@$bastion2:aba/mirror/save

test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m  "Loading vote-app image into mirror" "make -C aba/mirror load" 

test-cmd -h $reg_ssh_user@$bastion2 -m  "Installing sno cluster, ready to deploy test app" "make -C aba/sno"

test-cmd -h $reg_ssh_user@$bastion2 -m  "Listing VMs" "make -C aba/sno ls"

####test-cmd -h $reg_ssh_user@$bastion2 -m  "Deploying test vote-app" aba/test/deploy-test-app.sh $subdir
test-cmd -h steve@$bastion2 -m "Create project 'demo'" "make -C $subdir/aba/sno cmd cmd='oc new-project demo'" || true
test-cmd -h steve@$bastion2 -m "Launch vote-app" "make -C $subdir/aba/sno cmd cmd='oc new-app --insecure-registry=true --image $reg_host:$reg_port/$reg_path/sjbylo/flask-vote-app --name vote-app -n demo'" || true
test-cmd -h steve@$bastion2 -m "Wait for vote-app rollout" "make -C $subdir/aba/sno cmd cmd='oc rollout status deployment vote-app -n demo'"



mylog 
mylog Append svc mesh and kiali operators to imageset conf

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

########
test-cmd -r 99 3 -m "Saving mesh operators to local disk" "make -C mirror save"

mylog Copy tar+ssh archives to internal bastion
make -s -C mirror inc out=- | ssh $reg_ssh_user@$bastion2 -- tar xvf -

test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m  "Loading images to mirror" "make -C aba/mirror load" 

test-cmd -h $reg_ssh_user@$bastion2 -m  "Configuring day2 ops" "make -C aba/sno day2"

mylog 
mylog Append jaeger operator to imageset conf

cat >> mirror/save/imageset-config-save.yaml <<END
      - name: jaeger-product
        channels:
        - name: stable
END

test-cmd -r 99 3 -m "Saving jaeger operator to local disk" "make -C mirror save"

mylog Downloading the mesh demo into test/mesh, for use by deploy script
(
	rm -rf test/mesh && mkdir test/mesh && cd test/mesh && git clone https://github.com/sjbylo/openshift-service-mesh-demo.git && \
	cd openshift-service-mesh-demo && \
	# FIXME: so no need to make these changes
	sed -i "s#quay\.io#$reg_host:$reg_port/$reg_path#g" */*.yaml */*/*.yaml */*/*/*.yaml &&
	sed -i "s/source: .*/source: cs-redhat-operator-index/g" operators/* 
) 

mylog Copy tar+ssh archives to internal bastion
rm -f test/mirror-registry.tar.gz  # No need to copy this over!
make -s -C mirror inc out=- | ssh $reg_ssh_user@$bastion2 -- tar xvf - 

test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m  "Loading jaeger operator images to mirror" "make -C aba/mirror load" 

test-cmd -m "Pausing for 60s to let OCP to settle" sleep 60    # For some reason, the cluster was still not fully ready in tests!

# Sometimes the cluster is not fully ready... OCP API can fail, so re-run 'make day2' ...
test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m "Run 'day2' attempt number $i ..." "make -C aba/sno day2" && break || true  # Install CA cert and activate local op. hub

# Wait for https://docs.openshift.com/container-platform/4.11/openshift_images/image-configuration.html#images-configuration-cas_image-configuration 
test-cmd -m "Pausing for 30s to let OCP to settle" sleep 30  # And wait for https://access.redhat.com/solutions/5514331 to take effect 

test-cmd -h $reg_ssh_user@$bastion2 -m "Deploying service mesh with test app" "aba/test/deploy-mesh.sh"

sleep 30  # Sleep in case need to check the cluster

##  KEEP  # test-cmd -h $reg_ssh_user@$bastion2 -m  "Deleting sno cluster" "make -C aba/sno delete" 

rm -rf test/mesh 

######################
test-cmd -h $reg_ssh_user@$bastion2 -m  "Deleting cluster dirs, aba/sno aba/compact aba/standard" "rm -rf  aba/sno aba/compact aba/standard" 

test-cmd -h $reg_ssh_user@$bastion2 -m  "Creating standard cluster" "make -C aba standard" 
test-cmd -h $reg_ssh_user@$bastion2 -m  "deleting standard cluster" "make -C aba/standard delete" 

test-cmd -h $reg_ssh_user@$bastion2 -m  "Creating compact cluster" "make -C aba compact" 
test-cmd -h $reg_ssh_user@$bastion2 -m  "deleting compact cluster" "make -C aba/compact delete" 

## KEEP test-cmd -h $reg_ssh_user@$bastion2 -m  "Creating sno cluster with 'make -C aba cluster name=sno type=sno'" "make -C aba cluster name=sno type=sno" 
## KEEP test-cmd -h $reg_ssh_user@$bastion2 -m  "deleting sno cluster" "make -C aba/sno delete" 
######################

test-cmd -h $reg_ssh_user@$bastion2 -m  "Uninstalling mirror registry on internal bastion" "make -C aba/mirror uninstall"

mylog
mylog "===> Completed test $0"
mylog

[ -f test/test.log ] && cp test/test.log test/test.log.bak

echo SUCCESS 
