# Docker Registry as a First-Class Citizen

## Status: PLANNED (not yet implemented)

## Current State

The Docker registry path is bolted on the side:

- Separate Makefile targets: `install-docker-registry`, `uninstall-docker-registry`
- Inconsistent script naming: `reg-install.sh` (Quay), `reg-docker-install.sh` (Docker)
- No configuration in `mirror.conf` -- users must know which target to run
- Docker registry is local-only (no remote SSH install)
- Quay's `reg-install.sh` is a ~420-line monolith mixing local install, remote SSH orchestration, FQDN verification, firewall, and Quay-specific SSH-to-localhost setup
- TUI has its own `ABA_REGISTRY_TYPE` variable that doesn't persist to config
- Error messages in several scripts hardcode "Quay" references

**What already works for both:** sync, save, load, verify, credentials (same format)

## Design

### 1. Script layout

Each vendor has a small install script that handles only vendor-specific logic. Shared logic (pre-checks, post-steps) lives in `reg-common.sh`. One generic remote orchestrator handles SSH for all vendors.

```
scripts/
  reg-install.sh                    # Thin dispatcher (vendor + local/remote)
  reg-uninstall.sh                  # Thin dispatcher (vendor + local/remote)

  reg-common.sh                     # Shared functions: pre-checks, post-install, firewall, etc.

  reg-install-quay.sh               # Quay-specific install only (sources reg-common.sh)
  reg-install-docker.sh             # Docker-specific install only (sources reg-common.sh)
  reg-install-remote.sh             # Generic SSH orchestrator (any vendor)

  reg-uninstall-quay.sh             # Quay-specific uninstall (sources reg-common.sh)
  reg-uninstall-docker.sh           # Docker-specific uninstall (sources reg-common.sh)
  reg-uninstall-remote.sh           # Generic SSH uninstall orchestrator (any vendor)
```

9 scripts total. The vendor scripts are small -- they source `reg-common.sh` for all shared logic and only contain the vendor-specific install/uninstall commands.

### 2. Thin dispatcher scripts

`scripts/reg-install.sh` -- reads `reg_vendor` and `reg_ssh_key`, resolves `auto`, dispatches:

```bash
#!/bin/bash
# Dispatcher: installs the configured registry vendor (auto/quay/docker)

source scripts/include_all.sh
source <(normalize-mirror-conf)

vendor="${reg_vendor:-auto}"

# Resolve "auto": Quay if available for this arch, else Docker
if [ "$vendor" = "auto" ]; then
    arch=$(uname -m)
    case "$arch" in
        aarch64|arm64) vendor=docker ;;
        *)             vendor=quay ;;
    esac
    aba_info "reg_vendor=auto resolved to '$vendor' for architecture $arch"
fi

# Write resolved vendor for uninstall dispatcher
echo "$vendor" > .reg_vendor

# Dispatch: local or remote
if [ "$reg_ssh_key" ]; then
    exec scripts/reg-install-remote.sh "$vendor" "$@"
else
    exec scripts/reg-install-${vendor}.sh "$@"
fi
```

`scripts/reg-uninstall.sh` -- reads persistent state from `~/.aba/registry/state.sh`:

```bash
#!/bin/bash
# Dispatcher: uninstalls the currently installed registry

source scripts/include_all.sh

# Read install-time state (survives clean/reset)
state=~/.aba/registry/state.sh
if [ -f "$state" ]; then
    source "$state"
    vendor="$REG_VENDOR"
    reg_ssh_key="${REG_SSH_KEY:-}"
else
    aba_abort "No registry found. Nothing to uninstall." \
        "If a registry exists, its state may have been manually deleted from ~/.aba/registry/"
fi

if [ "$reg_ssh_key" ]; then
    exec scripts/reg-uninstall-remote.sh "$vendor" "$@"
else
    exec scripts/reg-uninstall-${vendor}.sh "$@"
fi
```

### 3. New `mirror.conf` option

Add `reg_vendor` to `templates/mirror.conf.j2`:

