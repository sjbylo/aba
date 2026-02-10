d=$1; shift
aba --dir $d -F ~/.aba/ssh.conf --cmd 'chronyc sources'
until aba --dir $d -F ~/.aba/ssh.conf --cmd 'chronyc sources' | grep "$*"; do echo -n .; sleep 10; done
aba --dir $d -F ~/.aba/ssh.conf --cmd 'chronyc sources'
