#!/bin/bash -x
# This test installs a mirror reg. on the internal bastion (just for testing) and then
# treats that registry as an "existing registry" in the test internal workflow. 

export INFO_ABA=1

# Required: 2 bastions (internal and external), for internal (no direct Internet) only yum works via a proxy. For external, the proxy is fully configured. 
# I.e. Internal bastion has no access to the Internet.  External has full access. 
# Ensure passwordless ssh access from bastion1 (external) to int_bastion_hostname (internal). 
# Be sure no mirror registries are installed on either bastion before running.  Internal int_bastion_hostname can be a fresh "minimal install" of RHEL8/9.

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

[ ! "$TEST_USER" ] && TEST_USER=$(whoami)

# Try to fix "out of space" error when generating the op. index
cat /etc/redhat-release | grep -q ^Fedora && sudo mount -o remount,size=20G /tmp && rm -rf /tmp/render-registry-*

cd `dirname $0`
cd ..  # Change into "aba" dir

rm -fr ~/.containers ~/.docker

source scripts/include_all.sh no-trap  # Need for below normalize fn() calls
source test/include.sh
trap - ERR # We don't want this trap during testing.  Needed for below normalize fn() calls

[ ! "$target_full" ] && default_target="--step iso"   # Default is to generate 'iso' only   # Default is to only create iso
mylog default_target=$default_target

#ntp=10.0.1.8 # If available
ntp=10.0.1.8,ntp.example.com # If available

rm -f ~/.aba.previous.backup

######################
# Set up test 

which make || sudo dnf install make -y

./install 

test-cmd -m "Cleaning up - aba reset --force" 
####mv cli cli.m && mkdir cli && cp cli.m/Makefile cli && aba reset --force; rm -rf cli && mv cli.m cli
aba -d cli reset --force  # Ensure there are no old and potentially broken binaries
test-cmd -m "Show content of mirror/save" 'ls -l mirror mirror/save || true'
#test-cmd -m "Cleaning up mirror - clean" "aba -s -C mirror clean" 

rm -rf sno compact standard 

# Need this so this test script can be run standalone
[ ! "$VER_OVERRIDE" ] && #export VER_OVERRIDE=4.16.12 # Uncomment to use the 'latest' stable version of OCP
[ ! "$internal_bastion_rhel_ver" ] && export internal_bastion_rhel_ver=rhel9  # rhel8 or rhel9

int_bastion_hostname=registry.example.com
int_bastion_vm_name=bastion-internal-$internal_bastion_rhel_ver
export subdir=\~/subdir

mylog ============================================================
mylog Starting test $(basename $0)
mylog ============================================================
mylog "Test to install a local reg. on $int_bastion_hostname and save + copy + load images.  Install sno ocp and a test app and svc mesh."

rm -f aba.conf  # Set it up next
vf=~steve/.vmware.conf
[ ! "$VER_OVERRIDE" ] && VER_OVERRIDE=latest
test-cmd -m "Configure aba.conf for ocp_version '$VER_OVERRIDE'" aba --noask --platform vmw --channel stable --version $VER_OVERRIDE
mylog "ocp_version set to $(grep -o '^ocp_version=[^ ]*' aba.conf) in $PWD/aba.conf"
mylog "ask set to $(grep -o '^ask=[^ ]*' aba.conf) in $PWD/aba.conf"

# Set up govc 
cp $vf vmware.conf 
sed -i "s#^VC_FOLDER=.*#VC_FOLDER=/Datacenter/vm/abatesting#g" vmware.conf

# Do not ask to delete things
test-cmd -m "Setting ask=false" aba --noask

mylog "Setting ntp_servers=$ntp" 
[ "$ntp" ] && sed -i "s/^ntp_servers=\([^#]*\)#\(.*\)$/ntp_servers=$ntp    #\2/g" aba.conf

mylog "Setting op_sets=abatest in aba.conf"
sed -i "s/^op_sets=.*/op_sets=ocp,abatest /g" aba.conf
echo kiali-ossm > templates/operator-set-abatest 

# Needed for $ocp_version below
source <(normalize-aba-conf)
mylog "Checking value of: ocp_version=$ocp_version"

# Be sure this file exists
test-cmd -m "Init test: download mirror-registry-amd64.tar.gz" "aba --dir test mirror-registry-amd64.tar.gz"

#################################
# Copy and edit mirror.conf 

rpm -q --quiet python3 || rpm -q --quiet python36 || sudo dnf install python3 -y 
# Simulate creation and edit of mirror.conf file
scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf
# FIXME: Why not use 'aba mirror.conf'?

