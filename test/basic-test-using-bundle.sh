#!/bin/bash -ex
# Basic test script to show how to create a custom bundle (*split* or normal) and then install OCP disonnected

[ "$1" ] && SPLIT="--split"   		# Test with *split* bundle with any arg.

CLUSTER_NAME=sno3
STARTING_IP=10.0.1.203
TEST_DIR_CONN=~/tmp/connected
TEST_DIR_DISCO=~/tmp/disco
mkdir -p $TEST_DIR_CONN
mkdir -p $TEST_DIR_DISCO

# Clean up after last test
cd $TEST_DIR_DISCO/aba 2>/dev/null && ./aba -d mirror uninstall -y && sudo rm -rf ~/quay-install || true  # Delete any existing mirror reg.
sudo rm -fv $(which aba)
rm -rf ~/.oc-mirror/.cache
rm -fv ~/bin/{oc-mirror,oc,openshift-install}
rm -rf $TEST_DIR_CONN/aba 
rm -f ~/.aba/.first_cluster_success

# Go online
export no_proxy=.lan,.example.com
export http_proxy=http://10.0.1.8:3128
export https_proxy=http://10.0.1.8:3128

# Install aba
cd $TEST_DIR_CONN
#set +x; bash -c "$(gitrepo=sjbylo/aba; gitbranch=main; curl -fsSL https://raw.githubusercontent.com/$gitrepo/refs/heads/$gitbranch/install)"; set -x
set +x; bash -c "$(gitrepo=sjbylo/aba; gitbranch=dev; curl -fsSL https://raw.githubusercontent.com/$gitrepo/refs/heads/$gitbranch/install)" -- dev; set -x
cd aba
echo cincinnati-operator > templates/operator-set-abatest   # Create a test "operator set"

# Create install bundle
aba -y bundle --pull-secret '~/.pull-secret.json' --platform vmw --channel fast --version p \
	--op-sets abatest --ops yaks vault-secrets-operator flux --base-domain example.com \
	--machine-network 10.0.0.0/20 --dns 10.0.1.8 10.0.2.8 --ntp 10.0.1.8  ntp.example.com --out $TEST_DIR_DISCO/delete-me \
	$SPLIT

# Keep empty line above!
echo "aba bundle returned: $?"

# Go offline
unset http_proxy https_proxy no_proxy # Go offline

# Clean up
sudo rm -vf $(which aba)
rm -rf ~/.oc-mirror/.cache
rm -vf ~/bin/{oc-mirror,oc,openshift-install}

cd $TEST_DIR_DISCO
rm -rf aba
tar xvf delete-me*tar
rm -vf delete-me*tar
cd aba
./install
[ "$SPLIT" ] && aba   # Show the bundle instructions
[ "$SPLIT" ] && mv -v $TEST_DIR_CONN/aba/mirror/save/mirror_00000*tar $TEST_DIR_DISCO/aba/mirror/save   # Merge the two repos (to save disk space on this filesystem) 
rm -rf $TEST_DIR_CONN/aba   # Not needed anymore
aba     # Show the bundle instructions
aba -d mirror load -H registry4.example.com -r -y
rm -rf $CLUSTER_NAME
aba cluster -n $CLUSTER_NAME -t sno -i $STARTING_IP -s install -y
aba -d $CLUSTER_NAME day2 
. <(./aba -d $CLUSTER_NAME login)
time until oc get packagemanifests | grep cincinnati-operator; do sleep 5; done
oc get packagemanifests
aba -d $CLUSTER_NAME day2-osus
aba -d $CLUSTER_NAME day2-ntp
. <(./aba -d $CLUSTER_NAME login)
aba -d $CLUSTER_NAME delete -y
aba -d mirror uninstall -y || true  # Delete mirror reg.
set +x
echo ALL TESTS COMPLETED OK
