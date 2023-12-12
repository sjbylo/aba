Migrate files to remote host

```
cd
tar czf - bin aba/aba aba/*.md aba/cli aba/*.conf aba/Makefile aba/scripts aba/templates aba/mirror | ssh $(whoami)@10.0.1.6 tar xvzf -
```

