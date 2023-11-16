#!/bin/bash

DIR=$1.src

validate-args() {
	if [ -z "$DIR" ]; then
		cat <<-END
			Usage: `basename $0` <directory> 

			The <directory> exists and contains both the agent-based config files: install-config.yaml and agent-config.yaml 
			- aba will do all steps needed to deploy OpenShift to ESXi/vSphere using the agent-based config files.

			Usage: `basename $0` <command> <directory> 

			Get started:

			bin/aba <directory>	If the directory does not exist it will be created and a config file added.
						edit the config file and run the command again. 

			Commands:

			create:    Create the VMs using the config files (install-config.yaml and agent-config.yaml)
			refresh:   Delete and re-create the VMs 
			stop:      Power down the VMs
			start:     Power on the VMs
			monitor:   View the installation progress on the rendezvous server after the agent service has started
			generate:  Create the config file install-config.yaml and agent-config.yaml from the config.yaml file

END
		exit 1
	fi

	:
}

