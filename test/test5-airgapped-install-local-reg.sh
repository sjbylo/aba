#!/bin/bash -x
# This test installs a mirror reg. on the internal bastion (just for testing) and then
# treats that registry as an "existing registry" in the test internal workflow. 

# Required: 2 bastions (internal and external), for internal (no direct Internet) only yum works via a proxy. For external, the proxy is fully configured. 
# I.e. Internal bastion has no access to the Internet.  External has full access. 
# Ensure passwordless ssh access from bastion1 (external) to int_bastion (internal). 
# Be sure no mirror registries are installed on either bastion before running.  Internal int_bastion can be a fresh "minimal install" of RHEL8/9.

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

source scripts/include_all.sh no-trap  # Need for below normalize fn() calls
source test/include.sh
trap - ERR # We don't want this trap during testing.  Needed for below normalize fn() calls

[ ! "$target_full" ] && default_target="--step iso"   # Default is to generate 'iso' only   # Default is to only create iso
mylog default_target=$default_target

ntp=10.0.1.8 # If available

rm -f ~/.aba.previous.backup

######################
# Set up test 

which make || sudo dnf install make -y

./install 

test-cmd -m "Cleaning up - aba reset --force" 
mv cli cli.m && mkdir cli && cp cli.m/Makefile cli && aba reset --force; rm -rf cli && mv cli.m cli
#test-cmd -m "Cleaning up mirror - clean" "aba -s -C mirror clean" 

rm -rf sno compact standard 

# Need this so this test script can be run standalone
[ ! "$VER_OVERRIDE" ] && #export VER_OVERRIDE=4.16.12 # Uncomment to use the 'latest' stable version of OCP
[ ! "$internal_bastion_rhel_ver" ] && export internal_bastion_rhel_ver=rhel9  # rhel8 or rhel9

int_bastion=registry.example.com
bastion_vm=bastion-internal-$internal_bastion_rhel_ver
subdir=~/subdir

mylog ============================================================
mylog Starting test $(basename $0)
mylog ============================================================
mylog "Test to install a local reg. on $int_bastion and save + copy + load images.  Install sno ocp and a test app and svc mesh."

rm -f aba.conf  # Set it up next
vf=~/.vmware.conf
[ ! "$VER_OVERRIDE" ] && VER_OVERRIDE=latest
test-cmd -m "Configure aba.conf for ocp_version '$VER_OVERRIDE'" aba noask --channel fast --version $VER_OVERRIDE
mylog "ocp_version set to $(grep -o '^ocp_version=[^ ]*' aba.conf) in $PWD/aba.conf"
mylog "ask set to $(grep -o '^ask=[^ ]*' aba.conf) in $PWD/aba.conf"

# Set up govc 
cp $vf vmware.conf 
sed -i "s#^VC_FOLDER=.*#VC_FOLDER=/Datacenter/vm/abatesting#g" vmware.conf

# Do not ask to delete things
mylog "Setting ask=false"
aba noask

mylog "Setting ntp_servers=$ntp" 
[ "$ntp" ] && sed -i "s/^ntp_servers=\([^#]*\)#\(.*\)$/ntp_servers=$ntp    #\2/g" aba.conf

mylog "Setting op_sets=\"abatest\" in aba.conf"
sed -i "s/^op_sets=.*/op_sets=\"abatest\" /g" aba.conf
echo kiali-ossm > templates/operator-set-abatest 

# Needed for $ocp_version below
source <(normalize-aba-conf)
mylog "Checking value of: ocp_version=$ocp_version"

# Be sure this file exists
test-cmd -m "Init test: download mirror-registry.tar.gz" "aba --dir test mirror-registry.tar.gz"

#################################
# Copy and edit mirror.conf 

rpm -q --quiet python3 || rpm -q --quiet python36 || sudo dnf install python3 -y 
# Simulate creation and edit of mirror.conf file
scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf
# FIXME: Why not use 'aba mirror.conf'?

mylog "Test the internal bastion ($int_bastion) as mirror"

mylog "Setting reg_host=$int_bastion"
sed -i "s/registry.example.com/$int_bastion /g" ./mirror/mirror.conf

