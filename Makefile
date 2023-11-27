# No file exists to check timestamps
.PHONY: all cli clean mirror install-connected install sync ocp-install save load

TEMPLATES = ../templates
SCRIPTS   = ../scripts
OCP_VER  ?= 4.13.19

#all: mirror install sync ocp-install
all: cli mirror install-connected ~/bin/oc ~/bin/openshift-install ~/bin/oc-mirror

cli:
	mkdir -p cli
	ln -fs $(TEMPLATES)/Makefile.cli cli/Makefile
	make -C cli

mirror:
	mkdir -p mirror
	ln -fs $(TEMPLATES)/Makefile.mirror mirror/Makefile

install-connected:
	make -C mirror

install:
	make -C mirror install

sync:
	make -C mirror sync

ocp-install:
	mkdir -p sno
	ln -fs $(TEMPLATES)/Makefile sno/Makefile
	make -C sno

stage:
	make -C mirror stage

load:
	make -C mirror load