mylog "Test the internal bastion ($int_bastion_hostname) as mirror"

mylog "Setting reg_host=$int_bastion_hostname"
sed -i "s/registry.example.com/$int_bastion_hostname /g" ./mirror/mirror.conf

# This is also a test that overriding vakues works ok, e.g. this is an override in the mirror.connf gile, overriding from aba.conf file
test-cmd -m "Setting op_sets='abatest' in mirror/mirror.conf" "sed -i 's/^.*op_sets=.*/op_sets=abatest /g' ./mirror/mirror.conf"
echo kiali-ossm > templates/operator-set-abatest 

# Uncomment this line
# NOT NEEDED.  This is a local reg on host $int_bastion_hostname!
#### test-cmd -m "Setting for local mirror" "sed -i 's/.*reg_ssh_key=/reg_ssh_key=/g' ./mirror/mirror.conf"

# This is needed for below VM reset!
aba --dir cli ~/bin/govc

source <(normalize-vmware-conf)
##scripts/vmw-create-folder.sh /Datacenter/vm/test

init_bastion $int_bastion_hostname $int_bastion_vm_name aba-test $TEST_USER

#################################

source <(cd mirror && normalize-mirror-conf)

mylog "Using container mirror at $reg_host:$reg_port and using reg_ssh_user=$reg_ssh_user reg_ssh_key=$reg_ssh_key"

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Create test subdir: '$subdir'" "mkdir -p $subdir" 
test-cmd -r 15 3 -m "Creating bundle for channel stable and version $ocp_version" "aba -f bundle --platform vmw --channel stable --version $ocp_version --out - | ssh $reg_ssh_user@$int_bastion_hostname tar -C $subdir -xvf -"

# Smoke tests!
test-cmd -m  "Verifying existance of file 'mirror/save/mirror_*000000.tar'" "ls -lh mirror/save/mirror_*.tar" 
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Verifying existance of file '$subdir/aba/mirror/save/mirror_*.tar' on remote host" "ls -lh $subdir/aba/mirror/save/mirror_*.tar" 
test-cmd -m  "Delete this file that's already been copied to internal bastion: 'mirror/save/mirror_*.tar'" "rm -v mirror/save/mirror_*.tar" 

ssh $reg_ssh_user@$int_bastion_hostname "rpm -q make || sudo yum install make -y"

test-cmd -h $reg_ssh_user@$int_bastion_hostname -r 5 3 -m "Checking regcreds/ does not exist on $int_bastion_hostname" "test ! -d $subdir/aba/mirror/regcreds" 

######################
mylog Runtest: START - airgap

test-cmd -h $reg_ssh_user@$int_bastion_hostname -r 15 3 -m  "Install aba script" "cd $subdir/aba; ./install" 

test-cmd -h $reg_ssh_user@$int_bastion_hostname -r 15 3 -m  "Loading cluster images into mirror on internal bastion (this will install quay)" "aba -d $subdir/aba load" 

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Delete already loaded image set archive file to make space: '$subdir/aba/mirror/save/mirror_*.tar'" "rm -v $subdir/aba/mirror/save/mirror_*.tar" 

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Tidying up internal bastion" "rm -rf $subdir/aba/sno" 

mylog "Running 'aba sno' on internal bastion"

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Installing sno/iso" "aba --dir $subdir/aba sno --step iso" 
#test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Checking cluster operators" aba --dir $subdir/aba/sno cmd

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Increase node cpu to 24 for loading mesh test app" "sed -i 's/^master_cpu=.*/master_cpu=24/g' $subdir/aba/sno/cluster.conf"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Increase node memory to 24 for loading mesh test app" "sed -i 's/^master_mem=.*/master_mem=24/g' $subdir/aba/sno/cluster.conf"

######################
mylog Now adding more images to the mirror registry
######################

mylog Runtest: vote-app

[ "$oc_mirror_version" = "v1" ] && gvk=v1alpha2 || gvk=v2alpha1

# For oc-miror v2 (v2 needs to have only the images that are needed for this next save/load cycle)
[ -f mirror/save/imageset-config-save.yaml ] && cp -v mirror/save/imageset-config-save.yaml mirror/save/imageset-config-save.yaml.$(date "+%Y-%m-%d-%H:%M:%S")
if [ "$oc_mirror_version" = "v2" ]; then
tee mirror/save/imageset-config-save.yaml <<END
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/$gvk
mirror:
END
fi
# For oc-miror v2

