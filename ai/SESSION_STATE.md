# Session State

## Current goal
Password special-char testing for Quay mirror install.

## Done this session
- Tested 6 passwords with various special characters against `aba install` (Quay mirror-registry).
- Identified 4 dangerous characters that break the install: backtick, double-quote, single-quote, dollar-sign.
- Root cause: `mirror-registry` (Red Hat tool) passes password through multiple unescaped quoting layers (shell → podman → bash -c → ansible -e).
- Confirmed safe chars: `!@#%^&*()<>|;\`
- Restored mirror.conf to working password `!@#$%^&*()`.
- Applied TUI fix (earlier): `_TUI_REG_VENDOR` reads mirror.conf directly instead of via normalize-mirror-conf.

## Next steps
1. Decide whether to add input validation for dangerous password chars in ABA (reject `` ` `` `"` `'` `$` with a clear error).
2. Consider filing a bug against `mirror-registry` upstream.
3. Commit pending TUI changes if approved.

## Decisions / notes
- Dangerous password chars: `` ` `` (backtick), `"` (double-quote), `'` (single-quote), `$` (dollar sign)
- `$` is the most insidious — install succeeds but auth silently fails (password mangled by variable expansion)
- This is upstream `mirror-registry` bug, not ABA's fault, but ABA should validate early to protect users
- `\` alone seems safe, but interacts badly with `$` (e.g. `\$` becomes literal `$` after one layer of expansion)
