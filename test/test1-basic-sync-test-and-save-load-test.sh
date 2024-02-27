#!/bin/bash -ex
# This test is for a connected bastion.  It will install registry on remote bastion and then sync images and install clusters, 
# ... then savd/load images and install clusters. 

cd `dirname $0`
cd ..

source scripts/include_all.sh
source test/include.sh

[ ! "$target_full" ] && targetiso=target=iso   # Default is to generate 'iso' only   # Default is to only create iso
mylog targetiso=$targetiso

mylog
mylog "===> Starting test $0"
mylog

rm -f ~/.aba.previous.backup

#> test/test.log

> mirror/mirror.conf
make distclean 
### test-cmd 'make -C mirror distclean'
#make uninstall clean 

v=4.14.9
test-cmd -m "Configure aba.conf for version $v and vmware esxi" ./aba --version $v --vmw ~/.vmware.conf.esxi

mylog "Setting 'ask='"
sed -i 's/^ask=[^ \t]\{1,\}\([ \t]\{1,\}\)/ask=\1/g' aba.conf
sed -i 's/^ntp_server=[^ \t]\{1,\}\([ \t]\{1,\}\)/ntp_server=10.0.1.8\1/g' aba.conf

source <(normalize-aba-conf)

### test-cmd 'make -C cli clean'
### test-cmd 'make -C cli'

mylog Revert internal bastion vm to snapshot and powering on ...
(
	source <(normalize-vmware-conf)
	govc snapshot.revert -vm bastion2-internal-rhel8 Latest
	sleep 8
	govc vm.power -on bastion2-internal-rhel8
	sleep 5
)
# Wait for host to come up
ssh $(whoami)@registry2.example.com -- "date" || sleep 2
ssh $(whoami)@registry2.example.com -- "date" || sleep 3
ssh $(whoami)@registry2.example.com -- "date" || sleep 8

# Copy and edit mirror.conf 
scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf

mylog "Confgure mirror to install registry on internal (remote) bastion2"

sed -i "s/registry.example.com/registry2.example.com/g" ./mirror/mirror.conf	# Install on registry2 
sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" ./mirror/mirror.conf	     	# Remote or localhost

#sed -i "s#channel=.*#channel=fast          #g" ./mirror/mirror.conf	    	# test channel
#sed -i "s#reg_root=#reg_root=~/my-quay-mirror#g" ./mirror/mirror.conf	     	# test other storage location
#sed -i "s#reg_pw=.*#reg_pw=             #g" ./mirror/mirror.conf	    	# test random password 
### sed -i "s#tls_verify=true#tls_verify=            #g" ./mirror/mirror.conf  	# test tlsverify = false # sno install fails 
### sed -i "s#reg_port=.*#reg_pw=443             #g" ./mirror/mirror.conf	    	# test port change
#sed -i "s#reg_path=.*#reg_path=my/path             #g" ./mirror/mirror.conf	    	# test path

test-cmd -m "Install mirror on internal bastion" "make -C mirror install"

source <(cd mirror; normalize-mirror-conf)

mylog "Mirror available at $reg_host:$reg_port"

######################
test-cmd -m "Synching cluster images to internal mirror" 'make -C mirror sync'   # This will install mirror and sync

# Install yq for below test!
which yq || (
	mylog Install yq
	curl -sSL -o - https://github.com/mikefarah/yq/releases/download/v4.41.1/yq_linux_amd64.tar.gz | tar -C ~/bin -xzf - ./yq_linux_amd64 && \
		mv ~/bin/yq_linux_amd64 ~/bin/yq && \
		chmod 755 ~/bin/yq
	)

######################
######################
# This test creates the ABI (agent-based installer) config files to check they are valid

