# ADR-005: normalize*() outputs config values only

## Status
Accepted

## Context
The normalize-*-conf functions (normalize-aba-conf, normalize-mirror-conf, etc.)
read config files and emit shell variable assignments. Some callers need derived
values like regcreds_dir (a path computed from other config values). Should
normalize functions compute and emit these?

## Decision
No. normalize*() outputs ONLY values that exist in config files, with defaults
for missing values. Derived/computed values (e.g. regcreds_dir, full registry
URL) belong in the calling script, computed after sourcing normalize output.

## Consequences
- normalize functions stay simple and predictable -- pure config -> defaults
- Callers are explicit about what they derive and why
- Avoids hidden coupling: if normalize emitted derived values like regcreds_dir,
  then changing how regcreds_dir is computed would silently affect every script
  that sources normalize output -- even scripts that never use regcreds_dir.
  You couldn't grep for "who depends on this formula?" because it's injected
  into everyone's environment. With the current rule, only the 3-4 scripts that
  actually need regcreds_dir compute it themselves. If the formula changes, you
  update those specific callers. The blast radius is visible and grep-able.
- Requires callers to do a bit more work after sourcing

## Clarification (2026-11-05)

Status stays Accepted. This does not allow normalize to emit derived names.

Three tools, three jobs:

- `fetch_value KEY FILE` reads one raw value. It does not coerce, default, or abort. A missing required key is the caller's abort (for example `verify-cluster-conf` when `num_masters` is missing).
- `normalize-*-conf` may sanitize, coerce the same key (`ask=0` / `ask=false` / `ask=1`, lowercased `domain`), and default that same key (`verify_conf=all`). It may not emit a new name and it may not apply a formula.
- Named helpers own formulas. Grep the helper. Do not rely on comments that list "vars used from normalize".

Helpers in use: `ocp_major_of`, `apply_cidr_split`, `cluster_type` / `is_sno`, `ask_is_on` (`-y` / `ASK_OVERRIDE` is not applied inside normalize). `resolved_reg_vendor` and `image_source_is_mirror` were already this shape.

`_state_override_cluster` may still replay a stored `prefix_length` from installed state (ADR-007). That is state, not a formula computed from the conf file.
