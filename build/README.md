# Work in progress 

podman build -t aba .
podman run -it --rm  -w $PWD --security-opt label=disable -v $HOME:$HOME -v $HOME:/root localhost/aba:latest bash