mylog Add ubi9 image to imageset conf file 
tee -a mirror/save/imageset-config-save.yaml <<END
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi:latest
END

test-cmd -r 15 1 -m "Saving ubi images to local disk on `hostname`" "aba --dir mirror save" 

mylog Copy tar+ssh archives to internal bastion
## aba --dir mirror inc --out - | ssh $reg_ssh_user@$int_bastion_hostname -- tar -C $subdir - xvf -
aba --dir mirror tarrepo --out - | ssh $reg_ssh_user@$int_bastion_hostname -- tar -C $subdir -xvf -
#### FIXME: test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Ensure image set tar file does not exist yet" "test ! -f $subdir/aba/mirror/save/mirror_seq2_000000.tar"
test-cmd -m "Listing image set files that need to be copied also" "ls -lh mirror/save/mirror_*.tar"
test-cmd -m "Copy over image set archive 2 file" "scp mirror/save/mirror_*.tar $reg_ssh_user@$int_bastion_hostname:$subdir/aba/mirror/save"
test-cmd -m "Delete the image set tar file that was saved and copied" rm -v mirror/save/mirror_*.tar
test-cmd -m "Copy over image set conf file (needed for oc-mirror v2 load)" "scp mirror/save/imageset-config-save.yaml $reg_ssh_user@$int_bastion_hostname:$subdir/aba/mirror/save"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Ensure image set tar file exists" "ls -lh $subdir/aba/mirror/save/mirror_*.tar"

test-cmd -h $reg_ssh_user@$int_bastion_hostname -r 15 3 -m  "Loading UBI images into mirror" "cd $subdir; aba -d aba load" 

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Delete loaded image set archive file" rm -v $subdir/aba/mirror/save/mirror_*.tar

# For oc-miror v2 (v2 needs to have only the images that are needed for this next save/load cycle)
[ -f mirror/save/imageset-config-save.yaml ] && cp -v mirror/save/imageset-config-save.yaml mirror/save/imageset-config-save.yaml.$(date "+%Y-%m-%d-%H:%M:%S")
if [ "$oc_mirror_version" = "v2" ]; then
tee mirror/save/imageset-config-save.yaml <<END
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/$gvk
mirror:
END
fi
# For oc-miror v2

mylog Add vote-app image to imageset conf file 
tee -a mirror/save/imageset-config-save.yaml <<END
  additionalImages:
  - name: quay.io/sjbylo/flask-vote-app:latest
END

test-cmd -r 15 3 -m "Saving vote-app image to local disk" "aba --dir mirror save" 

mylog Copy repo only to internal bastion
aba --dir mirror tarrepo --out - | ssh $reg_ssh_user@$int_bastion_hostname -- tar -C $subdir -xvf -

test-cmd -m "Listing image set files that need to be copied also" "ls -lh mirror/save/mirror_*.tar"
test-cmd -m "Copy extra image set tar file to internal bastion" scp mirror/save/mirror_*.tar $reg_ssh_user@$int_bastion_hostname:$subdir/aba/mirror/save
test-cmd -m "Delete the image set tar file that was saved and copied" rm -v mirror/save/mirror_*.tar
test-cmd -m "Copy over image set conf file" "scp mirror/save/imageset-config-save.yaml $reg_ssh_user@$int_bastion_hostname:$subdir/aba/mirror/save"

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Ensure image set tar file exists" "test -f $subdir/aba/mirror/save/mirror_*.tar"

test-cmd -h $reg_ssh_user@$int_bastion_hostname -r 15 3 -m  "Loading vote-app image into mirror" "aba -d $subdir/aba/mirror load" 

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Delete loaded image set archive file" rm -v $subdir/aba/mirror/save/mirror_*.tar

cluster_type=sno  # Choose either sno, compact or standard

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Installing $cluster_type cluster, ready to deploy test app" "aba --dir $subdir/aba $cluster_type"

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Checking cluster operators" aba --dir $subdir/aba/$cluster_type cmd

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Listing VMs (should show 24G memory)" "aba --dir $subdir/aba/$cluster_type ls"

myLog "Deploying test vote-app"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Delete project 'demo'" "aba --dir $subdir/aba/$cluster_type --cmd 'oc delete project demo || true'" 
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Create project 'demo'" "aba --dir $subdir/aba/$cluster_type --cmd 'oc new-project demo'" 
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Launch vote-app" "aba --dir $subdir/aba/$cluster_type --cmd 'oc new-app --insecure-registry=true --image $reg_host:$reg_port/$reg_path/sjbylo/flask-vote-app --name vote-app -n demo'"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Wait for vote-app rollout" "aba --dir $subdir/aba/$cluster_type --cmd 'oc rollout status deployment vote-app -n demo'"

