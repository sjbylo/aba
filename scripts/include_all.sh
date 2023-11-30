# Function to display an error message and the last executed command
show_error() {
	local exit_code=$?
	echo 
	echo Script error: 
	echo "Error occurred in command: '$BASH_COMMAND'"
	echo "Error code: $exit_code"
	exit $exit_code
}

# Set the trap to call the show_error function on ERR signal
trap 'show_error' ERR

