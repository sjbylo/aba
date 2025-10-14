d=$1; shift
until aba --dir $d ssh --cmd 'chronyc sources' | grep "$*"; do echo -n .; sleep 10; done
