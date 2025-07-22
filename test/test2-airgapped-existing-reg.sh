#!/bin/bash -x
# This test installs a mirror reg. on the internal bastion (just for testing) and then
# treats that registry as an "existing registry" in the test internal workflow. 

# Required: 2 bastions (internal and external), for internal (no direct Internet) only yum works via a proxy/NAT. For external, the proxy is fully configured. 
# I.e. Internal bastion has no access to the Internet.  External has full access. 
# Ensure passwordless ssh access from bastion1 (external) to int_bastion_hostname (internal). Script uses tar+ssh to copy over the aba repo. 
# Be sure no mirror registries are installed on either bastion before running.  Internal int_bastion_hostname can be a fresh "minimal install" of RHEL8/9.

export INFO_ABA=1
export ABA_TESTING=1  # No usage reporting
[ ! "$TEST_CHANNEL" ] && export TEST_CHANNEL=latest
hash -r  # Forget all command locations in $PATH

### TEST for clean start with or without the rpms.  
if true; then
	# Assuming user will NOT install all rpms in advance and aba will install them.
	#sudo dnf remove make jq bind-utils nmstate net-tools skopeo python3-jinja2 python3-pyyaml openssl coreos-installer -y
	sudo dnf remove git hostname make jq bind-utils nmstate net-tools skopeo python3-jinja2 python3-pyyaml openssl coreos-installer ncurses -y
else
	# FIXME: test for pre-existing rpms!  In this case we don't want yum to run *at all* as it may error out
	# Assuming user will install all rpms in advance.
	sudo dnf install -y $(cat templates/rpms-internal.txt)
	sudo dnf install -y $(cat templates/rpms-external.txt)
fi

[ ! "$TEST_USER" ] && export TEST_USER=$(whoami)

cd `dirname $0`
cd ..  # Change into "aba" dir

rm -fr ~/.containers ~/.docker
rm -f ~/.aba.previous.backup

# Need this so this test script can be run standalone
[ ! "$VER_OVERRIDE" ] && export VER_OVERRIDE=l  #export VER_OVERRIDE=4.16.12 # Uncomment to use the 'latest' stable version of OCP
[ ! "$internal_bastion_rhel_ver" ] && export internal_bastion_rhel_ver=rhel9  # rhel8 or rhel9

int_bastion_hostname=registry.example.com
int_bastion_vm_name=bastion-internal-$internal_bastion_rhel_ver
ntp_ip=10.0.1.8 # If available

source scripts/include_all.sh no-trap # Need for below normalize fn() calls
source test/include.sh
trap - ERR # We don't want this trap during testing.  Needed for below normalize fn() calls

[ ! "$target_full" ] && default_target="--step iso"   # Default is to generate 'iso' only on some tests
mylog default_target=$default_target

mylog
mylog "===> Starting test $0"
mylog "Test to integrate an existing reg. on $int_bastion_hostname and save + copy + load images.  Install sno ocp and a test app."
mylog

######################
# Set up test 

#export subdir=\~/subdir   # Unpack repo tar into this dir on internal bastion
export subdir=subdir   # Unpack repo tar into this dir on internal bastion

