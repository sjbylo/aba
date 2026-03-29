# Quay Stale Systemd Service Bug

**Date**: March 2026

## Problem

Quay mirror registry installs would intermittently fail with "Connection reset
by peer" on the host's external IP (e.g. `bastion.example.com:8443`), while
`localhost:8443` worked fine.  The `mirror-registry install` ansible playbook
would time out waiting for the health endpoint and report failure.

This was a rare, hard-to-reproduce issue that only affected hosts where an
**older** version of mirror-registry had been installed at some point in the
past.

## Root Cause

An older mirror-registry version (pre-SQLite, circa Dec 2024) created a
`quay-postgres.service` systemd user unit.  When that registry was later
uninstalled — either by `mirror-registry uninstall` or `aba -d mirror
uninstall` — the uninstaller only removed the services **it knew about**:

- `quay-pod.service`
- `quay-app.service`
- `quay-redis.service`

The stale `quay-postgres.service` was left behind because the newer
mirror-registry version does not manage PostgreSQL (it uses SQLite).

The stale unit file contained:

```ini
Requires=quay-pod.service
Restart=always
RestartSec=30
```

This meant that every time a **new** Quay pod was created, `quay-postgres.service`
would automatically activate (via `Requires=quay-pod.service`) and begin
crash-looping — running `podman run --pod=quay-pod --replace` every 30 seconds
and failing with exit code 125 because the PostgreSQL image/secrets were gone.

On the affected host the service had restarted **1,752 times**.  The constant
churn of failed container creation inside the pod disrupted pasta's network
port-forwarding, causing external connections to be reset while localhost
continued to work.

## Diagnosis Steps

1. `systemctl --user list-unit-files | grep quay` revealed `quay-postgres.service`
   with a Dec 2024 timestamp alongside the current services.
2. `journalctl | grep quay-postgres` showed `restart counter is at 1752`.
3. `systemctl --user show quay-postgres.service` confirmed `NRestarts=1752`,
   `Result=exit-code`.
4. Restarting the pod (after removing the stale service) restored full external
   connectivity immediately.

## Fix

1. **Immediate**: Removed the stale service file and reloaded systemd:
   ```bash
   systemctl --user stop quay-postgres.service
   systemctl --user disable quay-postgres.service
   rm -f ~/.config/systemd/user/quay-postgres.service
   systemctl --user daemon-reload
   ```

2. **Preventive**: Added `cleanup_orphaned_quay_services()` to
   `bundles/v2/common.sh`.  This function removes **all** `quay-*` systemd
   user services — not just the ones the current mirror-registry knows about.
   It runs as a safety net **after** `aba -d mirror uninstall` in both
   `00-setup.sh` (pre-flight) and `08-cleanup.sh` (post-build).  A guard
   prevents it from running if `quay-pod` still exists (forces proper aba
   uninstall first).

## Key Takeaway

`mirror-registry uninstall` only cleans up the services it creates.  When
upgrading between mirror-registry versions that use different backing services
(PostgreSQL -> SQLite), orphaned systemd units can persist indefinitely and
interfere with future installs.

## Related

After resolving this stale-service issue, a separate recurring hairpin
connectivity problem was identified.  That issue affects **any** offline host
lacking a default route and is documented in `ai/QUAY_PASTA_HAIRPIN.md`.
