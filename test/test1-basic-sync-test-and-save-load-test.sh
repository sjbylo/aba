#!/bin/bash -x
# This test is for a connected bastion.  It will install registry on remote bastion and then sync images and install clusters, 
# ... then savd/load images and install clusters. 
# This test requires a valid ~/.vmware.conf file.

export INFO_ABA=1
export ABA_TESTING=1  # No usage reporting
[ ! "$TEST_CHANNEL" ] && export TEST_CHANNEL=stable
hash -r  # Forget all command locations in $PATH

### TEST for clean start with or without the rpms.  
if true; then
	# Assuming user will NOT install all rpms in advance and aba will install them.
	#sudo dnf remove git hostname make jq bind-utils nmstate net-tools skopeo python3-jinja2 python3-pyyaml openssl coreos-installer ncurses -y
	sudo dnf remove git hostname make jq bind-utils nmstate net-tools skopeo python3-jinja2 python3-pyyaml openssl coreos-installer         -y
else
	# FIXME: test for pre-existing rpms!  In this case we don't want yum to run *at all* as it may error out
	# Assuming user will install all rpms in advance.
	sudo dnf install -y $(cat templates/rpms-internal.txt)
	sudo dnf install -y $(cat templates/rpms-external.txt)
fi

[ ! "$TEST_USER" ] && TEST_USER=$(whoami)

# On Fedora, Try to fix "out of space" error when generating the op. index
cat /etc/redhat-release | grep -q ^Fedora && sudo mount -o remount,size=20G /tmp && rm -rf /tmp/render-registry-*

#uname -n | grep -qi ^fedora$ && sudo mount -o remount,size=16G /tmp

cd `dirname $0`
cd ..

rm -fr ~/.containers ~/.docker
rm -f ~/.aba.previous.backup
rm -f ~/.ssh/quay_installer*

# Need this so this test script can be run standalone
###[ ! "$VER_OVERRIDE" ] && #export VER_OVERRIDE=4.16.12 # Uncomment to use the 'latest' stable version of OpenShift
[ ! "$internal_bastion_rhel_ver" ] && export internal_bastion_rhel_ver=rhel9  # rhel8 or rhel9

int_bastion_hostname=registry.example.com
int_bastion_vm_name=bastion-internal-$internal_bastion_rhel_ver

source scripts/include_all.sh no-trap  # Need for below normalize fn() calls
source test/include.sh
trap - ERR # We don't want this trap during testing.  Needed for below normalize fn() calls

[ ! "$target_full" ] && default_target="iso"   # Default is to generate 'iso' only   # Default is to only create iso
mylog default_target=$default_target

mylog ============================================================
mylog Starting test $(basename $0)
mylog ============================================================
mylog "Test to install remote reg. on $int_bastion_hostname and then sync and save/load images.  Install sno ocp + test app."
mylog

rm -rf ~/.cache/agent/*

rm -rf $HOME/*/.oc-mirror/.cache

aba --dir ~/aba reset --force

ntp_ip=10.0.1.8 # If available

###which make || sudo dnf install make -y

sudo rm -f `which aba`
sudo rm -f ~/bin/aba  # don't get mixed up!
sudo rm -f /usr/local/bin/aba
sudo rm -f /usr/local/sbin/aba

test-cmd -m "Install aba (1)" '../aba/install 2>&1 | grep " installed to "'
test-cmd -m "Install aba (2)" '../aba/install 2>&1 | grep "already up-to-date"'

#test-cmd -m "Activating shortcuts.conf" cp -f .shortcuts.conf shortcuts.conf

# Test update of aba script
mylog Testing update of aba script
sleep 1
new_v=$(date +%Y%m%d%H%M%S)
test-cmd -m "Testing update of aba script, update version" sed -i "s/^ABA_VERSION=.*/ABA_VERSION=$new_v/g" scripts/aba.sh
test-cmd -m "Testing update of aba script, run (and update) aba" "aba -h | head -8"  # This will trigger an update of aba
test-cmd -m "Testing update of aba script, grep aba version" "grep ^ABA_VERSION=$new_v `which aba`"

# clean up all, assuming reg. is not running (deleted)
v=4.16.3
#echo ocp_version=$v > aba.conf  # needed so reset works without calling aba (interactive). aba.conf is created below. 
#####mv cli cli.m && mkdir -v cli && cp cli.m/Makefile cli && aba reset --force; rm -rf cli && mv cli.m cli
### aba -d cli reset --force  # Ensure there are no old and potentially broken binaries
### test-cmd -m "Show content of mirror/save" 'ls -l mirror mirror/save || true'
#aba clean

