Hardening, stability and bug fixes

### Improvements

- **OSUS install hardened** — `aba day2-osus` now retries on timeout and cleans up stuck subscriptions.
- **Graceful shutdown resilience** — `aba shutdown` no longer aborts if debug pod warmup fails; falls back to SSH instead. Increased timeouts for slow environments.
- **Updated `operator-set-ai`** — Replaced `serverless-operator` with `gpu-operator-certified` (NVIDIA GPU Operator) and `nfd`. Updated mesh to v3. Added `rhcl-operator` (Connectivity Link).
- **Renamed `operator-set-ocpv` → `operator-set-virt`** — If you reference `ocpv` in scripts, update to `virt`.

### Bug fixes

- Fixed false `oc-mirror` failure caused by stale error files left from a previous save/load/sync operation.

Full changelog: [CHANGELOG.md](https://github.com/sjbylo/aba/blob/main/CHANGELOG.md)
