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

# Try to fix "out of space" error when generating the op. index
cat /etc/redhat-release | grep -q ^Fedora && sudo mount -o remount,size=20G /tmp && rm -rf /tmp/render-registry-*

cd `dirname $0`
cd ..  # Change into "aba" dir

rm -fr ~/.containers ~/.docker

source scripts/include_all.sh && trap - ERR
source test/include.sh

[ ! "$target_full" ] && default_target="target=iso"   # Default is to generate 'iso' only   # Default is to only create iso
mylog default_target=$default_target

ntp=10.0.1.8 # If available

rm -f ~/.aba.previous.backup

######################
# Set up test 

which make || sudo dnf install make -y

#v=4.16.5

###> mirror/mirror.conf
##echo "ocp_version=4.16.999" >> aba.conf  # Only to fix error, missing "ocp_version"
test-cmd -m "Cleaning up - make distclean force=1" 
mv cli cli.m && mkdir cli && cp cli.m/Makefile cli && make distclean force=1; rm -rf cli && mv cli.m cli
#test-cmd -m "Cleaning up mirror - clean" "make -s -C mirror clean" 

rm -rf sno compact standard 

bastion2=registry.example.com
bastion_vm=bastion-internal-rhel9
subdir=~
subdir=~/subdir

mylog ============================================================
mylog Starting test $(basename $0)
mylog ============================================================
mylog "Test to install a local reg. on $bastion2 and save + copy + load images.  Install sno ocp and a test app and svc mesh."
mylog

rm -f aba.conf  # Set it up next
vf=~/.vmware.conf
[ ! "$VER_OVERRIDE" ] && VER_OVERRIDE=latest
test-cmd -m "Configure aba.conf for version '$VER_OVERRIDE' and vmware $vf" ./aba --version $VER_OVERRIDE ### --vmw $vf
#test-cmd -m "Configure aba.conf for latest version and vmware $vf" ./aba --version latest ## --vmw $vf
# Set up govc 
cp $vf vmware.conf 
sed -i "s#^VC_FOLDER=.*#VC_FOLDER=/Datacenter/vm/abatesting#g" vmware.conf

# Do not ask to delete things
mylog "Setting ask="
make noask
#sed -i 's/^ask=[^ \t]\{1,\}\([ \t]\{1,\}\)/ask=\1 /g' aba.conf

mylog "Setting ntp_server=$ntp" 
[ "$ntp" ] && sed -i "s/^ntp_server=\([^#]*\)#\(.*\)$/ntp_server=$ntp    #\2/g" aba.conf

mylog "Setting op_sets=\"abatest\" in aba.conf"
sed -i "s/^op_sets=.*/op_sets=\"abatest\" /g" aba.conf
echo kiali-ossm > templates/operator-set-abatest 

source <(normalize-aba-conf)

# Be sure this file exists
test-cmd -m "Init test: download mirror-registry.tar.gz" "make -s -C test mirror-registry.tar.gz"

#################################
# Copy and edit mirror.conf 

##sudo dnf install python36 python3-jinja2 -y
rpm -q --quiet python3 || rpm -q --quiet python36 || sudo dnf install python3 -y 

# Simulate creation and edit of mirror.conf file
scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf

mylog "Test the internal bastion ($bastion2) as mirror"

mylog "Setting reg_host=$bastion2"
sed -i "s/registry.example.com/$bastion2 /g" ./mirror/mirror.conf
#sed -i "s#reg_ssh_key=#reg_ssh_key=~/.ssh/id_rsa #g" ./mirror/mirror.conf

mylog "Setting op_sets=\"abatest\" in mirror/mirror.conf"
sed -i "s/^.*op_sets=.*/op_sets=\"abatest\" /g" ./mirror/mirror.conf
echo kiali-ossm > templates/operator-set-abatest 

# FIXME: Why is this needed? 
make -C cli ~/bin/govc

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

cat <<END | ssh steve@$bastion2 -- sudo bash
set -ex
timedatectl
chronyc sources -v
chronyc add server 10.0.1.8 iburst
timedatectl set-timezone Asia/Singapore
chronyc -a makestep
sleep 3
timedatectl
chronyc sources -v
END