# Set up aba.conf properly
vf=~steve/.vmware.conf
[ ! "$VER_OVERRIDE" ] && VER_OVERRIDE=latest
[ ! "$oc_mirror_ver_override" ] && oc_mirror_ver_override=v2
test-cmd -m "Configure aba.conf for version '$VER_OVERRIDE' and vmware $vf" aba -A --platform vmw --channel $TEST_CHANNEL --version $VER_OVERRIDE ### --vmw $vf

test-cmd -m "Checking aba.conf settings - ask=false" "grep ^ask=false aba.conf"
test-cmd -m "Checking aba.conf settings - platform=vmw" "grep ^platform=vmw aba.conf"
test-cmd -m "Checking aba.conf settings - ocp_channel=$TEST_CHANNEL" "grep ^ocp_channel=$TEST_CHANNEL aba.conf"
test-cmd -m "Checking aba.conf settings - ocp_version=x.y.z" "grep -E '^ocp_version=[0-9]+(\.[0-9]+){2}\b' aba.conf"

mylog "Setting oc_mirror_version=$oc_mirror_ver_override in aba.conf"
sed -i "s/^oc_mirror_version=.*/oc_mirror_version=$oc_mirror_ver_override /g" aba.conf

##test-cmd -m "Setting 'ask=false' in aba.conf to enable full automation." aba --noask

mylog Set up vmware.conf
test-cmd cp -v $vf vmware.conf 
sed -i "s#^VC_FOLDER=.*#VC_FOLDER=/Datacenter/vm/abatesting#g" vmware.conf
test-cmd -m "Checking vmware.conf" grep vm/abatesting vmware.conf

#mylog "Setting ntp_servers=$ntp_ip" 
#[ "$ntp_ip" ] && sed -i "s/^ntp_servers=\([^#]*\)#\(.*\)$/ntp_servers=$ntp_ip    #\2/g" aba.conf
[ "$ntp_ip" ] && test-cmd -m "Setting ntp_servers=$ntp_ip ntp.example.com in aba.conf" aba --ntp $ntp_ip ntp.example.com

echo kiali-ossm > templates/operator-set-abatest 
test-cmd -m "Setting op_sets=abatest in aba.conf" aba --op-sets abatest

mylog Showing aba.conf settings
normalize-aba-conf
source <(normalize-aba-conf)

reg_ssh_user=$TEST_USER

aba --dir cli ~/bin/govc
source <(normalize-vmware-conf)
normalize-vmware-conf
#echo GOVC_URL=$GOVC_URL
#echo GOVC_DATASTORE=$GOVC_DATASTORE
#echo GOVC_NETWORK=$GOVC_NETWORK
#echo GOVC_DATACENTER=$GOVC_DATACENTER
#echo GOVC_CLUSTER=$GOVC_CLUSTER
#echo VC_FOLDER=$VC_FOLDER

export subdir=\~/subdir  # init_bastion() needs this to create 'subdir' dir! though test1 does not use it! #FIXME
##scripts/vmw-create-folder.sh /Datacenter/vm/test
init_bastion $int_bastion_hostname $int_bastion_vm_name aba-test $TEST_USER

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

######################
mylog "Installing Quay mirror registry at $int_bastion_hostname:8443, using key ~/.ssh/id_rsa and then ..."

# Note that the firewalld is used for the VLAN/private network masquerade/config ... 'test1' should be ok
test-cmd -m "Show Firewalld status" -h $TEST_USER@$int_bastion_hostname "sudo firewall-offline-cmd --list-all && sudo systemctl status firewalld || true"
# This will install mirror and sync images
# This should also set the firewall rule in 'firewalld offline' mode
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Bring down firewalld to test the mirror can be installed to remote host ok and the port added in offline mode" "sudo systemctl disable firewalld && sudo systemctl stop firewalld"
test-cmd -m "Show Firewalld status" -h $TEST_USER@$int_bastion_hostname "sudo firewall-offline-cmd --list-all && sudo systemctl status firewalld || true"

# Install & sync mirror on remote host
test-cmd -r 15 3 -m "Syncing images from external network to internal mirror registry (single command)" "aba -d mirror sync --retry -H $int_bastion_hostname -k ~/.ssh/id_rsa --data-dir '~/my-quay-mirror-test1'"

