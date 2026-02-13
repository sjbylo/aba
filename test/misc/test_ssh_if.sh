echo "Showing 'ip a' output:"
aba --dir "$1" ssh --cmd "ip a"

echo "Waiting for string: '$2':"
until aba --dir "$1" ssh --cmd "ip a" | grep "$2"; do sleep 10; done

echo "Showing 'ip a' output:"
aba --dir "$1" ssh --cmd "ip a"

exit 0
