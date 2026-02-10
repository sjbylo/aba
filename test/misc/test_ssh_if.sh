aba --dir "$1" --cmd "ip a"
until aba --dir "$1" --cmd "ip a" | grep "$2"; do sleep 10; done
aba --dir "$1" --cmd "ip a"
