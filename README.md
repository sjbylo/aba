# Aba is an agent-based wrapper

Aba makes it easier to install an OpenShift cluster - "Cluster Zero" - into a disconnected environment, onto vSphere or 
ESXi (or bare-metal). 
Aba uses the Agent-based installer under the covers which means there is no need to configure a load balancer, a bootstrap node or even require DHCP. 

Aba automatically completes the following:
1. Installs the Quay mirror registry onto localhost (your bastion).  This is optional as you can choose to use your existing registry. 
1. Uses Quay's credentials to build out the Agent-based configuration files.
1. Generates the needed boot ISO.
1. Creates and starts the required VMs in ESXi (or vSphere).
1. Monitors the installation progress. 

## Prerequisites

- A private subnet.
- DNS
   - with A records for OCP API, Ingress and the registry. 
- NTP
   - OCP requires that NTP be configured. 
- Optional vCenter API access. Bare-metal nodes can be booted manually using the generated ISO.
   - ESXi can also be used directly (i.e. without vCenter).
   - Ensure enough privileges to vCenter. See the [documentation](https://docs.openshift.com/container-platform/4.14/installing/installing_vsphere/installing-vsphere-installer-provisioned-customizations.html#installation-vsphere-installer-infra-requirements_installing-vsphere-installer-provisioned-customizations) for more.
- Bastion with Internet access
  - A RHEL host or VM 
  - If needed, Quay mirror registry can be installed here.
  - User account with sudo configured (root access). 
  - 50G disk space in your home directory.  Much more space is required if Operators are intended to be installed. 
  - Internet access from your bastion to download the container images and RPMs. 
     - A "[partially disconnected environment](https://docs.openshift.com/container-platform/4.14/installing/disconnected_install/installing-mirroring-disconnected.html#mirroring-image-set-partial)" is supported. This means the bastion needs to have (temporary) Internet access to download the images and then it needs access to the private subnet to install OpenShift (this can then be fully disconnected).  
     - Fully air-gapped or "[fully disconnected environment](https://docs.openshift.com/container-platform/4.14/installing/disconnected_install/installing-mirroring-disconnected.html#mirroring-image-set-full)" is also supported. 

## Basic use of aba

- First, install a bastion host with a fresh version of RHEL.
   - a 'minimal install' of RHEL 9.3 and RHEL 8.9 has been tested, other recent versions of RHEL should work too.
- Clone or copy this git repository (https://github.com/sjbylo/aba.git) to a user's home directory on the bastion. 
- When OpenShift installs, a secret is needed to allow access and pull images from Red Hat's registry.  Copy your pull secret in JSON format to the file ~/.pull-secret.json (in your $HOME directory).
   - A pull secret can be downloaded from https://console.redhat.com/openshift/install/pull-secret
   - It's a good idea to make the file user read-only, e.g. `chmod 600 ~/.pull-secret.json`.
- Create the needed DNS A records, *for example* (use your domain!):
   - OCP API: api.ocp1.example.com - points to a free IP in your private subnet. 
   - OCP Ingress: *.apps.ocp1.example.com - points to a free IP in your private subnet. 
     - Note: For Single Node OpenShift, the above records should point to a single IP address, used for the single OpenShift node. 
   - Quay mirror registry: registry.example.com - points to the IP address of your RHEL bastion. 

Be sure to set the correct (govc) values to access vCenter in the vmware.conf file.  
Note that ESXi will also work by changing the folder path (see the comments in the vmware.conf file).

To install identical versions of oc, oc-mirror and openshift-install, run:

```
./aba 
```

## Connected mode 

In this mode, the bastion has access to both the Internet and the private subnet (but not necessarily at the same time).

```
cd mirror
make sync
```
This command will:
  - install Quay registry on the bastion.
  - pull images from the Internet and store them in Quay.
  - copy the registry's pull secret and certificate into the 'mirror/deps' dir for later use. 


## Disconnected mode (air-gapped / fully disconnected) 

In this mode, the bastion (external) has access to the Internet only. 

```
cd mirror
make save
```

- This will pull the images and save them to the local directory "mirror/save".

Then, copy the whole aba/ directory and sub-directories to your internal bastion host in the private subnet, e.g. via a thumb drive or DVD. 

Example:

```
# On the external bastion:
cd 		                   # Assuming aba is directly under your $HOME dir
tar czf aba.tgz aba/aba bin aba/*.conf aba/Makefile aba/scripts aba/templates aba/*.md aba/mirror aba/cli 
# Copy the file 'aba.tgz' to your internal bastion.

# Then, on the internal bastion run:
cd
tar xzvf aba.tgz            # Extract the tar file 
sudo dnf install make -y    # Install 'make' 
cd aba             
```

Load the images from local storage to the internal mirror registry.

```
cd mirror
make load
```
- This will install Quay (from the files that were copied above) and then load the images into Quay.


Install OpenShift 

```
make sno
```
- This will create a directory 'sno' and then install SNO OpenShift using the Agent-based installer.  By default, it will use VMware. 
- Be sure to go through *all* the values in 'vmware.conf' and 'aba.conf'.
- Be sure to set up your DNS entries in advance. 
- Aba will show you the installation progress.  If there are any issues - e.g. missing DNS records - fix them and try again.  All commands are idempotent.

```
make compact
```
- Run this to create a compact cluster (functions in a similar way to the above). 

```
make ocp dir=mycluster
```
- This will create a directory 'mycluster', copy the Makefile into it and then run 'make'.

If needed, the following command can be used to monitor the progress of the Agent-based installer.

```
cd sno
make mon
```

Other examples of commands, when working with VMware/ESXi:

```
cd sno                               # change to the directory with the agent-based install files ('sno' is just an example).

make refresh                         # Delete the VMs and re-create them causing the cluster to be re-installed.

make stop                            # Shut down the guest OS (CoreOS) of all VMs in the 'sno' cluster.

make start                           # Power on all VMs in the 'sno' cluster. 

make delete                          # Delete all the VMs in the 'sno' cluster. 
```


## Using an existing registry 

This works as long as your existing registry credential files (pull secret and root CA) are placed at the correct location for aba to find them:
  - mirror/deps/pull-secret-mirror.json   (pull secret file for your registry)
  - mirror/deps/rootCA.pem                (root CA file for your registry) 
Then, manually add your mirror's pull secret to ~/.containers/auth.yaml and ~/.docker/auth.yaml.


# Features that are not implemented yet

- Specifying a different location to install Quay registry data.

- If you want to install some workers with different CPU/MEM sizes (which can be used to install cluster infra sub-systems, e.g. Ceph and/or ES etc - infra nodes), change the VM resources (CPU/RAM) as needed after OpenShift is installed. 

# Miscellaneous

- Once a cluster config directory has been created (e.g. 'compact') and Agent-based configuration has been created, some changes can be made to the 'install-config.yaml' and 'agent-config.yaml' files if needed. Aba can be run again to create the ISO and the VMs etc.  Aba should see the changes and try to preserve and use them.  Simple changes to the files, e.g. IP address changes and default route changes should work fine.  Changes, like adding link bonding may break the command to parse and extract the config.  The following is the script that is used to extract the cluster config from the agent-config yaml files. This must work. 

```
cd compact
scripts/cluster-config.sh        # example execution to show the cluster configuration extracted from the Agend-based files. 
```

- Govc is used to create and manage VMs on ESXi or vSphere.
  - https://github.com/vmware/govmomi/tree/main/govc

