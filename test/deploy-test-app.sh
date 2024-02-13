#!/bin/bash -e

source aba/scripts/include_all.sh

source <(cd aba/mirror && normalize-mirror-conf)

cd aba/sno

make cmd cmd='oc new-project demo'||true
make cmd cmd="oc new-app --insecure-registry=true --image $reg_host:$reg_port/$reg_path/sjbylo/flask-vote-app --name vote-app -n demo" || true
make cmd cmd='oc rollout status deployment vote-app -n demo'