# This is also a test that overriding vakues works ok, e.g. this is an override in the mirror.connf gile, overriding from aba.conf file
####mylog "Setting op_sets=\"abatest\" in mirror/mirror.conf"
test-cmd -m "Setting op_sets='abatest' in mirror/mirror.conf" "sed -i 's/^.*op_sets=.*/op_sets='abatest' /g' ./mirror/mirror.conf"
echo kiali-ossm > templates/operator-set-abatest 

# Uncomment this line
# NOT NEEDED.  This is a local reg on host $int_bastion!
#### test-cmd -m "Setting for local mirror" "sed -i 's/.*reg_ssh_key=/reg_ssh_key=/g' ./mirror/mirror.conf"

# This is needed for below VM reset!
aba --dir cli ~/bin/govc

source <(normalize-vmware-conf)
##scripts/vmw-create-folder.sh /Datacenter/vm/test

#################################
mylog Revert vm snapshot of the internal bastion vm and power on
(
	govc vm.power -off bastion-internal-rhel8
	govc vm.power -off bastion-internal-rhel9
	govc snapshot.revert -vm $bastion_vm aba-test
	sleep 8
	govc vm.power -on $bastion_vm
	sleep 5
)
# Wait for host to come up
ssh steve@$int_bastion -- "date" || sleep 2
ssh steve@$int_bastion -- "date" || sleep 3
ssh steve@$int_bastion -- "date" || sleep 8

cat <<END | ssh steve@$int_bastion -- sudo bash
set -ex
timedatectl
dnf install chrony podman -y
chronyc sources -v
chronyc add server 10.0.1.8 iburst
timedatectl set-timezone Asia/Singapore
chronyc -a makestep
sleep 3
timedatectl
chronyc sources -v
END

# Delete images
test-cmd -h steve@$int_bastion -m "Verify mirror uninstalled" podman ps 
test-cmd -i -h steve@$int_bastion -m "Deleting all podman images" "podman system prune --all --force && podman rmi --all && sudo rm -rf ~/.local/share/containers/storage && rm -rf ~/test"
# This file is not needed in a fully air-gapped env. 
ssh steve@$int_bastion -- "rm -fv ~/.pull-secret.json"
# Want to test fully disconnected 
ssh steve@$int_bastion -- "sed -i 's|^source ~/.proxy-set.sh|# aba test # source ~/.proxy-set.sh|g' ~/.bashrc"
# Ensure home is empty!  Avoid errors where e.g. hidden files cause reg. install failing. 
ssh steve@$int_bastion -- "rm -rfv ~/*"
# Just be sure a valid govc config file exists
scp $vf steve@$int_bastion: 

#################################

source <(cd mirror && normalize-mirror-conf)

mylog "Using container mirror at $reg_host:$reg_port and using reg_ssh_user=$reg_ssh_user reg_ssh_key=$reg_ssh_key"

test-cmd -h $reg_ssh_user@$int_bastion -m  "Create test subdir: '$subdir'" "mkdir -p $subdir" 
test-cmd -r 20 3 -m "Creating bundle for channel fast and versiono $ocp_version" "aba bundle --channel fast --version $ocp_version --out - | ssh $reg_ssh_user@$int_bastion tar -C $subdir -xvf -"

# Smoke test!
test-cmd -m  "Verifying existance of file 'mirror/save/mirror_seq1_000000.tar'" "ls -lh mirror/save/mirror_seq1_000000.tar" 
test-cmd -m  "Delete this file that's already been copied to internal bastion: 'mirror/save/mirror_seq1_000000.tar'" "rm -f mirror/save/mirror_seq1_000000.tar" 

ssh $reg_ssh_user@$int_bastion "rpm -q make || sudo yum install make -y"

test-cmd -h $reg_ssh_user@$int_bastion -r 5 3 -m "Checking regcreds/ does not exist on $int_bastion" "test ! -d $subdir/aba/mirror/regcreds" 

######################
mylog Runtest: START - airgap

test-cmd -h $reg_ssh_user@$int_bastion -r 20 3 -m  "Install aba script" "cd $subdir/aba; ./install" 

test-cmd -h $reg_ssh_user@$int_bastion -r 20 3 -m  "Loading cluster images into mirror on internal bastion" "aba -d $subdir/aba load" 

