# Functional Tests

Unit and integration tests that run on bastion. No VMs or clusters required.

## Running all tests

```bash
cd ~/aba
for t in test/func/test-*.sh; do bash "$t" || echo "FAILED: $t"; done
```

## TUI tests

The TUI test suite drives the ncurses dialog-based TUI (`abatui`) via tmux,
sending keystrokes and asserting on screen content. All non-destructive tests
cancel operations before executing — they only inspect menus, dialogs, and
navigation flows.

### Quick reference

```bash
# Run the full non-destructive suite (~12 min, 359 assertions)
bash test/func/test-tui-all.sh --quick

# Run a single test
bash test/func/test-tui-smoke.sh

# Watch live from another terminal
TMUX= tmux attach -t tui-test -r
```

The `-r` flag attaches read-only. Prefix with `TMUX=` if already inside tmux.

### Test inventory

The master runner (`test-tui-all.sh --quick`) executes these in order:

| # | Test | Assertions | What it covers |
|---|------|-----------|----------------|
| 1 | `test-tui-smoke.sh` | ~61 | Splash, main menu items, help, settings, advanced, day-2 menus, clean exit |
| 2 | `test-tui-help.sh` | ~61 | Help text consistency: every menu item mentioned in its help, navigation docs |
| 3 | `test-tui-nav.sh` | ~15 | Dynamic menu discovery, submenu entry/exit, arrow keys, button discovery |
| 4 | `test-tui-wizard.sh` | ~22 | Setup wizard pages: channel, version, platform, operators (cancel at end) |
| 5 | `test-tui-operators.sh` | ~49 | Operator workflows: sets, search, view/edit, clear, additional images, toggles |
| 6 | `test-tui-mirror-config.sh` | ~43 | Mirror config form fields, VMware config, platform selection, advanced menu |
| 7 | `test-tui-payload-deep.sh` | ~30 | Prepare upgrade picker, version/channel change, settings cycling, bundle/save/sync |
| 8 | `test-tui-cluster-pages.sh` | ~4 | Cluster wizard entry (skips gracefully if no mirror installed in CONNO mode) |
| 9 | `test-tui-day2-deep.sh` | ~35 | Day-2 status, OSUS warning, virt boot sources, upgrade picker, shutdown/delete |
| 10 | `test-tui-disco-smoke.sh` | ~39 | DISCO mode: bundle gate, menu, load dialog, ISC view (runs on disco host) |

Full mode (`test-tui-all.sh` without `--quick`) adds destructive tests that
require an installed mirror and cluster:

| # | Test | What it covers |
|---|------|----------------|
| 11 | `test-tui-mirror.sh` | Mirror install + sync (destructive) |
| 12 | `test-tui-cluster.sh` | Cluster wizard + install (destructive) |
| 13 | `test-tui-day2.sh` | OperatorHub, NTP, OSUS (destructive) |
| 14 | `test-tui-upgrade.sh` | Version selection + upgrade (destructive) |
| 15 | `test-tui-lifecycle.sh` | Shutdown, startup, clean, delete (destructive) |

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `TUI_TEST_HOST` | `conno.example.com` | Target host for tests |
| `TUI_CLUSTER_NAME` | `tuitest` | Cluster name for destructive tests |
| `TUI_SKIP_DELETE` | (unset) | Set to `1` to keep cluster after lifecycle test |

### Test library

All tests source `tui-test-lib.sh`, which provides:

- **`tui_start`** / **`tui_stop`** — launch/kill TUI in a tmux session
- **`tui_capture`** — capture current screen content
- **`tui_keys`** — send keystrokes (Enter, Escape, Tab, letters)
- **`tui_select_item "label"`** — find menu item by label, send its shortcut key
- **`tui_press_button "label"`** — navigate to and press a dialog button
- **`tui_assert_contains`** / **`tui_assert_appears`** — pattern-based assertions
- **`tui_back_to "pattern"`** — press Escape until a known screen appears
- **`tui_wait_isc_done`** — wait for ISC generation or dismiss error dialogs
- **`tui_clear_failed_tasks`** — clear stale `run_once` failures via `-F`

### When the TUI changes

Tests use pattern matching (`grep -qi "Day-2"`) and dynamic menu discovery
(`tui_find_key`), not hardcoded cursor positions. This makes them resilient
to layout changes, reordering, and new items.

If a test fails after a TUI change:

- **Renamed item** — update the pattern in the test (e.g. `"Day-2"` → `"Post-Install"`)
- **Removed item** — remove or skip the assertion
- **New dialog/gate** — add handling (e.g. dismiss with Enter, or press a button)
- **New menu item** — add assertions in the relevant test

A failing test after a TUI change is expected — it confirms the tests are
catching regressions. Run `bash test/func/test-tui-all.sh --quick` after
any TUI change to verify.

### AI-driven testing (hybrid mode)

The same helpers can be used interactively by an AI agent via the CLI wrapper:

```bash
CLI="bash test/func/tui-test-cli.sh"
$CLI tui_start                              # launch TUI
$CLI tui_capture                            # see the screen
$CLI tui_select_item "Day-2"                # navigate
$CLI tui_assert_contains "NTP" "Has NTP"    # assert
$CLI tui_stop                               # clean up
```

The AI reads `tui_capture` output, reasons about what's on screen, and adapts
— handling unexpected dialogs, changed labels, or new menus without script
updates. See `.cursor/skills/tui-test/SKILL.md` for the full guide.

Use scripted tests for CI regression. Use AI-driven testing for exploration,
verifying new features, and debugging TUI issues.

### Notes

- Tests adapt to host state: cluster-pages skips if no mirror is installed,
  day2-deep skips if no cluster exists, disco-smoke creates a temporary
  `.bundle` marker to force DISCO mode.
- Settings toggles (registry type, retry count, include/exclude) are restored
  to their original values after cycling.
- ISC generation can block the payload menu for minutes after settings changes.
  The test library handles this with `tui_wait_isc_done` and
  `tui_clear_failed_tasks`.

## Other notable tests

| Test | What it covers |
|------|---------------|
| `test-aba-wait-show.sh` | Spinner function: timeouts, signals, isolation |
| `test-run-once-*.sh` | Task runner: locking, races, TTL, validation |
| `test-e2e-framework.sh` | E2E test harness helpers |
| `test-mirror-save-workflow.sh` | Mirror save/load pipeline |
| `test-symlinks-exist.sh` | Cross-directory symlink integrity |
