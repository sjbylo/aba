d=$1; shift
aba --dir $d ssh --cmd 'chronyc sources'
until aba --dir $d ssh --cmd 'chronyc sources' | grep "$*"; do echo -n .; sleep 10; done
