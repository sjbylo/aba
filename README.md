# Aba agent-based helper

Aba makes it easier to install OpenShift onto vSphere or ESXi (or onto bare-metal) using the Agent-based installer.
It helps you generate valid agent-based configuration files and then, using those files, to create matching VMs in vSphere or ESXi. 

## Basic installation

Install a bastion host with a fresh version of RHEL (a 'minimal install' will work).  Note: RHEL 9.3 has been tested. 
Copy your pull secret in JSON format to the file ~/.pull-secret.json (in your $HOME diorectory). 
A pull secret can be downloaded from https://console.redhat.com/openshift/install/pull-secret

The following will install the mirror registry on your bastion host and configure the needed pull secrets and certificates. 
- # Be sure to set the correct values for vCenter.  ESXi will also work. 
```
bin/init-rag.sh basic   
```

The following will install openshift using the Agent-based assisted installer. 
- # Be sure to go through *all* the values in ~/.vmware.conf and config.yaml. Be sure to set up your DNS entries in advance. 
```
bin/aba basic           
```

Run the following for more instructions.

```
bin/aba -h 
```

