# What's new (main → HEAD)

## Features

- **Named mirrors** – `aba mirror --name mymirror` creates an isolated mirror directory, like named clusters. Multiple enclaves each get their own credentials and config.
- **Use a registry you already have** – Register an existing registry with `--pull-secret-mirror` and `--ca-cert`. ABA stores credentials locally and never touches the real registry. Deregister with `aba unregister`.
- **Quay or Docker** – New `reg_vendor` setting (`auto`, `quay`, `docker`). Auto picks Quay on x86_64/s390x/ppc64le, Docker on arm64. The TUI settings toggle writes this to `mirror.conf`.
- **Unified registry architecture** – Install, uninstall, and remote deployment go through a single dispatcher (`reg-install.sh`) with shared library (`reg-common.sh`) and vendor-specific scripts. Both Quay and Docker support remote install via SSH.
- **Credentials persist** – Registry pull secret and CA cert now live in `~/.aba/mirror/<name>/`, surviving `aba clean` and `aba reset`. A `mirror/regcreds` symlink is kept for convenience.
- **More CLI options** – `--vendor`, `--reg-port`, `--reg-host`, `-A`/`--api-vip`, `-G`/`--ingress-vip`, `-W`/`--num-workers`, `--num-masters`, `--vlan`, `--ssh-key`, `--proxy`, `--no-proxy`, `--data-disk-gb`, `-Y`/`--yes-permanent`. Old fake short flags removed.
- **Idempotent install** – If the registry is already healthy, `aba install` continues instead of failing.
- **Wildcard DNS detection** – DNS checks now detect wildcard entries and soften failures to warnings.
- **Shared catalog index** – Catalog index files stored in `aba/.index/` with symlinks per mirror directory, avoiding redundant downloads.
- **ISC dependency tracking** – ISC regeneration respects operator and `mirror.conf` changes; configurable catalog TTL.
- **Single RPM install** – All RPMs installed in one `dnf` call instead of individually.

## TUI

- **Settings persist** – Registry type (Quay/Docker) and "ask before big steps" saved to and reloaded from config files, including inline-comment handling.
- **Exit button on Pull Secret dialog** – Escape no longer the only way out.
- **ISC race condition fixed** – Background ISC generation no longer deletes save-dir ISC prematurely; System Z timestamp equality handled.
- **Basket works on fresh install** – Empty basket no longer appears when no operators are selected on first run.

## Reliability

- **Quay resource check warns, not aborts** – Pre-flight CPU/memory check logs a warning instead of blocking install.
- **Docker `--network host`** – Docker registry and pool registries use host networking, fixing pasta/hairpin issues.
- **CLI download race fixed** – `oc-mirror` and other CLI downloads complete before catalog fetches start.
- **Stale credential detection** – Fresh installs no longer blocked by leftover credentials from previous runs.
- **`aba reset` guarded** – Won't reset if registry is still installed; `aba clean` removes working-dir.
- **`grep -q` removed** – Eliminates SIGPIPE killing bash in pipelines.
- **Shutdown respects `-y`** – Cluster shutdown prompt honors `-y` flag and `ask=false`.
- **Retry on cluster shutdown** – Retry logic and failure reporting added.
- **Tarball extraction hardened** – Removed `|| true` masks; added gzip integrity guards.
- **Remote registry fixes** – Auth/data-dir paths, Docker image tarball existence check before scp, uninstall fallbacks.

## Errors & messages

- **OSUS error improved** – Mentions CatalogSource sync delay.
- **Vendor-neutral messages** – Registry messages no longer assume Quay.
- **Double `[ABA]` prefix removed** – Clean log output.
- **Breadcrumb and reinstall warnings** – Registry UX improved with clear context.

