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

# Define a cleanup function to handle Ctrl-C
cleanup() {
	if [[ -n "$sub_pid" ]]; then
		echo "Interrupt received. Terminating command ..."
		kill "$sub_pid" 2>/dev/null
		wait "$sub_pid" 2>/dev/null
		echo "Test command terminated."
	else
		echo Stopping
		echo
		exit 1
	fi
}

# Trap Ctrl-C (SIGINT) and call cleanup function
trap cleanup SIGINT

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

		[ "$1" = "-h" ] && local host="$2" && shift 2

		[ "$1" = "-r" ] && local tot_cnt="$2" && local backoff=$3 && shift 3

		[ "$1" = "-m" ] && local msg="$2" && shift 2
	done

	local cmd="$@"

	draw-line
	if [ "$msg" ]; then
		#echo "$(date "+%b %e %H:%M:%S") $msg ($cmd) ($host) ($PWD)" | tee -a test/test.log
		log-test -t "$msg ($cmd) ($host) ($PWD)"
	else
		#echo "$(date "+%b %e %H:%M:%S") ($cmd) ($host) ($PWD)" | tee -a test/test.log
		log-test -t "($cmd) ($host) ($PWD)"
	fi
	##draw-line

	# Loop to repeat the command if user requests
	while true
	do
		cd $PWD  # Just in case the dir is re-created

		local sleep_time=5     # Initial sleep time
		local i=1

		# Loop to repeat the command if it fails
		while true
		do
			if [ "$host" != "localhost" ]; then
				echo "Running command: \"$cmd\" on host $host"
				ssh -o LogLevel=ERROR $host -- "export TERM=xterm; $cmd" &    # TERM set just for testing purposes
			else
				echo "Running command: \"$cmd\" on localhost"
				eval "$cmd" &
			fi
			sub_pid=$!  # Capture the PID of the subprocess
			wait "$sub_pid"
			ret=$?

			[ $ret -eq 0 ] && return 0 # Command successful 
			[ $ret -eq 130 ] && break  # on Ctrl-C *during command execution*

			echo Return value = $ret

			echo_cyan "Attempt ($i/$tot_cnt) failed with error $ret for command \"$cmd\""
			let i=$i+1
			[ $i -gt $tot_cnt ] && echo "Giving up with command \"$cmd\"!" && break

			echo "Next attempt will be ($i/$tot_cnt)"
			echo "Sleeping $sleep_time seconds ..."
			#trap - SIGINT  # This will cause Ctl-C to quit everything during sleep $sleep_time
			sleep $sleep_time
			#trap cleanup SIGINT
			sleep_time=`expr $sleep_time + $backoff \* 8`

			#echo_cyan "$(date "+%b %e %H:%M:%S") Attempting command again ($i/$tot_cnt) - ($cmd)" | tee -a test/test.log
			log-test -t "Attempting command again ($i/$tot_cnt) - ($cmd)"

			( echo -e "test.log:\n"; tail -8 test/test.log; echo -e "\noutput.log:\n"; tail -20 test/output.log ) | notify.sh "Failed cmd: $cmd" || true
		done

		[ "$reset_xtrace" ] && set -x

		[ "$ignore_result" ] && echo "Ignoring result [$ret] and returning 0" && return 0  # We want to return 0 to ignore any errors (-i)

		sub_pid=
		if [[ $ret -eq 130 ]]; then
			sub_pid=
		fi
			
		( echo -e "test.log:\n"; tail -8 test/test.log; echo -e "\noutput.log:\n"; tail -20 test/output.log ) | notify.sh "Aborting cmd: $cmd" || true

		#echo $(date "+%b %e %H:%M:%S") COMMAND FAILED WITH RET=$ret >> test/test.log
		log-test COMMAND FAILED WITH RET=$ret
		echo_red -n "COMMAND FAILED WITH RET=$ret, TRY AGAIN (Y) OR SKIP (N) OR ENTER NEW COMMAND OR Ctrl-C? (Y/n/<cmd>): "
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

log-test() {
	if [ "$1" = "-t" ]; then
		shift
		echo $(date "+%b %e %H:%M:%S") "$@" | tee -a test/test.log
	else
		echo $(date "+%b %e %H:%M:%S") "$@" >> test/test.log
	fi
}

mylog() {
	local reset_xtrace=; set -o | grep -q ^xtrace.*on && set +x && local reset_xtrace=1

	##echo "---------------------------------------------------------------------------------------"
	draw-line
	echo $(date "+%b %e %H:%M:%S") $@ | tee -a test/test.log
	##draw-line

	[ "$reset_xtrace" ] && set -x

	return 0
}

