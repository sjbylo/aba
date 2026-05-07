# OCP 5 Research & Analysis

Reference material for the OCP Major Version Support plan.
Moved here to keep the action plan concise. See `~/.cursor/plans/ocp_major_version_support_f53f7762.plan.md` for the work items.

---

## Timeline (from Red Hat SME call, Apr 2026 -- INTERNAL ONLY)

```
4.22 (GA) → 5.0 (GA Oct 2026) → 4.23 (post-5.0, EUS, no new features) → 5.1 → 5.2 (first ELC, Jun/Jul 2027) → 5.3 (RHEL 10 only)
```

- Direct upgrade paths: **4.22→5.0** and **4.23→5.1** only (not any 4.x→5.0)
- No API removals in 5.0; deprecations start 5.2, removals in 6.0
- EUS renamed to ELC (Extended Life Cycle) -- 5-year support (12mo full + 12mo maintenance + 36mo ELC)
- First ELC release: 5.2
- 4.22 operators forward-qualified for 5.0 (`:v5.0` catalog tags may not exist at GA)
- New 5.0 installs: RHEL 10 only; upgrades from 4.22/4.23 can stay RHEL 9 until 5.2 ELC ends
- N+3 kubelet-to-control-plane skew enables 4.22→5.2 with single worker reboot

---

## Verified Infrastructure (Apr 2026)

### CDN (`mirror.openshift.com`)

| Path | Status |
|------|--------|
| `openshift-v4/` | Live (GA) |
| `openshift-v5/` | Pre-staged, currently mirrors v4 content only |
| RC paths (e.g., `4.10.0-rc.0/`) | Under main `ocp/` (same as GA) |
| EC paths | Under `ocp-dev-preview/` |

### Cincinnati API

- Same endpoint, same `?channel=` format for v5
- `stable`/`fast` channels are scoped to one major.minor (no cross-major mixing)
- `candidate` channels can mix majors (e.g., `candidate-5.0` has both `4.22.x` and `5.0.x` -- upgrade graph)
- ABA's version picker queries `stable`/`fast` → one minor line per query → no sorting issues

### Container registries

| Path | Status |
|------|--------|
| `quay.io/openshift-release-dev/ocp-release` | Has `5.0.0-ec.0` tags |
| `quay.io/openshift-release-dev/ocp-v5.0-art-dev` | Does not exist yet |
| `registry.redhat.io/redhat/*-operator-index:v5` | No tags yet |

---

## RC Version Test Results (registry4, Apr 2026)

Tested `4.22.0-rc.1`. Decision: **DEFERRED** (low value, moderate risk).

| Component | Result | Why |
|-----------|--------|-----|
| `normalize-aba-conf` | WORKS | Preserves version string |
| `reg-create-imageset-config.sh` | WORKS | Uses `cut -d. -f1-2` → `4.22` |
| `day2-config-ntp.sh`, `check-version-mismatch.sh` | WORKS | Use `cut` |
| oc-mirror imageset | WORKS | Passes through verbatim |
| CLI `--version` entry | BLOCKED | Regex rejects `-rc.1` |
| 6x `${var%.*}` locations | WRONG | `4.22.0-rc` instead of `4.22` |
| `cut -d. -f3` + arithmetic | WRONG | `0-rc` → silently evaluates as `-1` |
| Catalog downloads | BROKEN | Look for `:v4.22.0-rc` (doesn't exist) |

If revived: (a) relax 1 CLI regex, (b) replace 6 `${var%.*}` with `cut -d. -f1-2`, (c) strip `-suffix` before `cut -d. -f3`.

---

## What's Already Version-Agnostic

- `verify-aba-conf` regex: accepts any major
- `is_version_greater()`: `sort -V` works for GA
- `_prev_minor()`: generic arithmetic
- `_is_ga_version()`, `_is_prerelease()`: generic patterns
- Channel construction: `${ocp_channel}-${ocp_ver_major}` already templated
- Cincinnati API endpoint: same URL for v4 and v5
- Operator catalog tags: templated as `:v${ocp_ver_major}`

---

## Detailed RC Analysis (deferred items, kept for reference)

### Regex locations (6)
- `scripts/aba.sh:383,389,1317`
- `scripts/include_all.sh:1190,367`
- `tui/abatui.sh:1129`

### `${var%.*}` locations (6) that break with RC
- `scripts/aba.sh` (`ver_short`)
- `scripts/download-catalogs-start.sh`, `download-catalogs-wait.sh`, `download-and-wait-catalogs.sh` (`ocp_ver_short`)
- `scripts/prefetch-catalogs.sh` (`version_short`)

### `cut -d. -f1-2` locations (5) that work with RC
- `scripts/include_all.sh`, `reg-create-imageset-config.sh`, `day2-config-ntp.sh`
- `scripts/check-version-mismatch.sh`, `add-operators-to-imageset.sh`

### Butane FCC `version: 4.12.0`
This is the Butane OpenShift variant spec version, NOT the OCP version. Spec versions are backward-compatible. `4.12.0` works on any OCP 4.12+ cluster. ABA only uses basic `storage.files`. Risk for OCP 5: unknown -- keep pin, add comment, revisit when Butane publishes a 5.x spec.

### sort -V with pre-release
`sort -V` puts `4.22.0-rc.0` ABOVE `4.22.0` (wrong per SemVer). Not a problem today since RC is deferred.

### 4.23 after 5.0: NOT complicated
ABA sorts within each major separately. `sort -V` correctly orders within a major. User picks a version. No cross-major comparison needed.
