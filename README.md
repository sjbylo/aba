# Aba makes it easier to install your first OpenShift cluster in your air-gapped environment. 

Easily install an OpenShift cluster - "Cluster Zero" - into a fully or partially disconnected environment, either onto bare-metal or VMware (vSphere/ESXi).
Because Aba is based on the [Agent-based installer](https://www.redhat.com/en/blog/meet-the-new-agent-based-openshift-installer-1) there is no need to configure a load balancer, a bootstrap node or even require DHCP. 

## Who should use Aba?

Use Aba if you want to get OpenShift up and running quickly in an air-gapped environment without having to study the documentation in detail.

1. [What does Aba do for me?](#what-does-aba-do-for-me)
1. [Installing OpenShift in a Disconnected Network](#installing-openshift-in-a-disconnected-network)
1. [Prerequisites](#prerequisites)
   1. [Fully Disconnected (Air-Gapped) Prerequisites](#fully-disconnected-air-gapped-prerequisites)
   1. [Partially Disconnected Prerequisites](#partially-disconnected-prerequisites)
1. [Common Requirements for Both Environments](#common-requirements-for-both-environments)
1. [Quick Guide](#quick-guide)
1. [Getting Started with Aba](#getting-started-with-aba)
   1. [Disconnected Scenario](#disconnected-scenario)
   1. [Fully disconnected (air-gapped) Scenario](#fully-disconnected-air-gapped-scenario)
1. [Installing OpenShift](#installing-openshift)
1. [Configuration files](#configuration-files)
1. [Customizing agent-config.yaml and/or openshift-install.yaml files](#customizing-agent-config.yaml-andor-openshift-install.yaml-files)
1. [Features that are not implemented yet](#features-that-are-not-implemented-yet)
1. [Miscellaneous](#miscellaneous)
1. [Advanced](#advanced)



## What does Aba do for me?

Aba automatically completes the following and more:

1. Helps install any type of OpenShift cluster, e.g. SNO (1-node), Compact (3-nodes), Standard (5+nodes).
2. Makes use of any existing container registry or installs the Quay mirror registry appliance for you. 
1. Uses the registry's credentials and other inputs to generate the Agent-based configuration files.
1. Triggers the generation of the agent-based boot ISO. 
1. Configures NTP during installation time to help avoid issues when using nodes with incorrect date & time.
1. Optionally creates the required VMs in ESXi or vSphere.
1. Monitors the installation progress. 
1. Allows for adding more images (e.g. Operators) when synchronizing the mirror registry (day 1 or 2 operation).
1. Configures the OperatorHub integration with the mirror registry. 
1. Can create an "archive bundle" containing all the files needed to complete a fully air-gapped installation. 
1. Executes several workarounds for some typical issues with disconnected environments.
1. Enables the integration with vSphere as a day 2 operation.
1. Helps configure OpenShift with your NTP servers and many more. 

For the very impatient:

  - Clone/download this git repository (https://github.com/sjbylo/aba.git) onto a workstation with an internet connection (RHEL 8/9 or Fedora).
  - Run `./aba -h` or `./aba` and Aba will guide you through the process.


## Installing OpenShift in a Disconnected Network

![Air-gapped data transfer](images/air-gapped.jpg "Air-gapped data transfer")

The diagram above illustrates two scenarios for installing OpenShift in a disconnected network environment.

- **Top Section**: The *Disconnected Scenario* (partial network access, e.g. via a proxy).
- **Bottom Section**: The *Fully Disconnected (Air-Gapped) Scenario* (data transfer only through physical means, such as "sneaker net" into a private data center).

Each scenario includes two main network zones:

- **Connected Network**: Located on the left side of the diagram, where external resources are accessible.
- **Private Network**: Located on the right side of the diagram, isolated from direct internet access.

Bastion Requirements

- **Connected Bastion**: Can be a workstation or virtual machine (VM) running on a laptop, configured with RHEL 8/9 or Fedora.
- **Private Network Bastion**: Must be running RHEL 9 to support OpenShift installation in the private network.

These configurations ensure that each network zone meets OpenShift’s requirements for disconnected or fully air-gapped installations.


## Prerequisites

### Fully Disconnected (Air-Gapped) Prerequisites

In a fully disconnected environment, where no internet access is available, two bastions are required: one connected to the internet and the other on the private network.

- **Connected Bastion or Workstation**
   - An x86 RHEL 8/9 or Fedora (e.g. VM) with internet access, typically on a laptop.
   - Clone or download this Git repository (https://github.com/sjbylo/aba.git) to any location in your home directory.
   - Download and store the Red Hat registry pull secret to `~/.pull-secret.json` (a pull secret can be downloaded from https://console.redhat.com/openshift/install/pull-secret).
   - Install required RPMs listed in `templates/rpms-external.txt`.
   - Run `sudo dnf update` to ensure all packages are up to date (optional).
   - Password-less `sudo` access is highly recommended.

- **Internal Bastion**
   - A RHEL 9 VM or host within your private, air-gapped network.
   - Install required RPMs as listed in `templates/rpms-internal.txt` (or let Aba use dnf to install, if available).
   - Password-less `sudo` access is highly recommended.

### Partially Disconnected Prerequisites

In a partially disconnected environment, the internal network has limited or proxy-based internet access, allowing data synchronization directly.

- **Bastion**
   - A single RHEL 9 VM with internet access and connectivity to the private network.
   - Download and copy this Git repository to any location in your home directory on the bastion.
   - Configure the Red Hat registry pull secret at `~/.pull-secret.json` (a pull secret can be downloaded from https://console.redhat.com/openshift/install/pull-secret).
   - Install required RPMs from `templates/rpms-external.txt`.
   - Run `sudo dnf update` to ensure all packages are up to date (optional).
   - Password-less `sudo` access is highly recommended.

### Common Requirements for Both Environments

- **Registry Storage**
   - Minimum of 30 GB is required for OpenShift base images, with additional Operators requiring more (500 GB or more).

- **Network Configuration**
   - **DNS**: Configure the following DNS A records (these are examples!):
      - **OpenShift API**: `<api.ocp1.example.com>` pointing to a free IP in the private subnet.
      - **OpenShift Ingress**: `<*.apps.ocp1.example.com>` pointing to a free IP in the private subnet.
      - **Mirror Registry**: `<registry.example.com>` pointing to the IP address of your internal mirror registry (or where Aba should install it).
      - *Note*: For Single Node OpenShift (SNO), configure both OpenShift API and Ingress records to point to the same IP.
   - **NTP**: An NTP server is recommended to ensure time synchronization across all nodes, as OpenShift requires synchronized clocks for installation and proper operation.

- **Platform**
   - **VMware vCenter or ESXi API Access (optional)**: Ensure sufficient privileges for OpenShift installation. Refer to [vCenter account privileges](https://docs.openshift.com/container-platform/4.14/installing/installing_vsphere/installing-vsphere-installer-provisioned-customizations.html#installation-vsphere-installer-infra-requirements_installing-vsphere-installer-provisioned-customizations) for specific permissions.
   - For bare-metal installations, manually boot the nodes using the generated ISO file. 

- **Registry**
   - If using an existing registry, add its credentials (pull secret and root CA) in the `mirror/regcreds` directory:
      - `mirror/regcreds/pull-secret-mirror.json`
      - `mirror/regcreds/rootCA.pem`

After configuring these prerequisites, run `./aba` to start the OpenShift installation process.

Note: that Aba also works in connected environments without a private mirror registry, e.g. by accessing public container registries via a proxy.  To do this, configure the proxy values in `cluster.conf`.


## Quick Guide

For those who are less impatient...

```
git clone https://github.com/sjbylo/aba.git
cd aba
./aba
```
- clones the repo and configures some high-level settings, e.g. OpenShift target version, your domain name, machine network CIDR etc (if known).
- If needed, add any required operators to the `aba.conf` file.
- helps you decide if you have a partially disconnected or fully disconnected (air-gapped) environment and how you should proceed. 

```
make mirror 
```
- configures and connects to your existing container registry OR installs a fresh quay appliance registry.

```
make sync
```
- copies the required images directly to the mirror registry (for partially disconnected environments, e.g. via a proxy).
- Fully disconnected (air-gapped) environments are also supported with `make save/load` (see below).

```
make cluster name=mycluster type=sno
```
- creates a directory `mycluster` and the file `mycluser/cluster.conf`.
- Edit/verify the `mycluster/cluster.conf` file.
- Note that any topology of OpenShift is supported, e.g. sno (1), compact (3), standard (3+n).

```
cd mycluster
make
```
- creates the Agent-based config files, generates the Agent-based iso file, creates and boots the VMs (if using VMware). 
- monitors the installation progress.

```
make day2
```
- configures OpenShift to access the internal registry ready to install from the Operators Hub. 

```
make help
```
- shows what other commands are available. 


## Getting Started with Aba

To get started, run:

```
./aba 
```

Note that this command will create the `aba.conf` file which contains some values that you *must change*, e.g. your preferred platform, your domain name, your network address (if known) and any operators you will require etc.

Now, continue with either 'Disconnected scenario' or 'Fully disconnected (air-gapped) scenario' below. 

## Disconnected Scenario 

In this scenario, the connected bastion has access to both the Internet and the private subnet (but not necessarily at the same time).

![Disconnected and Air-gapped Scenario](images/make-sync.jpg "Disconnected and Air-gapped scenario")

```
make sync
```
This command will:
  - trigger `make mirror` (to configure the mirror registry), if needed. 
    - for an existing registry, check the connection is available and working (be sure to set up your registry credentials in `mirror/regcreds/` first! See above for more).
    - or, installs Quay registry on the internal bastion (or remote internal bastion) and copies the generated pull secret and certificate into the `mirror/regcreds` directory for later use.
  - pull images from the Internet and store them in the registry.

Now continue with "Installing OpenShift" below.

Note that the above 'disconnected scenario' can be repeated, for example to download and install Operators as a day 2 operation or to upgrade OpenShift, by updating the `sync/imageset-sync.yaml` file and running `make sync/day2` again.


## Fully disconnected (air-gapped) Scenario

In this scenario, your connected bastion has access to the Internet but no access to the private network.
You also require an internal bastion in a private subnet.

```
make save
```

- pulls the images from the Internet and saves them into the local directory "mirror/save". Make sure there is enough disk space (30+ GB or much more for Operators)!

Then, using one of `make inc/tar/tarrepo` (incremental/full or separate copies), copy the whole aba/ repo (including templates, scripts, images, CLIs and other install files) to your internal bastion (in your private network) via a portable storage device, e.g. a thumb drive. 

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
make tarrepo out=/dev/path/to/drive/aba.tgz
```
- Write archive `aba.tgz` to the device mounted at /dev/path/to/drive, EXCEPT for the `seq#` tar files under save/
- The `seq#` tar file(s) in the "mirror/save" directory and the repo tarball `aba.tgz` can be copied separately to a storage device, e.g. USB stick, S3 or other. 

Copy the "aba.tgz" file to the internal bastion and unpack the archive. Note the directory "aba/mirror/save".
Copy or move the "seq" tar file(s), as is, from the "mirror/save" directory to the internal bastion, into the "mirror/save" directory on the internal bastion.

```
sudo dnf install make -y     # If dnf does not work in the private environment (i.e. no Satalite), ensure all required RPMs are pre-installed, e.g. from a DVD drive at the time of installation. 
make load
```
- will (if required) install Quay (from the bundle archive) and then load the images into Quay.
- Required RPMs:
  - Note that the internal bastion will need to install RPMs from a suitable repository (for Aba testing purposes it's possible to configure `dnf` to use a proxy). 
  - If RPMs cannot be installed with "sudo dnf install", then ensure the RPMs are pre-installed, e.g. from a DVD at the time of RHEL installation. 
  - If rpms are not readily available in your private network, the command `make rpms` can help by downloading the required rpms, which can then be copied to the internal bastion and installed with `dnf localinstall rpms/*.rpm`.  Note this will only work if your external and internal bastions are running the exact same version of RHEL (at least, that was the experience when testing Aba!). 

Now continue with "Installing OpenShift" below.

Note that the above 'air-gapped workflow' can be repeated in the *exact same way*, for example to incrementally install Operators or download new versions of images to upgrade OpenShift.

For example, by:
- editing the `save/imageset-save.yaml` file on the connected bastion to add more images or to fetch the latest images
- running `make save`
- running `make inc` (or make tar or make tarrepo) to create a bundle archive (see above)
- unpacking the tar archive on the internal bastion
- running `make load` to load the images into the internal registry.

Note that generated 'image sets' are sequential and must be pushed to the target mirror registry in order. You can derive the sequence number from the file name of the generated image set archive file in the mirror/save directory. 

![Connecting to or creating Mirror Registry](images/make-install.jpg "Connecting to or creating Mirror Registry")


## Installing OpenShift 

![Installing OpenShift](images/make-cluster.jpg "Installing OpenShift")

```
cd aba
make cluster name=mycluster [type=sno|compact|standard] [target=xyz]
```
- will create a directory `mycluster`, copy the Makefile into it and then prompt you to run `make` inside the directory.
- Note, *all* advanced preset parameters at the bottom of the `aba.conf` configuration file must be completed for the optional "type" parameter to have any affect. 

 You should run the following command to monitor the progress of the Agent-based installer. For example: 

```
cd <cluster dir>   # e.g. cd compact
make mon
```

Get help with `make help`.

After OpenShift has been installed you will see the following output:

```
INFO Install complete!                            
INFO To access the cluster as the system:admin user when using 'oc', run 
INFO     export KUBECONFIG=/home/steve/aba/compact/iso-agent-based/auth/kubeconfig 
INFO Access the OpenShift web-console here: https://console-openshift-console.apps.compact.example.com 
INFO Login to the console with user: "kubeadmin", and password: "XXYZZ-XXYZZ-XXYZZ-XXYZZ" 

The cluster has been successfully installed.
Run '. <(make shell)' to access the cluster using the kubeconfig file (x509 cert), or
Run '. <(make login)' to log into the cluster using the 'kubeadmin' password. 
Run 'make help' for more options.

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

If you want to create the agent-based config files, e.g. to make changes to `install-config.yaml` and `agent-config.yaml`, use:

```
cd mycluster
make agentconf
# then, if needed,  manually edit the 'agent-config.yaml' file to set the appropriate mac addresses matching your bare-metal nodes, change drive and net interface hints etc.
```

If you want to create the agent-based iso file, e.g. to boot bare-metal nodes, use:

```
cd mycluster
make iso
# boot the bare-metal node(s) with the generated ISO file. This can be done using a USB stick or via the server's remote management interfaces (BMC etc).
make mon
```

If OpenShift fails to install, see the [Troubleshooting](Troubleshooting.md) readme. 

Other examples of commands (make <targets>):

cd mycluster     # change to the directory with the agent-based install files, using `mycluster` as an example.

| Target | Description |
| :----- | :---------- |
| `make day2`        | Integrate the private mirror into OpenShift. |
| `make ls`          | Show list of VMs and their state. |
| `make startup`     | Gracefully start up a cluster |
| `make shutdown`    | Gracefully shut down (or hibernate) a cluster. `make shutdown wait=1` wait for power-off |
| `make start`       | Power on all VMs |
| `make stop`        | Gracefully shut down all VMs (guest shutdown only!) |
| `make powerdown`   | Power down all VMs immediately |
| `make kill`        | Same as `powerdown` |
| `make create`      | Create all VMs  |
| `make refresh`     | Delete & re-create the VMs causing the cluster to be re-installed. |
| `make delete`      | Delete all the VMs  |
| `make login`       | Display the `oc login` command for the cluster.  Use: . <(make login)  |
| `make shell`       | Display the command to access the cluster using the kubeconfig file.  Use: . <(make shell) |
| `make help`        | Help is available in all Makefiles (in `aba/Makefile`,  `aba/mirror/Makefile`,  `aba/cli/Makefile` and `aba/<mycluster>/Makefile`)  |



## Configuration files

| Config file | Description |
| :---------- | :---------- |
| `aba/aba.conf`                    | the 'global' config, used to set the target version of OpenShift, your domain name, private network address, DNS IP etc |
| `aba/mirror/mirror.conf`          | describes your private/internal mirror registry (either existing or to-be-installed)  |
| `aba/`cluster-name`/cluster.conf` | describes how to build an OpenShift cluster, e.g. number/size of master and worker nodes, ingress IPs, bonding etc |
| `aba/vmware.conf`                 | vCenter/ESXi access configuration using `govc` CLI (optional) |


## Customizing agent-config.yaml and/or openshift-install.yaml files

- Once a cluster config directory has been created (e.g. `compact`) and Agent-based configuration has been created, some changes can be made to the `install-config.yaml` and `agent-config.yaml` files if needed. `make` can be run again to re-create the ISO and the VMs etc (if required).  Aba should see the changes and try to preserve and use them.  Simple changes to the files, e.g. IP/Mac address changes, default route changes, adding disk hints etc work fine.  

The workflow could look like this:
```
make cluster name=mycluser target=agentconf       # Create the cluster dir and Makefile & generate the initial agent config files.
cd mycluster
# Now manually edit the generated install-config.yaml and agent-config.yaml files (where needed, e.g. bare-metal mac addresses) and
# start cluster installation:
make
```

The following script can be used to extract the cluster config from the agent-config yaml files. This script can be run to check that the correct information can be extracted to create the VMs (if required). 

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

or, adding vSphere integration into `install-config.yaml` (works from the OpenShift Console on day 2, with v4.14 and below) - Note, this is completed automatically now if you are deploying on vSphere or ESXi.

```
platform:
  vsphere:
    apiVIP: "10.0.1.216"
    ingressVIP: "10.0.1.226"

```

Check `cluster-config.sh` is able to parse all the data it needs to create the agent config files (and the VMs, if needed):

```
scripts/cluster-config.sh        # example execution to show the cluster configuration extracted from the agend-based files. 
```

Run make again to rebuild the agent-based ISO and refresh the VMs, e.g.:

```
make
...
make iso
...
make upload
...
make refresh
...
make mon
```

## Features that are not implemented yet

- ~~Support bonding and vlan.~~

- ~~Make it easier to integrate with vSphere, including storage.~~

- Configure htpasswd login, add users, disable kubeadmin.

- ~~Disable public OperatorHub and configure the internal registry to serve images.~~

- Use PXE boot as alternative to ISO upload.

- ~~Make it easier to populate the imageset config file with current values, i.e. download the values from the latest catalog and insert them into the image set file.~~


## Miscellaneous


- If you want to install workers with different CPU/MEM sizes (which can be used to install Operators, e.g. Ceph, ODF, ACM etc, on infra nodes), change the VM resources (CPU/RAM) as needed after OpenShift is installed (if using VMs).

- Govc is used to create and manage VMs on ESXi or vSphere.
  - https://github.com/vmware/govmomi/tree/main/govc

Be sure to set the correct (govc) values to access vCenter in the `vmware.conf` file.  Note that ESXi is also supported.

Why `make` was chosen to build Aba?

The UNIX/Linux command "make" is a utility for automating tasks based on rules specified in a Makefile. It enhances efficiency by managing dependencies, 
facilitating streamlined processes. Widely applied beyond software development, "make" proves versatile in system management, ensuring organized 
execution of diverse tasks through predefined rules!


## Advanced

Cluster presets are used mainly to automate the testing of Aba. 

```
make sno
```
- This will create a directory `sno` and then install SNO OpenShift using the Agent-based installer (note, *all* preset parameters in `aba.conf` must be completed for this to work).  If you are using VMware it will create the VMs for you.
- Be sure to go through *all* the values in `aba/vmware.conf` and `sno/cluster.conf`.
- Be sure your DNS entries have been set up in advance. See above on Prerequisites. 
- Aba will show you the installation progress.  To troubleshoot cluster installation, run `make ssh` to log into the rendezvous node. If there are any issues - e.g. incorrect DNS records - fix them and try again.  All commands and actions in Aba are idempotent.  If you hit a problem, fix it and try again should always be the right way forward!

```
make compact    # for a 3 node cluster topology (note, *all* parameters in 'aba.conf' must be completed for this to work).
make standard   # for a 3+2 topology (note, *all* parameters in 'aba.conf' must be completed for this to work).
```
- Run this to create a compact cluster (works in a similar way to the above). 


