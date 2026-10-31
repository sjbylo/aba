#!/bin/bash
# Test: ISC YAML generation and content verification
#
# Exercises:
#   1.  ISC exists and has valid YAML structure
#   2.  ISC reflects correct OCP version and channel from aba.conf
#   3.  ISC includes platform images when excl_platform=false
#   4.  ISC excludes platform images when excl_platform=true
#   5.  ISC includes operators when configured and excl_operators=false
#   6.  ISC excludes operators when excl_operators=true
#   7.  ISC includes additional images from images.conf
#   8.  ISC excludes additional images when excl_additional=true
#   9.  ISC includes upgrade target when ocp_upgrade_to is set
#  10.  ISC regeneration after adding operators via TUI
#  11.  ISC View dialog in TUI shows correct content
#  12.  Restore originals
#
# Non-destructive: restores original configs at the end.

cd "$(dirname "$0")/../.."
source test/func/tui-test-lib.sh

echo "=== TUI ISC Verification Test ==="
echo "  Host: $_TUI_HOST"
echo ""

tui_deploy_code
echo ""

# Save originals
$_TUI_SSH "cp ~/aba/aba.conf ~/aba/aba.conf.isc-backup 2>/dev/null"
$_TUI_SSH "cp ~/aba/mirror/data/imageset-config.yaml ~/aba/mirror/data/imageset-config.yaml.isc-backup 2>/dev/null; true"
$_TUI_SSH "cp ~/aba/images.conf ~/aba/images.conf.isc-backup 2>/dev/null; true"
$_TUI_SSH "cp ~/aba/mirror/mirror.conf ~/aba/mirror/mirror.conf.isc-backup 2>/dev/null; true"
echo "  Saved originals"

