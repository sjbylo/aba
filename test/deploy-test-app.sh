#!/bin/bash -e

cd aba/sno

make cmd cmd='oc new-project demo'

make cmd cmd='oc new-app --insecure-registry=true --image registry2.example.com:8443/openshift4/sjbylo/flask-vote-app --name vote-app -n demo'
sleep 5

make cmd cmd='oc rollout status deployment vote-app -n demo' 

make -C aba/sno delete 

