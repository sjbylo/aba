# Aba is tooling, wrapped around the agent-based installer for OpenShift.

Aba makes it easier to install an OpenShift cluster - "Cluster Zero" - into a fully or partially disconnected environment, either onto vSphere, ESXi or bare-metal. 
Because Aba uses the [Agent-based installer](https://docs.openshift.com/container-platform/4.15/installing/installing_vsphere/installing-vsphere-agent-based-installer.html) there is no need to configure a load balancer, a bootstrap node or even require DHCP. 

Aba automatically completes the following:
1. Makes use of any existing container registry or installs the Quay mirror registry appliance for you. 
1. Uses the registry's credentials and other inputs to generate the Agent-based configuration files.
1. Triggers the generation of the agent-based boot ISO. 
1. Optionally creates the required VMs in ESXi or vSphere.
1. Monitors the installation progress. 
1. Allows for adding more images (e.g. Operators) as a day 1 or 2 operation.
1. Helps to configure the OperatorHub using the internal registry. 
1. Helps by executing several workarounds for some typical issues with disconnected environments.
1. Enables the integration with vSphere as a day 2 operation (day 1 comming with OCP v4.15+)

Use aba if you want to get OpenShift up and running quickly in an air-gapped environment without having to study the documentation in detail. 

For the impatient: clone this repo, install and run 'make'.  You will be guided through the process. 

## Quick Guide

For those who are impatient...

```
git clone https://github.com/sjbylo/aba.git
cd aba
./aba
```
- Clone the repo, install 'make' and configure high-level settings, e.g. target OCP version, your domain name etc.
- Decide if you want to use VMware or ESXi or not. 

```
make install 
```
- Configure and connect to your existing container registry or install a new quay appliance registry.

```
make sync
```
- Copy the required images directly to the mirror registry (for connected environments).
- Fully air-gapped, disconnected environments are also supported. 

```
make sno
```
- Create the Agent-based config files, generate the Agent-based iso file, create and boot the VMs.
- Install Single Node OpenShift 

```
make mon
```
- Monitor the installation progress.

```
make help
```
- See what other helper commands are available. 

Read more for all the details.

## Prerequisites

The usual things you need to install OpenShift using the Agent-based installer. 

- **DNS**
   - with A records for OpenShift API, Ingress and the internal mirror registry.
- **NTP**
   - OpenShift requires that NTP be available. Installation is possible without an NTP server. However, asynchronous server clocks will cause errors, which NTP server prevents.
- **Private subnet** (optional)
- **One or two Bastion hosts**
  - Connected mode: A RHEL VM with connectivity to both the external and the internal network. 
  - Disconnected mode: A RHEL VM in the private network and another RHEL VM (or a Fedora laptop) in the internet facing network. 
  - A user account with sudo configured (i.e. with root access). 
  - 40GB or more of disk space.  Much more space is required if Operators will be installed (400+ GB).
  - Internet access from your connected bastion (or laptop) to download the container images and RPMs. 
     - A "[partially disconnected environment](https://docs.openshift.com/container-platform/4.14/installing/disconnected_install/installing-mirroring-disconnected.html#mirroring-image-set-partial)" is supported. This means the bastion needs to have (temporary) Internet access to download the images and then it needs access to the private subnet to install OpenShift.   See 'Connected mode' below.
     - Fully air-gapped or "[fully disconnected environment](https://docs.openshift.com/container-platform/4.14/installing/disconnected_install/installing-mirroring-disconnected.html#mirroring-image-set-full)" is also supported.  For this, 2 bastions are required.  See 'Disconnected mode' below.
- **Platform** (optional)
   - vCenter or ESXi API access. 
      - Ensure enough privileges to vCenter. If you don't want to provide 'admin' privileges see the [vCenter account privileges](https://docs.openshift.com/container-platform/4.14/installing/installing_vsphere/installing-vsphere-installer-provisioned-customizations.html#installation-vsphere-installer-infra-requirements_installing-vsphere-installer-provisioned-customizations) documentation for more.
   - Bare-metal
      - Note that bare-metal nodes can be booted manually using the generated ISO. Mac addresses can be set in the 'install-config.yaml' file.


## Initial Steps

- **Bastion**
   - First, install a bastion host with a fresh version of RHEL. Fedora can also be used except Quay mirror fails to install on it. 
   - a 'minimal install' of RHEL 9.3, RHEL 8.9 and Fedora 39 have been tested, other recent versions of RHEL/Fedora should work too.
      - Note that on Fedora 39, the mirror registry failed to install due to an [unexpected keyword argument 'cert_file'](https://github.com/quay/mirror-registry/issues/140) error, but remote installs of the Quay appliance (from Fedora) worked ok. 
- **Git repo**
   - Clone or copy this git repository (https://github.com/sjbylo/aba.git) to your user's *home directory* on the external bastion (or on a Fedora laptop). 
   - Ensure sudo is configured. 
- **Pull Secret**
   - To install OpenShift, a secret is needed to allow access to and pull images from, Red Hat's registry.  Copy your pull secret in JSON format to the file '~/.pull-secret.json' (in your $HOME directory).
      - A pull secret can be downloaded from https://console.redhat.com/openshift/install/pull-secret
      - It's a good idea to make the file user read-only, e.g. `chmod 600 ~/.pull-secret.json`.
- **DNS**
   - Create the required DNS A records, *for example* (use your domain!):
      - OpenShift API: api.ocp1.example.com 
        - points to a free IP in your private subnet. 
      - OpenShift Ingress: *.apps.ocp1.example.com 
        - points to a free IP in your private subnet. 
        - Note: For Single Node OpenShift (SNO), the above records should point to a single IP address, used for the single OpenShift node. 
      - Quay mirror registry: registry.example.com 
        - points to the IP address of the registry.  This can be either the one you want installed or your existing registry. 
- **Registry**
   - If you are using an existing registry:
     - Copy your existing registry's credential files (pull secret and root CA) into the 'mirror/regcreds' directory, e.g.:
       - mirror/regcreds/pull-secret-mirror.json   (pull secret file for your registry)
       - mirror/regcreds/rootCA.pem                (root CA file for your registry) 
     - Later, when the images are pushed to the registry, these files will be used. 
- **Finally**
   - run the ./aba command to initialize the installation process (see 'Getting Started' below).


## Getting Started with aba

To set the version of OpenShift to install and, if needed, to download identical versions of oc, oc-mirror and openshift-install, run:

```
./aba 
```

Note that this command will create the 'aba.conf' file which contains some values that you will *want to change*, e.g. your domain name, your network address etc.

Now, continue with either 'Connected mode' or 'Disconnected mode' below. 


## Connected mode 

In this mode, the bastion has access to both the Internet and the private subnet (but not necessarily at the same time).

```
make sync
```
This command will:
  - for an existing registry, check the connection is available and working (be sure to set up your registry credentials first! See above for more).
  - or, installs Quay registry on the bastion (or remote bastion) and copies the generated pull secret and certificate into the 'mirror/regcreds' directory for later use.
  - pull images from the Internet and store them in the registry.

Now continue with "Install OpenShift" below.

Note that the above 'connected mode workflow' can be repeated, for example to install Operators or to upgrade OpenShift, by changing the 'sync/imageset-sync.yaml' file and running 'make sync' again.

## Disconnected mode (air-gapped / fully disconnected) 

In this mode, your external bastion has access to the Internet but no access to the private network.
There is also an internal bastion host in a private subnet.

```
make save
```

- This will pull the images from the Internet and save them to the local directory "mirror/save". Make sure there is enough disk space (30+ GB or much more for Operators)!

Then, using 'make inc', copy the whole aba/ directory and sub-directories to your internal bastion host in your private subnet via a portable storage device, e.g. a thumb drive. 

Example:

```
# On the external bastion:
# Mount your thumb drive and:

make inc                                          # Write tar archive to /tmp
or
make inc out=/dev/path/to/thumbdrive              # Write archive to the device mounted at /dev/path/to/thumbdrive
or
make inc out=- | ssh user@host "cat > aba.tgz"    # Archive and write to external host

# Copy the file 'aba.tgz' to your internal bastion via your portable storage device.

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
- This will (if required) install Quay (from the files and configuration that were archived & copied above) and then load the images into Quay.
- Note that the internal bastion will need to install RPMs from a suitable repository (for testing it's possible to configure 'dnf' to use a proxy).
- If rpms are not readily available in your private network, the command 'make rpms' can help by downloading the needed rpms, which can then be copied to the internal bastion and installed with 'dnf localinstall rpms/*.rpm'.  Note this will only work if your external and internal bastions are running the same version of RHEL. 

Now continue with "Install OpenShift" below.

Note that the above 'air-gapped workflow' can be repeated in the *exact same way*, for example to install Operators or to upgrade OpenShift.

For example, by:
- editing the 'save/imageset-save.yaml' file on the external bastion (or laptop) to add more images or to fetch the latest images
- running 'make save'
- running 'make inc' to create an incremental tar archive (see above)
- unpacking the tar archive on the internal bastion
- running 'make load' to load the images into the internal registry.

Note that generated 'image sets' are sequential and must be pushed to the target mirror registry in order. You can derive the sequence number from the file name of the generated image set archive file in the save/ directory. 

## Install OpenShift 

For example, to install Single Node OpenShift (SNO), edit the file 'templates/cluster-sno.conf' to match your environment. 

```
make sno
```
- This will create a directory 'sno' and then install SNO OpenShift using the Agent-based installer.  If you are using VMware it will create the VMs for you.
- Be sure to go through *all* the values in 'aba/vmware.conf' and 'sno/cluster.conf'.
- Be sure to set up your DNS entries in advance. See above on Prerequisites. 
- Aba will show you the installation progress.  You can also run 'make ssh' to log into the rendezvous server to troubleshoot. If there are any issues - e.g. incorrect DNS records - fix them and try again.  All commands are idempotent.

```
make compact    # for a 3 node cluster topology
make standard   # for a 3+2 topology
```
- Run this to create a compact cluster (works in a similar way to the above). 

```
make ocp name=mycluster
```
- This command will create a directory 'mycluster', copy the Makefile into it and then run 'make'.

If needed, the following command can be used to monitor the progress of the Agent-based installer. For example: 

```
cd <cluster dir>   # e.g. cd sno  
make mon
```

Get help from a Makefile using 'make help'.

After OpenShift has been installed you will see the following:

```
INFO Install complete!                            
INFO To access the cluster as the system:admin user when using 'oc', run 
INFO     export KUBECONFIG=/home/steve/aba/compact/iso-agent-based/auth/kubeconfig 
INFO Access the OpenShift web-console here: https://console-openshift-console.apps.compact.example.com 
INFO Login to the console with user: "kubeadmin", and password: "XXYZZ-XXYZZ-XXYZZ-XXYZZ" 
```
You can get access to the cluster using the command:

```
. <(make shell) 
oc whoami
```

You can run commands against the cluster, e.g. to show the installation progress:

```
watch make cmd cmd="get co"
```

If you only want to create the agent-based iso file, e.g. to boot bare-metal nodes, use:

```
cd sno
# then manually edit the 'agent-config.yaml' file to set the appropriate Mac addresses matching your bare-metal nodes
make iso
# boot the bare-metal node(s) with the generated ISO file.
```

If OpenShift fails to install, see the [Troubleshooting](Troubleshooting.md) readme. 

Other examples of commands, when working with VMware/ESXi:

```
cd mycluster     # change to the directory with the agent-based install files, using 'mycluster' as an example.

make refresh     # Delete the VMs and re-create them causing the cluster to be re-installed.

make stop        # Shut down the guest OS (CoreOS) of all VMs in the 'mycluster' cluster.

make start       # Power on all VMs in the 'mycluster' cluster. 

make delete      # Delete all the VMs in the 'mycluster' cluster. 

make ls          # Show list of VMs and their state.

make help        # Help is available in all Makefiles (in aba/Makefile  aba/mirror/Makefile  aba/cli/Makefile and aba/<mycluster>/Makefile) 
```


## Features that are not implemented yet

- ~~Make it easier to install Operators (ImageContentSourcePolicy and CatalogSource) once OpenShift has been installed.~~

- ~~Make it easier to integrate with vSphere, including storage.~~

- Configure htpasswd login, add users, disable kubeadmin.

- ~~Disable OperatorHub and configure the internal registry to serve images.~~

- Use PXE boot as alternative to ISO upload.


## Configuration files

- aba/aba.conf is the 'global' config file, used to set the target version of OpenShift, your domain name, private network address, DNS IP, choice of editor etc
- aba/mirror/mirror.conf describes your private/internal mirror registry (either existing or to-be-installed) 
- aba/`cluster name`/cluster.conf describes how to build an OpenShift cluster, e.g. number of master and worker nodes, ingress IPs etc

## Customizing agent-config.yaml and/or openshift-install.yaml files

- Once a cluster config directory has been created (e.g. 'compact') and Agent-based configuration has been created, some changes can be made to the 'install-config.yaml' and 'agent-config.yaml' files if needed. 'make' can be run again to re-create the ISO and the VMs etc (if required).  Aba should see the changes and try to preserve and use them.  Simple changes to the files, e.g. IP/Mac address changes, default route changes, adding disk hints etc work fine.  

The following script can be used to extract the cluster config from the agent-config yaml files. This script can be run to check that the correct information can be extracted to create the VMs. 

Example:

```
cd sno
scripts/cluster-config.sh        # example execution to show the cluster configuration extracted from the Agend-based config files. 
```

As an example, edit agent-config.yaml to include the following to direct agent-based installer to install RHCOS onto the 2nd disk, e.g. /dev/sdb:

```
    rootDeviceHints:
      deviceName: /dev/sdb
```

or, adding vSphere integration into 'install-config.yaml' (works from the OCP Console on day 2, with v4.14 and below)

```
platform:
  vsphere:
    apiVIP: "10.0.1.216"
    ingressVIP: "10.0.1.226"

```

Check 'cluster-config.sh' is able to parse all the data it needs to create the VMs:

```
scripts/cluster-config.sh        # example execution to show the cluster configuration extracted from the Agend-based files. 
```

Run make again to rebuild the agent-based ISO and refresh the VMs:

```
make
...
scripts/generate-image.sh
...
scripts/vmw-upload.sh
...
scripts/vmw-create.sh --start
...
scripts/monitor-install.sh
```


## Miscellaneous


- If you want to install workers with different CPU/MEM sizes (which can be used to install cluster infra sub-systems, e.g. Ceph and/or ES etc - infra nodes), change the VM resources (CPU/RAM) as needed after OpenShift is installed (if using VMs).

- Govc is used to create and manage VMs on ESXi or vSphere.
  - https://github.com/vmware/govmomi/tree/main/govc

Be sure to set the correct (govc) values to access vCenter in the vmware.conf file.  
Note that ESXi will also work by changing the folder path (see the comments in the vmware.conf file).

Why 'make' was chosen to build Aba?

The UNIX/Linux command "make" is a utility for automating tasks based on rules specified in a Makefile. It enhances efficiency by managing dependencies, 
facilitating streamlined processes. Widely applied beyond software development, "make" proves versatile in system management, ensuring organized 
execution of diverse tasks through predefined rules!


