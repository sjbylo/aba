#!/bin/bash -e

mkdir $1   # If dir exists, exit
ln -fs ../templates/Makefile $1/Makefile
cp templates/aba-standard.conf $1/aba.conf
echo -n "Edit the config file $1/aba.conf, hit RETURN "
read yn
vi $1/aba.conf
make -C $1

