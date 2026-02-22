# Proposed ABA/TUI core changes (from E2E runs)

*Do not apply without review. Document only.*

## Test framework fixes (applied)

- **Parallel dispatch**: In `test/e2e/lib/parallel.sh`, the remote command now exports `E2E_ON_BASTION=1` (and `ABA_TESTING=1` when set) so that `run.sh` on the pool host runs the suite directly instead of re-dispatching (which triggered SSH and the permissions error).
- **Coordinator-only suites**: In `test/e2e/run.sh`, when running with `--parallel`, coordinator-only suites (e.g. `clone-and-check`) are run locally on the coordinator first; only the remaining suites are dispatched to pools. This avoids running govc/VM suites on pool hosts.

## Environment / infra (not ABA code)

- **Parallel dispatch exit 255 / "Bad owner or permissions on ... 50-redhat.conf"**: The message is from the **coordinator** (the host where you run `run.sh --parallel`), not from the pool hosts. When the dispatcher runs `ssh con1 '...'` in the background, the **local** SSH client reads `/etc/ssh/ssh_config.d/50-redhat.conf`; if that file (or the directory) is not owned by root, SSH exits with 255. Fix on the **coordinator** (e.g. registry4):
  ```bash
  # On the coordinator (registry4)
  sudo chown root:root /etc/ssh/ssh_config.d /etc/ssh/ssh_config.d/50-redhat.conf
  sudo chmod 755 /etc/ssh/ssh_config.d
  sudo chmod 644 /etc/ssh/ssh_config.d/50-redhat.conf
  ```
  If the file does not exist on the coordinator, create it: `sudo touch /etc/ssh/ssh_config.d/50-redhat.conf` then chown/chmod as above. Optional: same checks on **pool hosts (con1/con2)** if a suite later SSHs from con1 to dis1 and you see the error in the pool log:

  1. **Diagnose** (on each host):
     ```bash
     ssh steve@con1.example.com 'ls -la /etc/ssh/ssh_config.d/ 2>/dev/null; grep -r Include /etc/ssh/ssh_config 2>/dev/null'
     ```
  2. **Fix directory and any config files** (directory must be root:root 755; any `.conf` files root:root 644):
     ```bash
     ssh steve@con1.example.com 'sudo chown root:root /etc/ssh/ssh_config.d; sudo chmod 755 /etc/ssh/ssh_config.d; for f in /etc/ssh/ssh_config.d/*.conf; do [ -f "$f" ] && sudo chown root:root "$f" && sudo chmod 644 "$f"; done'
     ssh steve@con2.example.com 'sudo chown root:root /etc/ssh/ssh_config.d; sudo chmod 755 /etc/ssh/ssh_config.d; for f in /etc/ssh/ssh_config.d/*.conf; do [ -f "$f" ] && sudo chown root:root "$f" && sudo chmod 644 "$f"; done'
     ```
  3. **If the main config explicitly Includes a missing file** (e.g. `50-redhat.conf`), create it so SSH stops complaining:
     ```bash
     ssh steve@con1.example.com 'sudo touch /etc/ssh/ssh_config.d/50-redhat.conf && sudo chown root:root /etc/ssh/ssh_config.d/50-redhat.conf && sudo chmod 644 /etc/ssh/ssh_config.d/50-redhat.conf'
     ssh steve@con2.example.com 'sudo touch /etc/ssh/ssh_config.d/50-redhat.conf && sudo chown root:root /etc/ssh/ssh_config.d/50-redhat.conf && sudo chmod 644 /etc/ssh/ssh_config.d/50-redhat.conf'
     ```
  Then retry `run.sh --parallel --suites mirror-sync --ci`.

## ABA/TUI core

(No ABA/TUI core code changes proposed yet.)
