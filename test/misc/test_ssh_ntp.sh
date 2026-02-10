d=$1; shift
aba --dir $d --cmd 'chronyc sources'
until aba --dir $d --cmd 'chronyc sources' | grep "$*"; do echo -n .; sleep 10; done
aba --dir $d --cmd 'chronyc sources'
