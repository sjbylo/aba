Migrate files to remote host

```
cd
tar czf - bin aba/aba aba/*.md aba/cli aba/*.conf aba/Makefile aba/scripts aba/templates aba/mirror | ssh $(whoami)@10.0.1.6 tar xvzf -
```

Or, use of netcat/nmap-ncat (RHEL 9)

```
# Insyall 'nc' onto both bastions
sudo yum install nmap-ncat -y 
ssh $(whoami)@10.0.1.6 sudo yum install  nmap-ncat -y  
# On external bastion only
p=22222
ssh $(whoami)@10.0.1.6 -- "sudo firewall-cmd --add-port=$p/tcp --permanent && sudo firewall-cmd --reload && rm -rf ~/bin/* ~/aba"
ssh $(whoami)@10.0.1.6 -- "nc -l $p| tar xvzf -"
cd
p=22222
#tar czf - bin aba | nc 10.0.1.6 $p
# Ensure aba can't be managed by git.  No need to copy everything over.
tar czf - `find bin aba -type f ! -path "aba/.git*" -a ! -path "aba/cli/*"` | nc 10.0.1.6 $p
```

or with rsync over ssh

```
rsync --progress --partial -avz --exclude '*/.git*' bin aba $(whoami)@10.0.1.6:
```

