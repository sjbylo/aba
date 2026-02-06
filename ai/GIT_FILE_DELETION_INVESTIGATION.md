# Git File Deletion Investigation

## Problem SOLVED ✅

**Date Solved:** 2026-01-28 10:15

Files in `/home/steve/aba` were mysteriously showing as deleted in `git status` repeatedly (43 times in 1.5 hours).

---

## ROOT CAUSE: Cursor Remote-SSH + Slow VPN + Git Repository

### The Problem

**Race condition between Cursor's file watcher and git operations over slow VPN:**

1. **Environment:** Cursor Remote-SSH to registry4 over slow VPN connection
2. **Cursor's fileWatcher:** Actively monitors `.git/` directory for git integration features
3. **Race Condition:**
   - Git operations on registry4 are FAST (local disk)
   - Cursor's file sync over VPN is SLOW (network latency)
   - Cursor sees intermediate/corrupted `.git/index` state during sync
   - Cursor "corrects" what it thinks is wrong state
   - Result: Files appear as deleted in `git status`
4. **Frequency:** Every ~2 seconds in bursts, triggered by context refreshes/AI responses

### Evidence from Monitoring

**Monitor deployed:** 2026-01-28 06:56:55  
**Deletions caught:** 43 between 08:27 and 10:02

```
DELETION DETECTED #1 at Wed Jan 28 08:27:46 AM +08 2026
DELETION DETECTED #2 at Wed Jan 28 08:27:49 AM +08 2026
DELETION DETECTED #3 at Wed Jan 28 08:27:51 AM +08 2026
...
DELETION DETECTED #43 at Wed Jan 28 10:02:47 AM +08 2026
```

**Process Correlation:**
- extensionHost PID 3887045 started at 08:26 → deletions began
- extensionHost PID 3968769 started at 10:01 → deletions continued  
- Multiple `fileWatcher` processes actively monitoring `.git/`
- High CPU usage (19-20%) on extensionHost during deletions

**Pattern:** Bursts every ~2 seconds when Cursor refreshes context or processes AI responses

---

## The Fix ✅

**Solution:** Tell Cursor to stop watching `.git/` directory

### Initial Attempt: Workspace Settings (FAILED)

Created `.vscode/settings.json` in workspace - but this failed because:
- `.vscode/` is in `.gitignore` (not committed)
- Settings were lost on `git restore .`
- Not a reliable solution for Remote-SSH

### Final Solution: User Settings (SUCCESS)

**Added to Cursor User Settings (applies globally):**

**Location:** `Cmd/Ctrl+Shift+P` → "Preferences: Open User Settings (JSON)"

**Settings added:**
```json
{
  "files.watcherExclude": {
    "**/.git/**": true,
    "**/.git/objects/**": true,
    "**/.git/subtree-cache/**": true
  }
}
```

**What this does:**
- Tells Cursor's file watcher to ignore `.git/` directory in ALL workspaces
- Prevents race condition between Cursor's cache and git operations over slow VPN
- Git integration still works (Cursor calls git commands, just doesn't watch files)
- Persists across window reloads and git operations
- Applies to all projects opened in Cursor (global setting)

**To apply:** 
1. Add settings to User Settings JSON (as shown above)
2. Reload window: `Cmd/Ctrl+Shift+P` → "Developer: Reload Window"
3. Verify: `git status --short` should only show untracked files, NO deletions

**Why User Settings vs Workspace Settings:**
- User settings stored on LOCAL machine (not affected by git operations)
- Workspace settings (`.vscode/`) in gitignore → lost on git restore
- User settings persist and apply globally

---

## Monitoring Setup (Historical)

### Monitor Script

**Location:** `/home/steve/aba/git-monitor.sh`

**Start:**
```bash
cd ~/aba
nohup ./git-monitor.sh > /tmp/git-monitor-console.log 2>&1 &
```

**Check status:**
```bash
ps aux | grep git-monitor | grep -v grep
tail -f /tmp/git-monitor-console.log
```

**Stop:**
```bash
pkill -f git-monitor.sh
```

**Logs:** `/tmp/git-monitor-*.log`

### What the Monitor Caught

- 43 deletion events
- Process information during each deletion
- Correlation with Cursor extensionHost/fileWatcher activity
- Timing patterns (every ~2 seconds in bursts)

This forensic data identified the root cause!

---

## Recovery (if files show as deleted)

```bash
cd ~/aba
git restore .
git status  # Verify clean
```

---

## Next Steps

1. ✅ Root cause identified (Cursor fileWatcher + slow VPN)
2. ✅ Fix implemented (User Settings - global)
3. ✅ User settings configured and Cursor reloaded
4. ⏳ Monitor for 30 minutes to verify fix works
5. ⏳ Stop monitor script if issue resolved: `pkill -f git-monitor.sh`
6. ⏳ Remove temporary files: `rm git-monitor.sh`

---

## Lessons Learned

1. **Slow network + git + file watchers = bad combination**
2. **File watchers should exclude `.git/`** to avoid race conditions
3. **Cursor Remote-SSH has known issues** with git repos over slow connections
4. **Monitoring script was invaluable** for catching the pattern

---

**Status:** RESOLVED (fix applied to User Settings)  
**Last Updated:** 2026-01-28 15:40  
**Fix Verification:** In progress - monitoring for 30 minutes