# Exec script with any arg to skip reg. install and load
if [ ! "$1" ]; then
	echo
	echo Setting up test $(basename $0)
	echo

	which make || sudo dnf install make -y

	v=4.16.3
	#v=4.15.22

	# clean up all, assuming reg. is not running (deleted)
	#test-cmd "echo ocp_version=$v > aba.conf"
	####make -C ~/aba reset --force
	test-cmd -m "Installing aba" ./install
	test-cmd -m "Activating shortcuts.conf" cp .shortcuts.conf shortcuts.conf
	mv cli cli.m && mkdir cli && cp cli.m/Makefile cli && aba reset --force; rm -rf cli && mv cli.m cli
	test-cmd -m "Show content of mirror/save" 'ls -l mirror mirror/save || true'
	#test-cmd "make -C mirror clean"
	rm -rf sno compact standard 

	rm -f aba.conf
	vf=~steve/.vmware.conf
	[ ! "$VER_OVERRIDE" ] && VER_OVERRIDE=latest
	[ ! "$oc_mirror_ver_override" ] && oc_mirror_ver_override=v2
	test-cmd -m "Configure aba.conf for version '$VER_OVERRIDE' and vmware $vf" aba --platform vmw --channel $TEST_CHANNEL --version $VER_OVERRIDE ### --vmw $vf

	mylog "Setting oc_mirror_version=$oc_mirror_ver_override in aba.conf"
	sed -i "s/^oc_mirror_version=.*/oc_mirror_version=$oc_mirror_ver_override /g" aba.conf

	test-cmd -m "Setting 'ask=false' in aba.conf to enable full automation." aba -A  # noask

	#test-cmd -m "Configure aba.conf for version 'latest' and vmware $vf" aba --version latest ## --vmw $vf
	# Set up govc 
	cp $vf vmware.conf 
	sed -i "s#^VC_FOLDER=.*#VC_FOLDER=/Datacenter/vm/abatesting#g" vmware.conf

	mylog "Setting ask="
	sed -i 's/^ask=[^ \t]\{1,\}\([ \t]\{1,\}\)/ask=\1 /g' aba.conf

	#mylog "Setting ntp_servers=$ntp" 
	#[ "$ntp" ] && sed -i "s/^ntp_servers=\([^#]*\)#\(.*\)$/ntp_servers=$ntp,ntp.example.com #\2/g" aba.conf
	[ "$ntp_ip" ] && test-cmd -m "Setting ntp_servers=$ntp_ip ntp.example.com in aba.conf" aba --ntp $ntp_ip ntp.example.com

	mylog "Setting op_sets=abatest in aba.conf"
	sed -i "s/^op_sets=.*/op_sets=abatest /g" aba.conf
	echo kiali-ossm > templates/operator-set-abatest 

	source <(normalize-aba-conf)

	# Be sure this file exists
	test-cmd "make -C test mirror-registry-amd64.tar.gz"

	#################################
	# Set up mirror.conf 

	aba --dir mirror mirror.conf

	## test the internal bastion ($int_bastion_hostname) as mirror
	mylog "Setting reg_host=$int_bastion_hostname"
	sed -i "s/registry.example.com/$int_bastion_hostname /g" ./mirror/mirror.conf

	aba --dir cli ~/bin/govc

	#################################
	source <(normalize-vmware-conf)  # Needed for govc below

	init_bastion $int_bastion_hostname $int_bastion_vm_name aba-test $TEST_USER

	#####

	#uname -n | grep -qi ^fedora$ && sudo mount -o remount,size=6G /tmp   # Needed by oc-mirror ("aba save") when Operators need to be saved!
	# Try to fix "out of space" error when generating the op. index
	cat /etc/redhat-release | grep -q ^Fedora && sudo mount -o remount,size=20G /tmp && rm -rf /tmp/render-registry-*


	ssh $TEST_USER@$int_bastion_hostname "rpm -q make  || sudo yum install make -y"

	##mylog "Install 'existing' test mirror registry on internal bastion: $int_bastion_hostname"
	test-cmd -m "Install 'existing' test mirror registry on internal bastion: $int_bastion_hostname" test/reg-test-install-remote.sh $int_bastion_hostname

	################################

	test-cmd -m "Cleaning mirror dir" aba --dir mirror clean
else
	echo
	echo Skipping setting up of test $(basename $0)
	echo
fi

mylog ============================================================
mylog Starting test $(basename $0)
mylog ============================================================
mylog "Test to integrate with existing reg. on $int_bastion_hostname and then sync and save/load images."
mylog

# Fetch the config
source <(cd mirror; normalize-mirror-conf)
mylog "Using container mirror at $reg_host:$reg_port and using reg_ssh_user=$reg_ssh_user reg_ssh_key=$reg_ssh_key"

test-cmd -r 15 1 -m "Saving images to local disk on `hostname`" aba save --retry

test-cmd -m "Checking existance of file mirror/save/mirror_*000000.tar" "ls -lh mirror/save/mirror_*\.tar"

mylog "Use 'aba tar' and copy (ssh) files over to internal bastion @ $TEST_USER@$int_bastion_hostname"
test-cmd -m "Create 'subdir' on host $int_bastion_hostname" "ssh $TEST_USER@$int_bastion_hostname -- mkdir -p $subdir"
test-cmd -m "Create the 'full' tar file and unpack on host $int_bastion_hostname" "aba -d mirror tar --out - | ssh $TEST_USER@$int_bastion_hostname -- tar -C $subdir -xvf -"

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Verifying existance of file '$subdir/aba/mirror/save/mirror_*.tar'" "ls -lh $subdir/aba/mirror/save/mirror_*\.tar"

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Install aba on the remote host $int_bastion_hostname" "$subdir/aba/install"
###test-cmd -h $TEST_USER@$int_bastion_hostname -m "Activating shortcuts.conf on remote host" "cd $subdir/aba; cp .shortcuts.conf shortcuts.conf"