test-cmd -m "Show Firewalld status" -h $TEST_USER@$int_bastion_hostname "sudo firewall-offline-cmd --list-all && sudo systemctl status firewalld || true"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Bring up firewalld to test the 8443 port was added during mirror installation (above)" "sudo systemctl enable firewalld && sudo systemctl start firewalld"
test-cmd -m "Show Firewalld status" -h $TEST_USER@$int_bastion_hostname "sudo firewall-offline-cmd --list-all && sudo systemctl status firewalld || true"
test-cmd -m "Test firewalld port open" -h $TEST_USER@$int_bastion_hostname "sudo firewall-cmd --list-all | grep \"ports: .*8443/tcp\""  # This port must be open


test-cmd -m "Check location of oc-mirror .cache dir" 						"sudo find ~/ | grep \.oc-mirror/\.cache$ || true"
test-cmd -m "Check location of oc-mirror .cache dir" -h $TEST_USER@$int_bastion_hostname	"sudo find ~/ | grep \.oc-mirror/\.cache$ || true"

source <(cd mirror; normalize-mirror-conf)  # This is only needed for the test script to output the $reg_* values (see below)
echo
echo mirror.conf values:
(cd mirror; normalize-mirror-conf | awk '{print $2}')
echo

# Install yq for below test only!
which yq || (
	mylog Install yq for tests
	curl --retry 8 -sSL -o - https://github.com/mikefarah/yq/releases/download/v4.41.1/yq_linux_amd64.tar.gz | tar -C ~/bin -xzf - ./yq_linux_amd64 && \
		mv ~/bin/yq_linux_amd64 ~/bin/yq && \
		chmod 755 ~/bin/yq
	)

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

######################
# This test creates the ABI (agent-based installer) config files to check they are valid

for cname in sno compact standard
do
	mkdir -v -p test/$cname

        mylog "Agent-config file generation test for cluster type '$cname'"

        rm -rf $cname

	test-cmd -m "Adding 10.0.2.8 to ntp servers" "aba --dns 10.0.1.8 10.0.2.8"

	[ "$cname" = "sno" ] && starting_ip=10.0.1.201
	[ "$cname" = "compact" ] && starting_ip=10.0.1.71
	[ "$cname" = "standard" ] && starting_ip=10.0.1.81
#../test/sno/agent-config.yaml.example:rendezvousIP: 10.0.1.201
	#test/compact/agent-config.yaml.example:rendezvousIP: 10.0.1.71
#../test/standard/agent-config.yaml.example:rendezvousIP: 10.0.1.81


	test-cmd -m "Creating cluster.conf for '$cname' cluster" "aba cluster -n $cname -t $cname -i $starting_ip --step cluster.conf"
	#test-cmd -m "Creating cluster.conf for '$cname' cluster" "aba cluster -n $cname -t $cname -i $starting_ip --machine-network 10.0.0.0/20 --gateway-ip 10.0.1.1 --step cluster.conf"
	#test-cmd -m "Update machine net and router" sed -e "s/^machine_network=.*/machine_network=10.0.0.0/20" -e "^next_hop_address=.*/next_hop_address=10.0.1.1" $cname/cluster.conf
        sed -i "s#mac_prefix=.*#mac_prefix=88:88:88:88:88:#g" $cname/cluster.conf   # Make sure all mac addr are the same, not random
        test-cmd -m "Creating install-config.yaml for $cname cluster" "aba --dir $cname install-config.yaml"
        test-cmd -m "Creating agent-config.yaml for $cname cluster" "aba --dir $cname agent-config.yaml"

	# There are only run on the very first run to generate the valis files
	# Note that the files test/{sno,compact,standrd}/{install,agent}-config.yaml.example have all been committed into git 
        ### NOT NEEDED [ ! -f test/$cname/install-config.yaml.example ] && cat $cname/install-config.yaml | yq 'del(.additionalTrustBundle,.platform.vsphere.vcenters,.pullSecret)' > test/$cname/install-config.yaml.example
        ### NOT NEEDED [ ! -f test/$cname/agent-config.yaml.example ]   && cat $cname/agent-config.yaml   > test/$cname/agent-config.yaml.example

	# Remove some of the params which either change or cannot be placed into git (FIXME: specify the VC password exactly) 
	# Remove all empty lines
	cat $cname/install-config.yaml | \
		yq "del(.additionalTrustBundle,.pullSecret,\
.platform.vsphere.vcenters[].password,\
.platform.vsphere.failureDomains[0].name,\
.platform.vsphere.failureDomains[0].region,\
.platform.vsphere.failureDomains[0].zone,\
.platform.vsphere.failureDomains[0].topology.datastore\
)" | \
		sed '/^[ \t]*$/d' | \
		sed 's/[ \t]*$//g' | \
		cat > test/$cname/install-config.yaml

	cat $cname/agent-config.yaml | \
		sed '/^[ \t]*$/d' | \
		sed 's/[ \t]*$//g' | \
		cat > test/$cname/agent-config.yaml

        # Check if the files DO NOT match (are different)

	mylog "Checking test/$cname/install-config.yaml"

	# Run only once
        test-cmd -r 0 0 -m "Comparing test/$cname/install-config.yaml with test/$cname/install-config.yaml.example" diff test/$cname/install-config.yaml test/$cname/install-config.yaml.example | tee -a test/$cname/install-config.yaml.diff

	mylog "Checking test/$cname/agent-config.yaml"

	# Run only once
        test-cmd -r 0 0 -m "Comparing test/$cname/agent-config.yaml with test/$cname/agent-config.yaml.example" diff test/$cname/agent-config.yaml test/$cname/agent-config.yaml.example | tee -a test/$cname/agent-config.yaml.diff

        test-cmd -m "Generate iso file for cluster type '$cname'" "aba --dir $cname iso"
