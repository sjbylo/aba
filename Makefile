# No file exists to check timestamps
.PHONY: all cli clean mirror install sync sno save load test

TEMPLATES = templates
SCRIPTS   = scripts
ocp_target_ver   ?= 4.13.19
d        ?= 
DEBUG     = $d
#version  ?= 4.14.2
version := $(shell $(SCRIPTS)/fetch-ocp-stable-version.sh)


#all: cli mirror ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror

cli:
	make -C cli

##mirror:
##	#mkdir -p mirror
##	echo ocp_target_ver=$(ocp_target_ver) > mirror/openshift-version.conf

install:
	make -C mirror install

uninstall:
	make -C mirror uninstall

sync:
	make -C mirror sync

save:
	make -C mirror save 

load:
	make -C mirror load

sno:
	mkdir -p sno
	ln -fs ../$(TEMPLATES)/Makefile sno/Makefile
	make -C sno

compact:
	mkdir -p compact
	ln -fs ../$(TEMPLATES)/Makefile compact/Makefile
	make -C compact

ocp:
	mkdir -p $(dir)
	ln -fs templates/Makefile $(dir)/Makefile
	ln -fs ../templates $(dir)
	cp test/aba-sno.conf $(dir)/aba.conf
	make -C $(dir) 

test:
	scripts/test.sh

clean:
	make -C mirror clean 
	make -C cli clean 

distclean:
	make -C mirror distclean 
	make -C cli distclean 

