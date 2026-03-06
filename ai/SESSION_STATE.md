# Session State

## Current goal
Implementing the "scripts-must-not-manage-markers" plan — removing redundant `.installed`/`.uninstalled` marker management from scripts and centralizing it in the Makefile.

## Done this session
- Removed `rm -f .installed` / `touch .uninstalled` from 5 uninstall scripts (reg-uninstall.sh, reg-uninstall-quay.sh, reg-uninstall-docker.sh, reg-uninstall-remote.sh, reg-unregister.sh)
- Removed `touch .installed` from reg-register.sh and reg-existing-create-pull-secret.sh
- Added marker management to Makefile `register`, `unregister`, and `pw` targets
- Added "scripts must never be called directly" rule to both rules-of-engagement.mdc and ai/RULES_OF_ENGAGEMENT.md
- Verified: zero scripts under `scripts/` still manage markers; all markers are in the Makefile

## Next steps
- User to approve commit and push
- Run `build/pre-commit-checks.sh` before committing
- Continue with gotest directive after commit

## Decisions / notes
- `unregister` target also needed markers added (the plan didn't explicitly mention it but it was a gap)
- `pw` target needed `@touch .installed` since the script no longer does it
- `uninstall-docker-registry` target already had markers — no change needed
