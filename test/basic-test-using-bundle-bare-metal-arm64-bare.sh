#!/bin/bash -ex
# Basic test script to show how to create a custom bundle (*light* or normal) and then install OpenShift disonnected

[ "$1" ] && LIGHT="--light"   		# Test with *light* bundle with any arg.

MY_HOST=$(hostname -f)    # This must be FQDN with A record pointing to IP address of this host
CLUSTER_NAME=sno3
STARTING_IP=10.0.1.203
TEST_DIR_CONN=~/tmp/connected
TEST_DIR_DISCO=~/tmp/disco
MAC=00:50:56:05:7B:01
mkdir -p $TEST_DIR_CONN $TEST_DIR_DISCO

# Go online
export no_proxy=.lan,.example.com
export http_proxy=http://10.0.1.8:3128
export https_proxy=http://10.0.1.8:3128

# Clean up after last test
##cd $TEST_DIR_DISCO/aba 2>/dev/null && ./aba -d mirror uninstall -y && sudo rm -rf ~/quay-install || true  # Delete any existing mirror reg.
# Checks if 'registry' is running, and stops it only if true
#[ "$(podman inspect -f '{{.State.Running}}' registry 2>/dev/null)" == "true" ] && podman stop registry
aba -d mirror uninstall-docker-registry
! curl -f -SkIL https://$MY_HOST:8443/ 2>/dev/null|| { echo Registry detected at https://$MY_HOST/; exit 1; }   # Sanity check
sudo rm -fv $(which aba)
rm -rf ~/.oc-mirror/.cache
rm -fv ~/bin/{oc-mirror,oc,openshift-install}
rm -rf $TEST_DIR_CONN/aba 
rm -f ~/.aba/.first_cluster_success

# Install aba
cd $TEST_DIR_CONN
#set +x; bash -c "$(gitrepo=sjbylo/aba; gitbranch=main; curl -fsSL https://raw.githubusercontent.com/$gitrepo/refs/heads/$gitbranch/install)"; set -x
set +x; bash -c "$(gitrepo=sjbylo/aba; gitbranch=dev; curl -fsSL https://raw.githubusercontent.com/$gitrepo/refs/heads/$gitbranch/install)" -- dev; set -x
cd aba
sed -i "s/--since 2025-01-01//g" scripts/reg-save.sh
echo group-sync-operator > templates/operator-set-abatest   # Create a test "operator set"

# Create install bundle (note that cincinnati-operator is not available as arm64 image)
aba -y bundle --pull-secret '~/.pull-secret.json' --platform vmw --channel fast --version p \
	--op-sets abatest --ops --base-domain example.com \
	--machine-network 10.0.0.0/20 --dns 10.0.1.8 10.0.2.8 --ntp 10.0.1.8  ntp.example.com --out $TEST_DIR_DISCO/test-bundle-delete-me \
	$LIGHT

# Keep empty line above!
echo "aba bundle returned: $?"

# Go offline
unset http_proxy https_proxy no_proxy # Go offline

# Clean up
sudo rm -vf $(which aba)
rm -rf ~/.oc-mirror/.cache
rm -vf ~/bin/{oc-mirror,oc,openshift-install}

cd $TEST_DIR_DISCO
rm -rf $TEST_DIR_CONN/aba   # Save disk space, not needed anymore
rm -rf aba
tar xvf test-bundle-delete-me*tar
rm -vf test-bundle-delete-me*tar   # Save space
cd aba
./install
# If "light" bundle, show the bundle instructions and move the ISC archive into place
[ "$LIGHT" ] && aba && mv -v $TEST_DIR_CONN/aba/mirror/save/mirror_00000*tar $TEST_DIR_DISCO/aba/mirror/save   # Merge the two repos (to save disk space on this filesystem) 
aba     # Show the bundle instructions again
aba -d mirror -H $MY_HOST install-docker-registry   # Preempt mirror installation and use docker (works on arm64)
aba -d mirror load -H $MY_HOST -r -y
rm -rf $CLUSTER_NAME
# Start bare-metal install ...
echo $MAC > $CLUSTER_NAME/macs.conf   				# Create the macs.conf file
aba cluster -n $CLUSTER_NAME -t sno -i $STARTING_IP -s iso -y	# Create the iso
echo -n "ISO created!  Now manually boot the VM with the ISO and then hit ENTER to run: aba mon: "
read yn
aba -d $CLUSTER_NAME mon
aba -d $CLUSTER_NAME day2 
. <(./aba -d $CLUSTER_NAME login)
time until oc get packagemanifests | grep cincinnati-operator; do sleep 5; done
oc get packagemanifests
#aba -d $CLUSTER_NAME day2-osus   # No arm64 operator availbale for this yet
aba -d $CLUSTER_NAME day2-ntp
. <(./aba -d $CLUSTER_NAME login)
#aba -d $CLUSTER_NAME delete -y   # Can't so this
aba -d mirror uninstall-docker-registry
set +x
echo ALL TESTS COMPLETED OK
