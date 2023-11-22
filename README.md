# Aba is an agent-based wrapper

Aba makes it easier to install OpenShift "Cluster Zero" onto vSphere or ESXi (or onto bare-metal) using the Agent-based installer in a disconnected environment. 
It will generate valid agent-based configuration files and then, using those files, creates the matching VMs in vSphere or ESXi. 
The default use-case will install the Quay mirror registry onto localhost (bastion) and use the generated credentials to build out the Agent-based configuration files. 

## Prerequisites

- A private subnet.
- DNS (with A records for OCP API and Ingress).
- NTP (OCP requires that ESXi be configured with NTP).
- vSphere with vCenter API access.  ESXi can also be used on its own (i.e. without vCenter).
- a RHEL host or VM for the bastion (where Quay mirror registry will be installed). 
- Internet access from your bastion to download the container images.
- So far, only a "(partially disconnected environment)[https://docs.openshift.com/container-platform/4.14/installing/disconnected_install/installing-mirroring-disconnected.html#mirroring-image-set-partial]" is supported.  Fully air-gapped (or "(fully disconnected environment)[https://docs.openshift.com/container-platform/4.14/installing/disconnected_install/installing-mirroring-disconnected.html#mirroring-image-set-full]" is work-in-progress. 

## Basic use 

- First, install a bastion host with a fresh version of RHEL (a 'minimal install' of RHEL 9.3 has been tested, other recent versions of RHEL should work too).  
- Copy your pull secret in JSON format to the file ~/.pull-secret.json (in your $HOME directory).  It's a good idea to make the file user read-only, e.g. 'chmod 600 ~/.pull-secret.json'.
  - A pull secret can be downloaded from https://console.redhat.com/openshift/install/pull-secret

The below command will:
  - If needed, indstall 'oc' and 'openshift-install' with the same version
  - install the Quay mirror registry on your bastion host
  - mirror the correct OCP version images and 
  - configure the pull secrets and certificates needed to install OCP. 

Be sure to set the correct (govc) values for vCenter in ~/.vmware.conf.  Note that ESXi will also work (see the comments in ~/.vmware.conf).

```
bin/aba reg init 
```

The following will install openshift using the Agent-based assisted installer. 
Be sure to go through *all* the values in ~/.vmware.conf and config.yaml. Be sure to set up your DNS entries in advance. 
```
bin/aba mycluster
```
- 'mycluster' (appended wuth '.src') is the directory aba creates to store all needed config files.  You can choose any name you wish, e.g. 'sno', 'compact', 'cluster0' ...

Run the following for more instructions.

```
bin/aba -h 
```



# Miscellaneous

Govc is used to create and manage VMs on ESXi or vSphere.

https://github.com/vmware/govmomi/tree/main/govc

