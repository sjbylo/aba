# TUI Operator Display Enhancement

**Date**: 2026-01-24  
**Status**: Design Document  
**Purpose**: Enhance TUI operator selection to display human-readable names and enable searching by description

---

## Problem Statement

Currently, the TUI only shows operator package names (e.g., `resource-locker-operator`), which are technical identifiers. Users have to guess what each operator does based on the name alone.

oc-mirror now outputs catalog indexes with richer information:
```
Package Name                       Display Name/Description                                                          Default Channel
registry-operator                  Devfile Registry Operator                                                         beta
reportportal-operator              reportportal-operator                                                             alpha
resource-locker-operator           Resource Locker Operator                                                          alpha
yaks                               YAKS Operator                                                                     alpha
zookeeper-operator                 ZooKeeper Operator                                                                alpha
```

We want to leverage this information to improve the user experience.

---

## Goals

1. **Display human-readable names** instead of just package names
2. **Enable searching by description** in addition to package name
3. **Maintain compatibility** with existing operations (package names for oc-mirror)
4. **Handle edge cases** gracefully (missing descriptions, long names)

---

## Design Decisions

### Display Format

**Selected Format**: `"Display Name (package-name)"`

**Examples**:
- `"Resource Locker Operator (resource-locker-operator)"`
- `"YAKS Operator (yaks)"`
- `"Devfile Registry Operator (registry-operator)"`

**Rationale**:
- Display name is prominent (user-friendly)
- Package name in parentheses provides technical reference
- Users can still type/search by either name

### Truncation Policy

**Rule**: Only truncate display text if total length exceeds **150 characters**

**Strategy**:
```
If display_name + package_name + formatting > 150 chars:
  - Keep full package name (needed for identification)
  - Truncate display name with "..." 
  - Example: "Very Long Display Name That Goes On... (package-name)"
```

**Rationale**:
- Most operator names are short
- 150 chars fits most terminal widths
- Preserves package name for user reference

### Channel Display

**Decision**: **Do NOT display** default channel in the operator list

**Rationale**:
- Channels are visible in the operator details screen
- Clutters the display unnecessarily
- Users primarily care about what the operator does, not its channel

### Search Behavior

**Strategy**: Search **both** package name and display name

**Implementation**:
- Case-insensitive matching
- User types "locker" → matches:
  - Package: `resource-locker-operator`
  - Display: `Resource Locker Operator`
- No prioritization (both fields equally important)

**Examples**:
- Search "registry" → matches `registry-operator` (Devfile Registry Operator)
- Search "devfile" → matches same operator via display name
- Search "zoo" → matches `zookeeper-operator` (ZooKeeper Operator)

---

## Data Structure

### Parsed Data Storage

Store three fields per operator:

```bash
# Option 1: Parallel arrays (bash 4.x compatible)
operator_packages=("registry-operator" "yaks" "zookeeper-operator")
operator_displays=("Devfile Registry Operator" "YAKS Operator" "ZooKeeper Operator")
operator_channels=("beta" "alpha" "alpha")

# Option 2: Associative array (if bash supports it)
declare -A operator_info
operator_info["registry-operator"]="Devfile Registry Operator|beta"
operator_info["yaks"]="YAKS Operator|alpha"
```

**Recommendation**: Use parallel arrays for maximum compatibility

### Dialog Menu Items

```bash
# Tag (what gets returned): package-name
# Item (what user sees): "Display Name (package-name)"

dialog --menu "Select Operator" 0 0 0 \
  "registry-operator" "Devfile Registry Operator (registry-operator)" \
  "yaks" "YAKS Operator (yaks)" \
  ...
```

**Critical**: The **tag must always be the package name** for oc-mirror operations!

---

## Implementation Plan

### Phase 1: Data Parsing

**Files to Modify**:
- Functions that parse `oc-mirror list operators` output

**Changes**:
1. Update regex/parsing logic to capture three fields:
   - Package name (column 1)
   - Display name (column 2)
   - Default channel (column 3)
2. Handle variable whitespace between columns
3. Store data in parallel arrays or associative array

**Edge Cases**:
- Display name missing → use package name as fallback
- Display name same as package name → still show both (user confirmation)
- Extra whitespace in display names → trim/normalize

### Phase 2: Search Enhancement

**Files to Modify**:
- TUI search/filter functions for operator selection

**Changes**:
1. When filtering operators, match search term against:
   - Package name (e.g., "resource-locker-operator")
   - Display name (e.g., "Resource Locker Operator")
2. Case-insensitive comparison
3. Return package names of matching operators

**Example Logic**:
```
For each operator:
  search_term_lower = lowercase(user_input)
  package_lower = lowercase(package_name)
  display_lower = lowercase(display_name)
  
  if search_term_lower in package_lower OR search_term_lower in display_lower:
    include in results
```

### Phase 3: Display Formatting

**Files to Modify**:
- Functions that build dialog menu items for operator selection

**Changes**:
1. Format display text: `"$display_name ($package_name)"`
2. Check total length:
   ```
   total_len = len(display_name) + len(" ()") + len(package_name)
   if total_len > 150:
     truncate display_name to fit
   ```
3. Build dialog menu with:
   - Tag: `"$package_name"` (for operations)
   - Item: `"$formatted_text"` (for display)

**Example**:
```bash
# Short name - no truncation
format_operator_item "yaks" "YAKS Operator"
→ Tag: "yaks"
→ Item: "YAKS Operator (yaks)"

# Long name - with truncation
format_operator_item "very-long-package" "This is an Extremely Long Display Name That Would Exceed Our Character Limit And Needs To Be Truncated For Reasonable Display"
→ Tag: "very-long-package"
→ Item: "This is an Extremely Long Display Name That W... (very-long-package)"
```

