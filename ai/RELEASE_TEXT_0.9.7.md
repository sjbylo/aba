# Release text: main → current head (dev)

User-facing features and fixes between the current `main` branch and current `HEAD` (dev). Use this for the GitHub release description or release announcement.

---

## New features

- **Named mirror directories** – Create multiple mirror workspaces with `aba mirror --name mymirror`. Same pattern as `aba cluster --name`: creates the directory, copies the Makefile, runs init, then prompts to edit `mirror.conf`. Supports oc-mirror enclaves and multiple disconnected registries.

- **Register existing registry** – Add an externally-managed mirror to ABA without installing it: `aba -d <mirror> --pull-secret-mirror <file> --ca-cert <file>`. ABA copies credentials to `~/.aba/mirror/<name>/`, trusts the CA, and records `REG_VENDOR=existing`. `aba uninstall` for such mirrors only removes local credentials and never touches the external registry.

- **Docker registry as first-class citizen** – `reg_vendor` in `mirror.conf` (`auto`, `quay`, `docker`). `auto` picks Quay on x86/s390x/ppc64le and Docker on arm64. Single commands `aba -d mirror install` / `uninstall` for both vendors, local or remote (SSH). Credentials live in `~/.aba/mirror/<mirror-name>/`.

- **CLI options for mirror and cluster** – New or clarified flags: `--vendor` (auto|quay|docker), `--reg-host` (primary name; `-H` kept), `--reg-port`, `--api-vip` (`-A`), `--ingress-vip` (`-G`), `--data-disk-gb`, `--yes-permanent` (long form for `-Y`), `--num-workers` (`-W`), `--num-masters`, `--vlan`, `--ssh-key`, `--proxy`, `--no-proxy`. Placeholder flags removed; `--reg-host` and mirror config flags work like `-H` (write into mirror.conf).

- **Marker files renamed** – `.installed` / `.uninstalled` are now `.available` / `.unavailable` for clearer meaning (e.g. “mirror is available” vs “ABA installed it”).

- **Mirror.conf edit prompt** – When creating or editing config for a named mirror (e.g. `xxxx`), the prompt now shows “Configure your private mirror registry (xxxx/mirror.conf)” instead of always “mirror/mirror.conf”.

---

## Improvements

- **Idempotent install** – If the mirror registry is already running and healthy, `aba -d mirror install` no longer fails; it detects the existing registry and continues.

- **Shutdown and prompts** – Cluster shutdown prompt and other confirmations respect `-y` and `ask=false` in `aba.conf`, so automation is not blocked.

- **Docker registry** – Uses `--network host` where needed; credentials are saved before connectivity checks; uninstall has a fallback path when state is missing.

- **TUI** – Loads `ask` and `reg_vendor` from config files even with inline comments; Docker (vendor) setting is applied when `mirror.conf` does not exist yet; settings persist correctly.

- **DNS and validation** – Wildcard DNS detection added; DNS checks can be softened to warnings where appropriate.

- **Catalog and mirror config** – Configurable catalog TTL; mirror.conf can override ops-related settings; ISC (image set config) regeneration and TUI ISC handling fixed (races and erroneous save deletion).

- **Skip CLI downloads for housekeeping** – Commands like mirror install/uninstall that don’t need OCP version no longer trigger full CLI download checks.

- **Quay on arm64** – On arm64, pool/setup can skip Quay mirror-registry and use Docker registry instead.

- **Error messages and verify** – Clearer errors; verify sentinel and pre-flight probes improved; stale registry state detection and Quay SSH fallback hardened.

- **Makefile and mirror flags** – Mirror Makefiles consolidated under `templates/`; mirror-related flags respect `-d <dir>` so named mirror dirs are used correctly (no hardcoded `cd` to default `mirror/`).

- **Unregister external mirror** – `aba -d mirror unregister` (or uninstall with `REG_VENDOR=existing`) cleanly removes only local credentials for externally-managed registries.

---

## E2E and testing (of interest to contributors)

- **Notifications** – E2E failure notifications include `[e2e]`, pool number, test name, and last ~20 lines of suite log; hostname shown instead of “localhost”.
- **Cleanup** – Pre-suite cleanup uses `aba -y` so uninstall/delete never prompt; snapshot revert can be replaced by ABA cleanup for faster, more realistic runs.
- **Retries** – Single retry for long cluster installs; “Attempt (X/Y) failed … – attempting again…” when a retry follows.
- **Resource lifecycle** – Suites clean up their own clusters and mirrors; only the OOB cluster is shared; no safety nets in framework.

---

## Summary (short blurb)

This release adds **named mirror directories** (`aba mirror --name mymirror`) and **register existing registry** (pull secret + CA cert → ABA-managed credentials, safe uninstall). **Docker registry** is a first-class option via `reg_vendor`, with a single install/uninstall path for Quay and Docker, local or remote. **CLI** gains `--vendor`, `--reg-host`, `-A`/`-G` for VIPs, `--data-disk-gb`, `--yes-permanent`, `--num-workers`/`--num-masters`, and proxy/vlan/ssh-key options. **Markers** are renamed to `.available`/`.unavailable`. **Install** is idempotent when the registry is already healthy; **prompts** respect `-y`/`ask=false`; **TUI** and **error handling** are improved. E2E notifications, cleanup, and retry behavior are updated for stability and clarity.
