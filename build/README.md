# A toolbox container 

A toolbox container that can be used on an internel bastion in case rpms cannot be installed.

Current status:
nmstate not working inside a UBI container. Seeing errors with NM.SettingBond.get_valid_options() failing.
Without nmstate can't create the ISO

`Work in progress`

Build:

podman build -t aba .

Run:
podman run -it --rm  -w $PWD --security-opt label=disable -v $HOME:$HOME -v $HOME:/root localhost/aba:latest bash