test-cmd -h $reg_ssh_user@$int_bastion -m  "Delete already loaded image set file to make space: '$subdir/aba/mirror/save/mirror_seq1_000000.tar'" "rm -f $subdir/aba/mirror/save/mirror_seq1_000000.tar" 

test-cmd -h $reg_ssh_user@$int_bastion -m  "Tidying up internal bastion" "rm -rf $subdir/aba/sno" 

mylog "Running 'aba sno' on internal bastion"

test-cmd -h $reg_ssh_user@$int_bastion -m  "Installing sno/iso" "aba --dir $subdir/aba sno --step iso" 
#test-cmd -h $reg_ssh_user@$int_bastion -m  "Checking cluster operators" aba --dir $subdir/aba/sno cmd

test-cmd -h $reg_ssh_user@$int_bastion -m  "Increase node cpu to 24 for loading mesh test app" "sed -i 's/^master_cpu=.*/master_cpu=24/g' $subdir/aba/sno/cluster.conf"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Increase node memory to 24 for loading mesh test app" "sed -i 's/^master_mem=.*/master_mem=24/g' $subdir/aba/sno/cluster.conf"

######################
mylog Now adding more images to the mirror registry
######################

mylog Runtest: vote-app

mylog Add ubi9 image to imageset conf file 
cat >> mirror/save/imageset-config-save.yaml <<END
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi:latest
END

test-cmd -r 20 3 -m "Saving ubi images to local disk on `hostname`" "aba --dir mirror save" 

mylog Copy tar+ssh archives to internal bastion
## aba --dir mirror inc --out - | ssh $reg_ssh_user@$int_bastion -- tar -C $subdir - xvf -
aba --dir mirror tarrepo --out - | ssh $reg_ssh_user@$int_bastion -- tar -C $subdir -xvf -
test-cmd -h $reg_ssh_user@$int_bastion -m "Ensure image set tar file does not exist yet" "test ! -f $subdir/aba/mirror/save/mirror_seq2_000000.tar"
scp mirror/save/mirror_seq2_000000.tar $reg_ssh_user@$int_bastion:$subdir/aba/mirror/save
test-cmd -h $reg_ssh_user@$int_bastion -m "Ensure image set tar file exists" "test -f $subdir/aba/mirror/save/mirror_seq2_000000.tar"

test-cmd -h $reg_ssh_user@$int_bastion -r 20 3 -m  "Loading UBI images into mirror" "cd $subdir; aba -d aba load" 

mylog Add vote-app image to imageset conf file 
cat >> mirror/save/imageset-config-save.yaml <<END
  - name: quay.io/sjbylo/flask-vote-app:latest
END

test-cmd -r 20 3 -m "Saving vote-app image to local disk" "aba --dir mirror save" 

mylog Copy repo only to internal bastion
aba --dir mirror tarrepo --out - | ssh $reg_ssh_user@$int_bastion -- tar -C $subdir -xvf -

test-cmd -h $reg_ssh_user@$int_bastion -m "Ensure image set tar file does not exist yet" "test ! -f $subdir/aba/mirror/save/mirror_seq3_000000.tar"
mylog "Copy extra image set tar file to internal bastion"
scp mirror/save/mirror_seq3_000000.tar $reg_ssh_user@$int_bastion:$subdir/aba/mirror/save
test-cmd -h $reg_ssh_user@$int_bastion -m "Ensure image set tar file exists" "test -f $subdir/aba/mirror/save/mirror_seq3_000000.tar"

test-cmd -h $reg_ssh_user@$int_bastion -r 20 3 -m  "Loading vote-app image into mirror" "aba -d $subdir/aba/mirror load" 

cluster_type=sno  # Choose either sno, compact or standard

test-cmd -h $reg_ssh_user@$int_bastion -m  "Installing $cluster_type cluster, ready to deploy test app" "aba --dir $subdir/aba $cluster_type"

test-cmd -h $reg_ssh_user@$int_bastion -m  "Checking cluster operators" aba --dir $subdir/aba/$cluster_type cmd

test-cmd -h $reg_ssh_user@$int_bastion -m  "Listing VMs (should show 24G memory)" "aba --dir $subdir/aba/$cluster_type ls"

