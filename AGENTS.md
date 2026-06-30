# AGENTS.md

Project context for AI coding agents (Cursor, Copilot, Codex, Claude Code, etc.).
For the full system spec, read `devel/01-SPEC.md`.

## What ABA is

ABA installs OpenShift clusters in connected, partially
disconnected, and fully air-gapped environments using a mirror registry workflow.
It is a bash project (~100 scripts) orchestrated by Make and a CLI wrapper.

## Build and test

```bash
# Install ABA (connected host)
./install && aba

# Run functional tests
test/func/run-all-tests.sh

# Run pre-commit checks before committing
build/pre-commit-checks.sh

# Pre-commit for docs-only changes
build/pre-commit-checks.sh --skip-version
```

## Architecture (quick reference)

- **Entry points**: `aba` CLI (`scripts/aba.sh`), `make -C <dir> <target>`, TUI (`tui/v2/abatui2.sh`)
- **Config as truth**: `aba.conf`, `mirror.conf`, `cluster.conf` -- CLI flags write to config, scripts read from config
- **Key abstractions**: `run_once()` (task dedup), `normalize*()` (config defaults), `ensure_*()` (tool install), marker files (lifecycle state)
- **State**: `~/.aba/` (external state), marker files (in-tree state), `~/.aba/runner/` (run_once only)

Read `devel/01-SPEC.md` for the full architecture. Read `devel/adr/` for design decisions.

## Key invariants

1. Scripts under `scripts/` are called only via Make targets or `aba` CLI -- never directly
2. Makefiles own marker files (.init, .available, etc.) -- scripts must not create/remove them
3. After `mirror load` or `mirror sync` on a running cluster, run `aba day2`
4. `$ABA_ROOT` is only for `aba.sh` and `abatui2.sh` -- all other scripts use relative paths
5. `normalize*()` outputs only config values/defaults -- never derived/computed values
6. `aba bundle --out -` keeps stdout as pure tar -- all messages to stderr

## Files the agent must not modify without permission

- Everything under `dev/` and `AGENTS.md` (human review required -- see `.cursor/rules/dev-review.mdc`)
- `scripts/`, `tui/`, `templates/`, `cli/`, Makefiles -- all require explicit permission
- Freely modifiable: `test/func/*`, `test/e2e/*`, `ai/*`

## Coding conventions

- **Tabs** for indentation, never spaces
- Empty lines must be truly empty (no trailing whitespace)
- **Never** use `(( var++ ))` -- use `var=$(( var + 1 ))` (crashes under `set -e` when var is 0)
- `aba_debug` for debug logging (stderr only, never stdout)
- `[ABA]` prefix only on operational messages, not banners
- Prefer `if ! cmd; then` over disabling `set -e` / ERR traps
- Comments explain **WHY**, not what
- **Never** commit or push without explicit user permission

## Git workflow

- Work on `dev` branch
- Run `build/pre-commit-checks.sh` before committing code changes