for cname in sno compact standard
do
	mkdir -p test/$cname

        mylog "Agent-config file generation test for cluster type '$cname'"

        rm -rf $cname

        test-cmd -m "Creating cluster.conf for $cname cluster" "make $cname target=cluster.conf"
        sed -i "s#mac_prefix=.*#mac_prefix=88:88:88:88:88:#g" $cname/cluster.conf   # make sure all mac addr are the same, not random
        test-cmd -m "Creating install-config.yaml for $cname cluster" "make -C $cname install-config.yaml"
        test-cmd -m "Creating agent-config.yaml for $cname cluster" "make -C $cname agent-config.yaml"

	# There are only run on the very first run to generate the valis files
	# Note that the files test/{sno,compact,standrd}/{install,agent}-config.yaml.example have all been committed into git 
        ### NOT NEEDED [ ! -f test/$cname/install-config.yaml.example ] && cat $cname/install-config.yaml | yq 'del(.additionalTrustBundle,.platform.vsphere.vcenters,.pullSecret)' > test/$cname/install-config.yaml.example
        ### NOT NEEDED [ ! -f test/$cname/agent-config.yaml.example ]   && cat $cname/agent-config.yaml   > test/$cname/agent-config.yaml.example

	# Remove some of the params which either change or cannot be placed into git (FIXME: specify the VC password exactly) 
	cat $cname/install-config.yaml | yq 'del(.additionalTrustBundle,.platform.vsphere.vcenters,.pullSecret)' > test/$cname/install-config.yaml
	cat $cname/agent-config.yaml                                                                             > test/$cname/agent-config.yaml

        # Check if the files DO NOT match (are different)
        if ! diff test/$cname/install-config.yaml test/$cname/install-config.yaml.example; then
		cp test/$cname/install-config.yaml test/$cname/install-config.yaml.failed
		mylog "Config mismatch! See file test/$cname/install-config.yaml.failed"
                exit 1
        fi

        if ! diff test/$cname/agent-config.yaml   test/$cname/agent-config.yaml.example; then
		cp test/$cname/agent-config.yaml test/$cname/agent-config.yaml.failed
		mylog "Config mismatch! See file test/$cname/agent-config.yaml.failed"
                exit 1
        fi

        test-cmd -m "Generate iso file for $cname" "make -C $cname iso"
        #test-cmd "make -C $cname delete"
done

######################
######################


######################
rm -rf sno
test-cmd -m "Installing sno cluster with target option [$targetiso]" make sno $targetiso
test-cmd -m "Setting NTP to be installed" make -C sno ntp
test-cmd -m "Installing SNO cluster" make -C sno mon
test-cmd -m "Deleting sno cluster (if it was created)" make -C sno delete || true

#######################
test-cmd -m "Saving and then loading cluster images into mirror" "make -C mirror save load"  #  This will save, install then load

rm -rf sno
test-cmd -m "Installing sno cluster with target option [$targetiso]" make sno $targetiso

test-cmd -m "Delete cluster (if needed)" make -C sno delete 

test-cmd -m "Uninstall mirror" make -C mirror uninstall 

########################
########################

# Copy and edit mirror.conf 
#cp -f templates/mirror.conf mirror/
#scripts/j2 templates/mirror.conf.j2 > mirror/mirror.conf
#sed -i "s/ocp_target_ver=[0-9]\+\.[0-9]\+\.[0-9]\+/ocp_target_ver=$ocp_version/g" ./mirror/mirror.conf

mylog "Configure mirror to install on internal (remote) bastion in '~/my-quay-mirror', with random password to '/my/path'"

#sed -i "s/registry.example.com/registry2.example.com/g" ./mirror/mirror.conf	# Install on registry2 
#sed -i "s#reg_ssh=#reg_ssh=~/.ssh/id_rsa#g" ./mirror/mirror.conf	     	# Remote or localhost

sed -i "s#reg_root=#reg_root=~/my-quay-mirror#g" ./mirror/mirror.conf	     	# test other storage location
sed -i "s#reg_pw=.*#reg_pw=             #g" ./mirror/mirror.conf	    	# test random password 
### sed -i "s#tls_verify=true#tls_verify=            #g" ./mirror/mirror.conf  	# test tlsverify = false # sno install fails 
sed -i "s#reg_path=.*#reg_path=my/path             #g" ./mirror/mirror.conf	    	# test path

test-cmd -m "Installing mirror registry" make -C mirror install 

######
# Remove all traces of CA files 
### rm -f mirror/regcreds/*pem   # Test without CA file
### sudo rm -f /etc/pki/ca-trust/source/anchors/rootCA*pem
### sudo update-ca-trust extract

rm -rf mirror/save   # The process will halt, otherwise with "You already have images saved on local disk"

source <(cd mirror; normalize-mirror-conf)

mylog "Mirror available at $reg_host:$reg_port"

######################
test-cmd make -C mirror sync   # This will install and sync

rm -rf sno
test-cmd -m "Installing sno cluster" make sno

#######################

test-cmd -m "Saving and loading images into mirror" make -C mirror save load   #  This will save, install then load

rm -rf sno
test-cmd -m "Installing sno cluster" make sno $targetiso

test-cmd -m "Deleting cluster" make -C sno delete 

mylog Removing vmware config file

> vmware.conf
rm -rf compact
test-cmd -m "Creating compact iso file" make compact target=iso # Since we're testing bare-metal, only create iso

test-cmd -m "Uninstalling mirror registry" make -C mirror uninstall 

mylog
mylog "===> Completed test $0"
mylog

[ -f test/test.log ] && cp test/test.log test/test.log.bak