myLog "Deploying test vote-app"
test-cmd -h steve@$int_bastion -m "Delete project 'demo'" "aba --dir $subdir/aba/$cluster_type --cmd 'oc delete project demo || true'" 
test-cmd -h steve@$int_bastion -m "Create project 'demo'" "aba --dir $subdir/aba/$cluster_type --cmd 'oc new-project demo'" 
test-cmd -h steve@$int_bastion -m "Launch vote-app" "aba --dir $subdir/aba/$cluster_type --cmd 'oc new-app --insecure-registry=true --image $reg_host:$reg_port/$reg_path/sjbylo/flask-vote-app --name vote-app -n demo'"
test-cmd -h steve@$int_bastion -m "Wait for vote-app rollout" "aba --dir $subdir/aba/$cluster_type --cmd 'oc rollout status deployment vote-app -n demo'"

export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

mylog 
mylog "Append svc mesh and kiali operators to imageset conf using v$ocp_ver_major ($ocp_version)"

# FIXME: Get values from the correct file!
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
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major
    packages:
END

mylog "Checking for file mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml"
test -s mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml
mylog "Checking for servicemeshoperator in mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml"
cat mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | grep -A2 servicemeshoperator$
mylog "Checking for kiali-ossm in mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml"
cat mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | grep -A2 kiali-ossm$

# Append the correct values for each operator
mylog Append sm and kiali operators to imageset conf
grep -A2 -e "name: servicemeshoperator$"  mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | tee -a mirror/save/imageset-config-save.yaml
grep -A2 -e "name: kiali-ossm$"	          mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | tee -a mirror/save/imageset-config-save.yaml

########
test-cmd -r 20 3 -m "Saving mesh operators to local disk" "aba --dir mirror save"

mylog Create incremental tar and ssh to internal bastion
aba --dir mirror inc --out - | ssh $reg_ssh_user@$int_bastion -- tar -C $subdir -xvf -

test-cmd -h $reg_ssh_user@$int_bastion -r 20 3 -m  "Loading images to mirror" "cd $subdir/aba/mirror; aba load" 

test-cmd -h $reg_ssh_user@$int_bastion -m  "Configuring day2 ops" "aba --dir $subdir/aba/$cluster_type day2"

mylog "Checking for jaeger-product in mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml"
cat mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | grep jaeger-product$

mylog Append jaeger operator to imageset conf
grep -A2 -e "name: jaeger-product$"		mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | tee -a mirror/save/imageset-config-save.yaml

test-cmd -r 20 3 -m "Saving jaeger operator to local disk" "aba --dir mirror save"

mylog Downloading the mesh demo into test/mesh, for use by deploy script

(
	pwd && \
	rm -rf test/mesh && mkdir test/mesh && cd test/mesh && \
	git clone https://github.com/sjbylo/openshift-service-mesh-demo.git && \
	pwd && \
	cd openshift-service-mesh-demo && \
	pwd && \
	sed -i "s#quay\.io#$reg_host:$reg_port/$reg_path#g" */*.yaml */*/*.yaml */*/*/*.yaml && \
	sed -i "s/source: .*/source: cs-redhat-operator-index/g" operators/* 
) 

mylog Copy tar+ssh archives to internal bastion
rm -f test/mirror-registry.tar.gz  # No need to copy this over!
test-cmd -r 2 2 -m "Running incremental tar copy to $reg_ssh_user@$int_bastion:$subdir" "aba --dir mirror inc --out - | ssh $reg_ssh_user@$int_bastion -- tar -C $subdir -xvf - "

test-cmd -h $reg_ssh_user@$int_bastion -r 20 3 -m  "Loading jaeger operator images to mirror" "cd $subdir/aba/mirror; aba load" 


test-cmd -m "Pausing for 90s to let OCP settle" sleep 90    # For some reason, the cluster was still not fully ready in tests!

test-cmd -h $reg_ssh_user@$int_bastion -m  "Waiting for all cluster operators to be available?" "aba --dir $subdir/aba/$cluster_type --cmd; until aba --dir $subdir/aba/$cluster_type --cmd | tail -n +2 |awk '{print \$3,\$4,\$5}' |tail -n +2 |grep -v '^True False False$' |wc -l |grep ^0$; do sleep 10; echo -n .; done"

