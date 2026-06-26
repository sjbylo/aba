# Dialog Spacing and Sizing — Test Findings

Date: 2026-06-26

## Background

The `dialog` utility is used throughout the ABA TUI. We investigated two questions:
1. How to get consistent spacing (blank line) between text and buttons?
2. Should we use auto-sizing (`0 0`) or fixed sizes, and when does each approach fail?

---

## Finding 1: Trailing `\n` is ignored, `\n ` works

`dialog` with auto-sizing (`0 0`) silently discards trailing `\n` when calculating
dialog height. This means adding `\n` at the end of text does NOT produce a blank
line before the buttons.

The workaround: use `\n ` (newline followed by a space character). The space makes
the line non-empty, so `dialog` counts it and renders a blank row before the buttons.

### Evidence

| Pattern               | Blank line before buttons? |
|-----------------------|---------------------------|
| `"text"`              | NO (short single-line gets auto-padding, but multiline does not) |
| `"text\n"`            | NO (trailing `\n` ignored) |
| `"text\n "`           | YES — consistent across all dialog types |
| `"\ntext\n "`         | YES — leading `\n` adds top padding, trailing `\n ` adds bottom |

### Leading `\n` behavior

The `dlg()` wrapper prepends `\n` to text for `--msgbox`, `--yesno`, `--inputbox`.
This creates a blank line between the title bar and the text content, which looks good.

However, prepending `\n` makes the text multiline, which means `dialog` no longer
auto-adds the default padding it gives to short single-line text. This is why
some short dialogs looked cramped after the wrapper was added — the wrapper removed
`dialog`'s built-in padding without replacing it.

### Dialog type applicability

| Dialog type       | Has buttons? | `\n ` useful? |
|-------------------|-------------|---------------|
| `--msgbox`        | Yes (OK)    | YES           |
| `--yesno`         | Yes (Yes/No)| YES           |
| `--inputbox`      | Yes (OK/Cancel) + input field | YES (spacing before input field) |
| `--passwordbox`   | Yes (OK/Cancel) + input field | YES |
| `--infobox`       | No          | NO — adds useless blank line at bottom |
| `--gauge`         | No          | NO            |
| `--menu/checklist/radiolist` | Has list items | NO — list spacing is separate |
| `--textbox`       | Yes (Exit)  | N/A — content from file, not text arg |

---

## Finding 2: Auto-sizing (`0 0`) is always correct for msgbox/yesno

Auto-sizing picks the minimum dialog dimensions that fit the content. It adapts to:
- Content width (URLs, ASCII art, long lines)
- Content height (many lines, bullet lists)
- Terminal size

### Fixed sizes fail in 4 ways

| Failure mode          | Example                  | Impact |
|-----------------------|--------------------------|--------|
| **Too narrow**        | URL wraps mid-word, ASCII art breaks | Ugly, unreadable |
| **Too short**         | Scrollbar appears (e.g., "44%") | User can't see full content |
| **Too tall**          | Large empty space below text | Looks unprofessional |
| **Mixed `0 N`** (auto height, fixed width) for msgbox | `--msgbox "text" 0 60` | **BROKEN** — content invisible, scrollbar at 0% |

### Head-to-head comparison results (msgbox/yesno)

**Short text** ("Basket is already empty."):
- AUTO `0 0`: 6×28, perfect fit
- FIXED `8×35`: minor waste (1 extra blank row)
- FIXED `15×35`: ugly (8 empty rows)
- FIXED `8×20`: text wraps, title truncated

**Long text with URLs** (pull secret info):
- AUTO `0 0`: 12×69, URL fits perfectly
- FIXED `16×75`: fine but 4 wasted rows
- FIXED `16×50`: URL wraps mid-word ("downloa" / "ds#tool-pull-secret")
- FIXED `8×75`: **SCROLLBAR at 44%** — text cut off

**Tall text** (cluster name error, 8 content lines):
- AUTO `0 0`: 12×47, all bullets visible
- FIXED `16×55`: fine, 4 wasted rows
- FIXED `8×55`: **SCROLLBAR at 44%** — only 4 of 8 lines visible

**ASCII art** (splash screen):
- AUTO `0 0`: 16×69, art aligned, everything visible
- FIXED `19×75`: fine, 4 wasted rows
- FIXED `19×50`: **BROKEN** — art wraps, scrollbar at 93%
- FIXED `25×75`: ugly, 10 empty rows

---

## Finding 3: Inputbox `0 N` — fixed width has a cosmetic benefit

