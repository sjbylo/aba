
test-cmd() {
	set +x

	local tot_cnt=1
	local sleep_time=20
	[ "$1" = "-r" ] && local tot_cnt="$2" && backoff=$3 && shift && shift && shift

	[ "$1" = "-m" ] && local msg="$2" && shift && shift 

	[ "$msg" ] && echo "`hostname`: $msg" >> test/test.log || echo "`hostname`: $@" >> test/test.log

	i=1
	while true
	do
		eval "$@"
		ret=$?
		[ $ret -eq 0 ] && break

		echo "Command failed: $@"

		let i=$i+1
		[ $i -gt $tot_cnt ] && echo "Giving up!" && break

		echo "Sleeping $sleep_time seconds ..."
		sleep $sleep_time
		sleep_time=`expr $sleep_time \* $backoff`
		echo "Attempting command again ($i/$tot_cnt)" | tee test/test.log
	done

	set -x  # This was always returning 0, even if $@ command failed
	return $ret
}

remote-test-cmd() {
	set +x

	local tot_cnt=1
	local sleep_time=20
	[ "$1" = "-r" ] && local tot_cnt="$2" && backoff=$3 && shift && shift && shift

	[ "$1" = "-m" ] && local msg="$2" && shift && shift 

	host=$1 && shift

	[ "$msg" ] && echo "$host: $msg" >> test/test.log || echo "$host: $@" >> test/test.log

	i=1
	while true
	do
		ssh $host -- "$@" 
		ret=$?
		[ $ret -eq 0 ] && break

		echo "Command failed: $@"

		let i=$i+1
		[ $i -gt $tot_cnt ] && echo "Giving up!" && break

		echo "Sleeping $sleep_time seconds ..."
		sleep $sleep_time
		sleep_time=`expr $sleep_time \* $backoff`
		echo "Attempting command again ($i/$tot_cnt)" | tee test/test.log
	done

	set -x  # This was always returning 0, even if $@ command failed
	return $ret
}

mylog() {
	set +x

	echo $@
	echo $@ >> test/test.log

	set -x
}