```bash
reg_vendor=auto                 # Registry type: auto, quay, or docker.
                                # auto = Quay if available for this architecture, otherwise Docker.
                                # quay = Mirror Registry for Red Hat OpenShift (Quay appliance).
                                # docker = Standard Docker/OCI registry (docker.io/library/registry).
```

Position: after `reg_pw`, before `data_dir`.

Also update the `reg_ssh_key` / `reg_ssh_user` comments to say they work for **both** vendors (not just Quay):

```bash
#reg_ssh_key=~/.ssh/id_rsa      # Optional: SSH private key for remote registry installation.
                                # Works with both Quay and Docker registries.
                                # If unset (default), the registry is installed locally.

#reg_ssh_user=                  # Optional: SSH username for remote registry installation.
                                # Defaults to current user.
```

### 4. `auto` resolution logic

At **install time** the dispatcher resolves `auto`:

- `aarch64`/`arm64` -> `docker` (mirror-registry tarball not available)
- All other architectures -> `quay`
- Future: attempt Quay download and fall back to Docker on failure

### 5. Shared functions (`reg-common.sh`)

All vendor-agnostic logic moves to `scripts/reg-common.sh`, providing functions that vendor scripts call:

```bash
# scripts/reg-common.sh
# Shared functions for registry install/uninstall

source scripts/include_all.sh

# Load and validate mirror.conf + aba.conf
reg_load_config() {
    source <(normalize-aba-conf)
    source <(normalize-mirror-conf)
    verify-aba-conf || exit 1
    verify-mirror-conf || exit 1
    scripts/install-rpms.sh internal
    export reg_hostport=$reg_host:$reg_port
    export reg_url=https://$reg_hostport
}

# Check FQDN resolves to an IP
reg_check_fqdn() { ... }

# Detect any existing registry at reg_url (probe /health/instance, /v2/, /)
reg_detect_existing() { ... }

# Verify reg_host points to this localhost (for local installs)
reg_verify_localhost() { ... }

# Open firewall port (firewalld or iptables fallback)
reg_open_firewall() { ... }

# Copy CA to regcreds/, generate pull secret, write uninstall params
reg_post_install() {
    local ca_path=$1    # vendor passes the CA location
    mkdir -p regcreds
    cp "$ca_path" regcreds/rootCA.pem
    # generate pull secret, write .reg-uninstall-params.sh, verify
    ...
}
```

### 6. Quay install script (vendor-specific only)

**`reg-install-quay.sh` (~80 lines):**

```bash
source scripts/reg-common.sh

reg_load_config
reg_check_fqdn
reg_detect_existing
reg_verify_localhost

# --- Quay-specific: SSH-to-localhost key setup (Quay quirk) ---
[ ! -s $HOME/.ssh/quay_installer ] && \
    ssh-keygen -t ed25519 -f $HOME/.ssh/quay_installer -N '' >/dev/null && \
    cat $HOME/.ssh/quay_installer.pub >> $HOME/.ssh/authorized_keys

# --- Quay-specific: run mirror-registry install ---
./mirror-registry install --quayHostname $reg_host --initUser $reg_user \
    --initPassword "$reg_pw" $reg_root_opts

reg_open_firewall
reg_post_install "$reg_root/quay-rootCA/rootCA.pem"
```

### 7. Docker install script (vendor-specific only)

**`reg-install-docker.sh` (~100 lines):**

```bash
source scripts/reg-common.sh

reg_load_config
reg_check_fqdn
reg_detect_existing
reg_verify_localhost

# --- Docker-specific: CA, certs, htpasswd, podman run ---
# (existing logic from current reg-docker-install.sh, trimmed)
# openssl genrsa, openssl req, htpasswd, podman run ...

reg_open_firewall
reg_post_install "$data_dir/docker-reg/data/.docker-certs/ca.crt"
```

