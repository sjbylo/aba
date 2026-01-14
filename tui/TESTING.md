# ABA TUI Testing Guide

## Quick Start

```bash
cd /Users/steve/src/aba
./tui/aba_tui_experimental.sh
```

## Bug Fixes Applied

### 1. Help Button Exit (Exit Code 2)
**Issue**: Pressing Help button exits the script
**Fix**: Changed from recursion to explicit loop with proper rc handling
**Test**: Press Help button on any screen - should show help and return to same screen

### 2. Operators Not Added to Basket  
**Issue**: Selected operators don't appear in basket
**Fix**: 
- Proper global array initialization in `resume_from_conf()`
- Fixed dialog output parsing (handles quoted strings)
- Added extensive logging

**Test**: 
```bash
# In TUI:
1. Go to Operators
2. Choose "Search Operator Names"
3. Search for "mtv"
4. Check the box
5. Choose "View Basket"
# MTV should appear in basket
```

### 3. Operator Sets Not Adding
**Issue**: Selecting operator sets shows "[*] 0" in basket
**Fix**: 
- Fixed array initialization (was being wiped)
- Proper parsing of set file contents
- Better dialog output handling

**Test**:
```bash
# In TUI:
1. Go to Operators  
2. Choose "Select Operator Set"
3. Check "mesh3"
4. Choose "View Basket"
# Should see: cincinnati-operator, kiali-ossm, servicemeshoperator3
```

## Log File Location

Check the log for debugging:
```bash
# Find the log
ls -lt /tmp/aba-tui-*.log | head -1

# View last 50 lines
tail -50 /tmp/aba-tui-*.log

# Search for specific operator
grep -i "mtv" /tmp/aba-tui-*.log

# See basket operations
grep -i "basket" /tmp/aba-tui-*.log
```

## Quick Basket Test

Run the standalone test:
```bash
cd /Users/steve/src/aba
chmod +x tui/test-basket.sh
./tui/test-basket.sh
```

Should show:
```
Test 1: Adding operators directly to basket
  Basket count: 2
  Basket contents: test-op-1 test-op-2
  
Test 2: Adding from operator set (mesh3)
  Added: cincinnati-operator
  Added: kiali-ossm
  Added: servicemeshoperator3
  Basket count after mesh3: 5
  
Test 3: Checking array persistence
  Inside function - basket count: 5
  After function - basket count: 6
```

## Common Issues

### Dialog Not Found
```bash
sudo dnf install dialog -y
# or
sudo yum install dialog -y
```

### Help Button Still Exits
Check the log:
```bash
tail -20 /tmp/aba-tui-*.log
```
Should see:
```
[timestamp] Help button pressed in header
[timestamp] User pressed OK on header
```

If you see "exiting" or exit code 2, there's still an issue.

### Operators Not Appearing
Check the log for basket operations:
```bash
grep "Adding operator" /tmp/aba-tui-*.log
grep "Basket count" /tmp/aba-tui-*.log
```

Should show:
```
[timestamp] Adding operator to basket: [mtv-operator]
[timestamp] Basket now has 1 operators
```

## Transfer to RHEL for Testing

Choose one method:

### Method 1: rsync (Recommended)
```bash
# From Mac:
rsync -avz \
  --exclude '.git' \
  --exclude '*.tar' \
  /Users/steve/src/aba/ \
  user@rhel-server:~/aba/
```

### Method 2: Git
```bash
# From Mac:
cd /Users/steve/src/aba
git add tui/
git commit -m "TUI: Fix operator basket and help button bugs"
git push

# On RHEL:
cd ~/aba
git pull
```

### Method 3: SCP Single File
```bash
# From Mac:
scp /Users/steve/src/aba/tui/aba_tui_experimental.sh \
    user@rhel-server:~/aba/tui/
```

## Expected Behavior

1. **Help buttons work** - show help, return to same screen
2. **Operator search works** - operators appear in basket
3. **Operator sets work** - all operators from set appear in basket
4. **Basket count accurate** - shows real count in menu
5. **View basket works** - shows all selected operators
6. **Clear basket works** - removes all operators
7. **Configuration saves** - aba.conf gets updated

## Debug Output

The TUI now logs everything. After running, check:

```bash
cat /tmp/aba-tui-*.log | grep -A5 "Adding operator set: mesh3"
```

Should show:
```
Adding operator set: mesh3 from file: .../templates/operator-set-mesh3
Adding operator from set: cincinnati-operator
Adding operator from set: kiali-ossm
Adding operator from set: servicemeshoperator3
Basket now has 3 operators after adding set mesh3
```