# FIXME: Is this needed since we use "full tar" copy above?
[ "$oc_mirror_ver_override" = "v2" ] && test-cmd -m "Copy image set file over also (oc-mirror v2 needs it) to $int_bastion_hostname" scp mirror/save/imageset-config-save.yaml $TEST_USER@$int_bastion_hostname:$subdir/aba/mirror/save

# This user's action is expected to fail since there are no login credentials for the "existing reg."
test-cmd -i -h $TEST_USER@$int_bastion_hostname -m "Loading images into mirror registry (without regcreds/ fails with 'Quay registry found')" "aba --dir $subdir/aba load --retry"

# But, now regcreds/ is created...
mylog "Simulating a manual config of 'existing' registry login credentials into mirror/regcreds/ on host: $TEST_USER@$int_bastion_hostname"

test-cmd -h $TEST_USER@$int_bastion_hostname "ls -l $subdir/aba/mirror"  
test-cmd -h $TEST_USER@$int_bastion_hostname "ls -l $subdir/aba/mirror/regcreds"  
test-cmd -h $TEST_USER@$int_bastion_hostname "cp -v ~/quay-install/quay-rootCA/rootCA.pem $subdir/aba/mirror/regcreds/"  
test-cmd -h $TEST_USER@$int_bastion_hostname "cp -v ~/.containers/auth.json $subdir/aba/mirror/regcreds/pull-secret-mirror.json"

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Verifying access to the mirror registry $reg_host:$reg_port now succeeds" "aba --dir $subdir/aba/mirror verify"

######################

# Now, this works
test-cmd -h $TEST_USER@$int_bastion_hostname -r 15 1 -m "Loading images into mirror registry $reg_host:$reg_port" "aba --dir $subdir/aba load --retry"

test-cmd                                             -m "Delete loaded image set 1 file" "rm -v mirror/save/mirror_*.tar"
test-cmd -h $TEST_USER@$int_bastion_hostname         -m "Delete loaded image set 1 file on registry" "rm -v $subdir/aba/mirror/save/mirror_*.tar"

test-cmd -h $TEST_USER@$int_bastion_hostname "rm -rf $subdir/aba/compact" 
test-cmd -m "Copy over shortcuts.conf, needed for next test command" scp .shortcuts.conf $TEST_USER@$int_bastion_hostname:$subdir/aba/shortcuts.conf
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Install compact cluster with default_target=[$default_target]" "aba --dir $subdir/aba compact $default_target" 
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Deleting cluster (if it exists)" "aba --dir $subdir/aba/compact delete" 

#############
### Tests for standard cluster configs, e.g. bonding and vlan
mylog "Starting tests to check out agent config files for various cluster configs, e.g. bonding and vlan"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Delete standard dir: $subdir/aba/standard" rm -rf $subdir/aba/standard
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Generate cluster.conf" "aba --dir $subdir/aba cluster --name standard --type standard --step cluster.conf"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Setting machine_network" "sed -i 's#^machine_network=.*#machine_network=10.0.0.0/22 #g' $subdir/aba/standard/cluster.conf"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Setting starting_ip" "sed -i 's/^starting_ip=.*/starting_ip=10.0.2.253 /g' $subdir/aba/standard/cluster.conf"

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Create iso to ensure config files are valid" "aba --dir $subdir/aba/standard iso" 

