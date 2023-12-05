# No file exists to check timestamps
.PHONY: all cli clean mirror install-connected install sync sno save load

TEMPLATES = templates
SCRIPTS   = scripts
ocp_target_ver   ?= 4.13.19
d        ?= 
DEBUG     = $d
#version  ?= 4.14.2
version := $(shell $(SCRIPTS)/fetch-ocp-stable-version.sh)


#all: mirror install sync ocp-install
all: cli mirror install-connected ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror

cli:
	mkdir -p cli
	make -C cli

mirror:
	mkdir -p mirror
	echo ocp_target_ver=$(ocp_target_ver) > mirror/openshift-version.conf

install-connected:
	make -C mirror

install:
	make -C mirror install

uninstall:
	make -C mirror uninstall

sync:
	make -C mirror sync

sno:
	mkdir -p sno
	ln -fs ../$(TEMPLATES)/Makefile sno/Makefile
	make -C sno

compact:
	mkdir -p compact
	ln -fs ../$(TEMPLATES)/Makefile compact/Makefile
	make -C compact

save:
	make -C mirror save d=$(d)

load:
	make -C mirror load

ocp:
	mkdir -p $(dir)
	ln -fs templates/Makefile $(dir)/Makefile
	ln -fs ../templates $(dir)
	make -C $(dir) 

clean:
	make -C mirror clean 
	make -C cli clean 

distclean:
	make -C mirror distclean 
	make -C cli distclean 
