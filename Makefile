# No file exists to check timestamps
.PHONY: all cli clean mirror install-connected install sync sno save load

TEMPLATES = ../templates
SCRIPTS   = ../scripts
ocp_target_ver   ?= 4.13.19
d        ?= 
DEBUG     = $d

#all: mirror install sync ocp-install
all: cli mirror install-connected ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror

cli:
	mkdir -p cli
	#ln -fs $(TEMPLATES)/Makefile.cli cli/Makefile
	make -C cli

mirror:
	mkdir -p mirror
	echo ocp_target_ver=$(ocp_target_ver) > mirror/openshift-version.conf
	#ln -fs $(TEMPLATES)/Makefile.mirror mirror/Makefile

install-connected:
	make -C mirror

install:
	make -C mirror install

sync:
	make -C mirror sync

sno:
	mkdir -p sno
	ln -fs $(TEMPLATES)/Makefile sno/Makefile
	make -C sno

compact:
	mkdir -p compact
	ln -fs $(TEMPLATES)/Makefile compact/Makefile
	make -C compact

save:
	make -C mirror save d=$(d)

load:
	make -C mirror load
