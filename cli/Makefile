# No file exists to check timestamps
.PHONY: all clean distclean

ocp_target_ver  := $(shell cat ../target-ocp-version.conf)

all: ../target-ocp-version.conf ~/bin ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror 

~/bin:
	mkdir ~/bin

../target-ocp-version.conf:
	../aba

# oc
~/bin/oc: openshift-client-linux-$(ocp_target_ver).tar.gz
	tar -C ~/bin -xmzf openshift-client-linux-$(ocp_target_ver).tar.gz oc

openshift-client-linux-$(ocp_target_ver).tar.gz:
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_target_ver)/openshift-client-linux-$(ocp_target_ver).tar.gz


# openshift-install
~/bin/openshift-install: openshift-install-linux-$(ocp_target_ver).tar.gz 
	tar -C ~/bin -xmzf openshift-install-linux-$(ocp_target_ver).tar.gz openshift-install

openshift-install-linux-$(ocp_target_ver).tar.gz:
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_target_ver)/openshift-install-linux-$(ocp_target_ver).tar.gz


# oc-mirror
~/bin/oc-mirror: oc-mirror.tar.gz ~/bin/oc 
	tar -C ~/bin -xmzf oc-mirror.tar.gz oc-mirror
	chmod +x ~/bin/oc-mirror

oc-mirror.tar.gz:
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_target_ver)/oc-mirror.tar.gz


#~/.pull-secret.json:
#	$(SCRIPTS)/install-pull-secret.sh 

clean:
	rm -f ~/bin/{oc,oc-mirror,openshift-install} 

distclean: clean
	rm -f *.tar.gz