# Delete images
test-cmd -h steve@$bastion2 -m "Verify mirror uninstalled" podman ps 
test-cmd -h steve@$bastion2 -m "Deleting all podman images" "podman system prune --all --force && podman rmi --all && sudo rm -rf ~/.local/share/containers/storage && rm -rf ~/test"
# This file is not needed in a fully air-gapped env. 
ssh steve@$bastion2 -- "rm -fv ~/.pull-secret.json"
# Want to test fully disconnected 
ssh steve@$bastion2 -- "sed -i 's|^source ~/.proxy-set.sh|# aba test # source ~/.proxy-set.sh|g' ~/.bashrc"
# Ensure home is empty!  Avoid errors where e.g. hidden files cause reg. install failing. 
ssh steve@$bastion2 -- "rm -rfv ~/*"
# Just be sure a valid govc config file exists
scp $vf steve@$bastion2: 

#################################

source <(cd mirror && normalize-mirror-conf)
#### [ ! "$reg_ssh_user" ] && reg_ssh_user=$(whoami)

mylog "Using container mirror at $reg_host:$reg_port and using reg_ssh_user=$reg_ssh_user reg_ssh_key=$reg_ssh_key"

#### NEW TEST test-cmd -r 99 3 -m "Saving images to local disk" "make save" 
test-cmd -h $reg_ssh_user@$bastion2 -m  "Create test subdir: '$subdir'" "mkdir -p $subdir" 
test-cmd -r 99 3 -m "Creating bundle for channel stable" "./aba bundle --channel stable --version 4.16.12 --out - | ssh $reg_ssh_user@$bastion2 tar -C $subdir -xvf -"

# Existing regcreds/pull-secret files issue.  E.g. if aba has been used already to install a reg. .. then 'make save' is run!
# Set up bad creds and be sure they do not get copied to internal bastion!
#if [ ! -d mirror/regcreds ]; then
#	echo "No mirror/regcreds dir found, as expected!  Creating invalid regcreds dir!"
#else
#	echo "Warning: mirror/regcreds dir should not exist!"
#	ls -al mirror/regcreds
#	cat mirror/regcreds/*
#	rm -rf mirror/regcreds
#fi
#cp -rf test/mirror/regcreds mirror
#tar xf test/regcreds-invalid.tar

# Smoke test!
##[ ! -s mirror/save/mirror_seq1_000000.tar ] && echo "Aborting test as there is no save/mirror_seq1_000000.tar file" && exit 1
test-cmd -m  "Verifying existance of file 'mirror/save/mirror_seq1_000000.tar'" "ls -lh mirror/save/mirror_seq1_000000.tar" 

# If the VM snapshot is reverted, as above, no need to delete old files
####test-cmd -h $reg_ssh_user@$bastion2 -m  "Clean up home dir on internal bastion" "rm -rf ~/bin/* $subdir/aba"

ssh $reg_ssh_user@$bastion2 "rpm -q make || sudo yum install make -y"

#### NEW TEST test-cmd -h $reg_ssh_user@$bastion2 -m  "Create test subdir: '$subdir'" "mkdir -p $subdir" 

#### NEW TEST mylog "Use 'make tarrepo' to copy tar+ssh archive plus seq1 tar file to internal bastion"
#### NEW TEST ###make -s -C mirror inc out=- | ssh $reg_ssh_user@$bastion2 -- tar -C $subdir - xvf -
#### NEW TEST make -s -C mirror tarrepo out=- | ssh $reg_ssh_user@$bastion2 -- tar -C $subdir -xvf -
#### NEW TEST scp mirror/save/mirror_seq1_000000.tar $reg_ssh_user@$bastion2:$subdir/aba/mirror/save

### test-cmd -h $reg_ssh_user@$bastion2 -r 5 3 -m "Checking regcreds/ does not exist on $bastion2" "test ! -d $subdir/aba/mirror/regcreds | exit 1" 