For `--inputbox`, the `0 N` pattern (auto height, fixed width) works correctly
(unlike `--msgbox` where it's broken). The fixed width controls the input field width.

### Inputbox comparison results

| Dialog | FIXED `0 60` | AUTO `0 0` | Verdict |
|--------|-------------|-----------|---------|
| "vCenter or ESXi hostname/IP:" | Wide input field, prompt on one line | Narrower field, prompt wraps to 2 lines | **FIXED looks better** — prompt fits one line, wider input field |
| "Username:" | Wide input field, lots of room | Narrower field, still fits `administrator@vsphere.local` | **FIXED looks better** — input field has comfortable width |
| "VM folder path (e.g. /Datacenter/vm):" | Prompt on one line, wide field | Prompt wraps to 2 lines | **FIXED looks better** — prompt stays on one line |
| "Registry port:" (`0 40`) | Moderate width | Narrower | **FIXED slightly better** — port field doesn't need to be tiny |
| "SSH username:" (`0 40`) | Moderate width | Narrower | Marginal — both are fine |

**Key insight**: For `--inputbox`, the fixed width serves a real purpose:
1. Keeps longer prompts (with examples) on a single line
2. Makes the input field wider, easier to see/edit long values (hostnames, paths, URIs)
3. The `0 N` pattern works correctly for inputbox (unlike msgbox)

### Passwordbox comparison

| Dialog | FIXED `0 70` | AUTO `0 0` |
|--------|-------------|-----------|
| "Enter registry password:" | Wide input field | Very narrow field |

**FIXED wins** — password fields benefit from width since the masked input is hard
to judge in a narrow field.

---

## Finding 4: Msgbox/yesno with both dims fixed

| Dialog | Fixed size | AUTO `0 0` | Verdict |
|--------|-----------|-----------|---------|
| "ISC file not yet generated." | `6 40`: text fits one line, one blank row | `0 0`: text wraps to 2 lines ("not yet" / "generated."), compact | **FIXED slightly better** — text stays on one line |
| ISC regenerate confirm | `11 60`: text fits with spacing | `0 0`: similar but 1 row tighter | **AUTO is fine** — both look good |
| Resume summary | `14 50`: text with 2 extra blank rows | `0 0`: snug fit | **AUTO better** — no wasted space |

---

## Finding 5: Infobox fixed sizes — clear winner for short spinners

| Dialog | Fixed size | AUTO `0 0` | Verdict |
|--------|-----------|-----------|---------|
| "Please wait..." | `3 25`: compact, single-line | `0 0`: wraps to 2 lines ("Please" / "wait..."), extra blank line | **FIXED wins** — compact spinner |
| "Checking mirror..." | `3 30`: compact, single-line | `0 0`: wraps to 2 lines ("Checking" / "mirror...") | **FIXED wins** — compact spinner |
| "Regenerating..." | `3 20`: compact, single-line | `0 0`: single-line but adds blank line | **FIXED wins** — tighter |
| "Detecting installation status: sno1, compact1..." | `5 55`: fits on one line with padding | `0 0`: wraps to 3 lines | **FIXED wins** — readable |

**Key insight**: For short transient `--infobox` spinners, fixed sizes are genuinely
better. Auto-sizing makes them too narrow, causing ugly word wrapping. These are
the one case where fixed sizes should be kept.

---

## Complete Audit: All Fixed-Size Dialogs in TUI v2

### Category 1: `--inputbox` with `0 N` (KEEP fixed width)

These all use auto height (`0`) with fixed width. The fixed width ensures prompt
text stays on one line and the input field is wide enough for long values.

| File | Line | Prompt | Size | Recommendation |
|------|------|--------|------|----------------|
| tui-cluster.sh | 366 | vCenter or ESXi hostname/IP | `0 60` | Keep |
| tui-cluster.sh | 383 | Username | `0 60` | Keep |
| tui-cluster.sh | 396 | Datastore name | `0 60` | Keep |
| tui-cluster.sh | 404 | Network (port group name) | `0 60` | Keep |
| tui-cluster.sh | 412 | Datacenter name | `0 60` | Keep |
| tui-cluster.sh | 420 | Cluster name | `0 60` | Keep |
| tui-cluster.sh | 428 | VM folder path | `0 60` | Keep |
| tui-cluster.sh | 527 | Libvirt connection URI | `0 70` | Keep |
| tui-cluster.sh | 535 | Storage pool path | `0 60` | Keep |
| tui-cluster.sh | 543 | Bridge name | `0 60` | Keep |
| tui-cluster.sh | 551 | Boot firmware/order | `0 60` | Keep |
| tui-cluster.sh | 559 | Graphics args | `0 70` | Keep |
| tui-cluster.sh | 1387 | Path to SSH private key | `0 60` | Keep |
| tui-mirror.sh | 217 | Remote registry hostname | `0 60` | Keep |
| tui-mirror.sh | 219 | Registry hostname | `0 60` | Keep |
| tui-mirror.sh | 233 | Registry port | `0 40` | Keep |
| tui-mirror.sh | 245 | Registry username | `0 40` | Keep |
| tui-mirror.sh | 261 | Image path | `0 60` | Keep |
| tui-mirror.sh | 287 | Data directory on remote host | `0 60` | Keep |
| tui-mirror.sh | 289 | Data directory (absolute path) | `0 60` | Keep |
| tui-mirror.sh | 306 | SSH username | `0 40` | Keep |
| tui-mirror.sh | 317 | SSH private key path | `0 60` | Keep |

**Total: 22 inputboxes with fixed width — all should KEEP their fixed width.**

### Category 2: `--passwordbox` with `0 N` (KEEP fixed width)

| File | Line | Prompt | Size | Recommendation |
|------|------|--------|------|----------------|
| tui-lib.sh | 407 | Password prompt | `0 70` | Keep |

### Category 3: `--infobox` with fixed sizes (KEEP fixed sizes)

| File | Line | Text | Size | Recommendation |
|------|------|------|------|----------------|
| abatui2.sh | 498 | "Please wait..." | `3 25` | Keep |
| abatui2.sh | 532 | "Checking mirror..." | `3 30` | Keep |
| tui-disco.sh | 154 | "Checking mirror..." | `3 30` | Keep |
| tui-mirror.sh | 842 | "Regenerating..." | `3 20` | Keep |
| tui-lib.sh | 889 | "Detecting installation status: ..." | `5 55` | Keep |

**Total: 5 infoboxes — all should KEEP their fixed sizes.**

### Category 4: `--msgbox` with fixed sizes (SWITCH to `0 0`)

| File | Line | Text | Size | Why switch |
|------|------|------|------|-----------|
| tui-mirror.sh | 474 | "ISC file not yet generated." | `6 40` | Auto-sizing is safe; `6 40` wastes 1 row. Minor. |
| tui-mirror.sh | 1350 | "ISC file not yet generated." | `6 40` | Same dialog, duplicate |

**Total: 2 msgboxes (1 unique) — switch to `0 0`.**

### Category 5: `--yesno` with fixed sizes (SWITCH to `0 0`)

| File | Line | Text | Size | Why switch |
|------|------|------|------|-----------|
| tui-mirror.sh | 835 | ISC regenerate confirm | `11 60` | Auto-sizing produces same result |
| tui-direct.sh | 73 | Resume summary | `14 50` | Auto-sizing is tighter, looks better |

**Total: 2 yesno dialogs — switch to `0 0`.**

---

## Summary: What to Change

| Action | Count | Details |
|--------|-------|---------|
| **Keep as-is** | 28 | 22 inputboxes (`0 N`), 1 passwordbox (`0 70`), 5 infoboxes (fixed) |
| **Switch to `0 0`** | 4 | 2 msgboxes (`6 40`), 2 yesno dialogs (`11 60`, `14 50`) |
| **Implement `\n ` wrapper** | 1 | Affects all msgbox/yesno/inputbox/passwordbox via `dlg()` |

---

## The `0 N` Pattern: When It Works and When It Doesn't

| Dialog type | `0 N` behavior | Safe to use? |
|------------|----------------|-------------|
| `--inputbox` | Works correctly — auto height, fixed width for input field | YES |
| `--passwordbox` | Works correctly — same as inputbox | YES |
| `--msgbox` | **BROKEN** — content invisible, scrollbar at 0% | NO |
| `--yesno` | Untested but risky given msgbox behavior | Avoid |
| `--infobox` | Works but pointless (no buttons) | Use full fixed (`N M`) instead |

---

## Recommended `dlg()` Wrapper Logic

For `--msgbox`, `--yesno`, `--inputbox`, and `--passwordbox`:
1. Prepend `\n` (already done — leading blank line)
2. Append `\n ` if text doesn't already end with `\n ` (trailing blank line before buttons)

Skip for: `--infobox`, `--gauge`, `--menu`, `--checklist`, `--radiolist`, `--textbox`,
`--editbox`, `--mixedform`.