export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

mylog 
mylog "Append svc mesh and kiali operators to imageset conf using v$ocp_ver_major ($ocp_version)"

# For oc-miror v2 (v2 needs to have only the images that are needed for this next save/load cycle)
[ -f mirror/save/imageset-config-save.yaml ] && cp -v mirror/save/imageset-config-save.yaml mirror/save/imageset-config-save.yaml.$(date "+%Y-%m-%d-%H:%M:%S")
if [ "$oc_mirror_version" = "v2" ]; then
tee mirror/save/imageset-config-save.yaml <<END
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/$gvk
mirror:
END
fi
# For oc-miror v2

# FIXME: Get values from the correct file!
tee -a mirror/save/imageset-config-save.yaml <<END
  additionalImages:
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
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major
    packages:
END

test-cmd -m "Checking for file mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml" "test -s mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml"
test-cmd -m "Checking for servicemeshoperator in mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml" "cat mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | grep -A2 servicemeshoperator$"
test-cmd -m "Checking for kiali-ossm in mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml" "cat mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | grep -A2 kiali-ossm$"

# Append the correct values for each operator
mylog Append sm and kiali operators to imageset conf
grep -A2 -e "name: servicemeshoperator$"  mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | tee -a mirror/save/imageset-config-save.yaml
grep -A2 -e "name: kiali-ossm$"	          mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | tee -a mirror/save/imageset-config-save.yaml

########
test-cmd -r 15 3 -m "Saving mesh operators to local disk" "aba --dir mirror save"

mylog Create incremental tar and ssh to internal bastion
aba --dir mirror inc --out - | ssh $reg_ssh_user@$int_bastion_hostname -- tar -C $subdir -xvf -

test-cmd -m "Delete the image set tar file that was saved and copied" rm -v mirror/save/mirror_*.tar

test-cmd -h $reg_ssh_user@$int_bastion_hostname -r 15 3 -m  "Loading images to mirror" "cd $subdir/aba/mirror; aba load" 

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Delete loaded image set archive file" rm -v $subdir/aba/mirror/save/mirror_*.tar

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Configuring day2 ops" "aba --dir $subdir/aba/$cluster_type day2"

##mylog "Checking for jaeger-product in mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml"
test-cmd -m "Checking jaeger-product operator exists in the catalog file" "cat mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | grep jaeger-product$"

# For oc-miror v2 (v2 needs to have only the images that are needed for this next save/load cycle)
[ -f mirror/save/imageset-config-save.yaml ] && cp -v mirror/save/imageset-config-save.yaml mirror/save/imageset-config-save.yaml.$(date "+%Y-%m-%d-%H:%M:%S")
if [ "$oc_mirror_version" = "v2" ]; then
tee mirror/save/imageset-config-save.yaml <<END
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/$gvk
mirror:
END
fi
# For oc-miror v2

tee -a mirror/save/imageset-config-save.yaml <<END
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major
    packages:
END

mylog Append jaeger operator to imageset conf
grep -A2 -e "name: jaeger-product$"		mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | tee -a mirror/save/imageset-config-save.yaml

test-cmd -r 15 3 -m "Saving jaeger operator to local disk" "aba --dir mirror save"

mylog Downloading the mesh demo into test/mesh, for use by deploy script

(
	pwd && \
	rm -rf test/mesh && mkdir test/mesh && cd test/mesh && \
	git clone https://github.com/sjbylo/openshift-service-mesh-demo.git && \
	pwd && \
	cd openshift-service-mesh-demo && \
	pwd && \
	sed -i "s#quay\.io#$reg_host:$reg_port/$reg_path#g" */*.yaml */*/*.yaml */*/*/*.yaml && \
	sed -i "s/source: .*/source: redhat-operators/g" operators/* 
) 

mylog Copy tar+ssh archives to internal bastion
rm -f test/mirror-registry-amd64.tar.gz  # No need to copy this over!
test-cmd -r 2 2 -m "Running incremental tar copy to $reg_ssh_user@$int_bastion_hostname:$subdir" "aba --dir mirror inc --out - | ssh $reg_ssh_user@$int_bastion_hostname -- tar -C $subdir -xvf - "

test-cmd -m "Delete the image set tar file that was saved and copied" rm -v mirror/save/mirror_*.tar