# Test node0 is accessible - start
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Upload iso" "aba --dir $subdir/aba/standard upload" 
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Refresh VMs" "aba --dir $subdir/aba/standard refresh" 
test-cmd -h $TEST_USER@$int_bastion_hostname -m  "Waiting ~3 mins for node0 to be reachable" "i=0; until aba --dir $subdir/aba/standard ssh --cmd hostname; do let i=\$i+1; [ \$i -gt 18 ] && exit 1; echo -n .; sleep 10; done"
test-cmd -h $TEST_USER@$int_bastion_hostname -m  "Waiting ~2 mins for node0 to config NTP" "i=0; until aba --dir $subdir/aba/standard ssh --cmd 'chronyc sources' | grep $ntp_ip ; do let i=\$i+1; [ \$i -gt 12 ] && exit 1; echo -n $i; sleep 10; done"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Refresh VMs" "aba --dir $subdir/aba/standard delete" 
# Test node0 is accessible - ned

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Clean up" aba -d $subdir/aba/standard clean

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Adding 2nd interface for bonding" "sed -i 's/^.*port1=.*/port1=ens192 /g' $subdir/aba/standard/cluster.conf"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Show config" "grep -e ^vlan= -e ^port0= -e ^port1= $subdir/aba/standard/cluster.conf | awk '{print $1}'"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Create iso to ensure config files are valid" "aba --dir $subdir/aba/standard iso" 

# Test node0 is accessible - start
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Upload iso" "aba --dir $subdir/aba/standard upload" 
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Refresh VMs" "aba --dir $subdir/aba/standard refresh" 
test-cmd -h $TEST_USER@$int_bastion_hostname -m  "Waiting ~3 mins for node0 to be reachable" "i=0; until aba --dir $subdir/aba/standard ssh --cmd hostname; do let i=\$i+1; [ \$i -gt 18 ] && exit 1; echo -n .; sleep 10; done"
test-cmd -h $TEST_USER@$int_bastion_hostname -m  "Waiting ~2 mins for node0 to config NTP" "i=0; until aba --dir $subdir/aba/standard ssh --cmd 'chronyc sources' | grep $ntp_ip ; do let i=\$i+1; [ \$i -gt 12 ] && exit 1; echo -n $i; sleep 10; done"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Refresh VMs" "aba --dir $subdir/aba/standard delete" 
# Test node0 is accessible - end

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Clean up" aba -d $subdir/aba/standard clean

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Adding vlan" "sed -i 's/^.*vlan=.*/vlan=888 /g' $subdir/aba/standard/cluster.conf"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Show config" "grep -e ^vlan= -e ^port0= -e ^port1= $subdir/aba/standard/cluster.conf | awk '{print $1}'"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Create iso to ensure config files are valid" "aba --dir $subdir/aba/standard iso" 
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Clean up" aba -d $subdir/aba/standard clean
# Note, I can't test vlan in my lab

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Remove 2nd interface, port1" "sed -i 's/^port1=.*/#port1= /g' $subdir/aba/standard/cluster.conf"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Show config" "grep -e ^vlan= -e ^port0= -e ^port1= $subdir/aba/standard/cluster.conf | awk '{print $1}'"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Create iso to ensure config files are valid" "aba --dir $subdir/aba/standard iso" 
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Clean up" aba -d $subdir/aba/standard clean
# Note, I can't test vlan in my lab

mylog "Completed tests to check out agent config files for various cluster configs, e.g. bonding and vlan"
#############

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Cleaning up $subdir/aba/sno" "rm -rf $subdir/aba/sno" 

#### TESTING ACM + MCH 
# Adjust size of SNO cluster for ACM install 
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Generate cluster.conf" "aba --dir $subdir/aba cluster --name sno --type sno --step cluster.conf"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Check cluster.conf exists" "test -s $subdir/aba/sno/cluster.conf"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Upgrade cluster.conf" "sed -i 's/^master_mem=.*/master_mem=40/g' $subdir/aba/sno/cluster.conf"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Upgrade cluster.conf" "sed -i 's/^master_cpu_count=.*/master_cpu_count=24/g' $subdir/aba/sno/cluster.conf"
#### TESTING ACM + MCH 

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Adding 2nd interface for bonding" "sed -i 's/^.*port1=.*/port1=ens192/g' $subdir/aba/sno/cluster.conf"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Adding 2nd dns ip addr" "sed -i 's/^dns_servers=.*/dns_servers=10.0.1.8,10.0.1.8/g' $subdir/aba/sno/cluster.conf"

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Install sno cluster with 'aba --dir $subdir/aba sno $default_target'" "aba --dir $subdir/aba sno $default_target" 


######################
# Now simulate adding more images to the mirror registry
######################

mylog Adding vote-app image to imageset conf file on `hostname`

[ "$oc_mirror_version" = "v1" ] && gvk=v1alpha2 || gvk=v2alpha1

