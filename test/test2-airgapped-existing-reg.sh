#!/bin/bash -x
# This test installs a mirror reg. on the internal bastion (just for testing) and then
# treats that registry as an "existing registry" in the test internal workflow. 

# Required: 2 bastions (internal and external), for internal (no direct Internet) only yum works via a proxy. For external, the proxy is fully configured. 
# I.e. Internal bastion has no access to the Internet.  External has full access. 
# Ensure passwordless ssh access from bastion1 (external) to int_bastion (internal). Script uses tar+ssh to copy over the aba repo. 
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

cd `dirname $0`
cd ..  # Change into "aba" dir

rm -fr ~/.containers ~/.docker
rm -f ~/.aba.previous.backup

int_bastion=registry.example.com
bastion_vm=bastion-internal-$internal_bastion_rhel_ver
ntp=10.0.1.8 # If available

source scripts/include_all.sh no-trap # Need for below normalize fn() calls
source test/include.sh
trap - ERR # We don't want this trap during testing.  Needed for below normalize fn() calls

[ ! "$target_full" ] && default_target="target=iso"   # Default is to generate 'iso' only on some tests
mylog default_target=$default_target

mylog
mylog "===> Starting test $0"
mylog "Test to integrate an existing reg. on $int_bastion and save + copy + load images.  Install sno ocp and a test app."
mylog

######################
# Set up test 

#subdir=~/
subdir=~/subdir   # Unpack repo tar into this dir on internal bastion

# Exec script with any arg to skip reg. install and load
##if [ ! "$1" ] && ! ssh steve@$int_bastion -- make -C $subdir/aba/mirror verify; then
if [ ! "$1" ]; then
	echo
	echo Setting up test $(basename $0)
	echo

	which make || sudo dnf install make -y

	v=4.16.3
	#v=4.15.22

	# clean up all, assuming reg. is not running (deleted)
	#test-cmd "echo ocp_version=$v > aba.conf"
	####make -C ~/aba distclean --force
	mv cli cli.m && mkdir cli && cp cli.m/Makefile cli && aba distclean --force 1; rm -rf cli && mv cli.m cli
	#test-cmd "make -C mirror clean"
	rm -rf sno compact standard 

	rm -f aba.conf
	vf=~/.vmware.conf
	[ ! "$VER_OVERRIDE" ] && VER_OVERRIDE=latest
	test-cmd -m "Configure aba.conf for version '$VER_OVERRIDE' and vmware $vf" aba --channel fast --version $VER_OVERRIDE ### --vmw $vf
	#test-cmd -m "Configure aba.conf for version 'latest' and vmware $vf" aba --version latest ## --vmw $vf
	# Set up govc 
	cp $vf vmware.conf 
	sed -i "s#^VC_FOLDER=.*#VC_FOLDER=/Datacenter/vm/abatesting#g" vmware.conf

	mylog "Setting ask="
	sed -i 's/^ask=[^ \t]\{1,\}\([ \t]\{1,\}\)/ask=\1 /g' aba.conf

	mylog "Setting ntp_servers=$ntp" 
	[ "$ntp" ] && sed -i "s/^ntp_servers=\([^#]*\)#\(.*\)$/ntp_servers=$ntp    #\2/g" aba.conf

	mylog "Setting op_sets=\"abatest\" in aba.conf"
	sed -i "s/^op_sets=.*/op_sets=\"abatest\" /g" aba.conf
	echo kiali-ossm > templates/operator-set-abatest 

	source <(normalize-aba-conf)

	# Be sure this file exists
	test-cmd "make -C test mirror-registry.tar.gz"

	#################################
	# Set up mirror.conf 

	make -C mirror mirror.conf

	## test the internal bastion ($int_bastion) as mirror
	mylog "Setting reg_host=$int_bastion"
	sed -i "s/registry.example.com/$int_bastion /g" ./mirror/mirror.conf
	#sed -i "s#.*reg_ssh_key=.*#reg_ssh_key=~/.ssh/id_rsa #g" ./mirror/mirror.conf

	mylog "Setting op_sets=\"abatest\""
	sed -i "s/^.*op_sets=.*/op_sets=\"abatest\" /g" ./mirror/mirror.conf
	echo kiali-ossm > templates/operator-set-abatest 

	make -C cli ~/bin/govc

	#################################
	source <(normalize-vmware-conf)  # Needed for govc below

	mylog Revert a snapshot and power on the internal bastion vm
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
	#################################

	# Delete images
	ssh steve@$int_bastion -- "sudo dnf install podman -y && podman system prune --all --force && podman rmi --all && sudo rm -rf ~/.local/share/containers/storage && rm -rf ~/test"
	# This file is not needed in a fully air-gapped env. 
	ssh steve@$int_bastion -- "rm -fv ~/.pull-secret.json"
	# Want to test fully disconnected 
	ssh steve@$int_bastion -- "sed -i 's|^source ~/.proxy-set.sh|# aba test # source ~/.proxy-set.sh|g' ~/.bashrc"
	# Ensure home is empty!  Avoid errors where e.g. hidden files cause reg. install failing. 
	ssh steve@$int_bastion -- "rm -rfv ~/*"

	# Just be sure a valid govc config file exists on internal bastion
	scp $vf steve@$int_bastion: 
	##scp ~/.vmware.conf testy@$int_bastion: 

	#uname -n | grep -qi ^fedora$ && sudo mount -o remount,size=6G /tmp   # Needed by oc-mirror ("make save") when Operators need to be saved!
	# Try to fix "out of space" error when generating the op. index
	cat /etc/redhat-release | grep -q ^Fedora && sudo mount -o remount,size=20G /tmp && rm -rf /tmp/render-registry-*


	ssh steve@$int_bastion "rpm -q make  || sudo yum install make -y"

	mylog "Install 'existing' test mirror registry on internal bastion: $int_bastion"
	test-cmd test/reg-test-install-remote.sh $int_bastion

	################################

	test-cmd -m "Cleaning mirror dir" make -C mirror clean

	test-cmd -h steve@$int_bastion -m "Create sub dir on remote host" "rm -rf $subdir && mkdir $subdir"
