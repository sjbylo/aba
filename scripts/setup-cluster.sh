#!/bin/bash -e

mkdir -p $1
ln -fs ../templates/Makefile $1/Makefile
cp templates/aba-standard.conf $1/aba.conf
echo -n "Edit the config file $1/aba.conf, hit RETURN "
read yn
vi $1/aba.conf
make -C $1