done

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

######################
rm -rf sno
test-cmd -m "Installing SNO cluster with 'aba cluster -n sno -t sno --step $default_target'" aba cluster -n sno -t sno --starting-ip 10.0.1.201 --step $default_target
test-cmd -i -m "Deleting sno cluster (if it was created)" aba --dir sno delete 

#######################
#  This will save the images, install (the reg.) then load the images
test-cmd -r 15 3 -m "Saving and then loading cluster images into mirror" "aba --dir mirror save load" 

test-cmd -m "Check location of oc-mirror .cache dir" 						"sudo find ~/ | grep \.oc-mirror/\.cache$ || true"
test-cmd -m "Check location of oc-mirror .cache dir" -h $TEST_USER@$int_bastion_hostname	"sudo find ~/ | grep \.oc-mirror/\.cache$ || true"

# Should we delete the seq file here? #FIXME

test-cmd -m "Checking sno dir" ls -ld sno
test-cmd -m "Deleting existing sno dir" rm -rf sno

test-cmd -m "Installing sno cluster with 'aba cluster -n sno -t sno --step $default_target'" aba cluster -n sno -t sno --starting-ip 10.0.1.201 --step $default_target
test-cmd -m "Delete cluster (if needed)" aba --dir sno delete 
test-cmd -m "Delete the remote registry" aba --dir mirror uninstall 
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Verify remote mirror uninstalled" "podman ps | tee /dev/tty | grep -v -e quay -e CONTAINER | wc -l | grep ^0$"
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Deleting all podman images" "podman system prune --all --force && podman rmi --all && sudo rm -rf ~/.local/share/containers/storage && rm -rf ~/test"

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

mylog "Configure mirror to install on internal bastion (remote host) in custom dir, with random password to '/my/path'"

reg_ssh_user=testy
reg_ssh_key=${reg_ssh_user}_rsa

test-cmd -m "Checking values in $PWD/mirror/mirror.conf" cat mirror/mirror.conf | cut -d\# -f1| sed '/^[ \t]*$/d'

#sed -i "s/registry.example.com/$int_bastion_hostname /g" ./mirror/mirror.conf	# Install on registry2 
#sed -i "s#.*reg_ssh_key=.*#reg_ssh_key=\~/.ssh/id_rsa #g" ./mirror/mirror.conf	     	# Remote or localhost

test-cmd -m "Setting data_dir=~/my-quay-mirror-test1 in mirror/mirror.conf" aba -d mirror --data-dir "\~/my-quay-mirror-test1"  # For $reg_ssh_user
#sed -i "s#^data_dir=[^ \t]*#data_dir=\~/my-quay-mirror-test1 #g" ./mirror/mirror.conf	     	# test other storage location

#mylog "Setting reg_root=~/my-quay-mirror-test1"
#sed -i "s#^reg_root=[^ \t]*#reg_root=\~/my-quay-mirror-test1 #g" ./mirror/mirror.conf	     	# test other storage location

test-cmd -m "Setting reg_pw=  (empty)" aba -d mirror --reg-password 
#sed -i "s#^reg_pw=[^ \t]*#reg_pw= #g" ./mirror/mirror.conf	    	# test random password 

