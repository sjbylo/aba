
test-cmd() {
	set +x

	local tot_cnt=1
	local sleep_time=20

	while echo $1 | grep -q ^-
	do
		[ "$1" = "-h" ] && local host="$2" && shift && shift 

		[ "$1" = "-r" ] && local tot_cnt="$2" && backoff=$3 && shift && shift && shift 

		[ "$1" = "-m" ] && local msg="$2" && shift && shift 
	done

	[ "$msg" ] && echo "`hostname`: $msg" | tee -a test/test.log || echo "`hostname`: $@" | tee -a test/test.log

	i=1
	while true
	do
		echo "Running command: \"$@\""
		set +e
		eval "$@"
		ret=$?
		set -e

		[ $ret -eq 0 ] && break

		echo "Attempt ($i/$tot_cnt) failed with error $ret for command \"$@\""

		let i=$i+1
		[ $i -gt $tot_cnt ] && echo "Giving up with command \"$@\"!" && break

		echo "Next attempt will be ($i/$tot_cnt)"
		echo "Sleeping $sleep_time seconds ..."
		sleep $sleep_time
		sleep_time=`expr $sleep_time \* $backoff`
		echo "Attempting command again ($i/$tot_cnt)" | tee -a test/test.log
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

	[ "$msg" ] && echo "$host: $msg" | tee -a test/test.log || echo "$host: $@" | tee -a test/test.log

	i=1
	while true
	do
		echo "Running command: \"$@\""
		set +e
		ssh $host -- "$@" 
		ret=$?
		set -e

		[ $ret -eq 0 ] && break

		echo "Attempt ($i/$tot_cnt) failed with error $ret for command \"$@\""

		let i=$i+1
		[ $i -gt $tot_cnt ] && echo "Giving up with command \"$@\"!" && break

		echo "Next attempt will be ($i/$tot_cnt)"
		echo "Sleeping $sleep_time seconds ..."
		sleep $sleep_time
		sleep_time=`expr $sleep_time \* $backoff`
		echo "Attempting command again ($i/$tot_cnt)" | tee -a test/test.log
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

