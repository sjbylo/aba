#!/bin/bash -ex
# This test installs a mirror reg. on the internal bastion (just for testing) and then
# treats that registry as an "existing registry" in the test internal workflow. 

# Required: 2 bastions (internal and external), for internal (no direct Internet) only yum works via a proxy. For external, the proxy is fully configured. 
# I.e. Internal bastion has no access to the Internet.  External has full access. 
# Ensure passwordless ssh access from bastion1 (external) to bastion2 (internal). Script uses rsync to copy over the aba repo. 
# Be sure no mirror registries are installed on either bastion before running.  Internal bastion2 can be a fresh "minimal install" of RHEL8/9.

sudo dnf remove make jq bind-utils nmstate net-tools skopeo python3-jinja2 python3-pyyaml openssl coreos-installer -y

### # FIXME: test for pre-existing rpms!  we don't want yum to run at all as it may error out
### sudo dnf install -y $(cat templates/rpms-internal.txt)
### sudo dnf install -y $(cat templates/rpms-external.txt)

cd `dirname $0`
cd ..  # Change into "aba" dir

rm -fr ~/.containers ~/.docker

source scripts/include_all.sh && trap - ERR
source test/include.sh

[ ! "$target_full" ] && targetiso=target=iso   # Default is to generate 'iso' only   # Default is to only create iso
mylog targetiso=$targetiso

mylog
mylog "===> Starting test $0"
mylog Test to install a local reg. on registry2.example.com and save + copy + load images.  Install sno ocp and a test app and svc mesh.
mylog

ntp=10.0.1.8 # If available

rm -f ~/.aba.previous.backup

######################
# Set up test 

which make || sudo dnf install make -y

> mirror/mirror.conf
test-cmd -m "Cleaning up mirror - distclean" "make -C mirror distclean" 
rm -rf sno compact standard 

v=4.13.30
v=4.15.0
rm -f aba.conf  # Set it up next
test-cmd -m "Configuring aba.conf for version $v and vmware vcenter" ./aba --version $v --vmw ~/.vmware.conf.esxi

# Do not ask to delete things
mylog "Setting ask="
sed -i 's/^ask=[^ \t]\{1,\}\([ \t]\{1,\}\)/ask=\1/g' aba.conf

mylog "Setting ntp_server=$ntp" 
[ "$ntp" ] && sed -i "s/^ntp_server=\([^#]*\)#\(.*\)$/ntp_server=$ntp    #\2/g" aba.conf

source <(normalize-aba-conf)

# Be sure this file exists
test-cmd -m "Init test: download mirror-registry.tar.gz" "make -C test mirror-registry.tar.gz"

bastion2=10.0.1.6

#################################
# Copy and edit mirror.conf 

sudo dnf install python36 python3-jinja2 -y
scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf

mylog "Test the internal bastion (registry2.example.com) as mirror"

mylog "Setting reg_host=registry2.example.com"
sed -i "s/registry.example.com/registry2.example.com/g" ./mirror/mirror.conf
#sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" ./mirror/mirror.conf


#################################
mylog Revert vm snapshot of the internal bastion vm and power on
(
	source <(normalize-vmware-conf)
	govc snapshot.revert -vm bastion2-internal-rhel8 Latest
	sleep 8
	govc vm.power -on bastion2-internal-rhel8
	sleep 5
)
# Wait for host to come up
ssh $reg_ssh_user@registry2.example.com -- "date" || sleep 2
ssh $reg_ssh_user@registry2.example.com -- "date" || sleep 3
ssh $reg_ssh_user@registry2.example.com -- "date" || sleep 8
ssh $reg_ssh_user@registry2.example.com -- "sudo dnf install podman make python3-jinja2 python3-pyyaml jq bind-utils nmstate net-tools skopeo openssl coreos-installer -y"
#################################

source <(cd mirror && normalize-mirror-conf)

test-cmd -r 99 3 -m "Saving images to local disk" "make save" 

# Smoke test!
[ ! -s mirror/save/mirror_seq1_000000.tar ] && echo "Aborting test as there is no save/mirror_seq1_000000.tar file" && exit 1

# If the VM snapshot is reverted, as above, no need to delete old files
test-cmd -h $bastion2 -m  "Clean up home dir on internal bastion" "rm -rf ~/bin/* ~/aba"

ssh $reg_ssh_user@$bastion2 "rpm -q make  || sudo yum install make -y"

mylog Copy tar+ssh archives to internal bastion
make -s -C mirror inc out=- | ssh $bastion2 -- tar xvf -

