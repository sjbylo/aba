# Aba is an agent-based wrapper

Aba makes it easier to install an OpenShift cluster - "Cluster Zero" - into a disconnected environment, onto vSphere or ESXi (or bare-metal) using the Agent-based installer.

Aba automatically completes the following:
1. installs the Quay mirror registry onto localhost (your bastion) 
1. uses Quay's credentials to build out the Agent-based configuration files
1. generates the needed boot ISO
1. creates the required VMs in ESXi (or vSphere) and powers them on. 

## Prerequisites

- A private subnet.
- DNS
   - with A records for OCP API and Ingress.
- NTP
   - OCP requires that ESXi be configured with NTP.
- vSphere with vCenter API access.  
   - ESXi can also be used on its own (i.e. without vCenter).
- a RHEL host or VM for the bastion (where Quay mirror registry will be installed). 
- Root access with sudo.
- Internet access from your bastion to download the container images.
   - So far, only a "[partially disconnected environment](https://docs.openshift.com/container-platform/4.14/installing/disconnected_install/installing-mirroring-disconnected.html#mirroring-image-set-partial)" is supported, which means the bastion needs to have both Internet access and access to the private subnet.  Fully air-gapped or "[fully disconnected environment](https://docs.openshift.com/container-platform/4.14/installing/disconnected_install/installing-mirroring-disconnected.html#mirroring-image-set-full)" is work-in-progress. 

## Basic use 

- First, install a bastion host with a fresh version of RHEL (a 'minimal install' of RHEL 9.3 has been tested, other recent versions of RHEL should work too).  
- Copy your pull secret in JSON format to the file ~/.pull-secret.json (in your $HOME directory).  It's a good idea to make the file user read-only, e.g. 'chmod 600 ~/.pull-secret.json'.
  - A pull secret can be downloaded from https://console.redhat.com/openshift/install/pull-secret
- Create the needed DNS A records for the following, *for example* (use your own domain):
  - OCP API: api.ocp1.example.com - points to a free IP in your private subnet. 
  - OCP Ingress: *.apps.ocp1.example.com - points to a free IP in your private subnet. 
  - Quay mirror registry: registry.example.com - points to the IP address of your RHEL bastion. 

The below command will:
  - If needed, install 'oc' and 'openshift-install' with the same specified version
  - install the Quay mirror registry on your bastion host
  - mirror the correct OCP version images and 
  - configure the pull secrets and certificates needed to install OCP. 

Be sure to set the correct (govc) values for vCenter in ~/.vmware.conf.  Note that ESXi will also work (see the comments in ~/.vmware.conf).

```
bin/aba reg init 
```

The following command will install openshift using the Agent-based installer. 

Be sure to go through *all* the values in '~/.vmware.conf' and 'aba.conf'. Be sure to set up your DNS entries in advance. 

```
bin/aba --dir mycluster
```

- 'mycluster' (appended with '.src') is the directory aba creates to store all needed configuration files.  You can choose any name you wish, e.g. 'sno', 'compact', 'cluster0' ...

aba will show you the install progress.  If there are any issues - e.g. missing DNS records - fix them and then run the same command again.  All commands should be idempotent.

You can also run this command to monitor the progress of the Agent-based installer.

```
bin/aba mon --dir mycluster
```

Run the following for more instructions.

```
bin/aba -h 
```



# Miscellaneous

Govc is used to create and manage VMs on ESXi or vSphere.

https://github.com/vmware/govmomi/tree/main/govc