init_bastion() {
	local int_bastion_hostname=$1
	local int_bastion_vm_name=$2
	local snap_name=$3
	local test_user=$4

	local def_user=steve  # This is the intial, pre-configured user to use

	mylog Revert internal bastion vm to snapshot and powering on ...

	govc vm.power -off bastion-internal-rhel8
	govc vm.power -off bastion-internal-rhel9
	govc snapshot.revert -vm $int_bastion_vm_name aba-test
	sleep 8
	govc vm.power -on $int_bastion_vm_name
	sleep 5

	# Copy over the - already working - default user's ssh config to /root
	if [ "$test_user" = "root" ]; then
		eval cp ~$def_user/.ssh/config /root/.ssh
		eval cp ~$def_user/.ssh/id_rsa* /root/.ssh
	fi

	# Wait for host to come up
	while ! ssh $def_user@$int_bastion_hostname -- "date"
	do
		sleep 3
	done

	pub_key=$(cat ~/.ssh/id_rsa.pub)

	# General bastion config, e.g. date/time/timezone and also root ssh
cat <<END | ssh $def_user@$int_bastion_hostname -- sudo bash
set -ex
timedatectl
dnf install chrony podman -y
chronyc sources -v
chronyc add server 10.0.1.8 iburst
timedatectl set-timezone Asia/Singapore
chronyc -a makestep
sleep 8
chronyc sources -v
timedatectl
mkdir -p /root/.ssh
echo $pub_key > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
END

	# Copy over the ssh config to /root on bastion (in case test_user = root)
	eval scp ~$def_user/.ssh/config root@$int_bastion_hostname:.ssh/config

	test-cmd -m "Verify ssh to root@$int_bastion_hostname" ssh root@$int_bastion_hostname whoami

	# Delete images
	ssh $test_user@$int_bastion_hostname -- "sudo dnf install podman -y && podman system prune --all --force && podman rmi --all && sudo rm -rf ~/.local/share/containers/storage && rm -rf ~/test"
	# This file is not needed in a fully air-gapped env. 
	ssh $test_user@$int_bastion_hostname -- "rm -fv ~/.pull-secret.json"
	# Want to test fully disconnected 
	ssh $test_user@$int_bastion_hostname -- "sed -i 's|^source ~/.proxy-set.sh|# aba test # source ~/.proxy-set.sh|g' ~/.bashrc"
	# Ensure home is empty!  Avoid errors where e.g. hidden files cause reg. install failing. 
	ssh $test_user@$int_bastion_hostname -- "rm -rfv ~/*"

	# Just be sure a valid govc config file exists on internal bastion
	scp $vf $test_user@$int_bastion_hostname: 

	# Set up test to install mirror with other user, "testy"
	rm -f ~/.ssh/testy_rsa*
	ssh-keygen -t rsa -f ~/.ssh/testy_rsa -N ''
	pub_key=$(cat ~/.ssh/testy_rsa.pub)   # This must be different key
	u=testy

cat << END  | ssh $def_user@$int_bastion_hostname -- sudo bash 
set -ex
userdel $u -r -f || true
useradd $u -p not-used
mkdir ~$u/.ssh 
chmod 700 ~$u/.ssh
#cp -p ~steve/.pull-secret.json ~$u 
echo $pub_key > ~$u/.ssh/authorized_keys
echo '$u ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$u
chmod 600 ~$u/.ssh/authorized_keys
chown -R $u.$u ~$u
END

	test-cmd -m "Verify ssh to testy@$int_bastion_hostname" ssh -i ~/.ssh/testy_rsa testy@$int_bastion_hostname whoami

	###test-cmd -h testy@$int_bastion_hostname -m "Delete and create sub dir on remote host for user $u" "rm -rf $subdir && mkdir $subdir"
	if [ "$test_user" = "root" ]; then
		# /root does not have enough space by default, so we link it to ~steve/root
		test-cmd -h $test_user@$int_bastion_hostname -m "Create sub dir on remote host for $test_user" "rm -rf $subdir && mkdir -p ~steve/root/subdir && ln -fs ~steve/root/subdir"
	else
		test-cmd -h $test_user@$int_bastion_hostname -m "Create sub dir on remote host for $test_user" "rm -rf $subdir && mkdir $subdir"
	fi
}
