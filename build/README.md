# A toolbox container 

A toolbox container that can be used on an internel bastion in case rpms cannot be installed.

`Work in progress`

Build:

podman build -t aba .

Run:
podman run -it --rm  -w $PWD --security-opt label=disable -v $HOME:$HOME -v $HOME:/root localhost/aba:latest bash


