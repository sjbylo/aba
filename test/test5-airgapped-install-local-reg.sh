#!/bin/bash -ex
# This test installs a mirror reg. on the internal bastion (just for testing) and then
# treats that registry as an "existing registry" in the test internal workflow. 

# Required: 2 bastions (internal and external), for internal (no direct Internet) only yum works via a proxy. For external, the proxy is fully configured. 
# I.e. Internal bastion has no access to the Internet.  External has full access. 
# Ensure passwordless ssh access from bastion1 (external) to bastion2 (internal). 
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

[ ! "$target_full" ] && default_target="target=iso"   # Default is to generate 'iso' only   # Default is to only create iso
mylog default_target=$default_target

mylog ============================================================
mylog Starting test $(basename $0)
mylog ============================================================
mylog "Test to install a local reg. on $bastion2 and save + copy + load images.  Install sno ocp and a test app and svc mesh."
mylog

ntp=10.0.1.8 # If available

rm -f ~/.aba.previous.backup

######################
# Set up test 

which make || sudo dnf install make -y

v=4.15.8

> mirror/mirror.conf
echo "ocp_version=$v" >> aba.conf  # Only to fix error, missing "ocp_version"
test-cmd -m "Cleaning up mirror - distclean" "make -C mirror distclean ask=" 
#test-cmd -m "Cleaning up mirror - clean" "make -C mirror clean" 
rm -rf sno compact standard 

bastion2=registry.example.com
bastion_vm=bastion-internal-rhel9
subdir=~
subdir=~/subdir

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

#################################
# Copy and edit mirror.conf 

##sudo dnf install python36 python3-jinja2 -y
rpm -q --quiet python3 || rpm -q --quiet python36 || sudo dnf install python3 -y 
scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf

mylog "Test the internal bastion ($bastion2) as mirror"

mylog "Setting reg_host=$bastion2"
sed -i "s/registry.example.com/$bastion2/g" ./mirror/mirror.conf
#sed -i "s#reg_ssh_key=#reg_ssh_key=~/.ssh/id_rsa#g" ./mirror/mirror.conf

make -C cli
source <(normalize-vmware-conf)
##scripts/vmw-create-folder.sh /Datacenter/vm/test

#################################
mylog Revert vm snapshot of the internal bastion vm and power on
(
	govc snapshot.revert -vm $bastion_vm aba-test
	sleep 8
	govc vm.power -on $bastion_vm
	sleep 5
)
# Wait for host to come up
ssh steve@$bastion2 -- "date" || sleep 2
ssh steve@$bastion2 -- "date" || sleep 3
ssh steve@$bastion2 -- "date" || sleep 8

# Just be sure a valid govc config file exists
scp ~/.vmware.conf steve@$bastion2: 

#################################

source <(cd mirror && normalize-mirror-conf)
#### [ ! "$reg_ssh_user" ] && reg_ssh_user=$(whoami)

mylog "Using container mirror at $reg_host:$reg_port and using reg_ssh_user=$reg_ssh_user reg_ssh_key=$reg_ssh_key"

test-cmd -r 99 3 -m "Saving images to local disk" "make save" 

# Smoke test!
[ ! -s mirror/save/mirror_seq1_000000.tar ] && echo "Aborting test as there is no save/mirror_seq1_000000.tar file" && exit 1

# If the VM snapshot is reverted, as above, no need to delete old files
####test-cmd -h $reg_ssh_user@$bastion2 -m  "Clean up home dir on internal bastion" "rm -rf ~/bin/* $subdir/aba"

ssh $reg_ssh_user@$bastion2 "rpm -q make  || sudo yum install make -y"

test-cmd -h $reg_ssh_user@$bastion2 -m  "Create test subdir: '$subdir'" "mkdir -p $subdir" 

mylog "Use 'make tarrepo' to copy tar+ssh archive plus seq1 tar file to internal bastion"
###make -s -C mirror inc out=- | ssh $reg_ssh_user@$bastion2 -- tar -C $subdir - xvf -
make -s -C mirror tarrepo out=- | ssh $reg_ssh_user@$bastion2 -- tar -C $subdir -xvf -
scp mirror/save/mirror_seq1_000000.tar $reg_ssh_user@$bastion2:$subdir/aba/mirror/save

