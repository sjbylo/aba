# TUI recording

These three scripts record the ABA TUI and turn the frames into a GIF. They are not part of the test suite. The automated tests stay in `test/func/`.

| Script | What it does |
|---|---|
| `tools/tui-record.sh` | Start a session, stop it, or build a GIF |
| `tools/tui-capture.sh` | Poll the tmux pane. `drive` copies this onto the host |
| `tools/tui-gif.py` | Draw the color frames into a GIF |

## Drive it yourself

```bash
tools/tui-record.sh drive
tools/tui-record.sh drive disco
tools/tui-record.sh stop
```

`drive` with no host uses `conno`. A short name is enough: `disco`, `conno`. `TUI_TEST_HOST=disco` is the same switch. `local` records on this machine.

The TUI starts in tmux session `tui-drive` at 100×30. Attach from another terminal:

```bash
ssh -t conno tmux attach -t tui-drive
ssh -t disco tmux attach -t tui-drive
```

`stop` ends the recording and leaves the TUI running. Closing the TUI also ends it.

While you drive, frames are written on that host under `/tmp/tui-drive/<stamp>/color/`. They are copied back here when `drive` returns. The local directory stays empty until then. `/tmp/tui-drive-current` holds the host and the remote path.

`TUI_WIDTH` and `TUI_HEIGHT` change the pane. `TUI_CAPTURE_INTERVAL` is the poll period (default `0.5`). A blank pane is dropped. A cursor move is kept.

## Make a GIF

```bash
tools/tui-record.sh gif
tools/tui-record.sh gif /tmp/tui-drive/20261119-181759 aba-mirror-sync.gif
tools/tui-record.sh gif /tmp/tui-drive/20261119-181759 aba-mirror-sync.gif 900
tools/tui-record.sh gif /tmp/tui-drive/20261119-181759 900
```

With no directory, `gif` uses the newest `/tmp/tui-drive` or `/tmp/tui-test` run that has color frames.

The last argument is the maximum width in pixels. Leave it off and the GIF is drawn at 28px, about 1712×1232 for a 100×30 pane. `900` is the README column. The font size is a whole number, so 900 comes out a little under 900 pixels wide and the page can show it at that size.

A frame that matches the previous one holds for 0.5 seconds. A new dialog holds for at least 1 second, longer when there is more text. The GIF ends on a black frame held for 3 seconds.

`tools/tui-gif.py RUN_DIR OUT.gif [WIDTH]` is the same step without the wrapper.

## Record a test instead

```bash
tools/tui-record.sh mirror
tools/tui-record.sh cluster disco
tools/tui-record.sh day2
```

These run `test/func/test-tui-mirror.sh`, `test-tui-cluster.sh`, or `test-tui-day2.sh`. The cluster name defaults to `compact`. Frames land in `/tmp/tui-test/`.
