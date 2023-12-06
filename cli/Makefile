# No file exists to check timestamps
.PHONY: all clean 

ocp_target_ver  := $(shell cat ../mirror/target-ocp-version.conf)

all: ~/bin ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror #  ~/.pull-secret.json

~/bin:
	mkdir ~/bin

# oc
~/bin/oc: openshift-client-linux-$(ocp_target_ver).tar.gz
	tar -C ~/bin -xzvf openshift-client-linux-$(ocp_target_ver).tar.gz oc
	touch ~/bin/oc

openshift-client-linux-$(ocp_target_ver).tar.gz:
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_target_ver)/openshift-client-linux-$(ocp_target_ver).tar.gz


# openshift-install
~/bin/openshift-install: openshift-install-linux-$(ocp_target_ver).tar.gz 
	tar -C ~/bin -xzvf openshift-install-linux-$(ocp_target_ver).tar.gz openshift-install
	touch ~/bin/openshift-install

openshift-install-linux-$(ocp_target_ver).tar.gz:
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_target_ver)/openshift-install-linux-$(ocp_target_ver).tar.gz


# oc-mirror
~/bin/oc-mirror: oc-mirror.tar.gz ~/bin/oc 
	tar -C ~/bin -xvzf oc-mirror.tar.gz oc-mirror
	chmod +x ~/bin/oc-mirror
	touch ~/bin/oc-mirror

oc-mirror.tar.gz:
	curl --progress-bar -OL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$(ocp_target_ver)/oc-mirror.tar.gz


#~/.pull-secret.json:
#	$(SCRIPTS)/install-pull-secret.sh 

clean:
	rm -f ~/bin/{oc,oc-mirror,openshift-install} 

distclean:
	rm -f *.tar.gz

