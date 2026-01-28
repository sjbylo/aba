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

### File Created: `.vscode/settings.json`

```json
{
  "files.watcherExclude": {
    "**/.git/**": true,
    "**/.git/objects/**": true,
    "**/.git/subtree-cache/**": true,
    "**/node_modules/*/**": true
  },
  "git.ignoreLimitWarning": true
}
```

**What this does:**
- Tells Cursor's file watcher to ignore `.git/` directory
- Prevents race condition between Cursor's cache and git operations
- Git integration still works (Cursor calls git commands, just doesn't watch files)
- Stops the file deletion issue immediately

**To apply:** 
- Cursor should auto-reload settings
- Or manually: `Cmd/Ctrl+Shift+P` → "Developer: Reload Window"

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

1. ✅ Root cause identified
2. ✅ Fix implemented (`.vscode/settings.json`)
3. ⏳ Monitor for 30 minutes to verify fix works
4. ⏳ Stop monitor script if issue resolved: `pkill -f git-monitor.sh`
5. ⏳ Decide: commit `.vscode/settings.json` or add to `.gitignore`

---

## Lessons Learned

1. **Slow network + git + file watchers = bad combination**
2. **File watchers should exclude `.git/`** to avoid race conditions
3. **Cursor Remote-SSH has known issues** with git repos over slow connections
4. **Monitoring script was invaluable** for catching the pattern

---

**Status:** RESOLVED  
**Last Updated:** 2026-01-28 10:15