else
	echo
	echo Skipping setting up of test $(basename $0)
	echo
fi

mylog ============================================================
mylog Starting test $(basename $0)
mylog ============================================================
mylog "Test to integrate with existing reg. on $int_bastion and then sync and save/load images."
mylog

# Fetch the config
source <(cd mirror; normalize-mirror-conf)
mylog "Using container mirror at $reg_host:$reg_port and using reg_ssh_user=$reg_ssh_user reg_ssh_key=$reg_ssh_key"

test-cmd -r 20 3 -m "Saving images to local disk on `hostname`" make save 

# Smoke test!
[ ! -s mirror/save/mirror_seq1_000000.tar ] && echo "Aborting test as there is no save/mirror_seq1_000000.tar file" && exit 1

mylog "'make tar' and copy (ssh) files over to internal bastion: steve@$int_bastion"
test-cmd -m "Create the 'full' tar file and unpack on host $int_bastion" "aba -d mirror tar --out - | ssh steve@$int_bastion -- tar -C $subdir -xvf -"
test-cmd -h steve@$int_bastion -m "Install aba" "$subdir/aba/install"

test-cmd -i -h steve@$int_bastion -m "Loading images into mirror registry (without regcreds/ fails with 'Not a directory')" "make -C $subdir/aba load" # This user's action is expected to fail since there are no login credentials for the "existing reg."

# But, now regcreds/ is created...
mylog "Simulating a manual config of 'existing' registry login credentials into mirror/regcreds/ on host: steve@$int_bastion"