### Phase 4: Selection Handling

**Files to Modify**:
- Functions that process user selection from dialog

**Changes**:
1. Extract **tag** (package name) from dialog return value
2. Use package name for all operations:
   - Adding to imageset-config
   - Running oc-mirror commands
   - Displaying confirmation messages
3. Look up display name from data structure for user-facing messages

**No change needed**: Dialog already returns the tag (package name), not the display text!

---

## Edge Cases & Error Handling

### Missing Display Name

**Scenario**: oc-mirror output doesn't include display name for some operators

**Handling**:
```
if display_name is empty or whitespace:
  display_name = package_name
  
format_text = "$display_name ($package_name)"
# Results in: "package-name (package-name)" - redundant but safe
```

**Alternative**: Detect duplicate and simplify:
```
if display_name == package_name:
  format_text = "$package_name"  # Don't show twice
else:
  format_text = "$display_name ($package_name)"
```

### Very Long Names

**Scenario**: Display name + package name > 150 characters

**Handling**:
```
max_display_len = 150 - len(" (...)") - len(package_name)
if len(display_name) > max_display_len:
  truncated_display = display_name[0:max_display_len-3] + "..."
  
format_text = "$truncated_display ($package_name)"
```

**Example**:
- Input: `display_name = "This Is A Very Long Operator Display Name That Goes On And On"`, `package_name = "long-operator-name"`
- Output: `"This Is A Very Long Operator Display Name Tha... (long-operator-name)"`

### Duplicate Display Names

**Scenario**: Multiple operators with same display name but different package names

**Example**:
- `operator-a` → "Generic Operator"
- `operator-b` → "Generic Operator"

**Handling**: Package name in parentheses already differentiates them!
- Display: `"Generic Operator (operator-a)"`
- Display: `"Generic Operator (operator-b)"`

User can distinguish by package name.

### Special Characters

**Scenario**: Display name contains special characters (quotes, backslashes)

**Handling**:
- Dialog handles quoting internally
- Ensure proper escaping when building menu items
- Test with operators that have special characters

### Backward Compatibility

**Scenario**: Older oc-mirror version outputs different format

**Handling**:
1. Attempt to parse three-column format (package, display, channel)
2. If parsing fails, fall back to single-column format (package only)
3. Graceful degradation: use package name for both tag and display

---

## Testing Checklist

### Unit Testing

- [ ] Parse oc-mirror output with all three columns
- [ ] Parse oc-mirror output with missing display names
- [ ] Handle empty/whitespace display names
- [ ] Truncate long names correctly (edge case: exactly 150 chars)
- [ ] Format short names without truncation
- [ ] Format names with special characters

### Integration Testing

- [ ] Search by package name finds correct operators
- [ ] Search by display name finds correct operators
- [ ] Search is case-insensitive
- [ ] Selection returns correct package name (tag)
- [ ] Selected operator is added to imageset-config correctly
- [ ] Dialog displays formatted text correctly
- [ ] Long names display without breaking dialog layout

### User Acceptance Testing

- [ ] Users can find operators more easily by description
- [ ] Display format is clear and not cluttered
- [ ] Search feels intuitive and fast
- [ ] Package names remain visible for reference

---

## Functions to Review/Modify

### Likely Affected Functions (in TUI)

1. **Operator catalog parsing**:
   - Functions that call `oc-mirror list operators`
   - Functions that parse catalog index files
   - May be in `tui/abatui.sh` or `scripts/include_all.sh`

2. **Operator search/filter**:
   - Functions that implement operator search in TUI
   - Dialog search/filter handlers
   - In `tui/abatui.sh`

3. **Operator display/selection**:
   - Functions that build operator selection dialogs
   - Menu item formatting functions
   - In `tui/abatui.sh`

4. **Operator selection processing**:
   - Functions that handle user selection
   - Functions that add operators to imageset-config
   - Functions that generate confirmation messages

### Files to Examine

- `tui/abatui.sh` - Main TUI logic
- `scripts/include_all.sh` - May contain operator parsing helpers
- `scripts/add-operators-to-imageset.sh` - Operator addition logic
- Any scripts that call `oc-mirror list operators`

---

## Benefits

1. **Improved UX**: Users see what operators do, not just cryptic names
2. **Better Search**: Find operators by description, not just package name
3. **Maintained Compatibility**: Operations still use correct package names
4. **Professional**: Matches expectations of modern CLIs
5. **Minimal Risk**: Changes are display-only, core operations unchanged

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| oc-mirror output format changes | Parse defensively, fall back to package name only |
| Very long names break dialog | Truncate at 150 chars with "..." |
| Special characters in names | Proper escaping in dialog commands |
| Missing display names | Fall back to package name |
| Performance (large catalogs) | Parsing is one-time, results cached |

---

## Open Questions

1. Should we cache the parsed operator data to disk for faster subsequent loads?
2. Should we show a hint in the dialog title like "Search by name or description"?
3. Should we highlight search matches in the display text?
4. Should we sort by display name or package name?

---

## Future Enhancements (Out of Scope)

- Show operator channel in a separate column (would require more complex dialog layout)
- Color-code operators by maturity (alpha/beta/stable)
- Show operator version information
- Multi-column display with aligned text
- Operator details preview before selection

---

**Next Steps**:
1. Review and approve this design document
2. Identify exact functions to modify (code inspection)
3. Implement parsing changes
4. Implement display changes
5. Test thoroughly
6. Update user documentation

---

**Last Updated**: 2026-01-24  
**Author**: AI Assistant (with user decisions)
