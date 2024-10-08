# Code that all scripts need.  Ensure this script does not create any std output.

umask 077

# Function to display an error message and the last executed command
show_error() {
	local exit_code=$?
	echo 
	#[ "$TERM" ] && tput setaf 1
	echo Script error: 
	echo "Error occurred in command: '$BASH_COMMAND'"
	echo "Error code: $exit_code"
	#[ "$TERM" ] && tput sgr0

	echo "FAILED" >> test/test.log

	exit $exit_code
}

# Set the trap to call the show_error function on ERR signal
trap 'show_error' ERR

draw-line() {
	# Get the number of columns (width of the terminal)
	cols=$(tput cols)

	# Create a line of dashes or any character you prefer
	printf '%*s\n' "$cols" '' | tr ' ' '-'
}

# -h remote <host or ip> to run the test on (optional)
# -r <count> <backoff>  (optional)
# -m "Description of test"
test-cmd() {
	local reset_xtrace=; set -o | grep -q ^xtrace.*on && set +x && local reset_xtrace=1

	local tot_cnt=1
	local sleep_time=20
	local host=localhost

	while echo $1 | grep -q ^-
	do
		[ "$1" = "-h" ] && local host="$2" && shift && shift 

		[ "$1" = "-r" ] && local tot_cnt="$2" && backoff=$3 && shift && shift && shift 

		[ "$1" = "-m" ] && local msg="$2" && shift && shift 
	done

	draw-line
	if [ "$msg" ]; then
		echo "$host: $msg ($@) ($(pwd)) ($(date))" | tee -a test/test.log
	else
		echo "$host: $@ ($(pwd)) ($(date))" | tee -a test/test.log
	fi
	draw-line

	i=1
	while true
	do
		set +e
		if [ "$host" != "localhost" ]; then
			echo "Running command: \"$@\" on host $host"
			ssh $host -- "export TERM=xterm; $@"    # TERM set just for testing purposes
		else
			echo "Running command: \"$@\" on localhost"
			eval "$@"
		fi
		ret=$?
		set -e

		[ $ret -eq 0 ] && break

		echo "Attempt ($i/$tot_cnt) failed with error $ret for command \"$@\""

		let i=$i+1
		[ $i -gt $tot_cnt ] && echo "Giving up with command \"$@\"!" && break

		echo "Next attempt will be ($i/$tot_cnt)"
		echo "Sleeping $sleep_time seconds ..."
		sleep $sleep_time
		#sleep_time=`expr $sleep_time \* $backoff`
		sleep_time=`expr $sleep_time + $backoff \* 10`
		echo "Attempting command again ($i/$tot_cnt) - ($@)" | tee -a test/test.log
	done

	[ "$reset_xtrace" ] && set -x

	return $ret  # 'set' was always returning 0, even if $@ command failed
}

mylog() {
	local reset_xtrace=; set -o | grep -q ^xtrace.*on && set +x && local reset_xtrace=1

	echo "---------------------------------------------------------------------------------------"
	echo $@
	echo $@ >> test/test.log
	draw-line

	[ "$reset_xtrace" ] && set -x
}

