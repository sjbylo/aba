#!/bin/bash 

usage="\
$(basename $0) lists operator dependencies
Usage: $(basename $0) [-hc] <version> <operator name>
   <version>       is OpenShift version.  Ex: 4.18
   <operator name> is Operator name.  Ex: odf-operator
Options:
   -h     help
   -c     clean
"

clean=
# -c will clean the old pod and data
if [ "$1" = "-h" ]; then
	echo "$usage" >&2

	exit 0
elif [ "$1" = "-c" ]; then
	clean=1
	shift
fi

[ ! "$1" ] && echo "Error: Parameters missing" && echo && echo "$usage" >&2 && exit 1

version=$1
if ! echo "$version" | grep -q -E "^[0-9]\.[0-9]+$"; then
	echo "Error: OpenShift version format is incorrect [$version]" >&2
	echo >&2
	echo "$usage" >&2

	exit 1
fi

if [ "$clean" ]; then
	existing_id=$(podman ps -a | grep registry.redhat.io/redhat/redhat-operator-index:v$version | awk '{print $1}')
	[ "$existing_id" ] && podman stop $existing_id >/dev/null && sleep 1 && podman rm $existing_id >/dev/null
	rm -rf configs-$version
fi

[ ! "$2" ] && echo "Error: Operator missing" && echo && echo "$usage" >&2 && exit 1
operator=$2

existing_id=$(podman ps -a | grep registry.redhat.io/redhat/redhat-operator-index:v$version | awk '{print $1}')
if [ ! "$existing_id" ]; then
	podman run -q --replace -d --name redhat-catalog registry.redhat.io/redhat/redhat-operator-index:v$version >/dev/null|| exit 1
fi

podman cp redhat-catalog:/configs configs-$version

cat configs-$version/$operator/catalog.json | jq -r 'select(.package=="'$operator'") | .properties[] | select(.type=="olm.package.required") | .value.packageName' 2>/dev/null| sort | uniq 