# For oc-miror v2 (v2 needs to have only the images that are needed for this next save/load cycle)
[ -f mirror/save/imageset-config-save.yaml ] && cp -v mirror/save/imageset-config-save.yaml mirror/save/imageset-config-save.yaml.$(date "+%Y%m%d_%H%M%S")
if [ "$oc_mirror_version" = "v2" ]; then
tee mirror/save/imageset-config-save.yaml <<END
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/$gvk
mirror:
END
fi
# For oc-miror v2

# Note that if multiple 'additionalImages:' lines are added, it seems to cause oc-mirror v1 to delete images unexpectedly
tee -a mirror/save/imageset-config-save.yaml <<END
  additionalImages:
  - name: quay.io/sjbylo/flask-vote-app:latest
END

test-cmd -r 15 1 -m "Saving 'vote-app' image to local disk" "aba --dir mirror save  --retry"

test-cmd -m "Checking existance of file mirror/save/mirror_*_000000.tar" "ls -lh mirror/save/mirror_*\.tar"

mylog "Simulate an 'inc' tar copy of 'mirror/save/mirror_*.tar' file from `hostname` over to internal bastion @ $TEST_USER@$int_bastion_hostname"
test-cmd -m "Create tmp dir" mkdir -p ~/tmp
test-cmd -m "Delete any old tar file (if any)" rm -fv ~/tmp/file.tar
test-cmd -m "Create the tar file.  Should only contain (more-or-less) the 'image set' archive file" aba --dir mirror inc out=~/tmp/file.tar
test-cmd -m "Check size of tar file" "ls -l ~/tmp/file.tar"
test-cmd -m "Copy tar file over to $int_bastion_hostname" scp ~/tmp/file.tar $TEST_USER@$int_bastion_hostname:
test-cmd -m "Remove local tar file" rm -v ~/tmp/file.tar  # Remove file on client side
mylog "The following untar command should unpack the file aba/mirror/save/mirror_*.tar only"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Unpacking tar file" "tar -C $subdir -xvf file.tar"   
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Removing tar file" "rm -v file.tar"

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Verifying existance of file '$subdir/aba/mirror/save/mirror_*.tar'" "ls -lh $subdir/aba/mirror/save/mirror_*\.tar"

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Verifying access to mirror registry $reg_host:$reg_port" "aba --dir $subdir/aba/mirror verify"

[ "$oc_mirror_ver_override" = "v2" ] && test-cmd -m "Copy image set file over also (oc-mirror v2 needs it) to $int_bastion_hostname" scp mirror/save/imageset-config-save.yaml $TEST_USER@$int_bastion_hostname:$subdir/aba/mirror/save

test-cmd -h $TEST_USER@$int_bastion_hostname -r 15 1 -m "Loading images into mirror $reg_host:$reg_port" "aba --dir $subdir/aba/mirror load --retry"

test-cmd                                     -m "Delete loaded image set 2 file" rm -v mirror/save/mirror_*.tar
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Delete loaded image set 2 file on registry" rm -v $subdir/aba/mirror/save/mirror_*.tar

# Is the cluster can be reached ... use existing cluster
#if test-cmd -i -h $TEST_USER@$int_bastion_hostname -m "Checking if sno cluster up" "aba --dir $subdir/aba/sno --cmd 'oc get clusterversion'"; then
# Do not use test-cmd here since that will never retiurn the true result!
mylog "Cecking if cluster was installed or not, if error, then not!"
if ssh $TEST_USER@$int_bastion_hostname "aba --dir $subdir/aba/sno --cmd 'oc get clusterversion'"; then
	mylog "Using existing sno cluster"
else
	mylog "Creating the sno cluster"

	# Run 'aba --dir mirror clean' here since we (might be) are re-installing another cluster *with the same mac addresses*! So, install might fail.
	test-cmd -h $TEST_USER@$int_bastion_hostname -m "Cleaning sno dir" "aba --dir $subdir/aba/sno clean"  # This does not remove the cluster.conf file, so cluster can be re-installed 
	test-cmd -h $TEST_USER@$int_bastion_hostname -m "Installing sno cluster" "aba --dir $subdir/aba sno --mmem 24 --mcpu 12"  
	test-cmd -h $TEST_USER@$int_bastion_hostname -r 15 3 -m "Check 'Running'" "cd $subdir; oc --kubeconfig=aba/sno/iso-agent-based/auth/kubeconfig get co"
	test-cmd -h $TEST_USER@$int_bastion_hostname -m "Checking cluster operators" aba --dir $subdir/aba/sno cmd
