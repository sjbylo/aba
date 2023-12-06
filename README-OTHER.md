Migrate files to remote host

```
tar czf - aba/aba bin aba/*.conf aba/Makefile aba/scripts aba/templates aba/*.md aba/mirror aba/cli | ssh $(whoami)@10.0.1.6 tar xvzf -
```

