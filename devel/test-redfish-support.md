# Testing the BMC/Redfish Bare-Metal Automation

Branch: `bm-auto-redfish`

This document covers how to install ABA from this branch and test the
Redfish-based bare-metal BMC automation feature (PR #27) at three
levels — from zero-hardware stub tests to a full bare-metal install.

---

## Getting Started — Install ABA from this Branch

### Prerequisites

- RHEL 8, 9, or 10 (x86_64)
- sudo access (passwordless recommended) or root
- Internet access (for the initial setup; not needed for air-gapped testing)
- A Red Hat pull secret at `~/.pull-secret.json`
  ([download here](https://console.redhat.com/openshift/install/pull-secret))

### Clone and install

```bash
git clone -b bm-auto-redfish https://github.com/sjbylo/aba.git
cd aba
./install
```

This installs the `aba` and `abatui` commands into your `$PATH` and
sets up the `~/.aba/` state directory.  You can now run ABA from
anywhere, but all commands below assume you are inside the `aba/`
directory.

### Quick smoke test

```bash
aba --version          # Should show the ABA version
aba --help             # Overview of all commands
```

---

## Level 1 — Functional Tests (stub-based, no hardware needed)

These use a Redfish HTTP stub (`test/func/lib/bmc-redfish-stub.sh`,
~840 lines of canned JSON responses) to exercise all logic paths
without contacting any BMC.  No hardware or mirror registry needed —
just bash on a RHEL box.

```bash
# BMC preflight — 17 paths (L1–L5 gates, MAC discovery scenarios)
bash test/func/test-preflight-check-bm.sh

# MAC auto-discovery — 9 paths (NIC resolution, caching, opt-out)
bash test/func/test-bmc-mac-discovery.sh

# Boot orchestrator — 8 paths (boot lifecycle, all 6 vendor adapters, error handling)
bash test/func/test-bmc-boot.sh

# Shipped-file hygiene (leaked secrets, ticket IDs, escape sequences)
bash test/func/test-shipped-file-hygiene.sh
```

Or run them all via the test runner (they are in the "integration" tier):

```bash
bash test/func/run-all-tests.sh
```

Expected result: every test prints `OK PASS` and the suite ends with
`OK ALL PATHS PASSED`.

---

## Level 2 — Preflight Against Real BMC Hardware (non-destructive)

This validates real Redfish connectivity, authentication, licensing,
and boot capabilities **without rebooting any server**.  Only L1–L5
read-only Redfish GETs are performed.

### Prerequisites

- A bare-metal server with a reachable BMC (iDRAC, iLO, iRMC, Supermicro, Lenovo, or any DSP0266 Redfish BMC)
- BMC credentials (a user with at least read access to the Redfish tree)
- A configured ABA mirror registry — if you don't have one yet:

```bash
# Create and install a mirror registry (one-time setup)
aba mirror                     # Creates the mirror/ directory and mirror.conf
aba -d mirror install          # Installs the registry (Docker, Quay, or OMR)
aba -d mirror sync             # Syncs OpenShift content to the registry
```

### Steps

```bash
# 1. Set platform to bare-metal (global setting in aba.conf)
aba --platform bm

# 2. Create a bare-metal cluster directory
aba cluster --name bmc-test --type sno

# 3. Copy the BMC config template and lock permissions
cp templates/bmc.conf bmc-test/bmc.conf
chmod 600 bmc-test/bmc.conf
```

> **Note**: `--platform bm` writes to `aba.conf` (global, not per-cluster).
> Remember to set it back (`aba --platform vmw` or `aba --platform kvm`)
> when you're done testing BMC and want to create VM-based clusters again.

Edit `bmc-test/bmc.conf` with your BMC details:

```
bmc_type_master0=idrac              # irmc | idrac | ilo | supermicro | lenovo | redfish
bmc_host_master0=10.0.1.50          # BMC IP or FQDN reachable from this host
bmc_user_master0=admin              # Redfish user
bmc_password_master0='YourPass'     # Keep file mode 0600; never logged
bmc_insecure_master0=true           # true for self-signed BMC certs
```

Also fill in the cluster networking in `bmc-test/cluster.conf`
(at minimum `starting_ip`, `api_vip`, `ingress_vip`, `gateway`,
`machine_network`, `dns1`).

```bash
# 4. Run preflight only (does NOT boot or mount anything)
aba -d bmc-test preflight
```

#### What to expect

Success (all levels pass):

```
BMC: master0 L1=ok L2=ok L3=ok L4=ok L5=ok MAC=ok
BMC: preflight 1/1 nodes ready
```

Failure (example — wrong password):

```
BMC: master0 L2=FAIL reason="HTTP 401 on /redfish/v1/"
BMC: preflight 0/1 nodes ready (1 failed - see BMC: messages above)
```

### Preflight levels explained

| Level | What it checks | Failure means |
|-------|---------------|---------------|
| L1 | TCP connectivity to BMC port 443 | Firewall, DNS, or wrong `bmc_host` |
| L2 | Redfish authentication (`/redfish/v1/`) | Wrong user/password |
| L3 | VirtualMedia collection exists and is licensed | BMC license doesn't include VirtualMedia |
| L4 | Boot target allowables (Cd or UsbCd + Once) | UEFI boot-from-CD not enabled in BMC firmware |
| L5 | Vendor-specific firmware/model gate | Unsupported firmware version or model (vendor-dependent) |
| MAC | Redfish EthernetInterfaces NIC discovery | No LinkUp NIC, ambiguous NICs, or MAC mismatch |

---

## Level 3 — Full Boot E2E (destructive — reboots the server)

> **Warning**: This mounts an ISO and reboots the bare-metal server.
> Only run on a lab machine you can safely reboot.

### Prerequisites

- Everything from Level 2, plus:
- A working mirror with synced content (`aba -d mirror sync`)
- A valid `cluster.conf` with full networking details
- The ISO must be HTTP-servable from this host to the BMC (aba auto-derives the URL, or set `iso_url` in `bmc.conf`)

### Steps

```bash
# Full install — generates ISO, mounts via Redfish, boots, monitors install
aba -d bmc-test install
```

This runs the complete pipeline:

1. Preflight (L1–L5 + MAC discovery)
2. Agent ISO generation
3. HTTP server started for the ISO (auto-derived or explicit `iso_url`)
4. ISO mounted via Redfish VirtualMedia (InsertMedia)
5. One-shot boot override set to CD/DVD
6. Server reset (reboot)
7. Normal `monitor-install.sh` takes over
8. Post-install: boot override disabled + ISO ejected (`bmc-unmount.sh`)

#### Post-install verification

```bash
# Check the BMC state files (one per node)
cat bmc-test/.bmc-state.master0
# Expected: last_step=session-logout, script_version=1.2.0

# Check the stamp file was created
ls -la bmc-test/.bm-bmc-boot-done

# Verify cluster came up
aba -d bmc-test status
```

---

## Supported Vendor Adapters

| `bmc_type` value | Hardware | Notes |
|------------------|----------|-------|
| `irmc` | Fujitsu iRMC S5/S6 | Fully tested; uses generic DSP0266 (no L5 gate) |
| `idrac` | Dell iDRAC9 | Firmware ≥ 4.40.10.00 (Intel) / 6.00.00.00 (AMD); iDRAC10 not yet supported |
| `ilo` | HPE iLO 5/6 | iLO 4 hard-fails at preflight L5 |
| `supermicro` | Supermicro X12/X13 | Requires SFT-OOB-LIC or SFT-DCMS-SINGLE license |
| `lenovo` | Lenovo XCC | Requires Enterprise license; uses PATCH (not POST) for InsertMedia |
| `redfish` | Any DSP0266 BMC | Generic fallback; no vendor-specific L5 gate |

---

## Troubleshooting

See `Troubleshooting.md` → **Bare-metal BMC Automation** for the full
diagnostic reference (greppable `BMC:` message catalog, per-vendor
admin notes, and the MAC discovery error table).

---

## Known Limitations (this branch)

- **Makefile integration incomplete**: `bmc-boot.sh` documents a
  `.bm-bmc-boot-done` stamp target in `Makefile.cluster`, but that
  target is not yet wired in.  The boot orchestrator works when called
  by the install flow, and `bmc-unmount.sh` is already hooked into
  `monitor-install.sh`.
- **Version references**: Code comments and CHANGELOG entries reference
  "v1.1" / "v1.2" — these need updating to match ABA's current
  versioning before merging into `dev` (see TODO in `CHANGELOG.md`).
- **E2E suites need real hardware**: `suite-bmc-preflight.sh` and
  `suite-bmc-mac-discovery.sh` require a Fujitsu iRMC-bound pool node.
  Other vendor E2E suites are planned for a future release.