### echo "Install the reg creds, simulating a manual config" 
### ssh $reg_ssh_user@$bastion2 -- "cp -v ~/quay-install/quay-rootCA/rootCA.pem ~/aba/mirror/regcreds/"  
### ssh $reg_ssh_user@$bastion2 -- "cp -v ~/.containers/auth.json ~/aba/mirror/regcreds/pull-secret-mirror.json"

######################
mylog Runtest: START - airgap

test-cmd -h $bastion2 -r 99 3 -m  "Loading cluster images into mirror on internal bastion" "make -C aba load" 

mylog "Running 'make sno' on internal bastion"

test-cmd -h $bastion2 -m  "Tidying up internal bastion" "rm -rf aba/sno" 

[ "$targetiso" ] && mylog Creating the cluster iso only 
test-cmd -h $bastion2 -m  "Installing sno/iso $targetiso" "make -C aba sno $targetiso" 

test-cmd -h $bastion2 -m  "Setting master memory to 24" "sed -i 's/^master_mem=.*/master_mem=24/g' aba/sno/cluster.conf"

######################
mylog Now adding more images to the mirror registry
######################

mylog Runtest: vote-app

mylog 
mylog Add ubi9 image to imageset conf file 
cat >> mirror/save/imageset-config-save.yaml <<END
  additionalImages:
  - name: registry.redhat.io/ubi9/ubi:latest
END

test-cmd -r 99 3 -m "Saving ubi images to local disk on `hostname`" "make -C mirror save" 

mylog Copy tar+ssh archives to internal bastion
make -s -C mirror inc out=- | ssh $bastion2 -- tar xvf -

test-cmd -h $bastion2 -r 99 3 -m  "Loading UBI images into mirror" "make -C aba/mirror load" 

mylog 
mylog Add vote-app image to imageset conf file 
cat >> mirror/save/imageset-config-save.yaml <<END
  - name: quay.io/sjbylo/flask-vote-app:latest
END

test-cmd -r 99 3 -m "Saving vote-app image to local disk" " make -C mirror save" 

mylog Copy repo to internal bastion
make -s -C mirror inc out=- | ssh $bastion2 -- tar xvf -

test-cmd -h $bastion2 -r 99 3 -m  "Loading vote-app image into mirror" "make -C aba/mirror load" 

test-cmd -h $bastion2 -m  "Installing sno cluster, ready to deploy test app" "make -C aba/sno"

test-cmd -h $bastion2 -m  "Listing VMs" "make -C aba/sno ls"

test-cmd -h $bastion2 -m  "Deploying test vote-app" "aba/test/deploy-test-app.sh"


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
make -s -C mirror inc out=- | ssh $bastion2 -- tar xvf -

test-cmd -h $bastion2 -r 99 3 -m  "Loading images to mirror" "make -C aba/mirror load" 

test-cmd -h $bastion2 -m  "Configuring day2 ops" "make -C aba/sno day2"

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
	# FIXME: so no need to make these changes
	sed -i "s#quay\.io#$reg_host:$reg_port/$reg_path#g" */*.yaml */*/*.yaml */*/*/*.yaml &&
	sed -i "s/source: .*/source: cs-redhat-operator-index/g" operators/* 
) 

mylog Copy tar+ssh archives to internal bastion
rm -f test/mirror-registry.tar.gz  # No need to copy this over!
make -s -C mirror inc out=- | ssh $bastion2 -- tar xvf - 

test-cmd -h $bastion2 -r 99 3 -m  "Loading jaeger operator images to mirror" "make -C aba/mirror load" 

test-cmd -m "Pausing for 60s to let OCP to settle" sleep 60    # For some reason, the cluster was still not fully ready in tests!

# Sometimes the cluster is not fully ready... OCP API can fail, so re-run 'make day2' ...
test-cmd -h $bastion2 -r 99 3 -m "Run 'day2' attempt number $i ..." "make -C aba/sno day2" && break || true  # Install CA cert and activate local op. hub

# Wait for https://docs.openshift.com/container-platform/4.11/openshift_images/image-configuration.html#images-configuration-cas_image-configuration 
test-cmd -m "Pausing for 30s to let OCP to settle" sleep 30  # And wait for https://access.redhat.com/solutions/5514331 to take effect 

test-cmd -h $bastion2 -m "Deploying service mesh with test app" "aba/test/deploy-mesh.sh"

sleep 30  # Slep in case need to check the cluster

test-cmd -h $bastion2 -m  "Deleting sno cluster" "make -C aba/sno delete" 

######################

test-cmd -h $bastion2 -m  "Uninstalling mirror registry on internal bastion" "make -C aba/mirror uninstall"

mylog
mylog "===> Completed test $0"
mylog

rm -rf test/mesh 

[ -f test/test.log ] && cp test/test.log test/test.log.bak

