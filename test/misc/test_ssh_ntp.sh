d=$1; shift

echo "Showing 'chronyc sources' output:"
aba --dir $d ssh --cmd 'chronyc sources'

echo "Waiting for: '$*'"
until aba --dir $d ssh --cmd 'chronyc sources' | grep "$*"; do echo -n .; sleep 10; done

echo "Showing 'chronyc sources' output:"
aba --dir $d ssh --cmd 'chronyc sources'

exit 0
