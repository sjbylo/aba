until aba --dir $1 ssh --cmd 'chronyc sources' | grep $2; do echo -n .; sleep 10; done
