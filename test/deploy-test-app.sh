#!/bin/bash -e

source scripts/include_all.sh

source <(cd mirror && normalize-mirror-conf)

cd aba/sno

make cmd cmd='oc new-project demo'
make cmd cmd='oc new-app --insecure-registry=true --image $reg_host:$reg_port/$reg_path/sjbylo/flask-vote-app --name vote-app -n demo'
make cmd cmd='oc rollout status deployment vote-app -n demo' 


