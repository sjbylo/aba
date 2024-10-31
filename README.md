# Aba is tooling, wrapped around the agent-based installer for OpenShift.

1. [Intro](#intro)
1. [Quick Guide](#quick-guide)
1. [Prerequisites](#prerequisites)
1. [Initial Steps](#initial-steps)
1. [Getting Started with aba](#getting-started-with-aba)
1. [Disconnected mode](#disconnected-mode)
1. [Fully disconnected (air-gapped) mode](#fully-disconnected-(air-gapped)-mode)
1. [Install OpenShift](#install-openshift)
1. [Features that are not implemented yet](#features-that-are-not-implemented-yet)
1. [Configuration files](#configuration-files)
1. [Customizing agent-config.yaml and/or openshift-install.yaml files](#customizing-agent-config.yaml-and-or-openshift-install.yaml-files)
1. [Miscellaneous](#miscellaneous)
1. [Advanced](#advanced)

## Intro

Aba makes it easier to install an OpenShift cluster - "Cluster Zero" - into a fully or partially disconnected environment, either onto vSphere, ESXi or bare-metal. 
Because Aba uses the [Agent-based installer](https://www.redhat.com/en/blog/meet-the-new-agent-based-openshift-installer-1) there is no need to configure a load balancer, a bootstrap node or even require DHCP. 

Aba automatically completes the following for you:
1. Helps install any type of OpenShift cluster, e.g. SNO (1-node), Compact (3-nodes), Standard (5+nodes).
2. Makes use of any existing container registry or installs the Quay mirror registry appliance for you. 
1. Uses the registry's credentials and other inputs to generate the Agent-based configuration files.
1. Triggers the generation of the agent-based boot ISO. 
1. Configures NTP during installation time to help avoid issues when using nodes with incorrect date & time.
1. Optionally creates the required VMs in ESXi or vSphere.
1. Monitors the installation progress. 
1. Allows for adding more images (e.g. Operators) when synchonizing the mirror registry. (day 1 or 2 operation.)
1. Configures the OperatorHub integration with the mirror registry. 
1. Can create an archive "bundle" containing all files needed to complete a fully air-gapped installation. 
1. Executes several workarounds for some typical issues with disconnected environments.
1. Enables the integration with vSphere as a day 2 operation.

Use aba if you want to get OpenShift up and running quickly in an air-gapped environment without having to study the documentation in detail.  It also works with connected environments.  

For the very impatient: clone this repo onto a RHEL VM with an internet connection, install and run 'make'.  You will be guided through the process.  Fedora has also been tested as the 'connected' VM to download the needed images and other content. 

## Quick Guide

For those who are less impatient...

```
git clone https://github.com/sjbylo/aba.git
cd aba
./aba
```
- clones the repo, installs 'make' and configures high-level settings, e.g. OCP target version, your domain name, machine network CIDR etc.
- helps decide if you want to install onto VMware/ESXi or onto bare-metal. 

```
make mirror 
```
- configures and connects to your existing container registry OR installs a fresh quay appliance registry.

```
make sync
```
- copies the required images directly to the mirror registry (for partially disconnected environments, e.g. via a proxy).
- Fully disconnected (air-gapped) environments are also supported with 'make save/load' (see below).

```
make cluster name=sno type=sno
```
- creates a directory 'sno' (for Single Node OpenShift) and the file `sno/cluster.conf` which needs to be edited. 
- any topology of OpenShift is supported, e.g. sno (1), compact (3), standard (3+n).

```
cd sno
make
```
- creates the Agent-based config files, generates the Agent-based iso file, creates and boots the VMs (for VMware). 
- monitors the installation progress.

```
make day2
```
- configures the internal registry for Operator Hub, ready to install Operators. 

```
make help
```
- shows what other commands are available. 

Read more for all the details.


## Prerequisites

The usual things you need to install OpenShift when using the Agent-based installer. 

- **RHEL**
   - Aba will attempt to install all required RPMs using "dnf".  If dnf is not configured or working the RPMs will need to be installed another way, e.g. DVD. 
   - Ensure the internal RHEL bastion has the RPMs installed (as defined in the file templates/rpms-internal.txt).
   - Ensure the *external* RHEL bastion has the RPMs installed (as defined in the file templates/rpms-external.txt).
   - Install your favorite editor. 
   - Ensure all RPMs are updated with "sudo dnf update". 
   - Ensure this git repository is cloned into the bastion anywhere under a user's home directory.
   - Add your Red Hat registry pull secret file to ~/.pull-secret.json
   - Ensure the user has sudo permission. Password-less is highly recommended!
- **DNS**
   - with A records for 1) OpenShift API 2) Ingress and 3) the internal mirror registry.
- **NTP**
   - OpenShift requires that NTP be available. Installation is possible without an NTP server. However, asynchronous server clocks will cause errors, which an NTP server prevents. Aba can configure NTP at installation time which helps avoid issues when using nodes with incorrect date & time.
- **Private subnet** (optional)
   - Install OpenShift into a private, air-gapped network.
   - Aba also works in connected environments without a private mirror registry, e.g. accessing public container registries via a proxy. 
- **One or two Bastion hosts**
  - Disconnected mode: A RHEL VM with connectivity to both the external (internet facing) and the internal networks.
  - Fully disconnected mode (air-gapped): A RHEL VM in the private network and another RHEL VM (or a Fedora/RHEL laptop) in the internet facing network. 
  - A user account with sudo configured (i.e. with root access). 
  - A large amount of space to store the OpenShift container images.  30 GB or more of disk space is required for the base OpenShift platform.  Much more space is required if Operators will be installed (500 GB or much more).
  - Internet access is required from your connected bastion (or laptop) to download the container images, CLI tools and other files. 
     - A "[partially disconnected environment](https://docs.openshift.com/container-platform/4.14/installing/disconnected_install/installing-mirroring-disconnected.html#mirroring-image-set-partial)" is supported. This means the bastion needs to have (temporary) Internet access to download the images and then it needs access to the private subnet to install OpenShift.   See 'Disconnected mode' below.
     - Fully air-gapped or "[fully disconnected environment](https://docs.openshift.com/container-platform/4.14/installing/disconnected_install/installing-mirroring-disconnected.html#mirroring-image-set-full)" is also supported.  For this, two bastions (one connected & the other internal) are required.  See 'Fully disconnected mode' below.
- **Platform** (optional)
   - vCenter or ESXi API access. 
      - Ensure enough privileges to vCenter. If 'admin' privileges cannot be provided, see the [vCenter account privileges](https://docs.openshift.com/container-platform/4.14/installing/installing_vsphere/installing-vsphere-installer-provisioned-customizations.html#installation-vsphere-installer-infra-requirements_installing-vsphere-installer-provisioned-customizations) documentation for more.
   - Bare-metal
      - Note that bare-metal nodes can be booted manually using the generated ISO. Mac addresses can be set in the 'install-config.yaml' file after running 'make install-config.yaml'.


## Initial Steps

- **Bastion**
   - First, install a bastion with a fresh version of RHEL. Fedora can also be used except Quay mirror fails to install on it.
   - a 'minimal install' of RHEL 9.4, RHEL 8.9 and Fedora 40 have been tested, other recent versions of RHEL/Fedora should work too.
      - Note that on Fedora 40, the mirror registry failed to install due to an [unexpected keyword argument 'cert_file'](https://github.com/quay/mirror-registry/issues/140) error, but remote installs of the Quay appliance (from Fedora) worked ok. 
      - Note that only RHEL 9 is supported for OCP v4.15+ as the latest version of oc-mirror only works on RHEL 9.
- **Git repo**
   - Clone or copy this git repository (https://github.com/sjbylo/aba.git) anywhere under your *home directory* on the connected bastion (e.g. on a Fedora/RHEL laptop). 
   - Ensure sudo root access is configured. Password-less sudo is preferable. 
- **Pull Secret**
   - To install OpenShift, a API credentials are needed to allow access to and pull images from, Red Hat's registries.  Copy your pull secret in JSON format to the file '~/.pull-secret.json' (in your $HOME directory).
      - A pull secret can be downloaded from https://console.redhat.com/openshift/install/pull-secret
      - It's a good idea to make the file user read-only, e.g. `chmod 600 ~/.pull-secret.json`.
- **DNS**
   - Create the required DNS A records, *for example* (use your domain!):
      - OpenShift API: api.ocp1.example.com 
        - points to a free IP in your private subnet. 
      - OpenShift Ingress: *.apps.ocp1.example.com 
        - points to a free IP in your private subnet. 
        - Note: For Single Node OpenShift (SNO), the above records should point to a single IP address, used for the single OpenShift node. For all other topologies, two separate IP addresses should be used!
      - Quay mirror registry: registry.example.com 
        - points to the IP address of your registry.  This can be either the one you want installed or your existing registry. 
- **Registry**
   - If you are using an existing registry:
     - Copy your existing registry's credential files (pull secret and root CA) into the `mirror/regcreds` directory, e.g.:
       - `mirror/regcreds/pull-secret-mirror.json`   (pull secret file for your registry)
       - `mirror/regcreds/rootCA.pem`                (root CA file for your registry) 
     - Later, when the images are pushed to the registry, these files will be used. 
- **Finally**
   - run the ./aba command to initialize the installation process (see 'Getting Started' below).

![Air-gapped data transfer](images/air-gapped.jpg "Air-gapped data transfer")

## Getting Started with aba

To get started, run:

```
./aba 
```

Note that this command will create the `aba.conf` file which contains some values that you *must change*, e.g. your preferred platform, your domain name, your network address (if known) and any operators you will require etc.

Now, continue with either 'Disconnected mode' or 'Fully disconnected (air-gapped) mode' below. 

## Disconnected mode 

In this mode, the connected bastion has access to both the Internet and the private subnet (but not necessarily at the same time).

![Disconnected and Air-gapped mode](images/make-sync.jpg "Disconnected and Air-gapped mode")

```
make sync
```
This command will:
  - trigger 'make mirror' (to configure the mirror registry), if needed. 
    - for an existing registry, check the connection is available and working (be sure to set up your registry credentials in `mirror/regcreds/` first! See above for more).
    - or, installs Quay registry on the internal bastion (or remote internal bastion) and copies the generated pull secret and certificate into the `mirror/regcreds` directory for later use.
  - pull images from the Internet and store them in the registry.

Now continue with "Install OpenShift" below.

Note that the above 'disconnected mode' can be repeated, for example to download and install Operators as a day 2 operation or to upgrade OpenShift, by updating the 'sync/imageset-sync.yaml' file and running 'make sync/day2' again.


## Fully disconnected (air-gapped) mode

In this mode, your connected bastion has access to the Internet but no access to the private network.
You also require an internal bastion in a private subnet.

```
make save
```

- pulls the images from the Internet and saves them into the local directory "mirror/save". Make sure there is enough disk space (30+ GB or much more for Operators)!

Then, using one of 'make inc/tar/tarrepo' (incremental/full or separate copies), copy the whole aba/ repo (including templates, scripts, images, CLIs and other install files) to your internal bastion (in your private network) via a portable storage device, e.g. a thumb drive. 

Example:

```
# On the connected bastion:
# Mount your thumb drive and:

make inc                                          # Write tar archive to /tmp
or
make inc out=/dev/path/to/thumb-drive/aba.tgz     # Write archive 'aba.tgz' to the device mounted at /dev/path/to/thumb-drive
or
make inc out=- | ssh user@host "cat > aba.tgz"    # Archive and write to internal host (if possible).

# Copy the file 'aba.tgz' to your internal bastion via your portable storage device.

# Then, on the internal bastion run:
tar xvf aba.tgz                                   # Extract the tar file. Ensure file timestamps are kept the same as on the connected bastion.
cd aba             
./aba
```

For such cases where it is not possible to write directly to a portable storage device, e.g. due to restrictions or access is not possible, an alternative command can be used.

Example:

```
make tarrepo out=/dev/path/to/drive/aba.tgz       # Write archive 'aba.tgz' to the device mounted at /dev/path/to/drive, EXCEPT for the 'seq#' tar files under save/
```
- The 'seq#' tar file(s) in the "mirror/save" directory and the repo tarball 'aba.tgz' can be copied separately to a storage device, e.g. USB stick, S3 or other. 

Copy the "aba.tgz" file to the internal bastion and unpack the archive. Note the directory "aba/mirror/save".
Copy or move the "seq" tar file(s), as is, from the "mirror/save" directory to the internal bastion, into the "mirror/save" directory on the internal bastion.

```
sudo dnf install make -y     # If dnf does not work in the private environment (i.e. no Satalite), ensure all required RPMs are pre-installed, e.g. from a DVD drive at the time of installation. 
make load
```
- will (if required) install Quay (from the bundle archive) and then load the images into Quay.
- Required RPMs:
  - Note that the internal bastion will need to install RPMs from a suitable repository (for Aba testing purposes it's possible to configure 'dnf' to use a proxy). 
  - If RPMs cannot be installed with "sudo dnf install", then ensure the RPMs are pre-installed, e.g. from a DVD at the time of RHEL installation. 
  - If rpms are not readily available in your private network, the command 'make rpms' can help by downloading the required rpms, which can then be copied to the internal bastion and installed with 'dnf localinstall rpms/*.rpm'.  Note this will only work if your external and internal bastions are running the exact same version of RHEL (at least, that was the experience when testing Aba!). 

Now continue with "Install OpenShift" below.

Note that the above 'air-gapped workflow' can be repeated in the *exact same way*, for example to incrementally install Operators or download new versions of images to upgrade OpenShift.

For example, by:
- editing the 'save/imageset-save.yaml' file on the connected bastion to add more images or to fetch the latest images
- running 'make save'
- running 'make inc' (or make tar or make tarrepo) to create a bundle archive (see above)
- unpacking the tar archive on the internal bastion
- running 'make load' to load the images into the internal registry.

Note that generated 'image sets' are sequential and must be pushed to the target mirror registry in order. You can derive the sequence number from the file name of the generated image set archive file in the mirror/save directory. 

![Connecting to or creating Mirror Registry](images/make-install.jpg "Connecting to or creating Mirror Registry")


## Install OpenShift 

![Installing OpenShift](images/make-cluster.jpg "Installing OpenShift")

```
cd aba
make cluster name=mycluster [type=sno|compact|standard] [target=xyz]
```
- will create a directory 'mycluster', copy the Makefile into it and then run 'make' inside the directory.
- Note, *all* advanced preset parameters at the bottom of the `aba.conf` configuration file must be completed for the optional "type" parameter to have any affect. 

If needed, the following command can be used to monitor the progress of the Agent-based installer. For example: 

```
cd <cluster dir>   # e.g. cd sno  
make mon
```

Get help with 'make help'.

After OpenShift has been installed you will see the following output:

```
INFO Install complete!                            
INFO To access the cluster as the system:admin user when using 'oc', run 
INFO     export KUBECONFIG=/home/steve/aba/compact/iso-agent-based/auth/kubeconfig 
INFO Access the OpenShift web-console here: https://console-openshift-console.apps.compact.example.com 
INFO Login to the console with user: "kubeadmin", and password: "XXYZZ-XXYZZ-XXYZZ-XXYZZ" 
```
You can get access to the cluster using one of the commands:

```
. <(make shell) 
oc whoami
```
- provides access via the kubeconfig file.

```
. <(make login) 
oc whoami
```
- provides access via "oc login".


You can run commands against the cluster, e.g. to show the installation progress:

```
watch make cmd cmd="get co"
```

If you only want to create the agent-based iso file, e.g. to boot bare-metal nodes, use:

```
cd mycluster
make agentconf
# then manually edit the 'agent-config.yaml' file to set the appropriate Mac addresses matching your bare-metal nodes, change drive and net interface hints etc.
make iso
# boot the bare-metal node(s) with the generated ISO file. This can be done using a USB stick or via the server's remote management interfaces (BMC etc).
make mon
```

If OpenShift fails to install, see the [Troubleshooting](Troubleshooting.md) readme. 

Other examples of commands (make <targets>), when working with VMware/ESXi:

cd mycluster     # change to the directory with the agent-based install files, using 'mycluster' as an example.

| Target | Description |
| :----- | :---------- |
| make day2        | Integrate the private mirror into OCP. |
| make ls          | Show list of VMs and their state. |
| make start       | Power on all VMs |
| make stop        | Gracefully shut down all VMs |
| make powerdown   | Power down all VMs immediately |
| make kill        | Same as 'powerdown' |
| make delete      | Delete all VMs  |
| make create      | Create all VMs  |
| make refresh     | Delete & re-create the VMs causing the cluster to be re-installed. |
| make delete      | Delete all the VMs  |
| make login       | Display the 'oc login' command for the cluster.  Use: . <(make login)  |
| make shell       | Display the command to access the cluster using the kubeconfig file.  Use: . <(make shell) |
| make help        | Help is available in all Makefiles (in aba/Makefile  aba/mirror/Makefile  aba/cli/Makefile and aba/<mycluster>/Makefile)  |


## Features that are not implemented yet

- ~~Support bonding and vlan.~~

- ~~Make it easier to integrate with vSphere, including storage.~~

- Configure htpasswd login, add users, disable kubeadmin.

- ~~Disable public OperatorHub and configure the internal registry to serve images.~~

- Use PXE boot as alternative to ISO upload.

- ~~Make it easier to populate the imageset config file with current values, i.e. download the values from the latest catalog and insert them into the image set file.~~


## Configuration files

| Config file | Description |
| :---------- | :---------- |
| `aba/aba.conf`                    | the 'global' config, used to set the target version of OpenShift, your domain name, private network address, DNS IP etc |
| `aba/mirror/mirror.conf`          | describes your private/internal mirror registry (either existing or to-be-installed)  |
| `aba/`cluster-name`/cluster.conf` | describes how to build an OpenShift cluster, e.g. number/size of master and worker nodes, ingress IPs etc |
| `aba/vmware.conf`                 | vCenter/ESXi access configuration using 'govc' CLI (optional) |


## Customizing agent-config.yaml and/or openshift-install.yaml files

- Once a cluster config directory has been created (e.g. 'compact') and Agent-based configuration has been created, some changes can be made to the 'install-config.yaml' and 'agent-config.yaml' files if needed. 'make' can be run again to re-create the ISO and the VMs etc (if required).  Aba should see the changes and try to preserve and use them.  Simple changes to the files, e.g. IP/Mac address changes, default route changes, adding disk hints etc work fine.  

The workflow could look like this:
```
make cluster name=mycluser target=agentconf       # Create the cluster dir and Makefile & generate the initial agent config files.
cd mycluster
# Now manually edit the generated install-config.yaml and agent-config.yaml files (where needed, e.g. bare-metal mac addresses) and
# start cluster installation:
make
```

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

or, adding vSphere integration into 'install-config.yaml' (works from the OCP Console on day 2, with v4.14 and below) - Note, this is completed automatically now if you are deploying on vSphere or ESXi.

```
platform:
  vsphere:
    apiVIP: "10.0.1.216"
    ingressVIP: "10.0.1.226"

```

Check 'cluster-config.sh' is able to parse all the data it needs to create the agent config files (and the VMs, if needed):

```
scripts/cluster-config.sh        # example execution to show the cluster configuration extracted from the Agend-based files. 
```

Run make again to rebuild the agent-based ISO and refresh the VMs, e.g.:

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


- If you want to install workers with different CPU/MEM sizes (which can be used to install Operators, e.g. Ceph, ODF, ACM etc, on infra nodes), change the VM resources (CPU/RAM) as needed after OpenShift is installed (if using VMs).

- Govc is used to create and manage VMs on ESXi or vSphere.
  - https://github.com/vmware/govmomi/tree/main/govc

Be sure to set the correct (govc) values to access vCenter in the `vmware.conf` file.  Note that ESXi is also supported.

Why 'make' was chosen to build Aba?

The UNIX/Linux command "make" is a utility for automating tasks based on rules specified in a Makefile. It enhances efficiency by managing dependencies, 
facilitating streamlined processes. Widely applied beyond software development, "make" proves versatile in system management, ensuring organized 
execution of diverse tasks through predefined rules!


## Advanced

Cluster presets are used mainly to automate the testing of Aba. 

```
make sno
```
- This will create a directory 'sno' and then install SNO OpenShift using the Agent-based installer (note, *all* preset parameters in `aba.conf` must be completed for this to work).  If you are using VMware it will create the VMs for you.
- Be sure to go through *all* the values in `aba/vmware.conf` and `sno/cluster.conf`.
- Be sure your DNS entries have been set up in advance. See above on Prerequisites. 
- Aba will show you the installation progress.  To troubleshoot cluster installation, run 'make ssh' to log into the rendezvous node. If there are any issues - e.g. incorrect DNS records - fix them and try again.  All commands and actions in Aba are idempotent.  If you hit a problem, fix it and try again should always be the right way forward!

```
make compact    # for a 3 node cluster topology (note, *all* parameters in `aba.conf` must be completed for this to work).
make standard   # for a 3+2 topology (note, *all* parameters in `aba.conf` must be completed for this to work).
```
- Run this to create a compact cluster (works in a similar way to the above). 