### echo "Install the reg creds, simulating a manual config" 
### ssh $reg_ssh_user@$bastion2 -- "cp -v ~/quay-install/quay-rootCA/rootCA.pem $subdir/aba/mirror/regcreds/"  
### ssh $reg_ssh_user@$bastion2 -- "cp -v ~/.containers/auth.json $subdir/aba/mirror/regcreds/pull-secret-mirror.json"

######################
mylog Runtest: START - airgap

test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m  "Loading cluster images into mirror on internal bastion" "make -s -C $subdir/aba load" 

test-cmd -h $reg_ssh_user@$bastion2 -m  "Tidying up internal bastion" "rm -rf $subdir/aba/sno" 

mylog "Running 'make sno' on internal bastion"

[ "$default_target" ] && mylog "Creating the cluster with target=$default_target only"
#test-cmd -h $reg_ssh_user@$bastion2 -m  "Installing sno/iso with 'make -s -C $subdir/aba sno $default_target'" "make -s -C $subdir/aba sno $default_target" 
test-cmd -h $reg_ssh_user@$bastion2 -m  "Installing sno/iso" "make -s -C $subdir/aba sno $default_target" 

test-cmd -h $reg_ssh_user@$bastion2 -m  "Increase node cpu to 24 for loading mesh test app" "sed -i 's/^master_cpu=.*/master_cpu=24/g' $subdir/aba/sno/cluster.conf"
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

