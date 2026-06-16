# Error Suppression Audit

Audit of places where we suppress stderr/stdout and whether that's appropriate.

## Legend
- ✅ **OK**: Suppression is appropriate
- ⚠️ **REVIEW**: May need to show errors
- ❌ **FIX**: Should definitely show errors to users

---

## TUI (tui/abatui.sh)

### ✅ OK - Infrastructure/Sanity Checks

```bash
# Line 74: Create symlink (failure is not critical)
ln -sf "$LOG_FILE" "$LOG_LINK" 2>/dev/null || true

# Line 80: Check if dialog is installed (error shown separately)
if ! command -v dialog >/dev/null 2>&1; then

# Line 172: Get terminal size (has fallback)
read -r TERM_ROWS TERM_COLS < <(stty size 2>/dev/null || echo "24 80")

# Line 832: JSON validation (error shown in dialog)
if jq empty "$pull_secret_file" 2>/dev/null; then

# Line 978: JSON validation (error shown in dialog)
if echo "$pull_secret" | jq empty 2>/dev/null; then
```

### ⚠️ REVIEW - Error Extraction (capturing for display)

```bash
# Lines 208-210, 218-220, 229-231: Reading error logs from run_once
# Currently: Captures errors to show in dialog
# Status: OK, but could be more robust
local err_msg=$(grep -E '^curl:' "$RUNNER_DIR/.../log" 2>/dev/null | head -1)
[[ -z "$err_msg" ]] && err_msg=$(tail -3 "$RUNNER_DIR/.../log" 2>/dev/null | grep -v '^$' | tail -1)
```

### ❌ FIX - Hiding Critical Operation Errors

```bash
# Line 801: Catalog downloads - user should see if this fails!
download_all_catalogs "$version_short" 86400 >/dev/null 2>&1

# Line 988: Pull secret validation - hide output but not errors!
if validate_pull_secret "$pull_secret_file" >/dev/null 2>&1; then

# Line 1384: Catalog wait - hide both stdout and stderr, show nothing to user
if ! wait_for_all_catalogs "$version_short" >/dev/null 2>&1; then

# Line 2403: oc-mirror install - completely silent
run_once -w -i cli:install:oc-mirror -- make -sC "$ABA_ROOT/cli" oc-mirror >/dev/null 2>&1

# Line 2406: Remove files - OK with `|| true` but could log
rm -f "$ABA_ROOT/mirror/save/imageset-config-save.yaml" 2>/dev/null || true
```

### ❌ FIX - Background Version Fetches (Lines 2683-2689)

```bash
# All version fetches are completely silent - if they fail, user has no idea
run_once -i "ocp:stable:latest_version_previous" -- bash -lc '...' >/dev/null 2>&1
run_once -i "ocp:fast:latest_version" -- bash -lc '...' >/dev/null 2>&1
# ... etc
```

**Issue**: If these fail, `run_once` logs the errors but user never sees them unless they dig into `~/.aba/runner/*/log`.

### ⚠️ REVIEW - File Operations

```bash
# Line 1143: Reading temp file (OK, fallback provided)
log "TMP file contents: $(cat "$TMP" 2>/dev/null || echo '(empty)')"

# Line 1426: Reading temp file (OK, fallback provided)
log "TMP file contents: $(cat "$TMP" 2>/dev/null || echo '(empty)')"

# Line 1532: Reading operator set name (OK, has fallback)
display=$(head -n1 "$f" 2>/dev/null | sed 's/^# *//' | sed 's/^Name: *//')

# Line 1634: Reading catalog files (should show error if missing!)
done < <(cat "$ABA_ROOT"/mirror/.index/* 2>/dev/null)
```

### ✅ OK - Config File Sourcing

```bash
# Lines 1915, 1983, 2051: Source config files (OK to suppress, has fallback)
source "$ABA_ROOT/mirror/mirror.conf" 2>/dev/null || true

# Lines 1919, 1987: hostname fallback
local default_host="${reg_host:-$(hostname -f 2>/dev/null || hostname)}"
```

### ⚠️ REVIEW - Validation Checks

```bash
# Line 599: Version validation (should maybe show why it failed?)
if "$ABA_ROOT/scripts/ocp-version-validate" "$OCP_CHANNEL" "$OCP_VERSION" >/dev/null 2>&1; then

# Line 1336: Operator grep (OK, silent filtering is intended)
if grep -q "^$op[[:space:]]" "$ABA_ROOT"/mirror/.index/* 2>/dev/null; then
```

---

## scripts/include_all.sh

### ✅ OK - Infrastructure