# Sometimes the cluster is not fully ready... OCP API can fail, so re-run 'aba day2' ...
test-cmd -h $reg_ssh_user@$int_bastion -r 20 3 -m "Run 'day2'" "aba --dir $subdir/aba/sno day2"  # Install CA cert and activate local op. hub

# Wait for https://docs.openshift.com/container-platform/4.11/openshift_images/image-configuration.html#images-configuration-cas_image-configuration 
test-cmd -m "Pausing for 60s to let OCP settle" sleep 60  # And wait for https://access.redhat.com/solutions/5514331 to take effect 

### MESH STOPPED test-cmd -h $reg_ssh_user@$int_bastion -m "Deploying service mesh with test app" "$subdir/aba/test/deploy-mesh.sh"

# Restart cluster test 
test-cmd -h $reg_ssh_user@$int_bastion -m  "Log into cluster" ". <(aba --dir $subdir/aba/sno login)"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Check node status" "aba --dir $subdir/aba/sno ls"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Shut cluster down gracefully and wait for poweroff (2/2)" "yes | aba --dir $subdir/aba/sno shutdown --wait"

test-cmd -h $reg_ssh_user@$int_bastion -m  "Checking for all nodes 'poweredOff'" "until aba --dir $subdir/aba/sno ls | grep poweredOff | wc -l| grep ^1$ ; do sleep 10; echo -n .;done"

test-cmd -h $reg_ssh_user@$int_bastion -m  "Check node status" "aba --dir $subdir/aba/sno ls"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Start cluster gracefully" "aba --dir $subdir/aba/sno startup --wait"
###test-cmd -m "Wait for cluster to settle" sleep 30
test-cmd -h $reg_ssh_user@$int_bastion -m  "Checking for all nodes 'Ready'" "cd $subdir/aba/sno; until oc get nodes| grep Ready|grep -v Not |wc -l| grep ^1$; do sleep 10; echo -n .; done"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up" "aba --dir $subdir/aba/sno --cmd 'get nodes'"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up" "aba --dir $subdir/aba/sno --cmd 'whoami' | grep system:admin"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up" "aba --dir $subdir/aba/sno --cmd 'version'"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up" "aba --dir $subdir/aba/sno --cmd 'get po -A | grep -v -e Running -e Complete'"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up" "aba --dir $subdir/aba/sno --cmd"
test-cmd -m "Wait for cluster to settle" sleep 30
test-cmd -h $reg_ssh_user@$int_bastion -m  "Waiting for all co available?" "aba --dir $subdir/aba/sno --cmd; aba --dir $subdir/aba/sno --cmd | tail -n +2 |awk '{print \$3}' |tail -n +2 |grep ^False$ |wc -l |grep ^0$"
# Restart cluster test end 

##### MESH STOPPED test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up and app running" "aba --dir $subdir/aba/sno --cmd 'get po -A | grep ^travel-.*Running'"

test-cmd -h $reg_ssh_user@$int_bastion -m  "Deleting sno cluster" "aba --dir $subdir/aba/sno delete" 
test-cmd -h $reg_ssh_user@$int_bastion -m  "Running 'aba clean' in $subdir/aba/sno" "aba --dir $subdir/aba/sno clean" 

rm -rf test/mesh 

######################
### test-cmd -h $reg_ssh_user@$int_bastion -m  "Deleting cluster dirs, $subdir/aba/sno $subdir/aba/compact $subdir/aba/standard" "rm -rf  $subdir/aba/sno $subdir/aba/compact $subdir/aba/standard" 