echo = TEST =
echo ~/.docker/*
cat ~/.docker/*
echo ~/.containers/*
cat ~/.containers/*
echo = TEST =

test-cmd -r 99 3 -m "Saving ubi images to local disk on `hostname`" "make -s -C mirror save" 

mylog Copy tar+ssh archives to internal bastion
## make -s -C mirror inc out=- | ssh $reg_ssh_user@$bastion2 -- tar -C $subdir - xvf -
make -s -C mirror tarrepo out=- | ssh $reg_ssh_user@$bastion2 -- tar -C $subdir -xvf -
scp mirror/save/mirror_seq2_000000.tar $reg_ssh_user@$bastion2:$subdir/aba/mirror/save

test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m  "Loading UBI images into mirror" "make -s -C $subdir/aba/mirror load" 

mylog 
mylog Add vote-app image to imageset conf file 
cat >> mirror/save/imageset-config-save.yaml <<END
  - name: quay.io/sjbylo/flask-vote-app:latest
END

test-cmd -r 99 3 -m "Saving vote-app image to local disk" " make -s -C mirror save" 

mylog Copy repo to internal bastion
##make -s -C mirror inc out=- | ssh $reg_ssh_user@$bastion2 -- tar -C $subdir - xvf -
make -s -C mirror tarrepo out=- | ssh $reg_ssh_user@$bastion2 -- tar -C $subdir -xvf -
scp mirror/save/mirror_seq3_000000.tar $reg_ssh_user@$bastion2:$subdir/aba/mirror/save

test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m  "Loading vote-app image into mirror" "make -s -C $subdir/aba/mirror load" 

cluster_type=sno  # Choose either sno, compact or standard

test-cmd -h $reg_ssh_user@$bastion2 -m  "Installing $cluster_type cluster, ready to deploy test app" "make -s -C $subdir/aba $cluster_type"

test-cmd -h $reg_ssh_user@$bastion2 -m  "Listing VMs (should show 24G memory)" "make -s -C $subdir/aba/$cluster_type ls"

#### DEL? test-cmd -h $reg_ssh_user@$bastion2 -m  "Deploying test vote-app" $subdir/aba/test/deploy-test-app.sh $subdir
test-cmd -h steve@$bastion2 -m "Create project 'demo'" "make -s -C $subdir/aba/$cluster_type cmd cmd='oc new-project demo'" || true
test-cmd -h steve@$bastion2 -m "Launch vote-app" "make -s -C $subdir/aba/$cluster_type cmd cmd='oc new-app --insecure-registry=true --image $reg_host:$reg_port/$reg_path/sjbylo/flask-vote-app --name vote-app -n demo'" || true
test-cmd -h steve@$bastion2 -m "Wait for vote-app rollout" "make -s -C $subdir/aba/$cluster_type cmd cmd='oc rollout status deployment vote-app -n demo'"

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
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.16
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
test-cmd -r 99 3 -m "Saving mesh operators to local disk" "make -s -C mirror save"

mylog Copy tar+ssh archives to internal bastion
make -s -C mirror inc out=- | ssh $reg_ssh_user@$bastion2 -- tar -C $subdir -xvf -

test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m  "Loading images to mirror" "make -s -C $subdir/aba/mirror load" 

test-cmd -h $reg_ssh_user@$bastion2 -m  "Configuring day2 ops" "make -s -C $subdir/aba/$cluster_type day2"

mylog 
mylog Append jaeger operator to imageset conf

cat >> mirror/save/imageset-config-save.yaml <<END
      - name: jaeger-product
        channels:
        - name: stable
END

test-cmd -r 99 3 -m "Saving jaeger operator to local disk" "make -s -C mirror save"

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

test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m  "Loading jaeger operator images to mirror" "make -s -C $subdir/aba/mirror load" 


test-cmd -m "Pausing for 90s to let OCP settle" sleep 90    # For some reason, the cluster was still not fully ready in tests!

test-cmd -h $reg_ssh_user@$bastion2 -m  "Waiting for all co available?" "make -s -C $subdir/aba/$cluster_type cmd; until make -s -C $subdir/aba/$cluster_type cmd | tail -n +2 |awk '{print \$3,\$4,\$5}' |tail -n +2 |grep -v '^True False False$' |wc -l |grep ^0$; do sleep 10; echo -n .; done"

# Sometimes the cluster is not fully ready... OCP API can fail, so re-run 'make day2' ...
test-cmd -h $reg_ssh_user@$bastion2 -r 99 3 -m "Run 'day2'" "make -s -C $subdir/aba/sno day2"  # Install CA cert and activate local op. hub

# Wait for https://docs.openshift.com/container-platform/4.11/openshift_images/image-configuration.html#images-configuration-cas_image-configuration 
test-cmd -m "Pausing for 60s to let OCP settle" sleep 60  # And wait for https://access.redhat.com/solutions/5514331 to take effect 

test-cmd -h $reg_ssh_user@$bastion2 -m "Deploying service mesh with test app" "$subdir/aba/test/deploy-mesh.sh"

sleep 30  # Sleep in case need to check the cluster

# Restart cluster test 
test-cmd -h $reg_ssh_user@$bastion2 -m  "Log into cluster" ". <(make -s -C $subdir/aba/sno login)"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Check node status" "make -s -C $subdir/aba/sno ls"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Shut cluster down gracefully (2/2)" "yes | make -s -C $subdir/aba/sno shutdown"
#test-cmd -m "Wait for cluster to power down" sleep 600
test-cmd -m "Wait for cluster to power down" sleep 60
test-cmd -h $reg_ssh_user@$bastion2 -m  "Checking for all nodes 'poweredOff'" "until make -s -C $subdir/aba/sno ls | grep poweredOff | wc -l| grep ^1$ ; do sleep 10; echo -n .;done"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Check node status" "make -s -C $subdir/aba/sno ls"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Start cluster gracefully" "make -s -C $subdir/aba/sno startup"
#test-cmd -m "Wait for cluster to settle" sleep 600
test-cmd -m "Wait for cluster to settle" sleep 60
test-cmd -h $reg_ssh_user@$bastion2 -m  "Checking for all nodes 'Ready'" "cd $subdir/aba/sno; until oc get nodes| grep Ready|grep -v Not |wc -l| grep ^1$; do sleep 10; echo -n .; done"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/sno cmd cmd='get nodes'"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/sno cmd cmd='whoami' | grep system:admin"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/sno cmd cmd='version'"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/sno cmd cmd='get po -A | grep -v -e Running -e Complete'"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/sno cmd"
test-cmd -m "Wait for cluster to settle" sleep 60
test-cmd -h $reg_ssh_user@$bastion2 -m  "Waiting for all co available?" "make -s -C $subdir/aba/sno cmd; make -s -C $subdir/aba/sno cmd | tail -n +2 |awk '{print \$3}' |tail -n +2 |grep ^False$ |wc -l |grep ^0$"
# Restart cluster test end 

test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/sno cmd cmd='get po -A | grep ^travel-.*Running'"

test-cmd -h $reg_ssh_user@$bastion2 -m  "Deleting sno cluster" "make -s -C $subdir/aba/sno delete" 
test-cmd -h $reg_ssh_user@$bastion2 -m  "Running 'make clean' in $subdir/aba/sno" "make -s -C $subdir/aba/sno clean" 

rm -rf test/mesh 

######################
### test-cmd -h $reg_ssh_user@$bastion2 -m  "Deleting cluster dirs, $subdir/aba/sno $subdir/aba/compact $subdir/aba/standard" "rm -rf  $subdir/aba/sno $subdir/aba/compact $subdir/aba/standard" 

###
build_and_test_cluster() {
	cluster_name=$1
	cnt=$2  # Number of nodes to check/validate in the cluster

	# Create cluster.conf
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Creating '$cluster_name' cluster.conf" "make -s -C $subdir/aba cluster name=$cluster_name type=$cluster_name target=cluster.conf" || true

	# Add more cpu/ram ... See if this will speed things up!
	test-cmd -h $reg_ssh_user@$bastion2 -m "Adding master CPU" "sed -i 's/^master_cpu_count=.*/master_cpu_count=12/g' $subdir/aba/$cluster_name/cluster.conf"
	test-cmd -h $reg_ssh_user@$bastion2 -m "Adding worker CPU" "sed -i 's/^worker_cpu_count=.*/worker_cpu_count=8/g' $subdir/aba/$cluster_name/cluster.conf"
	test-cmd -h $reg_ssh_user@$bastion2 -m "Adding master RAM" "sed -i 's/^master_mem=.*/master_mem=24/g' $subdir/aba/$cluster_name/cluster.conf"
	test-cmd -h $reg_ssh_user@$bastion2 -m "Adding worker RAM" "sed -i 's/^worker_mem=.*/worker_mem=16/g' $subdir/aba/$cluster_name/cluster.conf"

	###test-cmd -h $reg_ssh_user@$bastion2 -m  "Creating '$cluster_name' cluster" "make -s -C $subdir/aba $cluster_name" || true
	# Now run make INSIDE of the cluster directory
	####test-cmd -h $reg_ssh_user@$bastion2 -m  "Creating '$cluster_name' cluster" "make -s -C $subdir/aba/$cluster_name" || true
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Creating '$cluster_name' cluster" "make -s -C $subdir/aba/$cluster_name"
	test-cmd -h $reg_ssh_user@$bastion2 -r 8 3 -m  "Checking '$cluster_name' cluster with 'mon'" "make -s -C $subdir/aba/$cluster_name mon" 

	#####
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Waiting for all cluster operators available?" "make -s -C $subdir/aba/$cluster_name cmd; until make -s -C $subdir/aba/$cluster_name cmd | tail -n +2 |awk '{print \$3}' |tail -n +2 |grep ^False$ |wc -l |grep ^0$; do sleep 10; echo -n .; done"

	test-cmd -h $reg_ssh_user@$bastion2 -m  "Waiting for all cluster operators fully available?" "make -s -C $subdir/aba/$cluster_name cmd; until make -s -C $subdir/aba/$cluster_name cmd | tail -n +2 |awk '{print \$3,\$4,\$5}' |tail -n +2 |grep -v '^True False False$' |wc -l |grep ^0$; do sleep 10; echo -n .; done"

	test-cmd -h $reg_ssh_user@$bastion2 -m  "Show all cluster operators" "make -s -C $subdir/aba/$cluster_name cmd"

	# Restart cluster test 
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Log into cluster" ". <(make -s -C $subdir/aba/$cluster_name login)"
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Check node status" "make -s -C $subdir/aba/$cluster_name ls"
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Shut cluster down gracefully" "yes | make -s -C $subdir/aba/$cluster_name shutdown"
	test-cmd -m "Wait for cluster to power down" sleep 30
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Checking for all nodes 'poweredOff'" "until make -s -C $subdir/aba/$cluster_name ls |grep poweredOff |wc -l| grep ^$cnt$; do sleep 10; done"
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Check node status" "make -s -C $subdir/aba/$cluster_name ls"
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Start cluster gracefully" "make -s -C $subdir/aba/$cluster_name startup"
	test-cmd -m "Wait for cluster to settle" sleep 30
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Checking for all nodes 'Ready'" "until make -s -C $subdir/aba/$cluster_name cmd cmd='oc get nodes'| grep Ready|grep -v Not|wc -l| grep ^$cnt$; do sleep 10; done"
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/$cluster_name cmd cmd='get nodes'"
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/$cluster_name cmd cmd='whoami'"
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/$cluster_name cmd cmd='version'"
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/$cluster_name cmd cmd='get po -A | grep -v -e Running -e Complete'"
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/$cluster_name cmd"
	test-cmd -m "Wait for cluster to settle" sleep 60
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Waiting for all co available?" "make -s -C $subdir/aba/$cluster_name cmd; until make -s -C $subdir/aba/$cluster_name cmd | tail -n +2 |awk '{print \$3}' |tail -n +2 |grep ^False$ |wc -l |grep ^0$; do sleep 10; echo -n .; done"

	# Deploy test app
	test-cmd -h steve@$bastion2 -m "Create project 'demo'" "make -s -C $subdir/aba/$cluster_name cmd cmd='oc new-project demo'" || true
	test-cmd -h steve@$bastion2 -m "Launch vote-app" "make -s -C $subdir/aba/$cluster_name cmd cmd='oc new-app --insecure-registry=true --image $reg_host:$reg_port/$reg_path/sjbylo/flask-vote-app --name vote-app -n demo'" || true
	test-cmd -h steve@$bastion2 -m "Wait for vote-app rollout" "make -s -C $subdir/aba/$cluster_name cmd cmd='oc rollout status deployment vote-app -n demo'"
}

