# Session State

## Current goal
Designing "mirror --name" and existing-registry registration feature. Plan refined with enclave use case.

## Done this session
- Committed 127f6c3: notifications, force-deploy fix, cleanup prompts, VIP placeholder removal
- Committed 4264d4c: full CLI flag cleanup (17 files changed)
- Created and refined plan: `mirror_name_and_register_5ecd9095.plan.md`

## Scope of this chat
- **This chat**: coding, refactoring, new features ONLY
- **Separate chat**: E2E test monitoring, pool management

## Next steps
- Finalize and implement mirror --name + register feature
- Follow-up: rename .installed/.uninstalled to .available/.unavailable (separate commit)

## Decisions / notes
- Primary use case: oc-mirror v2 enclaves (multiple registries behind disconnected networks)
- REG_VENDOR=existing marks externally-managed registries in state.sh
- reg-uninstall-existing.sh: only cleans local creds, never touches external registry
- --pull-secret copies file as-is; interactive flow stays in 'aba mirror password'
- Both --pull-secret and --ca-cert -> touch .installed
- mirror/Makefile .init target is self-bootstrapping (symlinks via relative paths)
- aba mirror --name just needs: mkdir + cp Makefile + make init