### echo "Install the reg creds, simulating a manual config" 
### ssh $reg_ssh_user@$bastion2 -- "cp -v ~/quay-install/quay-rootCA/rootCA.pem $subdir/aba/mirror/regcreds/"  
### ssh $reg_ssh_user@$bastion2 -- "cp -v ~/.containers/auth.json $subdir/aba/mirror/regcreds/pull-secret-mirror.json"

######################
mylog Runtest: START - airgap

test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m  "Loading cluster images into mirror on internal bastion" "make -C $subdir/aba load" 

test-cmd -h $reg_ssh_user@$bastion2 -m  "Tidying up internal bastion" "rm -rf $subdir/aba/sno" 

mylog "Running 'make sno' on internal bastion"

[ "$default_target" ] && mylog "Creating the cluster with target=$default_target only"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Installing sno/iso with 'make -C $subdir/aba sno $default_target'" "make -C $subdir/aba sno $default_target" 

test-cmd -h $reg_ssh_user@$bastion2 -m  "Increase node memory to 24 for loading mesh test app" "sed -i 's/^master_mem=.*/master_mem=24/g' $subdir/aba/sno/cluster.conf"

######################
mylog Now adding more images to the mirror registry
######################

mylog Runtest: vote-app

mylog Add ubi9 image to imageset conf file 
cat >> mirror/save/imageset-config-save.yaml <<END
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi:latest
END

test-cmd -r 99 3 -m "Saving ubi images to local disk on `hostname`" "make -C mirror save" 

mylog Copy tar+ssh archives to internal bastion
## make -s -C mirror inc out=- | ssh $reg_ssh_user@$bastion2 -- tar -C $subdir - xvf -
make -s -C mirror tarrepo out=- | ssh $reg_ssh_user@$bastion2 -- tar -C $subdir -xvf -
scp mirror/save/mirror_seq2_000000.tar $reg_ssh_user@$bastion2:$subdir/aba/mirror/save

test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m  "Loading UBI images into mirror" "make -C $subdir/aba/mirror load" 

mylog 
mylog Add vote-app image to imageset conf file 
cat >> mirror/save/imageset-config-save.yaml <<END
  - name: quay.io/sjbylo/flask-vote-app:latest
END

test-cmd -r 99 3 -m "Saving vote-app image to local disk" " make -C mirror save" 

mylog Copy repo to internal bastion
##make -s -C mirror inc out=- | ssh $reg_ssh_user@$bastion2 -- tar -C $subdir - xvf -
make -s -C mirror tarrepo out=- | ssh $reg_ssh_user@$bastion2 -- tar -C $subdir -xvf -
scp mirror/save/mirror_seq3_000000.tar $reg_ssh_user@$bastion2:$subdir/aba/mirror/save

test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m  "Loading vote-app image into mirror" "make -C $subdir/aba/mirror load" 

cluster_type=sno  # Choose either sno, compact or standard

test-cmd -h $reg_ssh_user@$bastion2 -m  "Installing $cluster_type cluster, ready to deploy test app" "make -C $subdir/aba $cluster_type"

test-cmd -h $reg_ssh_user@$bastion2 -m  "Listing VMs (should show 24G memory)" "make -C $subdir/aba/$cluster_type ls"

#### DEL? test-cmd -h $reg_ssh_user@$bastion2 -m  "Deploying test vote-app" $subdir/aba/test/deploy-test-app.sh $subdir
test-cmd -h steve@$bastion2 -m "Create project 'demo'" "make -C $subdir/aba/$cluster_type cmd cmd='oc new-project demo'" || true
test-cmd -h steve@$bastion2 -m "Launch vote-app" "make -C $subdir/aba/$cluster_type cmd cmd='oc new-app --insecure-registry=true --image $reg_host:$reg_port/$reg_path/sjbylo/flask-vote-app --name vote-app -n demo'" || true
test-cmd -h steve@$bastion2 -m "Wait for vote-app rollout" "make -C $subdir/aba/$cluster_type cmd cmd='oc rollout status deployment vote-app -n demo'"

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
make -s -C mirror inc out=- | ssh $reg_ssh_user@$bastion2 -- tar -C $subdir -xvf -