Both vendor scripts follow the **exact same structure**: `reg_load_config` -> `reg_check_fqdn` -> `reg_detect_existing` -> `reg_verify_localhost` -> **vendor-specific install** -> `reg_open_firewall` -> `reg_post_install`. Only the middle part differs.

### 8. Generic remote orchestrator (`reg-install-remote.sh`)

One script handles remote install for **any vendor**. It receives the vendor name from the dispatcher.

```bash
#!/bin/bash
# Generic SSH orchestrator for remote registry install
# Usage: reg-install-remote.sh <vendor> [args...]

source scripts/include_all.sh
source <(normalize-mirror-conf)

vendor=$1; shift

# --- Shared SSH pre-checks ---
# (flag_file trick, FQDN verification, etc. -- same for all vendors)
verify_ssh_connectivity
verify_remote_host
ensure_remote_prereqs   # podman, jq, openssl, htpasswd as needed

# --- Vendor-specific: what to copy and where the CA ends up ---
case "$vendor" in
    quay)
        files_to_copy="mirror/mirror-registry-*.tar.gz"
        remote_install="tar xf mirror-registry-*.tar.gz && \
            ./mirror-registry install --quayHostname $reg_host \
            --initUser $reg_user --initPassword '$reg_pw' $reg_root_opts"
        remote_ca="$reg_root/quay-rootCA/rootCA.pem"
        ;;
    docker)
        files_to_copy="mirror/docker-reg-image.tgz scripts/reg-install-docker.sh"
        remote_install="REG_HOST=$reg_host REG_PORT=$reg_port \
            REG_USER=$reg_user REG_PW='$reg_pw' DATA_DIR=$data_dir \
            bash reg-install-docker.sh"
        remote_ca="$data_dir/docker-reg/data/.docker-certs/ca.crt"
        ;;
esac

# --- Shared SSH execution ---
ssh_open_firewall_port $reg_port
scp $files_to_copy $reg_ssh_user@$reg_host:$remote_dir/
ssh $reg_ssh_user@$reg_host "cd $remote_dir && $remote_install"
scp $reg_ssh_user@$reg_host:$remote_ca regcreds/rootCA.pem

# --- Shared local post-steps ---
generate_pull_secret
write_uninstall_params
scripts/reg-verify.sh
```

The vendor case block is ~15 lines. Everything else is shared. This is the key simplification: **the remote orchestrator doesn't care what it's installing -- it just copies files, runs a command, and fetches back the CA.**

For Quay specifically: by running `mirror-registry install` as a **local install on the remote host**, we eliminate `--targetHostname`, `--targetUsername`, `-k` flags entirely. The Quay binary just installs on "this machine."

### 9. Persistent registry state (`~/.aba/registry/`)

**Problem:** Today, Quay stores install-time params in `mirror/reg-uninstall.sh`. If the user runs `make clean`, `make reset`, or `aba reset`, those files are deleted. The registry is still running, but ABA has "forgotten" about it and can't uninstall it.

**Design principle:** The registry is **infrastructure** that outlives any particular workspace state. Its management data must live outside the cleanable area.

**Location: `~/.aba/registry/`** -- consistent with existing `~/.aba/runner/` for `run_once` state.

```
~/.aba/registry/
  state.sh            # Install-time snapshot of all params needed to manage the registry
  rootCA.pem          # Copy of the registry CA (so regcreds/ can be regenerated)
```

**`state.sh` contents** (written by `reg_post_install()` in `reg-common.sh`):

```bash
# ~/.aba/registry/state.sh -- generated at install time, do not edit
# This file survives make clean/reset and allows ABA to always manage the registry.
REG_VENDOR=quay           # or docker
REG_HOST=registry.example.com
REG_PORT=8443
REG_USER=init
REG_PW='p4ssw0rd'
REG_DATA_DIR=/home/user/quay-install   # or /home/user/docker-reg/data
REG_SSH_KEY=                           # empty = local install
REG_SSH_USER=                          # empty = local install
REG_INSTALLED_AT="2026-01-25 14:30:00" # timestamp for reference
```

