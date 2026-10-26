# ABA 1.4.2 Release Highlights

Bare-metal BMC automation, per-node disk and bonding configuration, and community-contributed Redfish fixes.

- **Automated bare-metal install via BMC** — ABA can now upload the agent ISO to a server's BMC using Redfish, boot from it, and eject the media automatically. Supports Fujitsu iRMC, Dell iDRAC9, HPE iLO, Supermicro, and Lenovo XCC. No more manual "boot your servers" step when BMC is configured. (Contributed by @mateuszslugocki)
- **Redfish compatibility fixes** — Eight fixes for BMC edge cases across different hardware vendors, including boot override handling, HTTPS ISO URLs, multi-NIC selection, and media status detection. (Contributed by @zetti12345)
- Thanks to **@kahlai** for independently requesting bundle disk space estimation ([#46](https://github.com/sjbylo/aba/issues/46)) — this feature shipped in v1.4.0.
- **MAC address auto-discovery** — When BMC credentials are configured, ABA queries the server's network interfaces during preflight and fills in MAC addresses automatically.
- **Disk selection per node** — New `disk_hint` setting in cluster.conf lets you target a specific install disk by path or size, per node, per role, or globally.
- **Bond mode configuration** — New `bond_mode` setting in cluster.conf to control network bonding mode per role or globally.
- **Quay local install hang fixed** — Local Quay installs no longer hang for 10 minutes during the health check.
