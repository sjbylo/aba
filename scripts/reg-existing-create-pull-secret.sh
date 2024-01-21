#!/bin/bash -e

source mirror.conf

read -p "Enter username [init]: " reg_user
#read reg_user
[ ! "$reg_user" ] && reg_user=init 

read -sp "Enter password: " reg_pw
echo

export enc_password=$(echo -n "$reg_user:$reg_pw" | base64 -w0)

# Inputs: enc_password, reg_host and reg_port 
scripts/j2 ./templates/pull-secret-mirror.json.j2 > ./regcreds/pull-secret-mirror.json