###
build_and_test_cluster() {
	cluster_name=$1
	cnt=$2  # Number of nodes to check/validate in the cluster

	# Create cluster.conf
	test-cmd -h $reg_ssh_user@$int_bastion -m  "Creating '$cluster_name' cluster.conf" "cd $subdir/aba; aba cluster --name $cluster_name --type $cluster_name --step cluster.conf || true" # || true

	# Add more cpu/ram ... See if this will speed things up!
	test-cmd -h $reg_ssh_user@$int_bastion -m "Adding master CPU" "sed -i 's/^master_cpu_count=.*/master_cpu_count=12/g' $subdir/aba/$cluster_name/cluster.conf"
	test-cmd -h $reg_ssh_user@$int_bastion -m "Adding worker CPU" "sed -i 's/^worker_cpu_count=.*/worker_cpu_count=8/g' $subdir/aba/$cluster_name/cluster.conf"
	test-cmd -h $reg_ssh_user@$int_bastion -m "Adding master RAM" "sed -i 's/^master_mem=.*/master_mem=24/g' $subdir/aba/$cluster_name/cluster.conf"
	test-cmd -h $reg_ssh_user@$int_bastion -m "Adding worker RAM" "sed -i 's/^worker_mem=.*/worker_mem=16/g' $subdir/aba/$cluster_name/cluster.conf"

	test-cmd -h $reg_ssh_user@$int_bastion -m  "Creating '$cluster_name' cluster" "aba --dir $subdir/aba/$cluster_name" || \
		test-cmd -h $reg_ssh_user@$int_bastion -m  "Restarting nodes of failed cluster" "aba --dir $subdir/aba/$cluster_name stop; sleep 200; aba --dir $subdir/aba/$cluster_name start"

	if ! test-cmd -h $reg_ssh_user@$int_bastion -r 8 3 -m  "Checking '$cluster_name' cluster with 'mon'" "aba --dir $subdir/aba/$cluster_name mon"; then
		mylog "CLUSTER INSTALL FAILED: REBOOTING ALL NODES ..."

		set -x

		# See if the agent is still running and fetch the logs
		aba --dir $subdir/aba/$cluster_name ssh --cmd "agent-gather -O" | ssh 10.0.1.6 -- "cat > agent-gather-$cluster_name-.tar.xz || true" # || true
		scp $subdir/aba/$cluster_name/iso-agent-based/.openshift_install.log 10.0.1.6:${cluster_name}_openshift_install.log

		aba --dir $subdir/aba/$cluster_name stop --wait
		aba --dir $subdir/aba/$cluster_name start
		sleep 60
		aba --dir $subdir/aba/$cluster_name mon
	fi

	#####
	test-cmd -h $reg_ssh_user@$int_bastion -m  "Waiting for all cluster operators available?" "aba --dir $subdir/aba/$cluster_name --cmd; until aba --dir $subdir/aba/$cluster_name --cmd | tail -n +2 |awk '{print \$3}' |tail -n +2 |grep ^False$ |wc -l |grep ^0$; do sleep 10; echo -n .; done"

	test-cmd -h $reg_ssh_user@$int_bastion -m  "Waiting for all cluster operators fully available?" "aba --dir $subdir/aba/$cluster_name --cmd; until aba --dir $subdir/aba/$cluster_name --cmd | tail -n +2 |awk '{print \$3,\$4,\$5}' |tail -n +2 |grep -v '^True False False$' |wc -l |grep ^0$; do sleep 10; echo -n .; done"

	test-cmd -h $reg_ssh_user@$int_bastion -m  "Show all cluster operators" "aba --dir $subdir/aba/$cluster_name --cmd"

	# Restart cluster test 
	test-cmd -h $reg_ssh_user@$int_bastion -m  "Log into cluster" ". <(aba --dir $subdir/aba/$cluster_name login)"
	test-cmd -h $reg_ssh_user@$int_bastion -m  "Check node status" "aba --dir $subdir/aba/$cluster_name ls"
	test-cmd -h $reg_ssh_user@$int_bastion -m  "Shut cluster down gracefully and wait" "yes | aba --dir $subdir/aba/$cluster_name shutdown --wait"

	####test-cmd -m "Wait for cluster to power down" sleep 30
	test-cmd -h $reg_ssh_user@$int_bastion -m  "Checking for all nodes 'poweredOff'" "until aba --dir $subdir/aba/$cluster_name ls |grep poweredOff |wc -l| grep ^$cnt$; do sleep 10; done"

	test-cmd -h $reg_ssh_user@$int_bastion -m  "Check node status" "aba --dir $subdir/aba/$cluster_name ls"
	test-cmd -h $reg_ssh_user@$int_bastion -m  "Start cluster gracefully" "aba --dir $subdir/aba/$cluster_name startup"
	####test-cmd -m "Wait for cluster to settle" sleep 30
	test-cmd -h $reg_ssh_user@$int_bastion -m  "Checking for all nodes 'Ready'" "until aba --dir $subdir/aba/$cluster_name --cmd 'oc get nodes'| grep Ready|grep -v Not|wc -l| grep ^$cnt$; do sleep 10; done"
	test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up" "aba --dir $subdir/aba/$cluster_name --cmd 'get nodes'"
	test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up" "aba --dir $subdir/aba/$cluster_name --cmd 'whoami'"
	test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up" "aba --dir $subdir/aba/$cluster_name --cmd 'version'"
	test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up" "aba --dir $subdir/aba/$cluster_name --cmd 'get po -A | grep -v -e Running -e Complete'"
	test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up" "aba --dir $subdir/aba/$cluster_name --cmd"
	test-cmd -m "Wait for cluster to settle" sleep 60
	test-cmd -h $reg_ssh_user@$int_bastion -m  "Waiting for all co available?" "aba --dir $subdir/aba/$cluster_name --cmd; until aba --dir $subdir/aba/$cluster_name --cmd | tail -n +2 |awk '{print \$3}' |tail -n +2 |grep ^False$ |wc -l |grep ^0$; do sleep 10; echo -n .; done"

	# Deploy test app
	test-cmd -h steve@$int_bastion -m "Delete project 'demo'" "aba --dir $subdir/aba/$cluster_name --cmd 'oc delete project demo || true'" 
	test-cmd -h steve@$int_bastion -m "Create project 'demo'" "aba --dir $subdir/aba/$cluster_name --cmd 'oc new-project demo' || true" # || true
	test-cmd -h steve@$int_bastion -m "Launch vote-app" "aba --dir $subdir/aba/$cluster_name --cmd 'oc new-app --insecure-registry=true --image $reg_host:$reg_port/$reg_path/sjbylo/flask-vote-app --name vote-app -n demo'"
	test-cmd -h steve@$int_bastion -m "Wait for vote-app rollout" "aba --dir $subdir/aba/$cluster_name --cmd 'oc rollout status deployment vote-app -n demo'"
}

