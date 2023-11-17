# Aba agent-based helper

Aba makes it easier to install OpenShift onto vSphere or ESXi (or onto bare-metal) using the Agent-based installer in a disconnected environment. 
It helps you generate valid agent-based configuration files and then, using those files, to create matching VMs in vSphere or ESXi. 

## Prerequisites

- A private subnet 
- DNS
- NTP (ESXi must be configured with NTP) 
- vSphere with vCenter API access
- ESXi can also be used on its own (i.e. no vCenter) 
- a RHEL host or VM for the bastion
- Internet access from your bastion to download the container images

## Basic use 

- First, install a bastion host with a fresh version of RHEL (a 'minimal install' will work fine).  
- Note that aba has been tested with RHEL 9.3 but other recent versions of RHEL should work. 
- Copy your pull secret in JSON format to the file ~/.pull-secret.json (in your $HOME directory). 
  - A pull secret can be downloaded from https://console.redhat.com/openshift/install/pull-secret

The following command will:
  - install the Quay mirror registry on your bastion host,
  - mirror the correct OCP version images and 
  - configure the pull secrets and certificates needed to install OCP. 
Be sure to set the correct values for vCenter.  Note that ESXi will also work (see the values in ~/.vmware.conf) 

```
bin/init-rag.sh basic   
```
- 'basic' is just the name of the directory to use to store agent-based config files.  You can choose any name you wish, e.g. 'sno' or 'compact'.

The following will install openshift using the Agent-based assisted installer. 
Be sure to go through *all* the values in ~/.vmware.conf and config.yaml. Be sure to set up your DNS entries in advance. 
```
bin/aba basic           
```

Run the following for more instructions.

```
bin/aba -h 
```

