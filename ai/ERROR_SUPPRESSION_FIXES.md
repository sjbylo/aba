# Error Suppression Fixes - Implementation Summary

Date: 2026-01-18

## Changes Made

### 1. Added Error Display Helper Function (tui/abatui.sh)

**New function**: `show_run_once_error()`
- Extracts last 8 meaningful error lines from run_once task logs
- Shows errors in a formatted dialog with log file path
- Provides context and actionable information to users

### 2. Fixed High Priority Error Suppressions

#### TUI (tui/abatui.sh)

**Line ~801 - Catalog Downloads**
- **Before**: `download_all_catalogs ... >/dev/null 2>&1`
- **After**: `download_all_catalogs ...` (no suppression)
- **Impact**: User sees download errors immediately in logs

**Line ~988 - Pull Secret Validation**
- **Before**: `validate_pull_secret ... >/dev/null 2>&1`
- **After**: `validate_pull_secret ... >/dev/null` (keep stderr)
- **Impact**: Authentication errors visible while success messages suppressed

**Line ~1384 - Wait for Catalogs**
- **Before**: `wait_for_all_catalogs ... >/dev/null 2>&1`
- **After**: No suppression + `show_run_once_error()` on failure
- **Impact**: Shows which catalog failed with actual error details

**Line ~2458 - oc-mirror Install**
- **Before**: `run_once ... oc-mirror >/dev/null 2>&1`
- **After**: Check exit code + `show_run_once_error()` on failure
- **Impact**: Install failures now visible with helpful context

**Lines ~2744-2750 - Background Version Fetches**
- **Before**: All version fetches with `>/dev/null 2>&1`
- **After**: Only suppress stdout, keep stderr
- **Impact**: Network/API errors now logged for debugging

#### scripts/include_all.sh

**Line 753 - curl in _fetch_cached**
- **Before**: `curl ... > "$tmp" 2>/dev/null`
- **After**: `curl ... > "$tmp"` (no suppression)
- **Impact**: Network errors visible when fetching versions/data

**Line 858 - jq parsing in fetch_all_versions**
- **Before**: `jq ... 2>/dev/null`
- **After**: `jq ...` (no suppression)
- **Impact**: JSON parse errors visible when processing versions

## Philosophy Applied

### What We Changed
1. **Critical user-facing operations**: No suppression
2. **Network operations**: Show stderr (errors), suppress stdout (success)
3. **Tool installations**: Show all errors with context
4. **Background tasks**: Let errors flow to logs

### What We Kept Suppressed
1. **Optional cleanups**: `rm -f ... 2>/dev/null || true`
2. **Fallback checks**: System info detection with multiple fallbacks
3. **Success messages**: When we show our own formatted message instead

### Pattern Used

```bash
# BEFORE (Bad - hides everything)
some_command >/dev/null 2>&1

# AFTER (Good - appropriate handling)
# Option 1: Let everything flow
some_command

# Option 2: Suppress success, show errors
some_command >/dev/null

# Option 3: Check and display errors
if ! some_command; then
    show_run_once_error "task:id" "User-friendly title"
fi
```

## Testing Recommendations

1. **Test catalog download failures**: Disconnect network during catalog download
2. **Test pull secret validation**: Use invalid/expired pull secret
3. **Test oc-mirror install**: Remove oc-mirror and trigger install
4. **Test version fetches**: Block access to api.openshift.com
5. **Monitor logs**: Check `~/.aba/runner/*/log` for proper error capture

## User Experience Improvements

### Before
- Errors silently written to logs
- User sees generic "failed" message
- Must exit TUI and navigate filesystem to debug

### After
- Errors immediately visible in TUI dialogs
- Shows last 8 error lines with context
- Provides log file path for deeper investigation
- User stays in TUI, gets actionable information

## Files Modified

1. `tui/abatui.sh`:
   - Added `show_run_once_error()` helper
   - Fixed 6 critical suppression points
   - Total: ~40 lines changed

2. `scripts/include_all.sh`:
   - Fixed 2 critical suppression points
   - Total: ~4 lines changed

## Backward Compatibility

✅ **Fully backward compatible**
- Only changes error visibility
- No functional changes to commands
- No changes to return codes
- Logs still capture everything

## Known Limitations

1. Background tasks still write to logs (not shown in TUI unless error)
2. Some stderr might be verbose during normal operation
3. May need fine-tuning based on user feedback

## Next Steps (Optional)

1. Monitor user feedback on error visibility
2. Add more specific error messages for common failures
3. Consider adding debug mode toggle in TUI
4. Add error summary at end of long operations

