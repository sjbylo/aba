# E2E Pool Workflow: Desired vs Current

## Desired flow (from scratch)

1. **Clone from template to golden** – One golden VM (e.g. `aba-e2e-golden-rhel8`).
2. **Configure golden** – General config good for all VM types (e.g. `dnf update -y`, SSH, NTP, test user).
3. **Snapshot golden** – Reuse it (snapshot `golden-ready`).
4. **Clone all 3 con hosts** from golden and initiate config.
5. **Clone all 3 dis hosts** from golden and initiate config.
6. **Configure and verify all conN** – when done, snapshot each (e.g. `pool-ready`).
7. **Configure and verify all disN** – when done, snapshot each (e.g. `pool-ready`).

So: **batch by role** (all cons, then all dis), one clone per VM, then config+verify+snapshot in that order.

---

## Current flow

### When we use `--create-pools` (parallel or sequential)

- **create_pools** always runs with **`--skip-phase2`** so it never clones con/dis:
  - **Phase 0 only**: template to golden, full golden config, snapshot `golden-ready`.
  - Phase 1 and 2 are **skipped** (no clones in create_pools; **one clone per VM**, done only in clone-and-check).

- **clone-and-check** runs **once per pool** (3 times for 3 pools):
  - Each run: clone that pool's **conN + disN** from golden, full config + verify, create `pool-ready` on that conN and disN.

So we do **batch by pool**: for each pool we clone 2 VMs, configure 2, snapshot 2. We never do "clone all 3 con, then all 3 dis" or "configure all conN then all disN" in one place.

- **clone-and-check** runs once per pool (parallel or sequential), and is the **only** place that clones conN/disN and creates `pool-ready`.

---

## Gap summary

| Aspect | Desired | Current (--parallel) |
|--------|--------|----------------------|
| Clone order | All 3 con, then all 3 dis | Per pool: conN+disN together, N times |
| Config order | Configure all conN then snapshot; then all disN then snapshot | Per pool: configure conN+disN then snapshot, N times |
| Where clones happen | In one place (e.g. create_pools Phase 1) | In clone-and-check, once per pool |
| Where pool-ready is created | After config and verify all conN / all disN | In clone-and-check after each pool |

End state is the same (all conN/disN configured and with `pool-ready`), but the **batching and ordering** differ.

---

## Why we do not do the desired flow today

1. **`--skip-phase2`** was added so we do not clone twice: create_pools used to do Phase 1 (clone) + Phase 2 (config), and then clone-and-check destroyed and re-cloned the same VMs. So we turned off Phase 1 and 2 when running with `--parallel` and let clone-and-check be the only place that clones and configures.

2. **clone-and-check** is written as a **single-pool** suite: it takes `POOL_NUM`, does everything for one con + one dis, and creates `pool-ready` for that pair. The runner just runs it N times. There is no "batch all cons / batch all dis" mode in the suite.

3. **create_pools Phase 2** does a **lighter** config than clone-and-check (no SSH keys, firewall, NTP, test user, full verify, etc.) and does **not** create `pool-ready`, so it cannot replace clone-and-check for the dispatcher.

---

## What would close the gap

To match the desired flow in one place:

1. **create_pools** (without `--skip-phase2`):
   - Keep Phase 0 (golden + `golden-ready`).
   - Keep Phase 1a (clone all conN), Phase 1b (clone all disN).
   - **Phase 2a**: Configure and verify all conN (same steps as clone-and-check for con), then create `pool-ready` on each conN.
   - **Phase 2b**: Configure and verify all disN (same steps as clone-and-check for dis; each disN can wait for its conN dnsmasq), then create `pool-ready` on each disN.

2. **run.sh**: When `--create-pools` is used, do **not** pass `--skip-phase2`, and **skip** running the clone-and-check suite (pools are already created and have `pool-ready`). Then run pool suites as today.

One command from scratch would then be: create_pools (golden, clone all con, clone all dis, config+snapshot all con, config+snapshot all dis), then dispatch pool suites. No per-pool clone-and-check run.