ssh steve@$int_bastion "ls -l $subdir/aba/mirror"  
ssh steve@$int_bastion "cp -v ~/quay-install/quay-rootCA/rootCA.pem $subdir/aba/mirror/regcreds/"  
ssh steve@$int_bastion "cp -v ~/.containers/auth.json $subdir/aba/mirror/regcreds/pull-secret-mirror.json"

test-cmd -h steve@$int_bastion -m "Verifying access to the mirror registry $reg_host:$reg_port now succeeds" "make -C $subdir/aba/mirror verify"

######################

# Now, this works
test-cmd -h steve@$int_bastion -r 20 3 -m "Loading images into mirror registry $reg_host:$reg_port" "make -C $subdir/aba load" 

ssh steve@$int_bastion "rm -rf $subdir/aba/compact" 
test-cmd -h steve@$int_bastion -m "Install compact cluster with default_target=[$default_target]" "make -C $subdir/aba compact $default_target" 
test-cmd -h steve@$int_bastion -m "Deleting cluster (if it exists)" "make -C $subdir/aba/compact delete" 

ssh steve@$int_bastion "rm -rf $subdir/aba/sno" 

#### TESTING ACM + MCH 
# Adjust size of SNO cluster for ACM install 
test-cmd -h steve@$int_bastion -m "Generate cluster.conf" "make -C $subdir/aba cluster name=sno type=sno target=cluster.conf"
test-cmd -h steve@$int_bastion -m "Check cluster.conf exists" "test -s $subdir/aba/sno/cluster.conf"
test-cmd -h steve@$int_bastion -m "Upgrade cluster.conf" "sed -i 's/^master_mem=.*/master_mem=40/g' $subdir/aba/sno/cluster.conf"
test-cmd -h steve@$int_bastion -m "Upgrade cluster.conf" "sed -i 's/^master_cpu_count=.*/master_cpu_count=24/g' $subdir/aba/sno/cluster.conf"
#### TESTING ACM + MCH 

test-cmd -h steve@$int_bastion -m "Adding 2nd interface for bonding" "sed -i 's/^.*port1=.*/port1=ens192/g' $subdir/aba/sno/cluster.conf"
test-cmd -h steve@$int_bastion -m "Adding 2nd dns ip addr" "sed -i 's/^dns_servers=.*/dns_servers=10.0.1.8,10.0.1.8/g' $subdir/aba/sno/cluster.conf"

test-cmd -h steve@$int_bastion -m "Install sno cluster with 'make -C $subdir/aba sno $default_target'" "make -C $subdir/aba sno $default_target" 

######################
# Now simulate adding more images to the mirror registry
######################

mylog Adding ubi images to imageset conf file on `hostname`

cat >> mirror/save/imageset-config-save.yaml <<END
  additionalImages:
  - name: quay.io/sjbylo/flask-vote-app:latest
END

test-cmd -r 20 3 -m "Saving 'vote-app' image to local disk" "make -C mirror save"

### mylog "'make inc' and ssh files over to internal bastion: steve@$int_bastion"
### make -s -C mirror inc out=- | ssh steve@$int_bastion -- tar xvf -
#
### mylog "'scp mirror/save/mirror_seq2.tar' file from `hostname` over to internal bastion: steve@$int_bastion"
### scp mirror/save/mirror_seq2.tar steve@$int_bastion $subdir/aba/mirror/save

mylog "Simulate an 'inc' tar copy of 'mirror/save/mirror_seq2.tar' file from `hostname` over to internal bastion: steve@$int_bastion"
test-cmd -m "Create tmp dir" mkdir -p ~/tmp
test-cmd -m "rm and old tar file" rm -f ~/tmp/file.tar
test-cmd -m "Create the tar file.  Should only contain (more-or-less) the seq2 file" make -s -C mirror inc out=~/tmp/file.tar
test-cmd -m "Check size of tar file" "ls -l ~/tmp/file.tar"
test-cmd -m "Copy tar file over to $int_bastion" scp ~/tmp/file.tar steve@$int_bastion:
test-cmd -m "Remove local tar file" rm -f ~/tmp/file.tar  # Remove file on client side
mylog "The following untar command should unpack the file aba/mirror/save/mirror_seq2.tar only"
test-cmd -h steve@$int_bastion -m "Unpacking tar file" "tar -C $subdir -xvf file.tar"   
test-cmd -h steve@$int_bastion -m "Removing tar file" "rm -f file.tar"

