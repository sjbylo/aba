# Functional Tests

Unit and integration tests that run on bastion. No VMs or clusters required.

## Running all tests

```bash
cd ~/aba
for t in test/func/test-*.sh; do bash "$t" || echo "FAILED: $t"; done
```

## TUI tests

The 4 TUI tests drive the dialog-based wizard via tmux:

```bash
bash test/func/test-tui-v2-01-wizard.sh
bash test/func/test-tui-v2-02-basket.sh
bash test/func/test-tui-v2-03-actions.sh
bash test/func/test-tui-v2-04-isconf.sh
```

They run sequentially (each takes 2-7 minutes). To watch live from another terminal:

```bash
TMUX= tmux attach -t tui-test -r
```

The `-r` flag attaches read-only. Prefix with `TMUX=` if already inside tmux.

Note: TUI tests run `aba reset` which removes `~/bin/govc` and other CLI tools.
Reinstall with `make -sC cli govc` if needed afterwards.

## Other notable tests

| Test | What it covers |
|------|---------------|
| `test-aba-wait-show.sh` | Spinner function: timeouts, signals, isolation |
| `test-run-once-*.sh` | Task runner: locking, races, TTL, validation |
| `test-e2e-framework.sh` | E2E test harness helpers |
| `test-mirror-save-workflow.sh` | Mirror save/load pipeline |
| `test-symlinks-exist.sh` | Cross-directory symlink integrity |
