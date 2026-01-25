# TUI Button Standards

**Date**: January 2026  
**Status**: Standardized button labels and order

## Standard Button Order

All dialogs follow this consistent order (left to right):

```
< Select >  < Next >  < Back >  < Help >
```

**Rationale**: Forward navigation (Next) comes before backward (Back) to encourage forward progress.

Or for yes/no dialogs:
```
< Yes >  < No >  < Back >  < Help >
```

## Standard Button Labels

### Navigation
- **`Select`** - Choose an item from menu
- **`Next`** - Move forward in workflow
- **`Back`** - Return to previous screen
- **`Exit`** - Close TUI

### Actions
- **`Execute`** - Run a command
- **`Continue`** - Proceed with current state
- **`Accept`** - Confirm selection (rare - prefer `Next`)

### Yes/No
- **`Yes`** / **`No`** - Binary choices
- **`Continue Anyway`** - Override warning
- **`Cancel`** - Abort action

### ❌ NEVER Use
- ~~`Accept & Next`~~ - Too long
- ~~`Accept & Next>`~~ - Has extra character
- ~~Long descriptive text~~ - Keep labels short

## Dialog Types

### 1. Menu Dialogs (most common)
```bash
dialog --title "Title" \
    --cancel-button --cancel-label "Back" \
    --help-button \
    --ok-label "Select" \
    --extra-button --extra-label "Next" \
    --menu "..." 0 0 5 \  # Last number = menu items count
```

**Button mapping**:
- OK (Enter) = "Select" (chooses menu item)
- Extra = "Next" (moves forward)
- Cancel (ESC) = "Back" (goes back)
- Help (F1) = "Help"

**Menu height**: Use **actual count of menu items**, not a larger number!
- 3 items → `0 0 3`
- 5 items → `0 0 5`
- NOT `0 0 8` for 5 items (wastes space)

### 2. Simple Navigation
```bash
dialog --title "Title" \
    --extra-button --extra-label "Back" \
    --help-button \
    --ok-label "Next" \
    --msgbox "..." ...
```

**Button mapping**:
- OK (Enter) = "Next"
- Extra = "Back"
- Help (F1) = "Help"

### 3. Yes/No Dialogs
```bash
dialog --title "Title" \
    --extra-button --extra-label "Back" \
    --yes-label "Execute" \
    --no-label "Cancel" \
    --yesno "..." ...
```

**Button mapping**:
- Yes = Positive action
- No = Negative/cancel
- Extra = "Back"

## Visual Consistency

### ✅ Good (even width, forward first)
```
< Select >  < Next >  < Back >  < Help >
```

### ❌ Bad (uneven width)
```
< Select >  < Next >  <Accept & Next>  < Help >
```

### ❌ Bad (backward first - discourages progress)
```
< Select >  < Back >  < Next >  < Help >
```

## Button Label Guidelines

1. **Short** - 1-2 words maximum
2. **Clear** - Action obvious from context
3. **Consistent** - Same labels mean same actions
4. **Even width** - Similar character counts

## Common Patterns

### Wizard Flow
```
Screen 1: < Select >  < Next >  < Help >
Screen 2: < Select >  < Next >  < Back >  < Help >
Screen 3: < Select >  < Next >  < Back >  < Help >
Final:    < Execute >  < Back >  < Exit >  < Help >
```

### Selection with Basket
```
Main:     < Select >  < Next >  < Back >  < Help >
Search:   < Select >  < Done >  < Back >  < Help >
Basket:   < Edit >  < Clear >  < Back >  < Help >
```

## Implementation Notes

### dialog(1) Button Order
Dialog shows buttons in this order by default:
1. `--yes-label` / `--ok-label` (leftmost)
2. `--extra-button --extra-label`
3. `--cancel-button --cancel-label`
4. `--help-button` (rightmost)

**To get `< Select > < Next > < Back > < Help >` order:**
- OK button = "Select"
- Extra button = "Next"
- Cancel button = "Back"
- Help button = "Help"

### Return Codes
- 0 = OK/Yes button pressed
- 3 = Extra button pressed
- 1 = Cancel/No button pressed
- 2 = Help button pressed
- 255 = ESC pressed

**Example mapping for menus:**
- 0 = "Select" (chose menu item, act on it)
- 3 = "Next" (move forward without selecting)
- 1 = "Back" (go to previous screen)
- 2 = "Help" (show help)
- 255 = ESC (treat as Back)

### Code Pattern
```bash
dialog ... 2>$TMP
rc=$?
case $rc in
    0) # OK/Yes button
        ;;
    1) # Cancel/No button
        ;;
    3) # Extra button (usually "Back")
        ;;
    2) # Help button
        ;;
    255) # ESC pressed
        ;;
esac
```

## Violations Fixed (Jan 2026)

1. **Platform & Network dialog**:
   - Was: `"Accept & Next>"` (too long, had `>`)
   - Now: `"Next"`

2. **Operators dialog**:
   - Was: `"Accept & Next"` (too long)
   - Was: Menu height 8 for 5 items (too tall)
   - Now: `"Next"`, menu height 5