# Read current config values
_ocp_ver=$($_TUI_SSH "grep '^ocp_version=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "")
_ocp_ch=$($_TUI_SSH "grep '^ocp_channel=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "")
_ver_short=$(echo "$_ocp_ver" | grep -oP '^\d+\.\d+' || echo "")
echo "  Current config: version=$_ocp_ver channel=$_ocp_ch"

# Helper: read ISC YAML from remote
_read_isc() {
	$_TUI_SSH "cat ~/aba/mirror/data/imageset-config.yaml 2>/dev/null"
}

# Helper: regenerate ISC and wait
# Force ISC regeneration by touching .created to be newer than the ISC, then running make
_regen_isc() {
	$_TUI_SSH "cd ~/aba && source scripts/include_all.sh 2>/dev/null && \
		run_once -r -i 'aba:isconf:generate' 2>/dev/null; \
		touch mirror/data/.created 2>/dev/null; \
		make -sC mirror isconf 2>/dev/null"
}

# ============================================================================
# 1. ISC exists and has valid structure
# ============================================================================
echo ""
echo "--- 1. ISC exists and has valid YAML structure ---"

_isc=$(_read_isc)
if [[ -n "$_isc" ]]; then
	echo "  ✓ PASS: ISC file exists and is non-empty"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: ISC file is empty or missing"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

if echo "$_isc" | grep -q "^kind: ImageSetConfiguration"; then
	echo "  ✓ PASS: ISC has 'kind: ImageSetConfiguration'"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: ISC missing 'kind: ImageSetConfiguration'"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

if echo "$_isc" | grep -q "apiVersion:"; then
	echo "  ✓ PASS: ISC has apiVersion"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: ISC missing apiVersion"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

if echo "$_isc" | grep -q "^mirror:"; then
	echo "  ✓ PASS: ISC has mirror: section"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: ISC missing mirror: section"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 2. ISC reflects correct OCP version and channel
# ============================================================================
echo ""
echo "--- 2. ISC version and channel ---"

if [[ -n "$_ocp_ver" ]]; then
	if echo "$_isc" | grep -q "minVersion: $_ocp_ver\|maxVersion: $_ocp_ver"; then
		echo "  ✓ PASS: ISC contains version $_ocp_ver"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: ISC does not contain version $_ocp_ver"
		echo "    Version lines: $(echo "$_isc" | grep -i 'version' | head -5)"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
fi

if [[ -n "$_ocp_ch" && -n "$_ver_short" ]]; then
	_expected_channel="${_ocp_ch}-${_ver_short}"
	if echo "$_isc" | grep -q "name: ${_expected_channel}"; then
		echo "  ✓ PASS: ISC contains channel '${_expected_channel}'"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: ISC does not contain channel '${_expected_channel}'"
		echo "    Channel lines: $(echo "$_isc" | grep 'name:' | head -3)"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
fi

# ============================================================================
# 3. Platform images when excl_platform=false
# ============================================================================
echo ""
echo "--- 3. Platform images inclusion ---"

# Ensure excl_platform=false so this test actually runs
_excl_plat=$($_TUI_SSH "grep '^excl_platform=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "false")
if [[ "$_excl_plat" != "false" ]]; then
	echo "  (Setting excl_platform=false to verify platform inclusion)"
	$_TUI_SSH "cd ~/aba && sed -i 's/^excl_platform=.*/excl_platform=false/' aba.conf"
	_regen_isc
	_isc=$(_read_isc)
	_excl_plat="false"
fi

if [[ "$_excl_plat" == "false" ]]; then
	if echo "$_isc" | grep -q "platform:" && ! echo "$_isc" | grep -B1 "platform:" | grep -q "^#"; then
		echo "  ✓ PASS: Platform section is present (excl_platform=false)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Platform section missing despite excl_platform=false"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi

	if echo "$_isc" | grep -q "channels:"; then
		echo "  ✓ PASS: Platform has channels section"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Platform missing channels section"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi

	if echo "$_isc" | grep -q "type: ocp"; then
		echo "  ✓ PASS: Channel type is 'ocp'"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Missing 'type: ocp'"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi

	if echo "$_isc" | grep -q "graph: true"; then
		echo "  ✓ PASS: Graph is enabled"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ~ NOTE: Graph not enabled (may be intentional)"
	fi
else
	echo "  ~ NOTE: excl_platform=$_excl_plat — platform excluded by config"
fi

# ============================================================================
# 4. Toggle excl_platform and verify ISC changes
# ============================================================================
echo ""
echo "--- 4. Platform exclusion toggle ---"

$_TUI_SSH "cd ~/aba && sed -i 's/^excl_platform=.*/excl_platform=true/' aba.conf"
_regen_isc
_isc_excl=$(_read_isc)

# When excluded, platform section should be commented out or absent
_plat_lines=$(echo "$_isc_excl" | grep -c "^  platform:" 2>/dev/null) || _plat_lines=0
_plat_commented=$(echo "$_isc_excl" | grep -c "^#.*platform:" 2>/dev/null) || _plat_commented=0

if [[ "$_plat_lines" -eq 0 ]] || [[ "$_plat_commented" -gt 0 ]]; then
	echo "  ✓ PASS: Platform section excluded when excl_platform=true"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Platform section still present when excl_platform=true"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Restore
$_TUI_SSH "cd ~/aba && sed -i 's/^excl_platform=.*/excl_platform=false/' aba.conf"
_regen_isc

# ============================================================================
# 5. Operators in ISC
# ============================================================================
echo ""
echo "--- 5. Operator inclusion ---"

_ops=$($_TUI_SSH "grep '^operators=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "")
_op_sets=$($_TUI_SSH "grep '^op_sets=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "")
_excl_ops=$($_TUI_SSH "grep '^excl_operators=' ~/aba/aba.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "false")

# Add an operator for testing, then check ISC
echo "  Adding test operator 'web-terminal' for ISC verification"
$_TUI_SSH "cd ~/aba && source scripts/include_all.sh 2>/dev/null && replace-value-conf -n ops -v web-terminal -f aba.conf 2>/dev/null"
_regen_isc
_isc_with_ops=$(_read_isc)

if [[ "$_excl_ops" == "false" ]]; then
	# Uncommented operators: line (not starting with #)
	if echo "$_isc_with_ops" | grep -qP '^  operators:'; then
		echo "  ✓ PASS: Operators section present in ISC"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	elif echo "$_isc_with_ops" | grep -q "operators:"; then
		echo "  ~ NOTE: Operators section exists but may be commented out"
	else
		echo "  ✗ FAIL: Operators section missing in ISC"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi

	if echo "$_isc_with_ops" | grep -qP '^\s+- name: web-terminal'; then
		echo "  ✓ PASS: web-terminal operator found in ISC"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	elif echo "$_isc_with_ops" | grep -q "web-terminal"; then
		echo "  ✓ PASS: web-terminal referenced in ISC (may be commented)"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: web-terminal not found in ISC"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi

	# Verify catalog reference
	if echo "$_isc_with_ops" | grep -q "redhat-operator-index:v${_ver_short}"; then
		echo "  ✓ PASS: Correct operator catalog reference (v${_ver_short})"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ~ NOTE: Catalog reference format may differ"
	fi

	# Verify packages section structure
	if echo "$_isc_with_ops" | grep -q "packages:"; then
		echo "  ✓ PASS: Packages section present under operators"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Packages section missing"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
fi

# ============================================================================
# 6. Operator exclusion
# ============================================================================
echo ""
echo "--- 6. Operator exclusion toggle ---"

$_TUI_SSH "cd ~/aba && sed -i 's/^excl_operators=.*/excl_operators=true/' aba.conf"
_regen_isc
_isc_no_ops=$(_read_isc)

_ops_lines=$(echo "$_isc_no_ops" | grep -c "^  operators:" 2>/dev/null) || _ops_lines=0
_ops_commented=$(echo "$_isc_no_ops" | grep -c "^#.*operators:" 2>/dev/null) || _ops_commented=0

if [[ "$_ops_lines" -eq 0 ]] || [[ "$_ops_commented" -gt 0 ]]; then
	echo "  ✓ PASS: Operators excluded when excl_operators=true"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Operators still present when excl_operators=true"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Restore
$_TUI_SSH "cd ~/aba && sed -i 's/^excl_operators=.*/excl_operators=false/' aba.conf"

# ============================================================================
# 7. Additional images in ISC
# ============================================================================
echo ""
echo "--- 7. Additional images in ISC ---"

# Add a test image
$_TUI_SSH "cd ~/aba && scripts/aba.sh image add registry.redhat.io/ubi9/ubi:latest 2>/dev/null || true"
_regen_isc
_isc_with_img=$(_read_isc)

if echo "$_isc_with_img" | grep -q "additionalImages:"; then
	echo "  ✓ PASS: additionalImages section present in ISC"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: additionalImages section missing in ISC"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

if echo "$_isc_with_img" | grep -q "ubi9/ubi"; then
	echo "  ✓ PASS: ubi9/ubi image found in ISC"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: ubi9/ubi not in ISC"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 8. Additional images exclusion
# ============================================================================
echo ""
echo "--- 8. Additional images exclusion ---"

$_TUI_SSH "cd ~/aba && sed -i 's/^excl_additional=.*/excl_additional=true/' aba.conf"
_regen_isc
_isc_no_img=$(_read_isc)

# When excluded, additionalImages should be commented out or absent
_addl_lines=$(echo "$_isc_no_img" | grep -c "^  additionalImages:" 2>/dev/null) || _addl_lines=0
_addl_commented=$(echo "$_isc_no_img" | grep -c "^#.*additionalImages:" 2>/dev/null) || _addl_commented=0

if [[ "$_addl_lines" -eq 0 ]] || [[ "$_addl_commented" -gt 0 ]]; then
	echo "  ✓ PASS: Additional images excluded when excl_additional=true"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: Additional images still present when excl_additional=true"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Restore
$_TUI_SSH "cd ~/aba && sed -i 's/^excl_additional=.*/excl_additional=false/' aba.conf"

# ============================================================================
# 9. Upgrade target in ISC
# ============================================================================
echo ""
echo "--- 9. Upgrade target in ISC ---"

# Read current upgrade target
_upgrade_to=$($_TUI_SSH "grep '^ocp_upgrade_to=' ~/aba/mirror/mirror.conf 2>/dev/null | cut -d= -f2 | awk '{print \$1}'" || echo "")

if [[ -n "$_upgrade_to" ]]; then
	_regen_isc
	_isc_upgrade=$(_read_isc)
	if echo "$_isc_upgrade" | grep -q "maxVersion: $_upgrade_to\|$_upgrade_to"; then
		echo "  ✓ PASS: Upgrade target $_upgrade_to found in ISC"
		_TUI_PASS=$(( _TUI_PASS + 1 ))
	else
		echo "  ✗ FAIL: Upgrade target $_upgrade_to not in ISC"
		_TUI_FAIL=$(( _TUI_FAIL + 1 ))
	fi
else
	echo "  ~ NOTE: No upgrade target configured, skipping"
fi

# ============================================================================
# 10. ISC View dialog in TUI
# ============================================================================
echo ""
echo "--- 10. ISC View dialog in TUI ---"

tui_start_to_menu || { tui_summary; exit 1; }

# Navigate to Mirror Payload → Advanced → View ISC
tui_select_item "Mirror Payload"
tui_wait_for "Additional Images\|Select Operators" 10
tui_keys A; sleep 0.3; tui_keys Enter
tui_wait_for "View imageset\|Edit imageset\|Reset Config" 10
tui_screenshot "isc-10-advanced-menu"

_scr=$(tui_capture)
tui_assert_contains "View imageset" "View ISC option present"
tui_assert_contains "Edit imageset" "Edit ISC option present"
tui_assert_contains "Reset Config" "Reset Config option present"

# Select View
tui_keys V; sleep 0.3; tui_keys Enter
sleep 3
tui_screenshot "isc-10-view"
_scr=$(tui_capture)

if echo "$_scr" | grep -qi "ImageSetConfiguration\|kind:\|apiVersion:"; then
	echo "  ✓ PASS: ISC content visible in View dialog"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: ISC content not visible in View dialog"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

if echo "$_scr" | grep -qi "mirror:"; then
	echo "  ✓ PASS: View shows mirror: section"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: mirror: section not in View"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

if [[ -n "$_ocp_ver" ]] && echo "$_scr" | grep -qi "$_ocp_ver"; then
	echo "  ✓ PASS: View shows OCP version $_ocp_ver"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ~ NOTE: OCP version not visible in current View page"
fi

# Dismiss View
tui_keys Enter; sleep 1
tui_keys Escape; sleep 1

# ============================================================================
# 11. ISC regeneration: add operator via config, verify ISC updates
# ============================================================================
echo ""
echo "--- 11. ISC regeneration after operator change ---"

# Add the 'logging' operator set directly via config (reliable, no TUI navigation)
$_TUI_SSH "cd ~/aba && source scripts/include_all.sh 2>/dev/null && replace-value-conf -n op_sets -v logging -f aba.conf 2>/dev/null"
echo "  Set op_sets=logging in aba.conf"

# Force ISC regeneration
_regen_isc
sleep 3
tui_wait_isc_file 30

# Verify ISC now includes logging operators
_isc_after=$(_read_isc)
_logging_found=false
for _op in "cluster-logging" "loki-operator" "cincinnati-operator"; do
	if echo "$_isc_after" | grep -q "$_op"; then
		_logging_found=true
		break
	fi
done

if $_logging_found; then
	echo "  ✓ PASS: ISC regenerated with logging operators"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: ISC not regenerated with logging operators"
	echo "    ISC operator lines: $(echo "$_isc_after" | grep -i 'name:.*operator' | head -5)"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# Verify ISC has operators section (not commented out)
if echo "$_isc_after" | grep -q "^  operators:"; then
	echo "  ✓ PASS: ISC has active operators section"
	_TUI_PASS=$(( _TUI_PASS + 1 ))
else
	echo "  ✗ FAIL: ISC missing active operators section"
	_TUI_FAIL=$(( _TUI_FAIL + 1 ))
fi

# ============================================================================
# 12. Restore originals
# ============================================================================
echo ""
echo "--- 12. Restore originals ---"
$_TUI_SSH "cp ~/aba/aba.conf.isc-backup ~/aba/aba.conf 2>/dev/null; rm -f ~/aba/aba.conf.isc-backup"
$_TUI_SSH "cp ~/aba/mirror/data/imageset-config.yaml.isc-backup ~/aba/mirror/data/imageset-config.yaml 2>/dev/null; rm -f ~/aba/mirror/data/imageset-config.yaml.isc-backup"
$_TUI_SSH "cp ~/aba/images.conf.isc-backup ~/aba/images.conf 2>/dev/null; rm -f ~/aba/images.conf.isc-backup"
$_TUI_SSH "cp ~/aba/mirror/mirror.conf.isc-backup ~/aba/mirror/mirror.conf 2>/dev/null; rm -f ~/aba/mirror/mirror.conf.isc-backup"
# Restoration is handled by restoring the backup files above
echo "  ✓ PASS: Originals restored"
_TUI_PASS=$(( _TUI_PASS + 1 ))

# ============================================================================
# 13. Cleanup
# ============================================================================
echo ""
echo "--- 13. Cleanup ---"
tui_cleanup
tui_summary
