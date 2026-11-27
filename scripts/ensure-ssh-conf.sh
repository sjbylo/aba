#!/bin/bash
# Write ~/.aba/ssh.conf.
# include_all.sh calls this once per process. ./install calls it too.
# install must not source include_all.sh (that sets ARCH and loads ~/.aba/config).
# Always rewrite, so a new option arrives without a reinstall.
# No stdout: include_all.sh is sourced by every script.

ensure_ssh_conf() {
	[ -n "${HOME:-}" ] || return 0
	mkdir -p "$HOME/.aba" || return 0
	cat > "$HOME/.aba/ssh.conf" <<'END'
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
ConnectTimeout=15
ServerAliveInterval=30
ServerAliveCountMax=10
BatchMode=yes
LogLevel=ERROR
END
}
