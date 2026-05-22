# Session State

## Current goal
TUI v2 — fix `_TUI_REG_VENDOR` to show configured intent ("auto") instead of resolved/installed value.

## Done this session
- Analyzed the flow: `reg-install.sh` resolves "auto"→"quay", writes resolved value to state.sh, `_state_override_mirror()` overrides `reg_vendor` in normalize-mirror-conf output, TUI reads that and shows "quay" instead of "auto".
- Determined the minimal fix: TUI reads `mirror.conf` directly (bypassing state override) for display purposes only. No changes needed to state.sh, scripts, or override logic.
- Showed the proposed change to user (awaiting approval).

## Next steps
1. Apply the TUI change to `tui/v2/tui-lib.sh` once user approves.
2. Test that TUI shows "Auto" when mirror.conf has `reg_vendor=auto`.

## Decisions / notes
- Scripts SHOULD use the resolved value (from state.sh override) — they need to dispatch to the correct vendor script (quay vs docker). Only the TUI display needs the raw config value.
- The fix is a single isolated change in `tui-lib.sh` lines 301-311.