```bash
# Line 15: Check for sudo (OK)
which sudo 2>/dev/null >&2 && SUDO=sudo

# Line 60: Terminal color detection (OK, has fallback)
if [ -t 1 ] && [ "$(tput colors 2>/dev/null)" -ge 8 ] && [ -z "$PLAIN_OUTPUT" ]; then

# Line 771: JSON validation helper (OK, returns exit code)
jq -c '.' "$1" >/dev/null 2>&1

# Line 1090-1092: Network interface checks (OK, checking state)
ip link show dev "$i" >/dev/null 2>&1 || return 1
```

### ❌ FIX - Cache/Network Operations

```bash
# Line 753: curl download - should show error if it fails!
if [[ -n "$tmp" ]] && curl -f -sS "$url" > "$tmp" 2>/dev/null; then

# Line 764: Cleanup (OK with || true)
rm -f "$tmp" 2>/dev/null || true

# Line 857: jq parsing version list - should show error!
| jq -r '.nodes[].version' 2>/dev/null \
```

### ✅ OK - Analytics (Line 1067)

```bash
# Analytics tracker - OK to suppress
curl ... >/dev/null 2>&1
```

### ⚠️ REVIEW - Network/System Info Gathering

```bash
# Lines 1112, 1122, 1126, 1137, 1147, 1151, 1179, 1183, 1189: System info queries
# These are for auto-detection, errors are expected and handled
# Status: OK, but could benefit from debug logging

# Lines 1226-1228, 1236-1238, 1245-1247, 1256-1257: DNS detection
# Status: OK, multiple fallbacks
```

### ❌ FIX - Run Once Operations

```bash
# Line 1400-1408: Kill process (OK to suppress, cleanup operation)
kill -TERM -"$old_pid" 2>/dev/null || true

# Line 1424: Cleanup (OK)
rm -rf "$WORK_DIR"/* 2>/dev/null || true

# Line 1436: Read exit code (OK, has fallback)
rc="$(cat "$exitf" 2>/dev/null || echo 1)"

# Line 1464: Get file mtime (OK, has fallback)
local exit_mtime=$(stat -c %Y "$exit_file" 2>/dev/null || stat -f %m "$exit_file" 2>/dev/null)

# Line 1665: Global cleanup (OK)
run_once -G >/dev/null 2>&1 || true
```

### ⚠️ REVIEW - Pull Secret Validation

```bash
# Line 1775: Check JSON structure (OK, error shown by caller)
if ! jq -e '.auths["registry.redhat.io"]' "$pull_secret_file" >/dev/null 2>&1; then
```

---

## Summary by Priority

### HIGH PRIORITY - Fix These (User-Facing Operations)

1. **Line 801 (TUI)**: `download_all_catalogs` - User should see download errors
2. **Line 988 (TUI)**: `validate_pull_secret` - Keep stdout suppressed, but show stderr
3. **Line 1384 (TUI)**: `wait_for_all_catalogs` - Should show why it failed
4. **Line 2403 (TUI)**: `oc-mirror` install - Critical tool, show install errors
5. **Lines 2683-2689 (TUI)**: Version fetches - At least log if they fail
6. **Line 753 (include_all.sh)**: curl in `_fetch_cached` - Show network errors
7. **Line 857 (include_all.sh)**: jq parsing - Show parse errors

### MEDIUM PRIORITY - Review These

1. **Line 599 (TUI)**: Version validation - Could show why version doesn't exist
2. **Line 1634 (TUI)**: Reading catalog index - Should warn if files missing
3. Error extraction from run_once logs (lines 208-231) - Works but fragile

### LOW PRIORITY - OK As-Is

1. Infrastructure checks (dialog, sudo, terminal size)
2. Config file sourcing with fallbacks
3. Cleanup operations (`rm`, `kill`)
4. System info auto-detection (network interfaces, DNS, etc.)
5. JSON validation with error dialogs shown separately

---

## Recommended Pattern

### Before (Bad):
```bash
some_important_command >/dev/null 2>&1
```

### After (Good):
```bash
# Option 1: Let errors show naturally
some_important_command

# Option 2: Capture and display errors
if ! error_output=$(some_important_command 2>&1); then
    echo_red "[ABA] Error: Command failed" >&2
    echo_red "$error_output" >&2
    return 1
fi

# Option 3: Suppress stdout but keep stderr
some_important_command >/dev/null

# Option 4: Only for truly non-critical operations
some_optional_command 2>/dev/null || true
```

---

## General Rules

1. **Never suppress errors from**:
   - Network operations (downloads, API calls)
   - File operations that should succeed (not optional cleanups)
   - Critical tool installations
   - Data validation/parsing

2. **OK to suppress**:
   - Optional file cleanups (`rm -f ... 2>/dev/null || true`)
   - System info detection with fallbacks
   - Infrastructure sanity checks with explicit error handling
   - Process cleanup in trap handlers

3. **Capture and display**:
   - When you need to parse/format errors for dialogs
   - When errors need context before showing to user
   - When you want to log AND show errors

4. **Document why**:
   - If suppression is intentional, add a comment explaining why
   - Makes future audits easier