fi

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Checking cluster operator status on cluster sno" "aba --dir $subdir/aba/sno cmd"

######################

###test-cmd -h $TEST_USER@$int_bastion_hostname -m "Deploying vote-app on cluster" $subdir/aba/test/deploy-test-app.sh $subdir
test-cmd -r 2 10 -h $TEST_USER@$int_bastion_hostname -m "Delete project 'demo'" "aba --dir $subdir/aba/sno --cmd 'oc delete project demo || true'"
test-cmd -r 2 10 -h $TEST_USER@$int_bastion_hostname -m "Create project 'demo'" "aba --dir $subdir/aba/sno --cmd 'oc new-project demo'"

test-cmd -m "Pausing 30s - sometimes 'oc new-app' fails!" sleep 30
# error: Post "https://api.sno.example.com:6443/api/v1/namespaces/demo/services": dial tcp 10.0.1.201:6443: connect: connection refused
test-cmd -r 5 10 -h $TEST_USER@$int_bastion_hostname -m "Launch vote-app" "aba --dir $subdir/aba/sno --cmd 'oc new-app --insecure-registry=true --image $reg_host:$reg_port/$reg_path/sjbylo/flask-vote-app --name vote-app -n demo'"

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Waiting for vote-app rollout" "aba --dir $subdir/aba/sno --cmd 'oc rollout status deployment vote-app -n demo'"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Deleting vote-app" "aba --dir $subdir/aba/sno --cmd 'oc delete project demo'"

mylog "Adding advanced-cluster-management operator images to mirror/save/imageset-config-save.yaml file on `hostname`"

export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

test-cmd -m "Checking for file mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml" "test -s mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml"
test-cmd -m "Checking for advanced-cluster-management in mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml" "cat mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | grep advanced-cluster-management$"
test-cmd -m "Checking for multicluster-engine in mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml" "cat mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | grep multicluster-engine$"

mylog Appending redhat-operator-index:v$ocp_ver_major header into mirror/save/imageset-config-save.yaml on `hostname`

# For oc-miror v2 (v2 needs to have only the images that are needed for this next save/load cycle)
[ -f mirror/save/imageset-config-save.yaml ] && cp -v mirror/save/imageset-config-save.yaml mirror/save/imageset-config-save.yaml.$(date "+%Y%m%d_%H%M%S")
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

# Append the correct values for each operator
test-cmd -m "Adding advanced-cluster-management  operator to mirror/save/imageset-config-save.yaml on `hostname`" "grep -A2 -e 'name: advanced-cluster-management$' mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | tee -a mirror/save/imageset-config-save.yaml"

test-cmd -m "Adding multicluster-engine          operator to mirror/save/imageset-config-save.yaml on `hostname`" "grep -A2 -e 'name: multicluster-engine$'         mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | tee -a mirror/save/imageset-config-save.yaml"
### WORKING BUT 60+ GB OF DATA !!! ### test-cmd -m "Adding multicluster-engine          operator to mirror/save/imageset-config-save.yaml on `hostname`" "grep     -e 'name: multicluster-engine$'         mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml | tee -a mirror/save/imageset-config-save.yaml"   # Fetch all ??


test-cmd -r 15 1 -m "Saving advanced-cluster-management images to local disk" "aba --dir mirror save  --retry"

test-cmd -m "Listing image set files created" "ls -lh mirror/save/mirror_*.tar"
mylog "Use 'scp' to copy mirror/save/mirror_*.tar file from `hostname` over to internal bastion @ $TEST_USER@$int_bastion_hostname"
test-cmd -m "Copy image set 3 file to $int_bastion_hostname" "scp mirror/save/mirror_*.tar $TEST_USER@$int_bastion_hostname:$subdir/aba/mirror/save"

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Verifying existance of file '$subdir/aba/mirror/save/mirror_*\.tar'" "ls -lh $subdir/aba/mirror/save/mirror_*\.tar"

test-cmd -h $TEST_USER@$int_bastion_hostname -m "Verifying mirror registry access $reg_host:$reg_port" "aba --dir $subdir/aba/mirror verify"

