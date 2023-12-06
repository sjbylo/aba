# Aba is an agent-based wrapper

Aba makes it easier to install an OpenShift cluster - "Cluster Zero" - into a disconnected environment, onto vSphere or 
ESXi (or bare-metal) using the Agent-based installer.

Aba automatically completes the following:
1. Installs the Quay mirror registry onto localhost (your bastion).  This is optional as you can choose to use your existing registry. 
1. Uses Quay's credentials to build out the Agent-based configuration files.
1. Generates the needed boot ISO.
1. Creates the required VMs in ESXi (or vSphere) and powers them on. 
1. Monitors the installation progress. 

## Prerequisites

- A private subnet.
- DNS
   - with A records for OCP API, Ingress and registry. 
- NTP
   - OCP requires that ESXi be configured with NTP.
- vSphere with vCenter API access. This is optional, you can manually boot your bar-metal machines using the ISO.
   - ESXi can also be used on its own (i.e. without vCenter).
   - Ensure enough privileges to vCenter, see the [documentation](https://docs.openshift.com/container-platform/4.14/installing/installing_vsphere/installing-vsphere-installer-provisioned-customizations.html#installation-vsphere-installer-infra-requirements_installing-vsphere-installer-provisioned-customizations) for more.
- Bastion with Internet access
  - a RHEL host or VM (where Quay mirror registry can be installed). 
  - Root access with sudo.
  - 50G or more disk space in your home directory. 
  - Internet access from your bastion to download the container images.
     - A "[partially disconnected environment](https://docs.openshift.com/container-platform/4.14/installing/disconnected_install/installing-mirroring-disconnected.html#mirroring-image-set-partial)" is supported. This means the bastion needs to have (temporary) Internet access to download the images and then it needs access to the private subnet to install OpenShift (can be disconnected).  
     - Fully air-gapped or "[fully disconnected environment](https://docs.openshift.com/container-platform/4.14/installing/disconnected_install/installing-mirroring-disconnected.html#mirroring-image-set-full)" is also supported. 

## Basic use of aba

- First, install a bastion host with a fresh version of RHEL
   - a 'minimal install' of RHEL 9.3 and RHEL 8.9 has been tested, other recent versions of RHEL should work too.
- Clone or copy this git repository (https://github.com/sjbylo/aba.git) to a user's home directory on the bastion. 
  - IMPORTANT: run 'git checkout dev' or 'git clone -b dev https://github.com/sjbylo/aba.git' to use the 'dev' branch. 
- Copy your pull secret in JSON format to the file ~/.pull-secret.json (in your $HOME directory).
   - It's a good idea to make the file user read-only, e.g. `chmod 600 ~/.pull-secret.json`.
   - A pull secret can be downloaded from https://console.redhat.com/openshift/install/pull-secret
- Create the needed DNS A records for the following, *for example* (use your own domain):
   - OCP API: api.ocp1.example.com - points to a free IP in your private subnet. 
   - OCP Ingress: *.apps.ocp1.example.com - points to a free IP in your private subnet. 
     - Note: For Single Node OpenShift, the above records should point to a single IP address, used for the single OpenShift node. 
   - Quay mirror registry: registry.example.com - points to the IP address of your RHEL bastion. 

Be sure to set the correct (govc) values for vCenter in vmware.conf.  Note that ESXi will also work (see the comments in vmware.conf).

To install identical versions of oc, oc-mirror and openshift-install, run:
```
./aba 
```

## Connected mode 

- Bastion has access to both the Internet and the private subnet (but not necessarily at the same time).

```
cd mirror
make sync
```
This command will:
  - install Quay registry on the bastion.
  - pull images from the Internet and write them to quay.
  - copy the registry pull secret and certificate into the 'mirror/deps' dir for later use. 


## Disconnected mode (air-gapped) 

- Bastion (external) has access to the Internet only.

```
cd mirror
make save
```
- This will pull the images and save them to a local directory mirror/save.

Then, copy *the whole aba/ directory* and sub-directories to your internal bastion host in the private subnet, e.g. via a thumb drive or DVD. 

Example:

```
# On the external bastion:
cd 		# Assuming aba is directly under your $HOME dir
tar czf aba.tgz aba/aba bin aba/*.conf aba/Makefile aba/scripts aba/templates aba/*.md aba/mirror aba/cli 
# Copy the file 'aba.tgz' to your internal bastion.

# Then, on the internal bastion run:
cd
tar xzvf aba.tgz 
sudo dnf install make -y 
cd aba
```

Load the images from local storage to the internal mirror registry.

```
cd mirror
make load
```
- This will install quay (from the files that were copied) and then load the images into quay.


Install OpenShift 

```
make sno
```
- This will create a directory 'sno' and then install SNO OpenShift using Agent-based installer.  By default it will use VMware. 
- Be sure to go through *all* the values in 'vmware.conf' and 'aba.conf'. Be sure to set up your DNS entries in advance. 
- aba will show you the install progress.  If there are any issues - e.g. missing DNS records - fix them and then run the same command again.  All commands should be idempotent.

```
make compact
```
- Run this to create a compact cluster.

```
make ocp dir=mycluster
```
- This will create directory 'mycluster', copy the Makefile into it and then run 'make'.

You can also run the following command to monitor the progress of the Agent-based installer.

```
cd sno
make mon
```

Other examples of commands, when working with VMware:

```
cd sno                               # change to the directory with the agent-based install files ('sno' is just an example).

make refresh                         # Delete the VMs and re-create them causing a re-install
                                     # of the 'compact' cluster.
make stop                            # Shut down the guest OS (CoreOS) of all VMs in the
                                     # 'compact' cluster.
make start                           # Power on all VMs in the 'compact' cluster. 

make delete                          # Delete all the VMs in the 'compact' cluster. 
```


Using an existing registry.  

This should work as long as your existing Quay's credential files are placed at the right location where aba looks for them:
  - mirror/deps/pull-secret-mirror.json   (pull secret for your registry)
  - mirror/deps/rootCA.pem                (the root CA key file for your registry) 

# Features that are not implemented yet

- Specifying a different location to install Quay registry data.

- If you want to install some workers with different CPU/MEM sizes (which can be used to install cluster infra sub-systems, e.g. Ceph and/or ES etc - infra nodes). These VMs can be changed after OpenShift has been installed. 

# Miscellaneous

- Once a cluster config directory has been created (e.g. compact) some changes can be made to the 'install-config.yaml' and 'agent-config.yaml' files if needed and aba can be run again to create the ISO and the VMs etc.  Aba should see the changes and try to preserve and use them.  Simple changes to the files, e.g. IP address changes, default route should work fine.  Changes, like adding link bonding may break the command to parse and extract the config.  The following is the script that is used to extract the cluster config from the agent-config yaml files. This must work. 

```
cd compact
scripts/cluster-config.sh     # example execution 
```

- Govc is used to create and manage VMs on ESXi or vSphere.
  - https://github.com/vmware/govmomi/tree/main/govc

