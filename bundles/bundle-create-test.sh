#!/bin/bash -e
# Create an install bundle and test it's working by installing SNO

#TEST_HOST=mirror.example.com  # Adjust this as needed
#BASE_DOM=example.com
BASE_DOM=$(hostname -d)
TEST_HOST=$(hostname -s).$BASE_DOM  # Adjust this as needed
PS_FILE='~/.pull-secret.json'
# Change these two paths where there's a lot of space!
WORK_DIR=$PWD/work
TEMPLATES_DIR=$PWD/templates
CLOUD_DIR=/nas/redhat/aba-openshift-install-bundles

mkdir -p ~/tmp
rpm -q podman || sudo dnf install podman -y
hash -r # Forget all cached command locations!

# ===========================
# Color Echo Functions
# ===========================

_color_echo() {
	local color="$1"; shift
	local text

	# Collect input from args or stdin
	if [ $# -gt 0 ]; then
	n_opt=
	if [ "$1" = "-n" ]; then
		n_opt="-n"
		shift
	fi
		text="$*"
	else
		text="$(cat)"
	fi

	# Apply color only if stdout is a terminal and terminal supports >= 8 colors
	if [ -t 1 ] && [ "$(tput colors 2>/dev/null)" -ge 8 ] && [ ! "$PLAIN_OUTPUT" ]; then
		tput setaf "$color"
		echo -e $n_opt "$text"
		tput sgr0
	else
		echo -e $n_opt "$text"
	fi
}

# Standard 8 colors
echo_black()   { set +x; _color_echo 0 "$@"; set -x; }
echo_red()     { set +x; _color_echo 1 "$@"; set -x; }
echo_green()   { set +x; _color_echo 2 "$@"; set -x; }
echo_yellow()  { set +x; _color_echo 3 "$@"; set -x; }
echo_blue()    { set +x; _color_echo 4 "$@"; set -x; }
echo_magenta() { set +x; _color_echo 5 "$@"; set -x; }
echo_cyan()    { set +x; _color_echo 6 "$@"; set -x; }
echo_white()   { set +x; _color_echo 7 "$@"; set -x; }

echo_step() {
	set +x
	echo
        echo_green "##################"
        echo_green $@
        echo_green "##################"
	set -x
}

export ABA_TESTING=1   # No stats recorded

set -x

. ~steve/.proxy-set.sh  # Go online!
# Test connectivity is not working
echo_step Test internet connection with curl google.com ...
curl -sfkIL google.com >/dev/null  # Must work

[ $# -lt 2 ] && exit 1
VER=$1; shift
NAME=$1; shift

uncomment_line() {
	local search="$1"
	local file="$2"
	# Match: optional spaces, then '#', optional spaces, then the search term
	sed -i "s|^[[:space:]]*#\(.*${search}.*\)|\1|" "$file"
}

BUNDLE_NAME=$VER-$NAME
WORK_BUNDLE_DIR=$WORK_DIR/$BUNDLE_NAME
WORK_BUNDLE_DIR_BUILD=$WORK_DIR/$BUNDLE_NAME/build
CLOUD_DIR_BUNDLE=$CLOUD_DIR/$BUNDLE_NAME

# Check this here, so we keep any files around for troubleshooting
BUNDLE_UPLOADING=INSTALL-BUNDLE-UPLOADING.txt
if [ -d $CLOUD_DIR_BUNDLE -a ! -f $CLOUD_DIR_BUNDLE/$BUNDLE_UPLOADING ]; then
	echo Install bundle dir already exists: $CLOUD_DIR_BUNDLE >&2

	exit 0
fi

which notify.sh 2>/dev/null && NOTIFY=1
[ "$NOTIFY" ] && echo Working on bundle: $BUNDLE_NAME ... | notify.sh

######################

# Remove quay 
if [ -d $WORK_DIR/test-install/aba ]; then
	(
		cd $WORK_DIR/test-install/aba
		./install  # install aba
		#aba -d mirror uninstall -y
		aba -d mirror uninstall-docker-registry -y
		sudo rm -rf ~/quay-install
		sudo rm -rf ~/docker-reg
	)
fi

# Remove any quay 
if podman ps | grep registry; then
(
	cd ..
	# Uninstall Quay
	./install  # install aba
	aba -A
	#aba uninstall  || true
	cd mirror
	./mirror-registry uninstall --autoApprove -v || true
	sudo rm -rf ~/quay-install
	sudo rm -rf ~/docker-reg
	./mirror-registry uninstall --autoApprove -v || true
	podman rmi `podman images -q` ##--force
)
fi
sudo rm -rf ~/quay-install
sudo rm -rf ~/docker-reg

######################

# Init ...
rm -rf $WORK_DIR/*
mkdir -p $WORK_DIR $WORK_BUNDLE_DIR $WORK_BUNDLE_DIR_BUILD

LOGFILE="$WORK_BUNDLE_DIR_BUILD/bundle-build.log"
# Send stdout and stderr through tee
exec > >(tee -a "$LOGFILE") 2>&1

cd $WORK_DIR

# If the finsl destination dir (e.g. cloud sync dir) doies not exist, quit.
[ ! -d $CLOUD_DIR ] && echo "Dir $CLOUD_DIR not available!  Set up a directory that syncs with a cloud drive, e.g. gdrive" && exit 1

# If the install bundle already exists AND is complete (i.e. not uploading), do nothing and exit
echo_step "Processing: $CLOUD_DIR_BUNDLE"
sleep 1

# If the dir exists, then it must be incomplete ... remove it. Assume this script is only run once every 24 hours
# i.e. don't want to delete a bundle that is still being created!
rm -rf $CLOUD_DIR_BUNDLE

# Install aba
echo_step Install Aba to $PWD/aba ...

rm -rf aba

# Install aba from the Internet
set +x
bash -c "$(gitrepo=sjbylo/aba; gitbranch=main; curl -fsSL https://raw.githubusercontent.com/$gitrepo/refs/heads/$gitbranch/install)"
#bash -c "$(gitrepo=sjbylo/aba; gitbranch=dev; curl -fsSL https://raw.githubusercontent.com/$gitrepo/refs/heads/$gitbranch/install)" -- dev
cd aba
####./install  # Done above
set -x

# Create bundle? 
echo Create the bundle in $WORK_BUNDLE_DIR ...
mkdir -p $WORK_BUNDLE_DIR_BUILD

# Need operator sets ?
OP=
[ "$*" ] && OP="--op-sets $*"

#echo Waiting 60s ...
#read -t 60 || true

aba --pull-secret $PS_FILE --platform bm --channel fast --version $VER $OP --base-domain $BASE_DOM

sleep 2
ls -l ~/bin/oc-mirror 
sleep 5
set -x
sleep 10 # wait for "download-operator"
ps -ef | grep download-operator
sleep 60 # Give some time ... # Hack: must wait for oc-mirror to d/l in the background b4 running "aba catalog" again! Otherwise the download happens in parallel causing trouble
while ps -ef | grep -v grep | grep download-operator
do
	echo -n .
	sleep 10
done
ls -l ~/bin/oc-mirror 
##timeout 120 bash -c 'until [ -f ~/bin/oc-mirror ]; do sleep 1; done'; echo ~/bin/oc-mirror installed
ps -ef | grep download 

echo_step Create image set config file ...

aba -d mirror isconf

uncomment_line additionalImages:			mirror/save/imageset-config-save.yaml
uncomment_line registry.redhat.io/openshift4/ose-cli	mirror/save/imageset-config-save.yaml
uncomment_line registry.redhat.io/rhel9/support-tools	mirror/save/imageset-config-save.yaml
uncomment_line quay.io/openshifttest/hello-openshift	mirror/save/imageset-config-save.yaml
uncomment_line registry.redhat.io/ubi9/ubi		mirror/save/imageset-config-save.yaml
#[ "$NAME" = "ocpv" ] && uncomment_line quay.io/containerdisks/centos-stream:10	mirror/save/imageset-config-save.yaml
[ "$NAME" = "ocpv" ] && uncomment_line quay.io/containerdisks/centos-stream:9	mirror/save/imageset-config-save.yaml
[ "$NAME" = "ocpv" ] && uncomment_line quay.io/containerdisks/fedora:latest	mirror/save/imageset-config-save.yaml

# START - Exception since issue with v2.10 #########
# Replace release-v2.10 with release-v2.9 - in the 2 lines - after mtv-operator found:
# What we need:
#    - name: mtv-operator
#      defaultChannel: release-v2.8
#      channels:
#      - name: "release-v2.8"
[ "$NAME" = "ocpv" ] && sed -i -e '/mtv-operator/{n;N; s/release-v2.10/release-v2.8/g}' mirror/save/imageset-config-save.yaml
# Append or insert line after "mtv-operator" line
[ "$NAME" = "ocpv" ] && sed -i -e '/mtv-operator/a\      defaultChannel: release-v2.8' mirror/save/imageset-config-save.yaml
# END - Exception since issue with v2.10 ##########

echo_step Show image set config file ...

#  additionalImages:
#  - name: registry.redhat.io/openshift4/ose-cli
#  - name: registry.redhat.io/rhel9/support-tools:latest
#  - name: quay.io/openshifttest/hello-openshift:1.2.0
#  - name: registry.redhat.io/ubi9/ubi:latest
# Useful images for testing OpenShift Virtualization
#  - name: quay.io/containerdisks/centos-stream:10
#  - name: quay.io/containerdisks/centos-stream:9
#  - name: quay.io/containerdisks/fedora:latest

cat mirror/save/imageset-config-save.yaml

echo Pausing 6s ...
read -t 6  || true


echo_step Save images to disk ...

rm -rf ~/.oc-mirror  # We don't want to include all the older images?!?!
aba -d mirror save -r 8

###rm -rf ~/.oc-mirror  # We need some storage back!

echo_step Create the install bundle files ...

# (1) Fix up aba.conf - remove network velues so they can be auto-added once unpacked in disco env.
echo pwd=$PWD
source scripts/include_all.sh; trap - ERR
echo
cat aba.conf
set -e
cp aba.conf ~/aba.conf.bk
replace-value-conf -n domain 		-v -f aba.conf
replace-value-conf -n machine_network	-v -f aba.conf
replace-value-conf -n dns_servers	-v -f aba.conf
replace-value-conf -n next_hop_address	-v -f aba.conf
replace-value-conf -n ntp_servers	-v -f aba.conf

echo
cat aba.conf
read -t 60 || true

# Create the bundle
#aba tar --out - | split -b 10G - $WORK_BUNDLE_DIR/ocp_${VER}_${NAME}_
# Is use aba, then aba immediatelly fills in the values again!
make tar out=- | split -b 10G - $WORK_BUNDLE_DIR/ocp_${VER}_${NAME}_

# (2) Fix up aba.conf so we can test the bundle
cp ~/aba.conf.bk aba.conf

echo_green Calculating the checksums in the background ...

(
	cd $WORK_BUNDLE_DIR && cksum ocp_* > CHECKSUM.txt
) &


echo_step Removing unneeded aba repo at $WORK_DIR/aba

rm -rf $WORK_DIR/aba # Remove the unneeded repo to save space

echo_step Going offline to test the install bundle ...
. ~steve/.proxy-unset.sh   # Go offline!
# Test connectivity is not working
echo_step Test internet connection with curl google.com ...
! curl -sfkIL google.com >/dev/null  # Must "Connection timed out"

# Should we delete here since we want to simulate a fresh/empty internal bastion?
###rm -rf ~/.oc-mirror  # We need some storage back!

#####################################################
# Test the install bundle works for SNO

mkdir -p $WORK_DIR/test-install
cd $WORK_DIR/test-install

rm -rf aba

## Output the files:
ls -l $WORK_BUNDLE_DIR/ocp_* || true

# Unpack the install bundle 
echo_step Unpack the install bundle ...

cat $WORK_BUNDLE_DIR/ocp_* | tar xvf -

# Uninstall old version of aba
if which aba; then sudo rm -fv $(which aba); fi

cd aba

# Switch to vmw for testing
echo_step Switch to platform = vmw ...
sed -i "s/platform=bm/platform=vmw/g" aba.conf

./install
aba
aba -A

echo_step Install Quay and load the images ...

echo_step Show podman ps output
podman ps

echo pwd=$PWD

ls -lta mirror 

echo -n "Pausing: "
read -t 60 yn || true

#rm -rf ~/.oc-mirror  # We need some storage back! # FIXME: The cache gets filled again!
#aba -d mirror load --retry 7 -H $TEST_HOST -k \~/.ssh/id_rsa
aba -d mirror -H $TEST_HOST install-docker-registry   # Use this instead of Quay due to quay issues
aba -d mirror load --retry 7 -H $TEST_HOST

# Be sure all CLI files can install and are executable
make -C cli 
for cmd in butane govc kubectl oc oc-mirror openshift-install
do
	~/bin/$cmd --help >/dev/null 2>&1 || { echo ~/bin/$cmd cannot execute!; exit 1; }
done

WORK_TEST_LOG=$WORK_BUNDLE_DIR_BUILD/tests-completed.txt
echo "## Test results for install bundle: $BUNDLE_NAME" > $WORK_TEST_LOG
echo >> $WORK_TEST_LOG
echo "Quay installed: ok" >> $WORK_TEST_LOG
echo "All images loaded (disk2mirror) into Quay: ok" >> $WORK_TEST_LOG

echo_step "Be sure to delete the cached agent files, otherwise we may mistakenly use a bad one instead of from the generated archive file! (like with v4.19.18!)"
rm -rf ~/.cache/agent 
echo_step Create the cluster ...
aba cluster --name sno4 --type sno --starting-ip 10.0.1.204 --mmem 20 --mcpu 10 --step install

echo_step Test this cluster type: $NAME ...

echo "Cluster installation test: ok" >> $WORK_TEST_LOG

# Test integrations ...
(
	set -x
	cd sno4

	# Verify at least one operator is available (base has none) and integrate OSUS
	if [ "$NAME" != "base" ]; then
		echo Pausing 100s ...
		sleep 100

		echo Integrating OperatorHub ...
		aba day2  # Connect OperatorHub to reg.

		. <(aba login)   # Access cluster
		. <(aba shell)   # Access cluster

		echo List of packagemanifests:
		oc get packagemanifests

		until oc get packagemanifests | grep cincinnati-operator; do echo -n .; sleep 10; done # cincinnati-operator should always be available for non-base bundles
		echo "OperatorHub integration test: ok" >> $WORK_TEST_LOG

		sleep 60  # Otherwise get "missing cincinnati-operator" error

		aba day2-osus
		echo "OpenShift Update Service (OSUS) integration test: ok" >> $WORK_TEST_LOG
	else
		echo "OperatorHub integration test: n/a" >> $WORK_TEST_LOG
		echo "OpenShift Update Service (OSUS) integration test: n/a" >> $WORK_TEST_LOG
	fi

	echo Running specific tests for bundle type:
	if [ -x $TEMPLATES_DIR/${NAME}-test.sh ]; then
		cp -p $TEMPLATES_DIR/${NAME}-test.sh $WORK_BUNDLE_DIR_BUILD
		# After 30 mins, stop and fail this script
		timeout 1800 $WORK_BUNDLE_DIR_BUILD/${NAME}-test.sh 3>> $WORK_TEST_LOG
	fi

	aba kill  # Poweroff VMs
) 

echo "All tests: passed" >> $WORK_TEST_LOG


#########################################################################
echo_step Cluster installed ok, all tests passed. Building install bundle.

echo_step Determine older bundles ... to delete later

# Before we create the bundle dir, fetch list of old dirs to delete.  Will be deleted at the end of the script!
MAJOR_VER=$(echo $VER | cut -d\. -f1,2)
# Delete any bundles with the exact same name OR e.g. 4.19.10-ocp-* # To replace a bundle rename it to e.g. 4.19.10-ocpv-to-be-removed, and it will be replaced
todel=$(ls -d $CLOUD_DIR/$MAJOR_VER.[0-9]*-$NAME   $CLOUD_DIR/$MAJOR_VER.[0-9]*-$NAME-* 2>/dev/null || true)
ls -l  $CLOUD_DIR
ls -ld $CLOUD_DIR/$MAJOR_VER.[0-9]*-$NAME   $CLOUD_DIR/$MAJOR_VER.[0-9]*-$NAME-* 2>/dev/null || true

[ ! "$todel" ] && echo_green No older install bundles to delete || echo_red Install bundles to delete: $todel

echo_step Create the install bundle dir and copy the files ...

# Create bundle in cloud drive, e.g. /nas/redhat/aba-openshift-install-bundles/4.18.19-ocpv
mkdir -p $CLOUD_DIR_BUNDLE

# Mark it as incomplete
echo "This archive is incomplete or it's still uploading.  Please wait for it to complete!" > $CLOUD_DIR_BUNDLE/$BUNDLE_UPLOADING
sleep 60  # Give the dir and file time to sync into cloud

# Generate and adjust the README with the bundle version and the list of install files etc
# Fetch list of available cli files
s=$(cd cli && echo $(ls -r *.gz) | sed "s/ /\\\n  - /g")

d=$(date -u)

# Fetch list of available operators
op_list=$(for i in $*; do cat $WORK_DIR/test-install/aba/templates/operator-set-$i; done | cut -d'#' -f1 | sed "/^[ \t]*$/d" | sort | uniq | sed "s/^/  - /g")
[ ! "$op_list" ] && op_list="  - No Operators!"

# Create readme file
sed -e "s/<VERSION>/$VER/g" -e "s/<CLIS>/$s/g" -e "s/<DATETIME>/$d/g" < $TEMPLATES_DIR/README.txt > $CLOUD_DIR_BUNDLE/README.txt

# Append to README file
( 
	echo
	cat $WORK_TEST_LOG
	echo
	echo "## List of Operators included in this install bundle:" 
	echo
	echo "$op_list" 
	echo 
	echo "## The oc-mirror Image Set Config file used for this install bundle:"
	echo
	cat $WORK_DIR/test-install/aba/mirror/save/imageset-config-save.yaml 
) >> $CLOUD_DIR_BUNDLE/README.txt

# Copy in the image set config file used (for good measure)
cp $WORK_DIR/test-install/aba/mirror/save/imageset-config-save.yaml $WORK_BUNDLE_DIR_BUILD

## Output the files to copy:
ls -l $WORK_BUNDLE_DIR/ocp_* || true

# Copy the files into the cloud sync dir
cp -v $WORK_BUNDLE_DIR/ocp_* 		$CLOUD_DIR_BUNDLE
rm -fv $WORK_BUNDLE_DIR/ocp_* 

cp -v $WORK_BUNDLE_DIR/CHECKSUM.txt		$CLOUD_DIR_BUNDLE
cp -v $TEMPLATES_DIR/VERIFY.sh 	$CLOUD_DIR_BUNDLE
cp -v $TEMPLATES_DIR/UNPACK.sh 	$CLOUD_DIR_BUNDLE

# Keep a record of how the bundle was created, in case there were any skipped errors!
echo
echo "BUNDLE COMPLETE!"
echo
echo Copy build artifact dir from $WORK_BUNDLE_DIR_BUILD to $CLOUD_DIR_BUNDLE
ls -la $WORK_BUNDLE_DIR_BUILD
cp -rpv $WORK_BUNDLE_DIR_BUILD 		$CLOUD_DIR_BUNDLE

# Remove the warning file
rm -f $CLOUD_DIR_BUNDLE/$BUNDLE_UPLOADING

echo_step "Show content of new bundle in cloud dir $CLOUD_DIR_BUNDLE:"

ls -al $CLOUD_DIR_BUNDLE
ls -al $CLOUD_DIR_BUNDLE/build

echo_step "Delete older bundles? ..."

if [ "$todel" ]; then
	echo Deleting the following old bundles: $todel:
	ls -d $todel
	echo "rm -vrf $todel"
	rm -vrf $todel
else
	echo "No older install bundles to delete!"
fi

# Tidy up ...
echo_step Tidy up ...

echo_step Remove Quay ...

# Uninstall Quay
cd $WORK_DIR/test-install/aba
./install  # install aba
aba -A
#aba -d mirror uninstall -y
aba -d mirror uninstall-docker-registry -y
sudo rm -rf ~/quay-install
sudo rm -rf ~/docker-reg

. ~steve/.proxy-set.sh  # Go online!
# Test connectivity is not working
echo_step Test internet connection with curl google.com ...
curl -sfkIL google.com >/dev/null  # Must work

[ "$NOTIFY" ] && notify.sh "New bundle created for $BUNDLE_NAME"

# Reset
echo_step Reset ...

rm -rf $WORK_DIR/aba
rm -rf $WORK_BUNDLE_DIR
rm -rf $WORK_DIR/test-install

echo Done $0

echo_step Done $0

exit 0

