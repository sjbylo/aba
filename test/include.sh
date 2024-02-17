
test-cmd() {
	echo "$@" >> test/test.log
	eval "$@"

	#echo done >> test/test.log
}

remote-test-cmd() {
	host=$1
	shift

	echo "$host: $@" >> test/test.log
	ssh $host -- "$@"

	#echo done >> test/test.log
}

mylog() {
	echo $@
	echo $@ >> test/test.log
}