test-cmd -h $reg_ssh_user@$int_bastion_hostname -r 15 3 -m  "Loading jaeger operator images to mirror" "cd $subdir/aba/mirror; aba load" 

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Delete loaded image set archive file" rm -v $subdir/aba/mirror/save/mirror_*.tar

#test-cmd -m "Pausing for 90s to let OCP settle" sleep 90    # For some reason, the cluster was still not fully ready in tests!

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Showing cluster operator status" aba --dir $subdir/aba/$cluster_type --cmd

test-cmd -h $TEST_USER@$int_bastion_hostname -r 5 3 -m "Log into the cluster" "source <(aba -d $subdir/aba/$cluster_type login)"

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Waiting max ~30 mins for all cluster operators to be *fully* available?" "i=0; until oc get co|tail -n +2|grep -v VSphereCSIDriverOperatorCRProgressing|awk '{print \$3,\$4,\$5}'|tail -n +2|grep -v '^True False False$'|wc -l|grep ^0$; do let i=\$i+1; [ \$i -gt 180 ] && exit 1; sleep 10; echo -n \"\$i \"; done"

# Sometimes the cluster is not fully ready... OCP API can fail, so re-run 'aba day2' ...
test-cmd -h $reg_ssh_user@$int_bastion_hostname -r 15 3 -m "Run 'day2'" "aba --dir $subdir/aba/sno day2"  # Install CA cert and activate local op. hub

# Wait for https://docs.openshift.com/container-platform/4.11/openshift_images/image-configuration.html#images-configuration-cas_image-configuration 
#test-cmd -m "Pausing for 60s to let OCP settle" sleep 60  # And wait for https://access.redhat.com/solutions/5514331 to take effect 

### MESH STOPPED test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Deploying service mesh with test app" "$subdir/aba/test/deploy-mesh.sh"

# Restart cluster test 
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Log into cluster" ". <(aba --dir $subdir/aba/sno login)"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check node status" "aba --dir $subdir/aba/sno ls"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Shut cluster down gracefully and wait for poweroff (2/2)" "yes | aba --dir $subdir/aba/sno shutdown --wait"

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Checking for all nodes 'poweredOff'" "until aba --dir $subdir/aba/sno ls | grep poweredOff | wc -l| grep ^1$ ; do sleep 10; echo -n .;done"

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Output node status" "aba --dir $subdir/aba/sno ls"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Start cluster gracefully" "aba --dir $subdir/aba/sno startup --wait"
###test-cmd -m "Wait for cluster to settle" sleep 30
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Waiting for all nodes to become 'Ready'" "cd $subdir/aba/sno; until oc get nodes| grep Ready|grep -v Not |wc -l| grep ^1$; do sleep 10; echo -n .; done"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster nodes" "aba --dir $subdir/aba/sno --cmd 'get nodes'"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster auth" "aba --dir $subdir/aba/sno --cmd 'whoami' | grep system:admin"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster version" "aba --dir $subdir/aba/sno --cmd 'version'"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster pending pods" "aba --dir $subdir/aba/sno --cmd 'get po -A | grep -v -e Running -e Complete'"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster COs" "aba --dir $subdir/aba/sno --cmd"
test-cmd -m "Wait for cluster to settle" sleep 30
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Waiting for all 'cluster operators' to become available?" "aba --dir $subdir/aba/sno --cmd; aba --dir $subdir/aba/sno --cmd | tail -n +2 |awk '{print \$3}' |tail -n +2 |grep ^False$ |wc -l |grep ^0$"
# Restart cluster test end 

##### MESH STOPPED test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster up and app running" "aba --dir $subdir/aba/sno --cmd 'get po -A | grep ^travel-.*Running'"

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Deleting sno cluster" "aba --dir $subdir/aba/sno delete" 
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Running 'aba clean' in $subdir/aba/sno" "aba --dir $subdir/aba/sno clean" 

rm -rf test/mesh 

######################
### test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Deleting cluster dirs, $subdir/aba/sno $subdir/aba/compact $subdir/aba/standard" "rm -rf  $subdir/aba/sno $subdir/aba/compact $subdir/aba/standard" 

