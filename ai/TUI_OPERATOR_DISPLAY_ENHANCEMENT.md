# TUI Operator Display Enhancement

**Date**: 2026-01-24 (design), 2026-03-18 (implemented)
**Status**: Implemented on `dev`

## Summary

Enhanced the TUI operator selection screen to show display names alongside
package names, and enabled searching by display name. Also added display name
comments to generated ISC files with fuzzy redundancy filtering.

## What Changed

### TUI Operator List

Before:
```
[X] cincinnati-operator         v1
[ ] web-terminal                stable
```

After:
```
[X] cincinnati-operator         OpenShift Update Service    v1
[ ] web-terminal                -                           stable
```

Display names come from the catalog index (extracted by podman). The `-`
placeholder appears when no display name is available.

### TUI Search

Search now matches against both the operator package name and the display name
(case-insensitive). Typing "migration" finds `mta-operator` via its display
name "Migration Toolkit for Applications".

The default channel is excluded from search matching to avoid false positives.

**Performance**: The search was optimized from `echo | awk` (2 process forks
per operator per keystroke) to pure bash parameter expansion
(`${line% *}`) -- zero forks, near-instant results.

### ISC Display Name Comments

Generated ImageSet Configuration files now include display names as YAML
comments where they add value:

```yaml
    - name: cincinnati-operator  # OpenShift Update Service
      channels:
      - name: "v1"
    - name: mta-operator  # Migration Toolkit for Applications
      channels:
      - name: "release-v7.2"
    - name: web-terminal
      channels:
      - name: "fast"
```

Comments are YAML-safe (ignored by oc-mirror and all parsers).

### Fuzzy Redundancy Filtering

A `_display_name_adds_info()` function decides whether a comment is worth
adding. It skips comments when the display name is just a reformatted version
of the operator name.

**Algorithm**:
1. Strip common suffixes (`-operator`, `-operator-rh`, `-rh`) from package name
2. Replace hyphens with spaces, lowercase both strings
3. Filter out the noise word "operator" from both
4. Check bidirectional word-substring containment:
   - If all op-name words appear in the display name → skip
   - If all display-name words appear in the op name → skip
   - Otherwise → add the comment

**Examples**:

| Operator | Display Name | Result | Why |
|---|---|---|---|
| `web-terminal` | Web Terminal | SKIP | Just reformatted |
| `openshift-cli-manager-operator` | CLI Manager | SKIP | All dn words in op |
| `node-healthcheck-operator` | Node Health Check Operator | SKIP | "health"+"check" in "healthcheck" |
| `redhat-oadp-operator` | OADP Operator | SKIP | "oadp" in op name |
| `cincinnati-operator` | OpenShift Update Service | ADD | Completely different |
| `mta-operator` | Migration Toolkit for Applications | ADD | Acronym → full name |
| `devspaces` | Red Hat OpenShift Dev Spaces | ADD | Different phrasing |

## Files Modified

| File | Change |
|---|---|
| `tui/abatui.sh` | Display names in operator list and basket; search matches display names; optimized search performance |
| `scripts/add-operators-to-imageset.sh` | `_display_name_adds_info()` function; reads display name from index; appends as YAML comment |

## Testing

- **TUI tests**: `test-tui-v2-01-wizard.sh` (77 pass) and `test-tui-v2-02-basket.sh` (69 pass) cover the full operator selection and search workflow
- **ISC generation**: exercised by E2E suites that run `aba save`/`aba sync`
- **Fuzzy logic**: validated manually against 12+ operator name/display name pairs

## Design Decisions

| Decision | Rationale |
|---|---|
| Display name as middle column (not parenthesised) | Cleaner layout, dialog auto-sizes |
| Search excludes default channel | Avoids false matches on version strings |
| Fuzzy skip for redundant comments | Keeps ISC clean -- only informative comments |
| "operator" as noise word | Most common false-match word in display names |
| Pure bash search (no awk/grep forks) | Performance: ~1000 operators searched instantly |
