
test-cmd() {
	[ "$1" = "-m" ] && local msg="$2" && shift && shift 
	[ "$msg" ] && echo "$msg" >> test/test.log || echo "$@" >> test/test.log
	eval "$@"
}

remote-test-cmd() {
	[ "$1" = "-m" ] && local msg="$2" && shift && shift 

	host=$1 && shift

	[ "$msg" ] && echo "$msg" >> test/test.log || echo "$@" >> test/test.log
	ssh $host -- "$@"
}

mylog() {
	echo $@
	echo $@ >> test/test.log
}

