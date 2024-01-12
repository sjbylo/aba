# Aba is an agent-based wrapper

Aba makes it easier to install an OpenShift cluster - "Cluster Zero" - into a disconnected environment, onto vSphere or 
ESXi or bare-metal. 
Aba uses the [Agent-based installer](https://docs.openshift.com/container-platform/4.14/installing/installing_with_agent_based_installer/preparing-to-install-with-agent-based-installer.html) which means there is no need to configure a load balancer, a bootstrap node or even require DHCP. 

Aba automatically completes the following:
1. Installs the Quay mirror registry onto localhost or a remote host. This is optional as you can choose to use your existing registry. 
1. Uses Quay's credentials and other inputs to build out the Agent-based configuration files.
1. Triggers the generation of the needed agent-based boot ISO.
1. Optionally creates the required VMs in ESXi (or vSphere).
1. Monitors the installation progress. 


## Prerequisites

- A private subnet (although optional).
- DNS
   - with A records for OpenShift API, Ingress and the mirror registry. 
- NTP
   - OpenShift requires that NTP be available.
- Optional vCenter API access. Bare-metal nodes can be booted manually using the generated ISO.
   - ESXi can also be used directly (i.e. without vCenter).
   - Ensure enough privileges to vCenter. If you don't want to provide 'admin' privileges see the [vCenter account privileges](https://docs.openshift.com/container-platform/4.14/installing/installing_vsphere/installing-vsphere-installer-provisioned-customizations.html#installation-vsphere-installer-infra-requirements_installing-vsphere-installer-provisioned-customizations) documentation for more.
- Bastion with Internet access:
  - A RHEL host or VM 
  - If needed, the Quay mirror registry can be installed here.
  - User account with sudo configured (root access). 
  - 50G or more of disk space in your home directory.  Much more space is required if Operators are intended to be installed. 
  - Internet access from your bastion to download the container images and RPMs. 
     - A "[partially disconnected environment](https://docs.openshift.com/container-platform/4.14/installing/disconnected_install/installing-mirroring-disconnected.html#mirroring-image-set-partial)" is supported. This means the bastion needs to have (temporary) Internet access to download the images and then it needs access to the private subnet to install OpenShift.   See 'Connected mode' below.
     - Fully air-gapped or "[fully disconnected environment](https://docs.openshift.com/container-platform/4.14/installing/disconnected_install/installing-mirroring-disconnected.html#mirroring-image-set-full)" is also supported.  See 'Disconnected mode' below.


## Initial Steps

- First, install a bastion host with a fresh version of RHEL.
   - a 'minimal install' of RHEL 9.3 and RHEL 8.9 has been tested, other recent versions of RHEL should work too.
- Clone or copy this git repository (https://github.com/sjbylo/aba.git) to a user's home directory on the bastion. 
- To install OpenShift, a secret is needed to allow access to, and pull images from, Red Hat's registry.  Copy your pull secret in JSON format to the file ~/.pull-secret.json (in your $HOME directory).
   - A pull secret can be downloaded from https://console.redhat.com/openshift/install/pull-secret
   - It's a good idea to make the file user read-only, e.g. `chmod 600 ~/.pull-secret.json`.
- Create the needed DNS A records, *for example* (use your domain!):
   - OpenShift API: api.ocp1.example.com 
     - points to a free IP in your private subnet. 
   - OpenShift Ingress: *.apps.ocp1.example.com 
     - points to a free IP in your private subnet. 
     - Note: For Single Node OpenShift (SNO), the above records should point to a single IP address, used for the single OpenShift node. 
   - Quay mirror registry: registry.example.com 
     - points to the IP address where you want to install Quay (e.g. your bastion) or to your existing registry. 
- If you are using an existing registry:
  - Copy your existing registry's credential files (pull secret and root CA) into the 'mirror/deps' directory, e.g.:
    - mirror/deps/pull-secret-mirror.json   (pull secret file for your registry)
    - mirror/deps/rootCA.pem                (root CA file for your registry) 
  - Later, when the boot ISO is created, these files will be used. 
- Finally, run ./aba command to initialize the installation process (see below).


## Getting Started with aba

To set the version of OpenShift to install and, if needed, to download identical versions of oc, oc-mirror and openshift-install, run:

```
./aba 
```

Now, continue with either 'connected mode' or 'disconnected mode' below. 


## Connected mode 

In this mode, the bastion has access to both the Internet and the private subnet (but not necessarily at the same time).

```
make sync
```
This command will:
  - for an existing registry, check the connection is available and working (be sure to set up your registry credentials first! See above for more).
  - or, installs Quay registry on the bastion (or remote bastion) and copies the generated pull secret and certificate into the 'mirror/deps' directory for later use.
  - pull images from the Internet and store them in the registry.

Now continue with "Install OpenShift" below.


## Disconnected mode (air-gapped / fully disconnected) 

In this mode, your external bastion has access to the Internet but no access to the private network.
There is also an internal bastion host in a private subnet.

```
make save
```

- This will pull the images from the Internet and save them to the local directory "mirror/save". Make sure there is enough disk space (30+ GB) here!

Then, copy the whole aba/ directory and sub-directories to your internal bastion host in your private subnet, e.g. via a thumb drive. 

Example:

```
# On the external bastion:
# Mount your thumbdrive and:

make tar name=/dev/path/to/thumbdrive 


# Or, do this manually 
cd 		                   # Assuming aba is directly under your $HOME dir
tar czf /path/to/thumbdrive/aba.tgz $(find bin aba -type f ! -path "aba/.git*" -a ! -path "aba/cli/*" -a ! -path "aba/mirror/mirror-registry" -a ! -path "aba/mirror/*.tar")

# Copy the file 'aba.tgz' to your internal bastion via the thumb drive. 

# Then, on the internal bastion run:
cd
tar xzvf aba.tgz            # Extract the tar file. Ensure file timestamps are kept the same as on the external bastion.
cd aba             
```

Load the images from local storage to the internal mirror registry.

```
sudo dnf install make -y 
make load
```
- This will install Quay (from the files and configuration that were copied above) and then load the images into Quay.
- Note that the internal bastion will need to install RPMs, e.g. from Satellite (or configure 'dnf' to use a proxy for testing).

Now continue with "Install OpenShift" below.

## Install OpenShift 

Edit the file 'templates/aba-sno.conf' to match your environment. 

```
make sno
```
- This will create a directory 'sno' and then install SNO OpenShift using the Agent-based installer.  If you are using vmware it will create the VMs for you.
- Be sure to go through *all* the values in 'aba/vmware.conf' and 'sno/aba.conf'.
- Be sure to set up your DNS entries in advance. See above on Prerequisites. 
- Aba will show you the installation progress.  You can also run 'make ssh' to log into the rendezvous server to troubleshoot. If there are any issues - e.g. incorrect DNS records - fix them and try again.  All commands are idempotent.

```
make compact    (or 'make standard' for 3+2)
```
- Run this to create a compact cluster (works in a similar way to the above). 

```
make ocp name=mycluster
```
- This will create a directory 'mycluster', copy the Makefile into it and then run 'make'.

If needed, the following command can be used to monitor the progress of the Agent-based installer.

```
cd sno
make mon
```

Get help from a Makefile using 'make help'

After OpenShift has been installed you will see the following:

```
INFO Install complete!                            
INFO To access the cluster as the system:admin user when using 'oc', run 
INFO     export KUBECONFIG=/home/steve/aba/compact/iso-agent-based/auth/kubeconfig 
INFO Access the OpenShift web-console here: https://console-openshift-console.apps.compact.example.com 
INFO Login to the console with user: "kubeadmin", and password: "XXYZZ-XXYZZ-XXYZZ-XXYZZ" 
```

If you just want to create the agent-based iso file to boot bare-metal nodes, use "cd sno; make iso"

If OpenShift fails to install, see the [Troubleshooting](Troubleshooting.md) readme. 

Other examples of commands, when working with VMware/ESXi:

```
cd sno           # change to the directory with the agent-based install files ('sno' is just an example).

make refresh     # Delete the VMs and re-create them causing the cluster to be re-installed.

make stop        # Shut down the guest OS (CoreOS) of all VMs in the 'sno' cluster.

make start       # Power on all VMs in the 'sno' cluster. 

make delete      # Delete all the VMs in the 'sno' cluster. 

make help        # This is available in all Makefiles (in aba/  aba/mirror/  aba/cli/ and aba/<mycluster>/) 
```


## Features that are not implemented yet

- Make it easier to install Operators (ImageContentSourcePolicy and CatalogSource) once OpenShift has been installed.

- Make it easier to integrate with vSphere, including storage. 

- Configure htpasswd login, add users, disable kubeadmin.

- Disable OperatorHub and configure the internal registry to serve images.

- Use PXE boot as alternative to ISO upload.


## Miscellaneous

- Once a cluster config directory has been created (e.g. 'compact') and Agent-based configuration has been created, some changes can be made to the 'install-config.yaml' and 'agent-config.yaml' files if needed. 'make' can be run again to re-create the ISO and the VMs etc.  Aba should see the changes and try to preserve and use them.  Simple changes to the files, e.g. IP address changes and default route changes should work fine.  Changes, like adding link bonding may break the command to parse and extract the config.  The following is the script that is used to extract the cluster config from the agent-config yaml files. This script must work for the VMs to be created. 

```
cd compact
scripts/cluster-config.sh        # example execution to show the cluster configuration extracted from the Agend-based files. 
```

- If you want to install workers with different CPU/MEM sizes (which can be used to install cluster infra sub-systems, e.g. Ceph and/or ES etc - infra nodes), change the VM resources (CPU/RAM) as needed after OpenShift is installed (if using VMs).

- Govc is used to create and manage VMs on ESXi or vSphere.
  - https://github.com/vmware/govmomi/tree/main/govc

Be sure to set the correct (govc) values to access vCenter in the vmware.conf file.  
Note that ESXi will also work by changing the folder path (see the comments in the vmware.conf file).