### sed -i "s#tls_verify=true#tls_verify=            #g" ./mirror/mirror.conf  	# test tlsverify = false # sno install fails 

test-cmd -m "Setting reg_path=my/path" aba -d mirror --reg-path my/path 
#sed -i "s#^reg_path=[^ \t]*#reg_path=my/path #g" ./mirror/mirror.conf	    	# test path

test-cmd -m "Setting reg_user=myuser" aba -d mirror --reg-user myuser 
#sed -i "s#^reg_user=[^ \t]*#reg_user=myuser #g" ./mirror/mirror.conf	    	# test username

test-cmd -m "Setting reg_ssh_user=$reg_ssh_user for remote installation" aba -d mirror --reg-ssh-user $reg_ssh_user
#sed -i "s#^\#reg_ssh_user=[^ \t]*#reg_ssh_user=$reg_ssh_user #g" ./mirror/mirror.conf	     	# If remote, set user

test-cmd -m "Setting reg_ssh_key=~/.ssh/testy_rsa for remote installation" aba -d mirror --reg-ssh-key "\~/.ssh/$reg_ssh_key"
#sed -E -i "s|^^#{,1}reg_ssh_key=[^ \t]*|reg_ssh_key=\~/.ssh/$reg_ssh_key |g" ./mirror/mirror.conf	     	# Remote or localhost

test-cmd -m "Checking values in $PWD/mirror/mirror.conf" cat mirror/mirror.conf | cut -d\# -f1| sed '/^[ \t]*$/d'

# FIXME: no need? or use 'aba clean' or?
rm -rf mirror/save   # The process will halt, otherwise with "You already have images saved on local disk"

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

source <(cd mirror; normalize-mirror-conf)

mylog "Using remote container mirror at $reg_host:$reg_port and using reg_ssh_user=$reg_ssh_user reg_ssh_key=$reg_ssh_key"

######################
# This will install the reg. and sync the images
test-cmd -r 15 3 -m "Syncing images from external network to internal mirror registry" aba --dir mirror sync --retry

test-cmd -m "Check location of oc-mirror .cache dir" 						"sudo find ~/ | grep \.oc-mirror/\.cache$ || true"
test-cmd -m "Check location of oc-mirror .cache dir" -h $TEST_USER@$int_bastion_hostname	"sudo find ~/ | grep \.oc-mirror/\.cache$ || true"

aba --dir sno clean # This should clean up the cluster and make should start from scratch next time. Instead of running "rm -rf sno"
rm sno/cluster.conf   # This should 100% reset the cluster and 'make' should start from scratch next time

##mylog "Testing with smaller CIDR 10.0.1.200/30 with start ip 201"
test-cmd -m "Creating SNO iso with small CIDR 10.0.1.200/30" aba cluster -n sno -t sno --starting-ip 10.0.1.201 --machine-network "10.0.1.200/30" --step iso
#test-cmd -m "Setting machine_network=10.0.1.200/30" "sed -i 's#^machine_network=[^ \t]*#machine_network=10.0.1.200/30 #g' sno/cluster.conf"
###test-cmd -m "Setting machine_network=10.0.1.200/30" aba -d sno --machine-network "10.0.1.200/30"

test-cmd -m "Deleting sno/ dir" rm -rf sno

####### test-cmd -m "Setting starting_ip=10.0.1.201" "sed -i 's/^starting_ip=[^ \t]*/starting_ip=10.0.1.201 /g' sno/cluster.conf"
test-cmd -m "Creating iso: CIDR 10.0.0.0/20 with start ip 10.0.1.201" aba cluster -n sno -t sno --starting-ip 10.0.1.201 --step iso --machine-network 10.0.0.0/20 

#mylog "Testing with larger CIDR 10.0.0.0/20 with start ip 10.0.1.201"
#test-cmd -m "Setting machine_network=10.0.0.0/20" "sed -i 's#^machine_network=[^ \t]*#machine_network=10.0.0.0/20 #g' sno/cluster.conf"
###test-cmd -m "Setting in aba.conf machine_network=10.0.0.0/20" aba -d sno --machine-network 10.0.0.0/20  -i 10.0.1.201

#test-cmd -m "Setting starting_ip=10.0.1.201" "sed -i 's/^starting_ip=[^ \t]*/starting_ip=10.0.1.201 /g' sno/cluster.conf"
###test-cmd -m "Setting starting_ip=10.0.1.201" aba -d sno -i 10.0.1.201

