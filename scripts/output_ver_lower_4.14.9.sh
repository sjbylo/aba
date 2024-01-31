a=4.14.9
r=`echo -e "$1\n$a"| sort -V | tail -1`
[ "$r" != "$1" ] 