#for c in sno compact standard
for c in standard
do
	mylog "Building cluster $c"
	[ "$c" = "sno" ] && cnt=1
	[ "$c" = "compact" ] && cnt=3
	[ "$c" = "standard" ] && cnt=6
	build_and_test_cluster $c $cnt

	test-cmd -h $reg_ssh_user@$bastion2 -m  "Deleting '$c' cluster" "make -s -C $subdir/aba/$c delete" 
	test-cmd -h $reg_ssh_user@$bastion2 -m  "Running 'make clean' in $subdir/aba/$c" "make -s -C $subdir/aba/$c clean" 
done

# Test bare-metal with BYO macs
test-cmd -h $reg_ssh_user@$bastion2 -m  "Creating standard cluster dir" "cd $subdir/aba; rm -rf standard; mkdir -p standard; ln -s ../templates/Makefile standard; make -s -C standard init" 
echo "00:50:56:1d:9e:01
00:50:56:1d:9e:02
00:50:56:1d:9e:03
00:50:56:1d:9e:04
00:50:56:1d:9e:05
00:50:56:1d:9e:06
" > macs.conf
scp macs.conf $reg_ssh_user@$bastion2:$subdir/aba/standard
test-cmd -h $reg_ssh_user@$bastion2 -m  "Creating cluster.conf" "cd $subdir/aba/standard; scripts/create-cluster-conf.sh standard standard"

	cluster_name=standard
	test-cmd -h $reg_ssh_user@$bastion2 -m "Adding master CPU" "sed -i 's/^master_cpu_count=.*/master_cpu_count=12/g' $subdir/aba/$cluster_name/cluster.conf"
	test-cmd -h $reg_ssh_user@$bastion2 -m "Adding worker CPU" "sed -i 's/^worker_cpu_count=.*/worker_cpu_count=8/g' $subdir/aba/$cluster_name/cluster.conf"
	test-cmd -h $reg_ssh_user@$bastion2 -m "Adding master RAM" "sed -i 's/^master_mem=.*/master_mem=24/g' $subdir/aba/$cluster_name/cluster.conf"
	test-cmd -h $reg_ssh_user@$bastion2 -m "Adding worker RAM" "sed -i 's/^worker_mem=.*/worker_mem=16/g' $subdir/aba/$cluster_name/cluster.conf"