test-cmd -h steve@$int_bastion -m "Verifying access to mirror registry $reg_host:$reg_port" "make -C $subdir/aba/mirror verify"

test-cmd -h steve@$int_bastion -r 20 3 -m "Loading images into mirror $reg_host:$reg_port" "make -C $subdir/aba/mirror load" 

# Is the cluster can be reached ... use existing cluster
#if test-cmd -i -h steve@$int_bastion -m "Checking if sno cluster up" "make -C $subdir/aba/sno cmd cmd='oc get clusterversion'"; then
# Do not use test-cmd here since that will never retiurn the true result!
mylog "Cecking if cluster was installed or not, if error, then not!"
if ssh steve@$int_bastion "make -C $subdir/aba/sno cmd cmd='oc get clusterversion'"; then
	mylog "Using existing sno cluster"
else
	mylog "Creating the sno cluster"

	# Run 'make -C mirror clean' here since we (might be) are re-installing another cluster *with the same mac addresses*! So, install might fail.
	test-cmd -h steve@$int_bastion -m "Cleaning sno dir" "make -C $subdir/aba/sno clean"  # This does not remove the cluster.conf file, so cluster can be re-installed 
	test-cmd -h steve@$int_bastion -m "Installing sno cluster" "make -C $subdir/aba/sno"  
	test-cmd -h steve@$int_bastion -m "Checking cluster operators" aba --dir $subdir/aba/sno cmd
fi

test-cmd -h steve@$int_bastion -m "Checking cluster operator status on cluster sno" "make -C $subdir/aba/sno cmd"

######################

###test-cmd -h steve@$int_bastion -m "Deploying vote-app on cluster" $subdir/aba/test/deploy-test-app.sh $subdir
test-cmd -h steve@$int_bastion -m "Create project 'demo'" "make -C $subdir/aba/sno cmd cmd='oc new-project demo'"
test-cmd -h steve@$int_bastion -m "Launch vote-app" "make -C $subdir/aba/sno cmd cmd='oc new-app --insecure-registry=true --image $reg_host:$reg_port/$reg_path/sjbylo/flask-vote-app --name vote-app -n demo'"
test-cmd -h steve@$int_bastion -m "Wait for vote-app rollout" "make -C $subdir/aba/sno cmd cmd='oc rollout status deployment vote-app -n demo'"
test-cmd -h steve@$int_bastion -m "Deleting vote-app" "make -C $subdir/aba/sno cmd cmd='oc delete project demo'"

mylog "Adding advanced-cluster-management operator images to mirror/save/imageset-config-save.yaml file on `hostname`"

export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)

cat >> mirror/save/imageset-config-save.yaml <<END
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v$ocp_ver_major
    packages:
END

# Append the correct values for each operator
grep -A2 -e "name: advanced-cluster-management$"	mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml >> mirror/save/imageset-config-save.yaml
grep -A2 -e "name: multicluster-engine$"  	mirror/imageset-config-operator-catalog-v${ocp_ver_major}.yaml >> mirror/save/imageset-config-save.yaml

#      - name: multicluster-engine
#        channels:
#        - name: stable-2.5
#END

test-cmd -r 20 3 -m "Saving advanced-cluster-management images to local disk" "make -C mirror save"

### mylog Tar+ssh files from `hostname` over to internal bastion: steve@$int_bastion 
### make -s -C mirror inc out=- | ssh steve@$int_bastion -- tar xvf -
mylog "'scp mirror/save/mirror_seq3.tar' file from `hostname` over to internal bastion: steve@$int_bastion"
scp mirror/save/mirror_seq3*.tar steve@$int_bastion:$subdir/aba/mirror/save

