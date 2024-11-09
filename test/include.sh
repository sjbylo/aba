# Code that all scripts need.  Ensure this script does not create any std output.

echo_black()	{ [ "$TERM" ] && tput setaf 0; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_red()	{ [ "$TERM" ] && tput setaf 1; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_green()	{ [ "$TERM" ] && tput setaf 2; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_yellow()	{ [ "$TERM" ] && tput setaf 3; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_blue()	{ [ "$TERM" ] && tput setaf 4; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_magenta()	{ [ "$TERM" ] && tput setaf 5; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_cyan()	{ [ "$TERM" ] && tput setaf 6; echo -e "$@"; [ "$TERM" ] && tput sgr0; }
echo_white()	{ [ "$TERM" ] && tput setaf 7; echo -e "$@"; [ "$TERM" ] && tput sgr0; }

umask 077

# Function to display an error message and the last executed command
#show_error() {
#	local exit_code=$?
#	echo 
#	#[ "$TERM" ] && tput setaf 1
#	echo Script error: 
#	echo "Error occurred in command: '$BASH_COMMAND'"
#	echo "Error code: $exit_code"
#	#[ "$TERM" ] && tput sgr0
#
#	echo "FAILED" >> test/test.log
#
#	exit $exit_code
#}

# Set the trap to call the show_error function on ERR signal
#trap 'show_error' ERR

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

	local ignore_result=    # No matter what the command's exit code is, return 0 (success)
	local tot_cnt=1		# Try to run the command max tot_cnt times.
	local host=localhost	# def. host to run on

	#trap - ERR  # FIXME: needed?

	while echo $1 | grep -q ^-
	do
		[ "$1" = "-i" ] && local ignore_result=1 && shift

		[ "$1" = "-h" ] && local host="$2" && shift && shift 

		[ "$1" = "-r" ] && local tot_cnt="$2" && backoff=$3 && shift && shift && shift 

		[ "$1" = "-m" ] && local msg="$2" && shift && shift 
	done

	local cmd="$@"

	draw-line
	if [ "$msg" ]; then
		echo "$host: $msg ($cmd) ($(pwd)) ($(date))" | tee -a test/test.log
	else
		echo "$host: $cmd ($(pwd)) ($(date))" | tee -a test/test.log
	fi
	draw-line

	while true
	do
		cd $PWD  # Just in case the dir is re-created

		local sleep_time=20     # Initial sleep time
		local i=1

		while true
		do
			if [ "$host" != "localhost" ]; then
				echo "Running command: \"$cmd\" on host $host"
				ssh $host -- "export TERM=xterm; $cmd"    # TERM set just for testing purposes
			else
				echo "Running command: \"$cmd\" on localhost"
				eval "$cmd"
			fi
			ret=$?
			echo Return value = $ret

			[ $ret -eq 0 ] && return 0

			echo "Attempt ($i/$tot_cnt) failed with error $ret for command \"$cmd\""
			let i=$i+1
			[ $i -gt $tot_cnt ] && echo "Giving up with command \"$cmd\"!" && break

			echo "Next attempt will be ($i/$tot_cnt)"
			echo "Sleeping $sleep_time seconds ..."
			sleep $sleep_time
			sleep_time=`expr $sleep_time + $backoff \* 8`
			echo "Attempting command again ($i/$tot_cnt) - ($cmd)" | tee -a test/test.log
		done

		[ "$reset_xtrace" ] && set -x

		[ "$ignore_result" ] && echo "Ignoring result [$ret] and returning 0" && return 0  # We want to return 0 to ignore any errors (-i)

		echo_red -n "COMMAND FAILED WITH RET=$ret, TRY AGAIN (Y) OR SKIP (N) OR ENTER NEW COMMAND? (Y/n/<cmd>): "
		read ans

		if [ "$ans" = "n" -o "$ans" = "N" ]; then
			echo Skipping this command ...

			return 0  # If return non-zero then this shell is lost!
		elif [ "$ans" = "Y" -o "$ans" = "y" -o ! "$ans" ]; then
			echo Trying same command again ...
		else
			cmd="$ans"
			echo "Running new command: $cmd"
		fi
	done

	echo Returning val $ret
	return $ret
}

mylog() {
	local reset_xtrace=; set -o | grep -q ^xtrace.*on && set +x && local reset_xtrace=1

	echo "---------------------------------------------------------------------------------------"
	echo $@
	echo $@ >> test/test.log
	draw-line

	[ "$reset_xtrace" ] && set -x

	return 0
}