###
build_and_test_cluster() {
	cluster_name=$1
	cnt=$2  # Number of nodes to check/validate in the cluster

	# Create cluster.conf
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Creating '$cluster_name' cluster.conf" "cd $subdir/aba; aba cluster --name $cluster_name --type $cluster_name --step cluster.conf || true" # || true

	# Add more cpu/ram ... See if this will speed things up!
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Adding master CPU" "sed -i 's/^master_cpu_count=.*/master_cpu_count=12/g' $subdir/aba/$cluster_name/cluster.conf"
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Adding worker CPU" "sed -i 's/^worker_cpu_count=.*/worker_cpu_count=8/g' $subdir/aba/$cluster_name/cluster.conf"
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Adding master RAM" "sed -i 's/^master_mem=.*/master_mem=24/g' $subdir/aba/$cluster_name/cluster.conf"
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Adding worker RAM" "sed -i 's/^worker_mem=.*/worker_mem=16/g' $subdir/aba/$cluster_name/cluster.conf"

	# This will run make in $subdir/aba/$cluster_name
	if ! test-cmd -i -h $reg_ssh_user@$int_bastion_hostname -m  "Creating '$cluster_name' cluster" "aba --dir $subdir/aba/$cluster_name"; then
		test-cmd -i -h $reg_ssh_user@$int_bastion_hostname -m  "Showing cluster nodes" "cd $subdir/aba/$cluster_name && . <(aba shell) && oc get nodes && aba ls"
		test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Restarting all worker nodes of failed cluster" "aba --dir $subdir/aba/$cluster_name stop --wait --workers start"
	fi

	if ! test-cmd -i -h $reg_ssh_user@$int_bastion_hostname -r 2 1 -m  "Checking '$cluster_name' cluster with 'mon'" "aba --dir $subdir/aba/$cluster_name mon"; then
		mylog "CLUSTER INSTALL FAILED: REBOOTING ALL NODES ..."

		set -x

		# See if the agent is still running and fetch the logs
		aba --dir $subdir/aba/$cluster_name ssh --cmd "agent-gather -O" | ssh 10.0.1.6 -- "cat > agent-gather-$cluster_name-.tar.xz || true" # || true
		scp $subdir/aba/$cluster_name/iso-agent-based/.openshift_install.log 10.0.1.6:${cluster_name}_openshift_install.log

		aba --dir $subdir/aba/$cluster_name stop --wait
		aba --dir $subdir/aba/$cluster_name start
		sleep 60
		aba --dir $subdir/aba/$cluster_name mon

		set +x
	fi

	#####
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Showing cluster operator status" aba --dir $subdir/aba/$cluster_name --cmd

	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Log into cluster" ". <(aba --dir $subdir/aba/$cluster_name login)"

	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Waiting forever for all cluster operators available?" "aba --dir $subdir/aba/$cluster_name --cmd; until aba --dir $subdir/aba/$cluster_name --cmd | tail -n +2 |awk '{print \$3}' |tail -n +2 |grep ^False$ |wc -l |grep ^0$; do sleep 10; echo -n .; done"

	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Waiting max ~30 mins for all cluster operators to become *fully* available (completeed/non-degraded)?" "i=0; until aba --dir $subdir/aba/$cluster_name --cmd | tail -n +2 |grep -v VSphereCSIDriverOperatorCRProgressing|awk '{print \$3,\$4,\$5}' |tail -n +2 |grep -v '^True False False$'|wc -l |grep ^0$; do let i=\$i+1; [ \$i -gt 180 ] && exit 1; sleep 10; echo -n \"\$i \"; done"

	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Show all cluster operators" "aba --dir $subdir/aba/$cluster_name --cmd"

	# Restart cluster test 
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check node status" "aba --dir $subdir/aba/$cluster_name ls"
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Shut cluster down gracefully and wait for powerdown" "yes | aba --dir $subdir/aba/$cluster_name shutdown --wait"

	####test-cmd -m "Wait for cluster to power down" sleep 30
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Checking for all nodes 'poweredOff'" "until aba --dir $subdir/aba/$cluster_name ls |grep poweredOff |wc -l| grep ^$cnt$; do sleep 10; done"

	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check node status" "aba --dir $subdir/aba/$cluster_name ls"
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Start cluster gracefully" "aba --dir $subdir/aba/$cluster_name startup"
	####test-cmd -m "Wait for cluster to settle" sleep 30
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Checking for all nodes 'Ready'" "until aba --dir $subdir/aba/$cluster_name --cmd 'oc get nodes'| grep Ready|grep -v Not|wc -l| grep ^$cnt$; do sleep 10; done"
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster nodes" "aba --dir $subdir/aba/$cluster_name --cmd 'get nodes'"
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster auth" "aba --dir $subdir/aba/$cluster_name --cmd 'whoami'"
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster version" "aba --dir $subdir/aba/$cluster_name --cmd 'version'"
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster pending pods" "aba --dir $subdir/aba/$cluster_name --cmd 'get po -A | grep -v -e Running -e Complete'"
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster operators" "aba --dir $subdir/aba/$cluster_name --cmd"
	test-cmd -m "Wait for cluster to settle" sleep 60
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Waiting forever for all co available?" "aba --dir $subdir/aba/$cluster_name --cmd; until aba --dir $subdir/aba/$cluster_name --cmd | tail -n +2 |awk '{print \$3}' |tail -n +2 |grep ^False$ |wc -l |grep ^0$; do sleep 10; echo -n .; done"

	# Deploy test app
	test-cmd -h $TEST_USER@$int_bastion_hostname -m "Delete project 'demo'" "aba --dir $subdir/aba/$cluster_name --cmd 'oc delete project demo || true'" 
	test-cmd -h $TEST_USER@$int_bastion_hostname -m "Create project 'demo'" "aba --dir $subdir/aba/$cluster_name --cmd 'oc new-project demo' || true" # || true
	test-cmd -h $TEST_USER@$int_bastion_hostname -m "Launch vote-app" "aba --dir $subdir/aba/$cluster_name --cmd 'oc new-app --insecure-registry=true --image $reg_host:$reg_port/$reg_path/sjbylo/flask-vote-app --name vote-app -n demo'"
	test-cmd -h $TEST_USER@$int_bastion_hostname -m "Wait for vote-app rollout" "aba --dir $subdir/aba/$cluster_name --cmd 'oc rollout status deployment vote-app -n demo'"
}