#for c in sno compact standard
for c in standard
do
	mylog "Building cluster $c"
	[ "$c" = "sno" ] && cnt=1
	[ "$c" = "compact" ] && cnt=3
	[ "$c" = "standard" ] && cnt=6
	build_and_test_cluster $c $cnt

	test-cmd -h $reg_ssh_user@$int_bastion -m  "Deleting '$c' cluster" "aba --dir $subdir/aba/$c delete" 
	test-cmd -h $reg_ssh_user@$int_bastion -m  "Running 'aba clean' in $subdir/aba/$c" "aba --dir $subdir/aba/$c clean" 
done

# Test bare-metal with BYO macs
test-cmd -h $reg_ssh_user@$int_bastion -m  "Creating standard cluster dir" "cd $subdir/aba; rm -rf standard; mkdir -p standard; ln -s ../templates/Makefile standard; aba --dir standard init" 
echo "\
00:50:56:1d:9e:01
00:50:56:1d:9e:02
00:50:56:1d:9e:03
00:50:56:1d:9e:04
00:50:56:1d:9e:05
00:50:56:1d:9e:06
" > macs.conf
scp macs.conf $reg_ssh_user@$int_bastion:$subdir/aba/standard
test-cmd -h $reg_ssh_user@$int_bastion -m  "Creating cluster.conf" "cd $subdir/aba/standard; scripts/create-cluster-conf.sh standard standard"

	cluster_name=standard
	test-cmd -h $reg_ssh_user@$int_bastion -m "Adding master CPU" "sed -i 's/^master_cpu_count=.*/master_cpu_count=12/g' $subdir/aba/$cluster_name/cluster.conf"
	test-cmd -h $reg_ssh_user@$int_bastion -m "Adding worker CPU" "sed -i 's/^worker_cpu_count=.*/worker_cpu_count=8/g' $subdir/aba/$cluster_name/cluster.conf"
	test-cmd -h $reg_ssh_user@$int_bastion -m "Adding master RAM" "sed -i 's/^master_mem=.*/master_mem=24/g' $subdir/aba/$cluster_name/cluster.conf"
	test-cmd -h $reg_ssh_user@$int_bastion -m "Adding worker RAM" "sed -i 's/^worker_mem=.*/worker_mem=16/g' $subdir/aba/$cluster_name/cluster.conf"