**What this enables:**

1. **Uninstall after clean/reset**: `aba mirror uninstall` reads `~/.aba/registry/state.sh` and knows exactly how to tear down the registry, even if `mirror/` has been wiped clean.

2. **Re-connect after clean/reset**: `aba mirror install` (or `sync`/`load`) can detect that a registry already exists, regenerate `regcreds/pull-secret-mirror.json` and `regcreds/rootCA.pem` from the persistent state, and continue working without re-installing.

3. **Detect orphaned registries**: If `~/.aba/registry/state.sh` exists but `mirror/.installed` doesn't, ABA knows there's a registry out there that this workspace hasn't connected to yet.

**Lifecycle:**

- **Install** writes `~/.aba/registry/state.sh` + `~/.aba/registry/rootCA.pem`
- **Uninstall** deletes `~/.aba/registry/` entirely
- **Clean/reset** does NOT touch `~/.aba/registry/` -- clean/reset proceeds normally
- **`aba mirror install`** checks `~/.aba/registry/state.sh` first:
  - If a registry is already installed at the same host:port -> reconnect (regenerate regcreds), skip install
  - If installed at a different host:port -> warn/abort ("A registry is already tracked at X. Uninstall it first.")
  - If not installed -> proceed with fresh install

**Resolved decisions:**