#for c in sno compact standard
for c in standard
do
	mylog "Building cluster $c"
	[ "$c" = "sno" ] && cnt=1
	[ "$c" = "compact" ] && cnt=3
	[ "$c" = "standard" ] && cnt=6
	build_and_test_cluster $c $cnt

	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Deleting '$c' cluster" "aba --dir $subdir/aba/$c delete" 
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Running 'aba clean' in $subdir/aba/$c" "aba --dir $subdir/aba/$c clean" 
done

cluster_name=standard

# Test bare-metal with BYO macs
##test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Creating $cluster_name cluster dir" "cd $subdir/aba; rm -rf $cluster_name; mkdir -p $cluster_name; ln -s ../templates/Makefile $cluster_name; aba --dir $cluster_name init" 
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Creating cluster.conf" "aba -d $subdir/aba cluster --name $cluster_name --type $cluster_name --step cluster.conf"
mylog "Generating macs.conf file at $reg_ssh_user@$int_bastion_hostname:$subdir/aba/$cluster_name/macs.conf"
echo -n "\
00:50:56:20:xx:01
00:50:56:20:xx:02
00:50:56:20:xx:03
00:50:56:20:xx:04
00:50:56:20:xx:05
00:50:56:20:xx:06
" | sed -E "s/xx/$(printf '%02x' $((RANDOM%256)))/" | ssh $reg_ssh_user@$int_bastion_hostname -- "cat > $subdir/aba/$cluster_name/macs.conf"
##scp macs.conf $reg_ssh_user@$int_bastion_hostname:$subdir/aba/$cluster_name

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Adding master CPU" "sed -i 's/^master_cpu_count=.*/master_cpu_count=12/g' $subdir/aba/$cluster_name/cluster.conf"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Adding worker CPU" "sed -i 's/^worker_cpu_count=.*/worker_cpu_count=8/g' $subdir/aba/$cluster_name/cluster.conf"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Adding master RAM" "sed -i 's/^master_mem=.*/master_mem=24/g' $subdir/aba/$cluster_name/cluster.conf"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Adding worker RAM" "sed -i 's/^worker_mem=.*/worker_mem=16/g' $subdir/aba/$cluster_name/cluster.conf"

# Added agntconf here so the cluster is NOT created.  It's created below!  This failed since running aba with an already installed cluster shows error!
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Setting cluster config: machine_network 10.0.0.0/20 and starting_ip=10.0.3.254" "aba -d $subdir/aba/$cluster_name -M 10.0.0.0/20 agentconf"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Setting machine_network" "sed -i 's#^machine_network=[^ \t]*#machine_network=10.0.0.0/20 #g' $subdir/aba/$cluster_name/cluster.conf"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Setting starting_ip" "sed -i 's/^starting_ip=[^ \t]*/starting_ip=10.0.2.253 /g' $subdir/aba/$cluster_name/cluster.conf"

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Making iso" "aba --dir $subdir/aba/$cluster_name iso"

