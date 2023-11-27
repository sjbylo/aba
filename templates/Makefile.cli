# No file exists to check timestamps
.PHONY: all clean 

OCP_VER  ?= 4.13.19

#all: mirror install sync ocp-install
all: ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror 

# CLI tools 
~/bin/oc: openshift-client-linux-$(OCP_VER).tar.gz
	tar -C ~/bin -xzvf openshift-client-linux-$(OCP_VER).tar.gz oc
	touch ~/bin/oc

openshift-client-linux-$(OCP_VER).tar.gz:
	curl -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(OCP_VER)/openshift-client-linux-$(OCP_VER).tar.gz

~/bin/openshift-install: openshift-install-linux-$(OCP_VER).tar.gz 
	tar -C ~/bin -xzvf openshift-install-linux-$(OCP_VER).tar.gz openshift-install
	touch ~/bin/openshift-install

openshift-install-linux-$(OCP_VER).tar.gz:
	curl -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(OCP_VER)/openshift-install-linux-$(OCP_VER).tar.gz

~/bin/oc-mirror: oc-mirror.tar.gz
	tar -C ~/bin -xvzf oc-mirror.tar.gz oc-mirror
	chmod +x ~/bin/oc-mirror
	touch ~/bin/oc-mirror

oc-mirror.tar.gz:
	curl -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(OCP_VER)/oc-mirror.tar.gz