test-cmd -h $reg_ssh_user@$int_bastion -m  "Making iso" "aba --dir $subdir/aba/standard iso"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Creating standard cluster" "aba --dir $subdir/aba/standard"

test-cmd -h $reg_ssh_user@$int_bastion -m  "Waiting for all co available?" "aba --dir $subdir/aba/standard --cmd; until aba --dir $subdir/aba/standard --cmd | tail -n +2 |awk '{print \$3}' |tail -n +2 |grep ^False$ |wc -l |grep ^0$; do sleep 10; echo -n .; done"

# Restart cluster test 
test-cmd -h $reg_ssh_user@$int_bastion -m  "Log into cluster" ". <(aba --dir $subdir/aba/standard login)"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Check node status" "aba --dir $subdir/aba/standard ls"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Shut cluster down gracefully and wait (2/2)" "yes | aba --dir $subdir/aba/standard shutdown --wait"

#test-cmd -m "Wait for cluster to power down" sleep 60
test-cmd -h $reg_ssh_user@$int_bastion -m  "Checking for all nodes 'poweredOff'" "until aba --dir $subdir/aba/standard ls |grep poweredOff |wc -l| grep ^6$; do sleep 10; echo -n .; done"

test-cmd -h $reg_ssh_user@$int_bastion -m  "Check node status" "aba --dir $subdir/aba/standard ls"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Start cluster gracefully" "aba --dir $subdir/aba/standard startup --wait"
test-cmd -m "Wait for cluster to settle" sleep 60
test-cmd -h $reg_ssh_user@$int_bastion -m  "Checking for all nodes 'Ready'" "cd $subdir/aba/standard; until oc get nodes| grep Ready|grep -v Not|wc -l| grep ^6$; do sleep 10; echo -n .; done"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up" "aba --dir $subdir/aba/standard --cmd 'get nodes'"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up" "aba --dir $subdir/aba/standard --cmd 'whoami'"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up" "aba --dir $subdir/aba/standard --cmd 'version'"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up" "aba --dir $subdir/aba/standard --cmd 'get po -A | grep -v -e Running -e Complete'"
test-cmd -h $reg_ssh_user@$int_bastion -m  "Check cluster up" "aba --dir $subdir/aba/standard --cmd"
test-cmd -m "Wait for cluster to settle" sleep 60
test-cmd -h $reg_ssh_user@$int_bastion -m  "Waiting for all co available?" "aba --dir $subdir/aba/standard --cmd; aba --dir $subdir/aba/standard --cmd | tail -n +2 |awk '{print \$3}' |tail -n +2 |grep ^False$ |wc -l |grep ^0$"
# Restart cluster test end 

# keep it # test-cmd -h $reg_ssh_user@$int_bastion -m  "Deleting standard cluster" "aba --dir $subdir/aba/standard delete" 
###test-cmd -h $reg_ssh_user@$int_bastion -m  "Stopping standard cluster and wait" "yes|aba --dir $subdir/aba/standard shutdown --wait" 

test-cmd -h $reg_ssh_user@$int_bastion -m "If cluster up, shutting cluster down and wait" ". <(aba --dir $subdir/aba/standard shell) && . <(aba --dir $subdir/aba/standard login) && yes|aba --dir $subdir/aba/standard shutdown --wait || echo cluster shutdown failure"

# keep it # test-cmd -h $reg_ssh_user@$int_bastion -m  "Running 'aba clean' in $subdir/aba/stanadard" "aba --dir $subdir/aba/standard clean" 

#test-cmd "aba reset --force"
# keep it # aba --dir ~/aba reset --force
# keep it # mv cli cli.m && mkdir cli && cp cli.m/Makefile cli && aba reset --force; rm -rf cli && mv cli.m cli

mylog "===> Completed test $0"

[ -f test/test.log ] && cp test/test.log test/test.log.bak

echo SUCCESS $0