- **Single registry only.** `~/.aba/registry/` tracks one registry. If the user wants a different one, uninstall the current one first.
- **Password stored in `state.sh`.** Same security model as `mirror.conf` (user's home dir, 077 umask). Acceptable.
- **`aba reset` / `aba clean` prints a reminder:** e.g. "Note: registry at registry.example.com:8443 is still running and can still be managed via ABA. Run 'aba mirror uninstall' to remove it."

### 10. Uninstall scripts

All uninstall scripts source `~/.aba/registry/state.sh` for install-time params. On success, they delete `~/.aba/registry/`.

**`reg-uninstall-quay.sh` (local):** sources state, runs `mirror-registry uninstall` with captured params, deletes `~/.aba/registry/`

**`reg-uninstall-docker.sh` (local):** sources state, stops container, removes data dir, deletes `~/.aba/registry/`

**`reg-uninstall-remote.sh` (generic remote):** sources state, SSH to remote, executes the appropriate uninstall command. Short vendor case block:
- Quay: `ssh remote "./mirror-registry uninstall ..."`
- Docker: `ssh remote "podman rm -f registry && rm -rf $data_dir/docker-reg"`
- On success: deletes `~/.aba/registry/`

### 11. Unified Makefile targets

In `mirror/Makefile`:

```makefile
# Unified install -- dispatcher handles vendor + local/remote
.PHONY: install
install: .installed
.installed: .init .rpmsext mirror.conf
    @$(SCRIPTS)/reg-install.sh
    @rm -f .uninstalled
    @touch .installed

# Unified uninstall -- dispatcher handles vendor + local/remote
.PHONY: uninstall
uninstall: .init .uninstalled
.uninstalled:
    $(SCRIPTS)/reg-uninstall.sh
    @rm -f .installed
    @touch .uninstalled
```

Backward-compat aliases:

```makefile
.PHONY: install-docker-registry uninstall-docker-registry
install-docker-registry:
    @REG_VENDOR_OVERRIDE=docker $(SCRIPTS)/reg-install.sh
    @rm -f .uninstalled && touch .installed

uninstall-docker-registry:
    @REG_VENDOR_OVERRIDE=docker $(SCRIPTS)/reg-uninstall.sh
    @touch .uninstalled && rm -f .installed
```

### 12. Vendor marker file (`.reg_vendor`)

Written by the install dispatcher in `mirror/` after resolving `auto`. Contains `quay` or `docker`. Used by:

- Makefile targets (quick check for idempotency)
- `clean` / `reset` can delete this file (it's non-critical -- real state is in `~/.aba/registry/`)

Added to `.gitignore`.

Note: `.reg_vendor` in `mirror/` is a **convenience copy** for the Makefile. The authoritative state is `~/.aba/registry/state.sh`.

### 13. TUI alignment

In `tui/abatui.sh`:

- Remove `ABA_REGISTRY_TYPE` and `get_actual_registry_type()`
- Read/write `reg_vendor` in `mirror.conf` directly
- All install/uninstall commands simplify to `aba -d mirror install` / `uninstall`

### 14. Validation and normalization

In `scripts/include_all.sh`:

- `normalize-mirror-conf`: include `reg_vendor` in exported variables
- `verify-mirror-conf`: validate `reg_vendor` is `auto`, `quay`, or `docker` (if set)
- Default: missing `reg_vendor` = `auto` (backward compat)

### 15. Error message cleanup

- `scripts/reg-verify.sh`: "To install Quay" -> "To install a registry"
- `scripts/reg-sync.sh`: vendor-aware `$reg_root` references
- `scripts/reg-load.sh`: same

### 16. Backward compatibility

- `aba -d mirror install-docker-registry` still works
- `aba -d mirror uninstall-docker-registry` still works
- Missing `reg_vendor` in old `mirror.conf` defaults to `auto` -> Quay on x86 (same as today)
- Old `mirror.conf` files work unchanged

### 17. What does NOT change

- Credential format (pull-secret-mirror.json + rootCA.pem)
- sync/save/load/verify flows (already unified)
- Bundle creation (already downloads both tarballs)

### 18. Documentation

- Update `README.md`: document `reg_vendor`, update SSH options text
- Update `CHANGELOG.md`: feature entry
- Update help text

### 19. Risk assessment

- **Low risk to existing users**: default `auto` = Quay on x86 (identical to today)
- **Medium-high complexity**: splitting `reg-install.sh` is the biggest task
- **Big win for Quay remote**: eliminating `--targetHostname` / `--targetUsername` simplifies the install and removes Quay remote-install quirks
- **Test coverage**: need to test all 4 paths (Quay local, Quay remote, Docker local, Docker remote)
- **Script rename risk**: all callers must be updated; grep sweep required

## Implementation principles

The existing install/uninstall scripts are battle-tested (2+ years in production). Respect what works, but improve it.

- **Start from the working code.** Copy existing logic into the new files, then refactor. Don't write from scratch when proven code exists.
- **Improve readability and efficiency.** Cleaner code, better variable names, simpler flow -- all welcome. But don't change something that works just for style if there's a risk of breaking it.
- **Comment cryptic bash.** Especially string manipulation (`${var##*/}`, `${var%.*}`, parameter expansion, etc.) and array operations. If a bash feature isn't obvious, add a short comment explaining what it does.
- **Preserve the overall flow order** where possible. The new code should be recognizable to someone who knows the old code.
- **Test after each step.** Rename -> test. Split -> test. Add remote -> test. Don't batch changes.

## Classification

This is a **feature** (design improvement / refactoring). It should go on the `dev` branch and be part of the next feature release.

## Dispatch flow diagram

```
reg-install.sh (dispatcher)
  |
  |-- resolve auto -> quay or docker
  |-- write .reg_vendor (convenience copy in mirror/)
  |
  +-- quay + no SSH key   --> reg-install-quay.sh   (local)
  +-- quay + SSH key      --> reg-install-remote.sh quay   (generic SSH orchestrator)
  +-- docker + no SSH key --> reg-install-docker.sh (local)
  +-- docker + SSH key    --> reg-install-remote.sh docker (generic SSH orchestrator)
  |
  |-- all paths call reg_post_install() which writes:
  |     ~/.aba/registry/state.sh   (persistent, survives clean/reset)
  |     ~/.aba/registry/rootCA.pem (persistent copy of CA)
  |     mirror/regcreds/           (workspace copy, deleted by clean/reset)
  |     mirror/.reg_vendor         (workspace copy, deleted by clean/reset)

reg-uninstall.sh (dispatcher)
  |
  |-- reads ~/.aba/registry/state.sh (authoritative, always available)
  |
  +-- local  --> reg-uninstall-${vendor}.sh
  +-- remote --> reg-uninstall-remote.sh $vendor
  |
  |-- on success: deletes ~/.aba/registry/
```

## File impact summary

- **Rename (git mv)**: `reg-install.sh` -> `reg-install-quay.sh`, `reg-docker-install.sh` -> `reg-install-docker.sh`, `reg-uninstall.sh` -> `reg-uninstall-quay.sh`, `reg-docker-uninstall.sh` -> `reg-uninstall-docker.sh`
- **New dispatchers (thin)**: `reg-install.sh`, `reg-uninstall.sh`
- **New shared functions**: `reg-common.sh`
- **New generic remote scripts**: `reg-install-remote.sh`, `reg-uninstall-remote.sh`
- **Simplify (heavy)**: `reg-install-quay.sh` (strip ~200 lines of SSH logic, local only)
- **Minor modify**: `reg-install-docker.sh` (accept config via env vars for remote execution)
- **Modify**: `mirror/Makefile`, `tui/abatui.sh`, `scripts/include_all.sh`, `templates/mirror.conf.j2`, `reg-verify.sh`, `reg-sync.sh`, `reg-load.sh`
- **New persistent state**: `~/.aba/registry/state.sh`, `~/.aba/registry/rootCA.pem`
- **Update references**: all test scripts, bundle scripts, README, CHANGELOG, .gitignore, ai/RULES_OF_ENGAGEMENT.md

## Testing strategy

**Approach:** Manual testing after each implementation step, then update automated tests at the end.

### Manual test checkpoints

After each step, verify the affected path still works before moving to the next:

1. **After script renames + dispatchers:** `aba mirror install` (Quay local) and `aba mirror uninstall` work identically to before. Run `test1` to confirm no regression.
2. **After `reg-common.sh` extraction:** Same -- Quay local install/uninstall still works through shared functions.
3. **After Docker refactoring:** `aba mirror install` with `reg_vendor=docker` works locally. Run `test5` to confirm.
4. **After `auto` resolution:** Verify `reg_vendor=auto` resolves to `quay` on x86, `docker` on arm64 (simulate with env override or arch check).
5. **After remote orchestrator (Quay):** SSH to a test VM, `reg_vendor=quay` + `reg_ssh_key` installs Quay on the remote host.
6. **After remote orchestrator (Docker):** Same VM, `reg_vendor=docker` + `reg_ssh_key` installs Docker registry remotely.
7. **After persistent state:** Install registry -> `aba reset` -> verify `~/.aba/registry/state.sh` survives -> `aba mirror uninstall` still works.
8. **After persistent state (reconnect):** Install registry -> `make -C mirror clean` -> `aba mirror install` (same host:port) -> verify it reconnects without re-installing.
9. **After backward-compat aliases:** `aba -d mirror install-docker-registry` and `uninstall-docker-registry` still work.
10. **After TUI alignment:** TUI registry selection writes `reg_vendor` to `mirror.conf`, install/uninstall work through unified commands.

### Automated test updates

After manual testing passes, update the existing automated tests:

- **`test1`** -- verify it works unchanged through the dispatcher (Quay local)
- **`test5`** -- verify it works unchanged through the dispatcher (Docker local)
- **New `test-cmd` additions** to an existing test file:
  - Verify `~/.aba/registry/state.sh` is created after install
  - Verify `make clean` does NOT delete `~/.aba/registry/`
  - Verify `aba mirror uninstall` after `make clean` still works
  - Verify `aba mirror install` after `make clean` reconnects (regcreds regenerated)
- **Grep sweep:** verify no script, Makefile, or test references the old script names

### Remote testing

Use available VMs to test all 4 remote/local combinations:
- Quay local, Quay remote (SSH to VM)
- Docker local, Docker remote (SSH to VM)
- Verify firewall, CA fetch, pull secret generation for each

## Implementation todos

1. Rename scripts (git mv): `reg-install.sh` -> `reg-install-quay.sh`, etc.
2. Create thin dispatcher scripts (`reg-install.sh`, `reg-uninstall.sh`)
3. Create `reg-common.sh` with shared functions (config loading, FQDN check, existing registry detection, firewall, post-install)
4. Add `reg_vendor=auto` to `mirror.conf` template and normalize/verify logic
5. Strip SSH remote logic out of `reg-install-quay.sh` (local only, sources `reg-common.sh`)
6. Refactor `reg-install-docker.sh` (sources `reg-common.sh`, accept config via env vars for remote)
7. Create `reg-install-remote.sh` (generic SSH orchestrator for any vendor)
8. Create `reg-uninstall-remote.sh` (generic SSH uninstall orchestrator)
9. Implement persistent registry state in `~/.aba/registry/` (written by `reg_post_install()`, read by uninstall dispatcher)
10. Refactor `mirror/Makefile` (unified targets, backward-compat aliases, `.reg_vendor` convenience marker)
11. Update Quay-hardcoded messages to be vendor-neutral
12. Align TUI (replace `ABA_REGISTRY_TYPE` with `reg_vendor`)
13. Update `README.md`, `CHANGELOG.md`, help text
14. Update clean/reset targets (clean `mirror/` freely; `~/.aba/registry/` is untouched)
15. Test all 4 paths: Quay local, Quay remote, Docker local, Docker remote
16. Test clean/reset scenarios: install -> clean -> uninstall (must work); install -> clean -> re-install (must reconnect)

---

## Addendum: Explicit Remote Mode (`reg_remote`)

**Problem:** Today, setting `reg_ssh_key` in `mirror.conf` implicitly triggers remote
installation. The parameter name doesn't communicate this intent, which can confuse users
who don't realize that filling in an SSH key means "install the registry on a remote host."

**Decision:** Add `reg_remote=true/false` to `mirror.conf` (default: not set).

- If `reg_remote=true`: remote install mode; `reg_ssh_key` and `reg_ssh_user` must be set
  (dispatcher validates this and aborts with a clear error if missing).
- If `reg_remote=false` or not set: local install mode. `reg_ssh_key` is ignored even if set.
- **Backward compatibility:** If `reg_remote` is not set but `reg_ssh_key` IS set, fall back to
  current behavior (treat as remote) and emit a deprecation warning nudging the user to add
  `reg_remote=true` explicitly.

This removes the "magic inference" while keeping existing configs working.

---

## Addendum: Multiple Mirror Registries / Enclaves (Future)

**Problem:** Today ABA assumes a single `mirror/` directory. Users managing multiple
disconnected enclaves need multiple mirrors, each with its own registry, imageset-config,
and credentials.

**Current state:** The architecture *almost* supports this already -- `aba -d mirror2 sync`
would work if `mirror2/` existed with its own Makefile and `mirror.conf`.

**Design principles for multi-mirror readiness (apply NOW during refactoring):**

1. **Don't hardcode `mirror/`** in new code. Use `$PWD` or the directory set by `aba -d`.
2. **Scope persistent state by registry host:** Use `~/.aba/registry/<reg_host>/` instead of
   a flat `~/.aba/registry/`, so multiple registries don't collide.
3. **Cluster config needs a mirror pointer:** Add (or plan for) a `mirror_dir=mirror` field
   in cluster configs so each cluster knows which mirror to use.

**NOT implementing now, but when the time comes:**

- Provide a `aba mirror-init <name>` command (or Makefile target) that copies the mirror
  directory template to `mirror-<name>/` with its own `mirror.conf`.
- TUI would offer a mirror selector when multiple mirror dirs exist.
- Bundle creation would ask which mirror to bundle (or accept `-d mirror2`).

**Documentation:** Add a note in `README.md`: "To manage multiple mirrors, copy `mirror/`
to `mirror2/`, edit its `mirror.conf`, and use `aba -d mirror2`."