test-cmd -m "Installing sno cluster" aba cluster -n sno -t sno --starting-ip 10.0.1.201 --step install
test-cmd -m "Checking cluster operators" aba --dir sno run

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

#######################
#  Delete the reg. first!
test-cmd -m "Delete the registry so it will be re-created again in next test" aba --dir mirror uninstall 
#  This will save the images, install (the reg.) then load the images
test-cmd -r 15 3 -m "Saving and loading images into mirror (should install quay again)" aba --dir mirror save load 

test-cmd -m "Check location of oc-mirror .cache dir" 						"sudo find ~/ | grep \.oc-mirror/\.cache$ || true"
test-cmd -m "Check location of oc-mirror .cache dir" -h $TEST_USER@$int_bastion_hostname	"sudo find ~/ | grep \.oc-mirror/\.cache$ || true"

aba --dir sno clean # This should clean up the cluster and 'make' should start from scratch next time. Instead of running "rm -rf sno"
test-cmd -m "Installing sno cluster with 'aba cluster -n sno -t sno --step $default_target'" aba cluster -n sno -t sno --starting-ip 10.0.1.201 --step $default_target

### Let it be ## test-cmd -m "Deleting cluster" aba --dir sno delete.  -i ignore the return value, i.e. if cluster not running/accessible 
#test-cmd -i -m "If cluster up, stopping cluster" ". <(aba -sC sno shell) && . <(aba -sC sno login) && yes|aba --dir sno shutdown --wait"
test-cmd -i -m "If cluster up, stopping cluster" "yes|aba --dir sno shutdown --wait"

### FIXME mylog "Removing vmware config file to simulate 'bare metal' and iso creation"
mylog "Bare-metal simulation: Changing 'platform' to non-vmware in 'aba.conf' file to simulate 'bare metal' and iso creation"

# FIXME
#sed -i "s/^platform=.*/platform=bm/g" aba.conf
test-cmd -m "Setting platform=bm in aba.conf" aba --platform bm

test-cmd -m "Testing download-all - rm govc" rm -f cli/govc*
test-cmd -m "Testing download-all - checking govc tar file does NOT exists" ! test -f cli/govc*gz
test-cmd -m "Testing download-all - bm install should also download govc binary" aba -d cli download-all
test-cmd -m "Testing download-all - checking govc tar file exists" test -f cli/govc*gz

####> vmware.conf
rm -rf standard   # Needs to be 'standard' as there was a bug for iso creation in this topology
####test-cmd -m "Creating standard iso file with 'aba cluster -n standard -t standard --step iso'" aba cluster -n standard -t standard --step iso # Since we're simulating bare-metal, only create iso

# We're simulating bare-metal, *make will stop* after creating agent configs 
test-cmd -m "Bare-metal simulation: Creating agent config files" aba cluster -n standard -t standard -i 10.0.1.81 -s install
test-cmd -m "Verify cluster config file exists"		ls -l standard/cluster.conf
test-cmd -m "Verify agent config file"			ls -l standard/install-config.yaml standard/agent-config.yaml
test-cmd -m "Verify ISO file does NOT YET exist"	! ls -l standard/iso-agent-based/agent.*.iso
test-cmd -m "Bare-metal simulation: Creating iso file"	aba --dir standard install #iso        	# Since we're simulating bare-metal, stop after creating iso
test-cmd -m "Verify ISO file now exists"		ls -l standard/iso-agent-based/agent.*.iso

#test-cmd -m "Delete the registry" aba --dir mirror uninstall 
#test-cmd -h $TEST_USER@$int_bastion_hostname -m "Verify mirror uninstalled" "podman ps | tee /dev/tty | grep -v -e quay -e CONTAINER | wc -l | grep ^0$"
#test-cmd -h $TEST_USER@$int_bastion_hostname -m "Deleting all podman images" "podman system prune --all --force && podman rmi --all && sudo rm -rf ~/.local/share/containers/storage && rm -rf ~/test"

test-cmd -m "Delete the remote registry" aba --dir mirror uninstall 
test-cmd -h $TEST_USER@$int_bastion_hostname -m "Verify mirror uninstalled" "podman ps | tee /dev/tty | grep -v -e quay -e CONTAINER | wc -l | grep ^0$"

#####################################################################################################################
#####################################################################################################################
#####################################################################################################################

mylog
mylog "===> Completed test $0"
mylog

test-cmd -m "Move log file" "test -f test/test.log && cp test/test.log test/test.log.bak || true"

echo SUCCESS $0