test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m  "Loading images to mirror" "make -C $subdir/aba/mirror load" 

test-cmd -h $reg_ssh_user@$bastion2 -m  "Configuring day2 ops" "make -C $subdir/aba/$cluster_type day2"

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

	sed -i "s#quay\.io#$reg_host:$reg_port/$reg_path#g" */*.yaml */*/*.yaml */*/*/*.yaml &&  # required since other methods are messy
	sed -i "s/source: .*/source: cs-redhat-operator-index/g" operators/* 
) 

mylog Copy tar+ssh archives to internal bastion
rm -f test/mirror-registry.tar.gz  # No need to copy this over!
make -s -C mirror inc out=- | ssh $reg_ssh_user@$bastion2 -- tar -C $subdir -xvf - 
##mylog "Copy latest tar file $(ls -1tr mirror/save/mirror_seq*tar | tail -1)"   # THIS FAILS: DOES NOT COPY THE MESH FILES "openshift-service-mesh-demo"
##scp $(ls -1tr mirror/save/mirror_seq*tar | tail -1) $reg_ssh_user@$bastion2:$subdir/aba/mirror/save 

test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m  "Loading jaeger operator images to mirror" "make -C $subdir/aba/mirror load" 

test-cmd -m "Pausing for 60s to let OCP to settle" sleep 60    # For some reason, the cluster was still not fully ready in tests!

# Sometimes the cluster is not fully ready... OCP API can fail, so re-run 'make day2' ...
test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m "Run 'day2' attempt number $i ..." "make -C $subdir/aba/sno day2"  # Install CA cert and activate local op. hub

# Wait for https://docs.openshift.com/container-platform/4.11/openshift_images/image-configuration.html#images-configuration-cas_image-configuration 
test-cmd -m "Pausing for 30s to let OCP to settle" sleep 30  # And wait for https://access.redhat.com/solutions/5514331 to take effect 

test-cmd -h $reg_ssh_user@$bastion2 -m "Deploying service mesh with test app" "$subdir/aba/test/deploy-mesh.sh"

sleep 30  # Sleep in case need to check the cluster

##  KEEP SNO  # test-cmd -h $reg_ssh_user@$bastion2 -m  "Deleting sno cluster" "make -C $subdir/aba/sno delete" 

rm -rf test/mesh 

######################
### test-cmd -h $reg_ssh_user@$bastion2 -m  "Deleting cluster dirs, $subdir/aba/sno $subdir/aba/compact $subdir/aba/standard" "rm -rf  $subdir/aba/sno $subdir/aba/compact $subdir/aba/standard" 

## KEEP standard test-cmd -h $reg_ssh_user@$bastion2 -m  "Creating standard cluster" "make -C $subdir/aba standard" 
## KEEP standard test-cmd -h $reg_ssh_user@$bastion2 -m  "deleting standard cluster" "make -C $subdir/aba/standard delete" 

##test-cmd -h $reg_ssh_user@$bastion2 -m  "Creating compact cluster" "make -C $subdir/aba compact" 
##test-cmd -h $reg_ssh_user@$bastion2 -m  "deleting compact cluster" "make -C $subdir/aba/compact delete" 

## KEEP SNO test-cmd -h $reg_ssh_user@$bastion2 -m  "Creating sno cluster with 'make -C $subdir/aba cluster name=sno type=sno'" "make -C $subdir/aba cluster name=sno type=sno" 
## KEEP SNO test-cmd -h $reg_ssh_user@$bastion2 -m  "deleting sno cluster" "make -C $subdir/aba/sno delete" 
######################

### KEEP test-cmd -h $reg_ssh_user@$bastion2 -m  "Uninstalling mirror registry on internal bastion" "make -C $subdir/aba/mirror uninstall"

mylog
mylog "===> Completed test $0"
mylog

[ -f test/test.log ] && cp test/test.log test/test.log.bak

echo SUCCESS 