[ "$oc_mirror_ver_override" = "v2" ] && test-cmd -m "Copy image set file over also (oc-mirror v2 needs it) to $int_bastion_hostname" scp mirror/save/imageset-config-save.yaml $TEST_USER@$int_bastion_hostname:$subdir/aba/mirror/save

test-cmd -h $TEST_USER@$int_bastion_hostname -r 15 1 -m "Loading images into mirror $reg_host:$reg_port on remote host" "aba --dir $subdir/aba/mirror load --retry"

test-cmd                                     -m "Delete loaded image set 3 file" rm -v mirror/save/mirror_*.tar
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Delete loaded image set 3 file on registry" rm -v $subdir/aba/mirror/save/mirror_*.tar

test-cmd -h $TEST_USER@$int_bastion_hostname -r 15 3 -m "Run 'day2' on sno cluster" "aba --dir $subdir/aba/sno day2"

test-cmd -m "Pausing 30s" sleep 30

test-cmd -h $TEST_USER@$int_bastion_hostname -r 15 3 -m "Checking available Operators on sno cluster" "aba --dir $subdir/aba/sno --cmd 'oc get packagemanifests -n openshift-marketplace' | grep advanced-cluster-management"

# Needed for acm-subs.yaml
test-cmd -m "Copy over test dir for the acm-*.yaml files" scp -rp test $TEST_USER@$int_bastion_hostname:$subdir/aba

# Need to fetch the actual channel name from the operator catalog that's in use
acm_channel=$(cat mirror/.index/redhat-operator-index-v$ocp_ver_major | grep ^advanced-cluster-management | awk '{print $NF}' | tail -1)
[ "$acm_channel" ] && test-cmd -h $TEST_USER@$int_bastion_hostname -r 5 3 -m "Setting correct channel in test/acm-subs.yaml" "sed -i \"s/channel: release-.*/channel: $acm_channel/g\" $subdir/aba/test/acm-subs.yaml"
test-cmd -h $TEST_USER@$int_bastion_hostname -r 5 3 -m "Log into the cluster" "source <(aba -d $subdir/aba/sno login)"
test-cmd -h $TEST_USER@$int_bastion_hostname -r 3 3 -m "Install ACM Operator" "i=0; until oc apply -f $subdir/aba/test/acm-subs.yaml; do let i=\$i+1; [ \$i -ge 5 ] && exit 1; echo -n \"\$i \"; sleep 10; done"

###test-cmd sleep 60

test-cmd -h $TEST_USER@$int_bastion_hostname -r 3 3 -m "Install Multiclusterhub" "i=0; until oc apply -f $subdir/aba/test/acm-mch.yaml; do let i=\$i+1; [ \$i -ge 5 ] && exit 1; echo -n \"\$i \"; sleep 10; done"

test-cmd -m "Leave time for ACM to deploy ..." sleep 30

# Need 'cd' here due to '=$subdir' not 'resolving' ok
# cd $subdir only works in "" .. and will work for root or user
test-cmd -h $TEST_USER@$int_bastion_hostname -r 3 3 -m "Waiting up to 8 mins for acm hub status is 'Running'" "cd $subdir; i=0; while ! oc --kubeconfig=aba/sno/iso-agent-based/auth/kubeconfig get multiclusterhub multiclusterhub -n open-cluster-management -o jsonpath={.status.phase}| grep -i running; do echo -n .; let i=\$i+1; [ \$i -gt 48 ] && exit 1; sleep 10; done"
#### TESTING ACM + MCH 

# Apply NTP config, but don't wait for it to complete!
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Initiate NTP config but not wait for completion" "aba --dir $subdir/aba/sno day2-ntp"

test-cmd -m "Pausing 5s ..." sleep 5

# Keep it # test-cmd -h $TEST_USER@$int_bastion_hostname -m "Deleting sno cluster" "aba --dir $subdir/aba/sno delete" 
test-cmd -h $TEST_USER@$int_bastion_hostname -m "If cluster up, stopping cluster" "cd $subdir/aba/;. <(aba -d sno shell) && . <(aba --dir sno login) && yes|aba --dir sno shutdown || echo cluster shutdown failure"

######################

###trap - SIGINT

mylog
mylog "===> Completed test $0"
mylog

[ -f test/test.log ] && cp test/test.log test/test.log.bak || true

echo SUCCESS $0