# -i means ignore any error and let this script handle the error. I.e. restart workers.
test-cmd -i -h $reg_ssh_user@$int_bastion_hostname -m  "Creating $cluster_name cluster" "aba --dir $subdir/aba/$cluster_name" || \
(
	test-cmd -i -h $reg_ssh_user@$int_bastion_hostname -m "Showing cluster nodes" "cd $subdir/aba/$cluster_name && . <(aba shell) && oc get nodes && aba ls"
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Cluster creation failed? Restarting all worker nodes" "aba --dir $subdir/aba/$cluster_name stop --wait --workers start"
	test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "Wait for cluster install to complete ..." "aba --dir $subdir/aba/$cluster_name"
)

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Log into cluster" ". <(aba --dir $subdir/aba/$cluster_name login)"

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Waiting ~30mins for all cluster operators to become available?" "aba --dir $subdir/aba/$cluster_name --cmd; i=0; until aba --dir $subdir/aba/$cluster_name --cmd | tail -n +2 |awk '{print \$3}' |tail -n +2 |grep ^False$ |wc -l |grep ^0$; do let i=\$i+1; [ \$i -gt 180 ] && exit 1; echo -n .; sleep 10; done"

# Restart cluster test 
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Log into cluster" ". <(aba --dir $subdir/aba/$cluster_name login)"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check node status" "aba --dir $subdir/aba/$cluster_name ls"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Shut cluster down gracefully and wait for powerdown" "yes | aba --dir $subdir/aba/$cluster_name shutdown --wait"

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Checking for all nodes 'poweredOff'" "until aba --dir $subdir/aba/$cluster_name ls |grep poweredOff |wc -l| grep ^6$; do sleep 10; echo -n .; done"

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check node status" "aba --dir $subdir/aba/$cluster_name ls"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Start cluster gracefully" "aba --dir $subdir/aba/$cluster_name startup --wait"
test-cmd -m "Wait for cluster to settle" sleep 10
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Checking for all nodes 'Ready'" "cd $subdir/aba/$cluster_name; until oc get nodes| grep Ready|grep -v Not|wc -l| grep ^6$; do sleep 10; echo -n .; done"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster nodes" "aba --dir $subdir/aba/$cluster_name --cmd 'get nodes'"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster auth" "aba --dir $subdir/aba/$cluster_name --cmd 'whoami'"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster version" "aba --dir $subdir/aba/$cluster_name --cmd 'version'"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster pending pods" "aba --dir $subdir/aba/$cluster_name --cmd 'get po -A | grep -v -e Running -e Complete'"
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Check cluster operators" "aba --dir $subdir/aba/$cluster_name --cmd"
test-cmd -m "Wait for cluster to settle" sleep 10
test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Waiting for all co available?" "aba --dir $subdir/aba/$cluster_name --cmd; aba --dir $subdir/aba/$cluster_name --cmd | tail -n +2 |awk '{print \$3}' |tail -n +2 |grep ^False$ |wc -l |grep ^0$"
# Restart cluster test end 

# keep it # test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Deleting $cluster_name cluster" "aba --dir $subdir/aba/$cluster_name delete" 
###test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Stopping $cluster_name cluster and wait" "yes|aba --dir $subdir/aba/$cluster_name shutdown --wait" 

test-cmd -h $reg_ssh_user@$int_bastion_hostname -m "If cluster up, shutting cluster down and wait" ". <(aba --dir $subdir/aba/$cluster_name shell) && . <(aba --dir $subdir/aba/$cluster_name login) && yes|aba --dir $subdir/aba/$cluster_name shutdown --wait || echo cluster shutdown failure"

# keep it # test-cmd -h $reg_ssh_user@$int_bastion_hostname -m  "Running 'aba clean' in $subdir/aba/stanadard" "aba --dir $subdir/aba/$cluster_name clean" 

#test-cmd "aba reset --force"
# keep it # aba --dir ~/aba reset --force
# keep it # mv cli cli.m && mkdir cli && cp cli.m/Makefile cli && aba reset --force; rm -rf cli && mv cli.m cli

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Delete the registry" "aba --dir $subdir/aba/mirror uninstall"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Verify mirror uninstalled" "podman ps | tee /dev/tty | grep -v -e quay -e CONTAINER | wc -l | grep ^0$"

mylog "===> Completed test $0"

[ -f test/test.log ] && cp test/test.log test/test.log.bak

echo SUCCESS $0
