until aba --dir "$1" ssh --cmd "ip a" | grep "$2"; do sleep 10; done