test-cmd -h steve@$int_bastion -m "Verifying mirror registry access $reg_host:$reg_port" "make -C $subdir/aba/mirror verify"

test-cmd -h steve@$int_bastion -r 20 3 -m "Loading images into mirror $reg_host:$reg_port" "make -C $subdir/aba/mirror load" 

test-cmd -h steve@$int_bastion -r 20 3 -m "Run 'day2' on sno cluster" "make -C $subdir/aba/sno day2" 

test-cmd -m "Pausing 30s" sleep 30

test-cmd -h steve@$int_bastion -r 20 3 -m "Checking available Operators on sno cluster" "make -C $subdir/aba/sno cmd cmd='oc get packagemanifests -n openshift-marketplace'" | grep advanced-cluster-management

#### TESTING ACM + MCH 
# 30 attempts, always waiting 20s (fixed value) secs between attempts

# Need to fetch the actual channel name from the operator catalog that's in use
acm_channel=$(cat mirror/.redhat-operator-index-v*[0-9] | grep ^advanced-cluster-management | awk '{print $NF}' | tail -1)
[ "$acm_channel" ] && sed -i "s/channel: release-.*/channel: $acm_channel/g" ../test/acm-subs.yaml
test-cmd -h steve@$int_bastion -r 15 1 -m "Install ACM Operator" "make -C $subdir/aba/sno cmd cmd='oc apply -f ../test/acm-subs.yaml'"
sleep 60

test-cmd -h steve@$int_bastion -r 15 1 -m "Install Multiclusterhub" "make -C $subdir/aba/sno cmd cmd='oc apply -f ../test/acm-mch.yaml'"
sleep 300
# THIS TEST ALWAYS EXIT 0 # test-cmd -h steve@$int_bastion -r 15 1 -m "Check Multiclusterhub status is 'Running'" "make -C $subdir/aba/sno cmd cmd='oc get multiclusterhub multiclusterhub -n open-cluster-management -o jsonpath={.status.phase} | grep -i running'"
test-cmd -h steve@$int_bastion -r 15 1 -m "Check hub status is 'running'" "oc --kubeconfig=$subdir/aba/sno/iso-agent-based/auth/kubeconfig get multiclusterhub multiclusterhub -n open-cluster-management -o jsonpath={.status.phase}| grep -i running"
test-cmd -h steve@$int_bastion -r 15 1 -m "Output hub status" "oc --kubeconfig=$subdir/aba/sno/iso-agent-based/auth/kubeconfig get multiclusterhub multiclusterhub -n open-cluster-management -o jsonpath={.status}| grep -i running"
#### TESTING ACM + MCH 

# Apply config, but don't wait for it to complete!
test-cmd -h steve@$int_bastion -m "Initiate NTP config but not wait for completion" "make -C $subdir/aba/sno day2-ntp"

# Keep it # test-cmd -h steve@$int_bastion -m "Deleting sno cluster" "make -C $subdir/aba/sno delete" 
####test-cmd -h steve@$int_bastion -m "Stopping sno cluster" "yes|make -C $subdir/aba/sno shutdown" 
test-cmd -h steve@$int_bastion -m "If cluster up, stopping cluster" ". <(make -sC sno shell) && . <(make -sC sno login) && yes|make -C sno shutdown || echo cluster shutdown failure"

######################

## keep it up # test-cmd -m "Clean up 'existing' mirror registry on internal bastion" test/reg-test-uninstall-remote.sh $int_bastion

#test-cmd "make distclean --force"

## keep it up # make -C ~/aba distclean --force
## keep it up # mv cli cli.m && mkdir cli && cp cli.m/Makefile cli && make distclean --force; rm -rf cli && mv cli.m cli

mylog
mylog "===> Completed test $0"
mylog

[ -f test/test.log ] && cp test/test.log test/test.log.bak

echo SUCCESS $0