3. **Button order**:
   - Was: `< Select > < Back > < Next >` (backward first)
   - Now: `< Select > < Next > < Back >` (forward first) ✅

4. **Menu heights**:
   - Fixed all menus to use actual item count
   - Operators: 8 → 5
   - Reduces wasted vertical space

## Testing Checklist

When adding new dialogs:
- [ ] Buttons are short (1-2 words)
- [ ] Button order matches standard
- [ ] Button widths are similar
- [ ] Navigation flow makes sense
- [ ] Help button included where appropriate
- [ ] ESC key handled gracefully

## Development Best Practices

### Always Check Syntax Before Committing

**CRITICAL**: Bash syntax errors will cause the TUI to fail on startup!

```bash
# Always run before committing/syncing:
bash -n tui/abatui_experimental.sh && echo "Syntax OK"
```

**Common mistakes**:
- Duplicate closing braces `}}`
- Missing closing braces in functions
- Unclosed quotes in dialog strings
- Missing `fi`, `done`, `esac` keywords

### Critical Dialog Flags

**Wrong**: Using non-existent flags
```bash
# This causes "Unknown option" error and immediate exit:
dialog --cancel-button --cancel-label "Back" ...  # WRONG! No --cancel-button flag
```

**Right**: Using only label flags
```bash
dialog --cancel-label "Back" ...  # CORRECT
```

**Note**: `--cancel-button` does NOT exist in `dialog`. Only use `--cancel-label`.

### Error Handling with set -e

Bash's `set -e` treats non-zero exit codes as fatal errors. Dialog returns non-zero for user actions (Cancel=1, Extra=3).

**Wrong**: Dialog exits script on Cancel
```bash
set -e
dialog --yesno "Continue?" 0 0  # Script exits if user clicks No!
```

**Right**: Wrap dialog calls with set +e
```bash
set +e
dialog --yesno "Continue?" 0 0
rc=$?
set -e
case $rc in
    0) # Yes
        ;;
    1) # No
        ;;
esac
```

### Color Codes in Dialog

**Wrong**: Using markdown-style color codes
```bash
dialog --colors --msgbox "[red]ERROR[/red]" 0 0  # Shows literal text
```

**Right**: Using dialog's \Z codes
```bash
dialog --colors --msgbox "\Z1ERROR\Zn" 0 0  # Shows red text
```

**Dialog color codes**:
- `\Z0` = Black
- `\Z1` = Red
- `\Z2` = Green
- `\Z3` = Yellow
- `\Z4` = Blue
- `\Z5` = Magenta
- `\Z6` = Cyan
- `\Z7` = White
- `\Zn` = Normal (reset)
- `\Zb` = Bold
- `\ZB` = Reverse

### Preserving Whitespace in Dialog

When displaying formatted text (like two-column layouts):

```bash
dialog --no-collapse --msgbox "
Required sites:                    Other sites:
  mirror.openshift.com               docker.io
  api.openshift.com                  docker.com
" 0 0
```

The `--no-collapse` flag preserves leading spaces and prevents dialog from collapsing multiple spaces into one.

### Using run_once for Connectivity Checks

**Wrong**: Slow commands in connectivity checks
```bash
# oc-mirror download is too slow (minutes)!
if ! run_once -w -i check:oc-mirror -- make -sC cli oc-mirror; then
    echo "No internet"
fi
```

**Right**: Fast checks, useful work
```bash
# Quick API call (seconds), pre-caches needed data
if ! run_once -w -i ocp:stable:latest_version -- bash -lc 'fetch_latest_version stable'; then
    echo "No internet"
fi

# Or simple HEAD request with -f flag
if ! curl -sf --head https://mirror.openshift.com >/dev/null 2>&1; then
    echo "No internet"
fi
```

**Rule**: Connectivity checks must complete in seconds, not minutes. If a real command takes too long, use a dummy check instead.

### curl Best Practices for Connectivity Checks

**Always use the `-f` (--fail) flag** when checking connectivity:

```bash
# WRONG: Returns exit code 0 even if server returns 404, 500, etc
curl -s --head https://api.openshift.com

# RIGHT: Returns non-zero exit code for HTTP errors (4xx, 5xx)
curl -sf --head https://api.openshift.com
```

**Why `-f` matters:**
- Without `-f`: curl exits 0 if it successfully connects, regardless of HTTP status
- With `-f`: curl exits non-zero for HTTP errors (404, 500, 503, etc)
- Critical for accurate connectivity/health checks

**Typical connectivity check pattern:**
```bash
curl -sf --head --connect-timeout 5 --max-time 10 https://site.com >/dev/null 2>&1
```
- `-s` = silent (no progress bar)
- `-f` = fail on HTTP errors
- `--head` = HEAD request only (faster)
- `--connect-timeout 5` = 5 seconds to connect
- `--max-time 10` = 10 seconds total timeout
- `>/dev/null 2>&1` = suppress all output

---

**Last Updated**: January 17, 2026  
**Location**: `tui/abatui_experimental.sh`

