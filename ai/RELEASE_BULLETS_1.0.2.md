# ABA 1.0.2 - Release Notes

New `aba upgrade` command, trace logging, bug fixes and reliability improvements.

## New Features

- `aba upgrade` -- Upgrade air-gapped clusters via the local mirror. 
- Trace logging -- Every invocation logs to `~/.aba/logs/trace.log`
- `aba show-op-sets` -- List available operator sets and descriptions (alias: `aba op-sets`).
- `aba delete --force` -- Removes the entire cluster directory after deleting VMs.

## Improvements

- Smarter `day2-ntp` -- Skips MCO reboot when NTP config is already applied.
- Ctrl-C skip hints on long waits (startup, NTP, upgrade monitoring).
- Spinner and `[ABA]` colored output restored (trace logging regression).
- Podman catalog errors now visible instead of suppressed.

## Bug Fixes

- `run_once` error recovery -- Zombie cleanup, partial download removal, lock fix for `setsid` children. Clear recovery hint shown to user.
- `oc-command.sh` stdout pollution -- `grep` and `aba_info` leaked to stdout, corrupting `aba run --cmd` output.
- VM delete guards -- `kvm-delete.sh`/`vmw-delete.sh` exit 0 when config is missing.
