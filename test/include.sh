
test-cmd() {
	set +x

	[ "$1" = "-m" ] && local msg="$2" && shift && shift 
	[ "$msg" ] && echo "$msg from host `hostname`" >> test/test.log || echo "$@ from host `hostname`" >> test/test.log
	eval "$@"

	set -x
}

remote-test-cmd() {
	set +x

	[ "$1" = "-m" ] && local msg="$2" && shift && shift 

	host=$1 && shift

	[ "$msg" ] && echo "$msg from host $host" >> test/test.log || echo "$@ from host $host" >> test/test.log
	ssh $host -- "$@"

	set -x
}

mylog() {
	set +x

	echo $@
	echo $@ >> test/test.log

	set -x
}