test-cmd -h $reg_ssh_user@$bastion2 -m  "Making iso" "make -s -C $subdir/aba/standard iso"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Creating standard cluster" "make -s -C $subdir/aba/standard"

test-cmd -h $reg_ssh_user@$bastion2 -m  "Waiting for all co available?" "make -s -C $subdir/aba/standard cmd; until make -s -C $subdir/aba/standard cmd | tail -n +2 |awk '{print \$3}' |tail -n +2 |grep ^False$ |wc -l |grep ^0$; do sleep 10; echo -n .; done"

# Restart cluster test 
test-cmd -h $reg_ssh_user@$bastion2 -m  "Log into cluster" ". <(make -s -C $subdir/aba/standard login)"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Check node status" "make -s -C $subdir/aba/standard ls"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Shut cluster down gracefully (2/2)" "yes | make -s -C $subdir/aba/standard shutdown"
#test-cmd -m "Wait for cluster to power down" sleep 600
test-cmd -m "Wait for cluster to power down" sleep 60
test-cmd -h $reg_ssh_user@$bastion2 -m  "Checking for all nodes 'poweredOff'" "until make -s -C $subdir/aba/standard ls |grep poweredOff |wc -l| grep ^6$; do sleep 10; echo -n .; done"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Check node status" "make -s -C $subdir/aba/standard ls"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Start cluster gracefully" "make -s -C $subdir/aba/standard startup"
#test-cmd -m "Wait for cluster to settle" sleep 600
test-cmd -m "Wait for cluster to settle" sleep 60
test-cmd -h $reg_ssh_user@$bastion2 -m  "Checking for all nodes 'Ready'" "cd $subdir/aba/standard; until oc get nodes| grep Ready|grep -v Not|wc -l| grep ^6$; do sleep 10; echo -n .; done"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/standard cmd cmd='get nodes'"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/standard cmd cmd='whoami'"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/standard cmd cmd='version'"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/standard cmd cmd='get po -A | grep -v -e Running -e Complete'"
test-cmd -h $reg_ssh_user@$bastion2 -m  "Check cluster up" "make -s -C $subdir/aba/standard cmd"
test-cmd -m "Wait for cluster to settle" sleep 60
test-cmd -h $reg_ssh_user@$bastion2 -m  "Waiting for all co available?" "make -s -C $subdir/aba/standard cmd; make -s -C $subdir/aba/standard cmd | tail -n +2 |awk '{print \$3}' |tail -n +2 |grep ^False$ |wc -l |grep ^0$"
# Restart cluster test end 

# keep it # test-cmd -h $reg_ssh_user@$bastion2 -m  "Deleting standard cluster" "make -s -C $subdir/aba/standard delete" 
###test-cmd -h $reg_ssh_user@$bastion2 -m  "Stopping standard cluster" "yes|make -s -C $subdir/aba/standard shutdown" 
test-cmd -h $reg_ssh_user@$bastion2 -m "If cluster up, stopping cluster" ". <(make -sC $subdir/aba/standard shell) && . <(make -sC $subdir/aba/standard login) && yes|make -sC $subdir/aba/standard shutdown || echo cluster not up"
# keep it # test-cmd -h $reg_ssh_user@$bastion2 -m  "Running 'make clean' in $subdir/aba/stanadard" "make -s -C $subdir/aba/standard clean" 

#test-cmd "make distclean force=1"
# keep it # make -C ~/aba distclean force=1
# keep it # mv cli cli.m && mkdir cli && cp cli.m/Makefile cli && make distclean force=1; rm -rf cli && mv cli.m cli

mylog
mylog "===> Completed test $0"
mylog

[ -f test/test.log ] && cp test/test.log test/test.log.bak

echo SUCCESS 
