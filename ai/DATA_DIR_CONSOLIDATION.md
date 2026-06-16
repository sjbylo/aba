# Data Directory Consolidation: save/ + sync/ → data/

## Overview

Consolidate `mirror/save/` and `mirror/sync/` into a single `mirror/data/` directory for oc-mirror v2.

**Rationale:**
- oc-mirror v2 uses unified workspace concept
- Reduces code duplication
- Simplifies user experience
- Cleaner architecture

**Migration Strategy:**
- No backward compatibility needed
- Users must re-install aba after this change
- All-in-one-go conversion

---

## Directory Structure Changes

### Before (oc-mirror v1 legacy):
```
mirror/
├── save/
│   ├── imageset-config-save.yaml
│   ├── mirror_*.tar
│   └── working-dir/
└── sync/
    ├── imageset-config-sync.yaml
    └── working-dir/
```

### After (oc-mirror v2):
```
mirror/
└── data/
    ├── imageset-config.yaml
    ├── mirror_*.tar (for save/load workflows)
    └── working-dir/
```

---

## File-by-File Code Changes

### 1. scripts/reg-save.sh

```diff
 # Line 56: Change directory reference
-aba_info "Now saving (mirror2disk) images from external network to mirror/save/ directory."
+aba_info "Now saving (mirror2disk) images from external network to mirror/data/ directory."

 # Lines 59-60: Change disk space warning
 aba_warning \
-	"Ensure there is enough disk space under $PWD/save." \
+	"Ensure there is enough disk space under $PWD/data." \

 # Lines 92-93: Change config file and cd directory (v1)
-		cmd="oc-mirror --v1 --config=imageset-config-save.yaml file://."
-		echo "cd save && umask 0022 && $cmd" > save-mirror.sh && chmod 700 save-mirror.sh
+		cmd="oc-mirror --v1 --config=imageset-config.yaml file://."
+		echo "cd data && umask 0022 && $cmd" > save-mirror.sh && chmod 700 save-mirror.sh

 # Lines 99-100: Change config file and cd directory (v2)
-		cmd="oc-mirror --v2 --config=imageset-config-save.yaml file://. --since 2025-01-01  --image-timeout 15m --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times"
-		echo "cd save && umask 0022 && $cmd" > save-mirror.sh && chmod 700 save-mirror.sh
+		cmd="oc-mirror --v2 --config=imageset-config.yaml file://. --since 2025-01-01  --image-timeout 15m --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times"
+		echo "cd data && umask 0022 && $cmd" > save-mirror.sh && chmod 700 save-mirror.sh

 # Line 120: Change error file path
-			error_file=$(ls -t save/working-dir/logs/mirroring_errors_*_*.txt 2>/dev/null | head -1)
+			error_file=$(ls -t data/working-dir/logs/mirroring_errors_*_*.txt 2>/dev/null | head -1)

 # Lines 130-132: Change saved_errors path
-				mkdir -p save/saved_errors
-				cp $error_file save/saved_errors
-				echo_red "[ABA] Error detected and log file saved in save/saved_errors/$(basename $error_file)" >&2
+				mkdir -p data/saved_errors
+				cp $error_file data/saved_errors
+				echo_red "[ABA] Error detected and log file saved in data/saved_errors/$(basename $error_file)" >&2
```

---

### 2. scripts/reg-sync.sh

```diff
 # Lines 108-109: Change config file and cd directory (v1)
-	cmd="oc-mirror --v1 --config=imageset-config-sync.yaml docker://$reg_host:$reg_port$reg_path"
-	echo "cd sync && umask 0022 && $cmd" > sync-mirror.sh && chmod 700 sync-mirror.sh
+	cmd="oc-mirror --v1 --config=imageset-config.yaml docker://$reg_host:$reg_port$reg_path"
+	echo "cd data && umask 0022 && $cmd" > sync-mirror.sh && chmod 700 sync-mirror.sh

 # Lines 116-117: Change config file and cd directory (v2)
-	cmd="oc-mirror --v2 --config imageset-config-sync.yaml --workspace file://. docker://$reg_host:$reg_port$reg_path --image-timeout 15m --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times"
-	echo "cd sync && umask 0022 && $cmd" > sync-mirror.sh && chmod 700 sync-mirror.sh
+	cmd="oc-mirror --v2 --config imageset-config.yaml --workspace file://. docker://$reg_host:$reg_port$reg_path --image-timeout 15m --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times"
+	echo "cd data && umask 0022 && $cmd" > sync-mirror.sh && chmod 700 sync-mirror.sh

 # Line 138: Change error file path
-			error_file=$(ls -t sync/working-dir/logs/mirroring_errors_*_*.txt 2>/dev/null | head -1)
+			error_file=$(ls -t data/working-dir/logs/mirroring_errors_*_*.txt 2>/dev/null | head -1)

 # Lines 148-150: Change saved_errors path
-				mkdir -p sync/saved_errors
-				cp $error_file sync/saved_errors
-				echo_red "[ABA] Error detected and log file saved in sync/saved_errors/$(basename $error_file)" >&2
+				mkdir -p data/saved_errors
+				cp $error_file data/saved_errors
+				echo_red "[ABA] Error detected and log file saved in data/saved_errors/$(basename $error_file)" >&2
```

---

### 3. scripts/reg-load.sh

```diff
 # Lines 51-52: Change missing directory check
-if [ ! -d save ]; then
-	aba_abort "Error: Missing 'mirror/save' directory!  For air-gapped environments, run 'aba -d mirror save' first on an external (Internet connected) bastion/laptop" 
+if [ ! -d data ]; then
+	aba_abort "Error: Missing 'mirror/data' directory!  For air-gapped environments, run 'aba -d mirror save' first on an external (Internet connected) bastion/laptop" 

 # Line 56: Change message
-aba_info "Now loading (disk2mirror) the images from mirror/save/ directory to registry $reg_host:$reg_port$reg_path."
+aba_info "Now loading (disk2mirror) the images from mirror/data/ directory to registry $reg_host:$reg_port$reg_path."

 # Line 87: Change config file path
-	cmd="oc-mirror --v2 --config imageset-config-save.yaml --from file://. docker://$reg_host:$reg_port$reg_path --image-timeout 15m --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times"
+	cmd="oc-mirror --v2 --config imageset-config.yaml --from file://. docker://$reg_host:$reg_port$reg_path --image-timeout 15m --parallel-images $parallel_images --retry-delay ${retry_delay}s --retry-times $retry_times"

 # Line 88: Change cd directory
-	echo "cd save && umask 0022 && $cmd" > load-mirror.sh && chmod 700 load-mirror.sh 
+	echo "cd data && umask 0022 && $cmd" > load-mirror.sh && chmod 700 load-mirror.sh 

 # Line 107: Change error file path
-			error_file=$(ls -t save/working-dir/logs/mirroring_errors_*_*.txt 2>/dev/null | head -1)
+			error_file=$(ls -t data/working-dir/logs/mirroring_errors_*_*.txt 2>/dev/null | head -1)

 # Lines 117-119: Change saved_errors path
-				mkdir -p save/saved_errors
-				cp $error_file save/saved_errors
-				aba_warning "An error was detected and the log file was saved in save/saved_errors/$(basename $error_file)"
+				mkdir -p data/saved_errors
+				cp $error_file data/saved_errors
+				aba_warning "An error was detected and the log file was saved in data/saved_errors/$(basename $error_file)"
```

---

### 4. scripts/reg-create-imageset-config-save.sh → scripts/reg-create-imageset-config.sh

**Action:** Rename file and consolidate both save and sync config generation.

```diff
 # Lines 23-24: Change directory creation
-# Note that any existing save/* files will not be deleted
-mkdir -p save 
+# Note that any existing data/* files will not be deleted
+mkdir -p data

+# Determine operation type based on calling context or parameter
+# Usage: reg-create-imageset-config.sh [save|sync]
+operation="${1:-save}"  # default to save for backward compat

 # Lines 31-72: Consolidate config generation
-if [ ! -s save/imageset-config-save.yaml -o save/.created -nt save/imageset-config-save.yaml ]; then
+if [ ! -s data/imageset-config.yaml -o data/.created -nt data/imageset-config.yaml ]; then
 	[ ! "$ocp_channel" -o ! "$ocp_version" ] && aba_abort "ocp_channel or ocp_version incorrectly defined in aba.conf"
 	
 	export ocp_ver_major=$(echo $ocp_version | cut -d. -f1-2)
 	
-	aba_info "Generating image set configuration: save/imageset-config-save.yaml to save images to local disk ..."
+	if [ "$operation" = "save" ]; then
+		aba_info "Generating image set configuration: data/imageset-config.yaml to save images to local disk ..."
+	else
+		aba_info "Generating image set configuration: data/imageset-config.yaml to sync images to the mirror registry ..."
+	fi
+	
 	[ ! "$excl_platform" ] && aba_info "OpenShift platform release images for 'v$ocp_version', channel '$ocp_channel' and arch '$ARCH' ..."
 	
 	aba_debug Values: ARCH=$ARCH ocp_channel=$ocp_channel ocp_version=$ocp_version
-	scripts/j2 ./templates/imageset-config-save-$oc_mirror_version.yaml.j2 > save/imageset-config-save.yaml
-	touch save/.created
+	scripts/j2 ./templates/imageset-config-$oc_mirror_version.yaml.j2 > data/imageset-config.yaml
+	touch data/.created
 	
-	scripts/add-operators-to-imageset.sh --output save/imageset-config-save.yaml
-	touch save/.created
+	scripts/add-operators-to-imageset.sh --output data/imageset-config.yaml
+	touch data/.created
 	
-	[ "$excl_platform" ] && sed -i -E "/ platform:/,/ graph: true/ s/^/#/" save/imageset-config-save.yaml
-	touch save/.created
+	[ "$excl_platform" ] && sed -i -E "/ platform:/,/ graph: true/ s/^/#/" data/imageset-config.yaml
+	touch data/.created
 	
-	aba_info_ok "Image set config file created: mirror/save/imageset-config-save.yaml ($ocp_channel-$ocp_version $ARCH)"
+	aba_info_ok "Image set config file created: mirror/data/imageset-config.yaml ($ocp_channel-$ocp_version $ARCH)"
 	aba_info    "Reminder: Edit this file to add more content, e.g. Operators, and then run 'aba -d mirror save' again."
 else
-	aba_info "Using existing image set config file (save/imageset-config-save.yaml)"
+	aba_info "Using existing image set config file (data/imageset-config.yaml)"
 fi
```

---

### 5. scripts/reg-create-imageset-config-sync.sh

**Action:** DELETE this file (functionality merged into reg-create-imageset-config.sh)

---

### 6. scripts/check-version-mismatch.sh

```diff
 # Line 2: Update comment
-# This script compares the OpenShift target version in aba.conf with versions defined in any existing imageset config files under sync/ or save/
+# This script compares the OpenShift target version in aba.conf with versions defined in any existing imageset config file under data/

 # Lines 13-60: Simplify to check single location
-if [ ! -s sync/imageset-config-sync.yaml -a ! -s save/imageset-config-save.yaml ]; then
+if [ ! -s data/imageset-config.yaml ]; then
 	exit 0
 fi
 
-if [ -s save/imageset-config-save.yaml ]; then
-	# Don't run version check if user has updated the imageset conf file
-	[ save/.created -nt save/imageset-config-save.yaml ] && exit 0
-
-	aba_info "Checking OpenShift version in aba.conf against value in save/imageset-config-save.yaml ..."
-
-	# Get the version and channel from save/imageset-config-save.yaml
-	ver_channel=$(grep -A2 'platform:' save/imageset-config-save.yaml | grep 'name:' | awk '{print $NF}' | head -1)
-
-	save_version=$(echo $ver_channel | cut -d'-' -f2)
-	save_channel=$(echo $ver_channel | cut -d'-' -f1)
-fi
-
-if [ -s sync/imageset-config-sync.yaml ]; then
-	# Don't run version check if user has updated the imageset conf file
-	[ sync/.created -nt sync/imageset-config-sync.yaml ] && exit 0
-
-	aba_info "Checking OpenShift version in aba.conf against value in sync/imageset-config-sync.yaml ..."
-
-	# Get the version and channel from sync/imageset-config-sync.yaml
-	ver_channel=$(grep -A2 'platform:' sync/imageset-config-sync.yaml | grep 'name:' | awk '{print $NF}' | head -1)
-
-	sync_version=$(echo $ver_channel | cut -d'-' -f2)
-	sync_channel=$(echo $ver_channel | cut -d'-' -f1)
-fi
+# Don't run version check if user has updated the imageset conf file
+[ data/.created -nt data/imageset-config.yaml ] && exit 0
 
-for f in sync/imageset-config-sync.yaml save/imageset-config-save.yaml
-do
-	[ ! -s $f ] && continue
+aba_info "Checking OpenShift version in aba.conf against value in data/imageset-config.yaml ..."
 
-	# Get the version and channel from imageset config files 
-	ver_channel=$(grep -A2 'platform:' $f | grep 'name:' | awk '{print $NF}' | head -1)
-	imageset_version=$(echo $ver_channel | cut -d'-' -f2)
-	imageset_channel=$(echo $ver_channel | cut -d'-' -f1)
-
-	if [ "$imageset_version" != "$ocp_version" -o "$imageset_channel" != "$ocp_channel" ]; then
-		aba_abort \
-			"Version mismatch detected between aba.conf and $f!" \
-			"The aba.conf file has channel=$ocp_channel version=$ocp_version (line ~32, using notation: $ocp_channel-$ocp_version)" \
-			"The imageset config file has channel=$imageset_channel version=$imageset_version (using notation: $imageset_channel-$imageset_version)" \
-			"These values must match!" \
-			"Either update the aba.conf file or delete the imageset config file: rm $f" 
-	fi
-done
+# Get the version and channel from data/imageset-config.yaml
+ver_channel=$(grep -A2 'platform:' data/imageset-config.yaml | grep 'name:' | awk '{print $NF}' | head -1)
+
+config_version=$(echo $ver_channel | cut -d'-' -f2)
+config_channel=$(echo $ver_channel | cut -d'-' -f1)
+
+if [ "$config_version" != "$ocp_version" -o "$config_channel" != "$ocp_channel" ]; then
+	aba_abort \
+		"Version mismatch detected between aba.conf and data/imageset-config.yaml!" \
+		"The aba.conf file has channel=$ocp_channel version=$ocp_version (line ~32, using notation: $ocp_channel-$ocp_version)" \
+		"The imageset config file has channel=$config_channel version=$config_version (using notation: $config_channel-$config_version)" \
+		"These values must match!" \
+		"Either update the aba.conf file or delete the imageset config file: rm data/imageset-config.yaml" 
+fi
```

---

### 7. scripts/day2.sh

```diff
 # Line 5-6: Update comment
-# Apply the imageContentSourcePolicy resource files that were created by oc-mirror (make sync/load)
-## This script also solves the problem that multiple sync/save runs do not containing all ICSPs. See: https://github.com/openshift/oc-mirror/issues/597 
+# Apply the imageContentSourcePolicy resource files that were created by oc-mirror
+## This script also solves the problem that multiple operations do not containing all ICSPs. See: https://github.com/openshift/oc-mirror/issues/597 

 # Line 54: Update comment
-aba_info "- Apply any/all idms/itms resource files under aba/mirror/save/working-dir/cluster-resources that were created by oc-mirror (aba -d mirror sync/load)."
+aba_info "- Apply any/all idms/itms resource files under aba/mirror/data/working-dir/cluster-resources that were created by oc-mirror."

 # Line 121: Update comment
-# mirror/sync/working-dir/cluster-resources/itms-oc-mirror.yaml
+# mirror/data/working-dir/cluster-resources/itms-oc-mirror.yaml

 # Line 243: Update warning message
-	aba_warning "Missing oc-mirror working directory: $PWD/mirror/save/working-dir and/or $PWD/mirror/sync/working-dir"
+	aba_warning "Missing oc-mirror working directory: $PWD/mirror/data/working-dir"
```

---

### 8. scripts/backup.sh

```diff
 # Lines 81-84: Update exclusion paths
-	! -path "aba/mirror/sync/working-dir*"  		\
-	! -path "aba/mirror/save/working-dir*"			\
-	! -path "aba/mirror/sync/oc-mirror-workspace*"  	\
-	! -path "aba/mirror/save/oc-mirror-workspace*"		\
+	! -path "aba/mirror/data/working-dir*"			\
+	! -path "aba/mirror/data/oc-mirror-workspace*"		\

 # Line 113: Update message (commented out line, but update for consistency)
-	#echo_magenta "           The image set archive file(s) are located at $PWD/aba/mirror/save/mirror_*.tar." >&2
+	#echo_magenta "           The image set archive file(s) are located at $PWD/aba/mirror/data/mirror_*.tar." >&2

 # Line 119: Update message
-	echo_magenta "           The image-set archive(s) are located at: $PWD/aba/mirror/save/mirror_*.tar" >&2
+	echo_magenta "           The image-set archive(s) are located at: $PWD/aba/mirror/data/mirror_*.tar" >&2

 # Line 137: Update command example
-	aba_info " cp mirror/save/mirror_*.tar </path/to/your/portable/media/usb-stick/or/thumbdrive>"
+	aba_info " cp mirror/data/mirror_*.tar </path/to/your/portable/media/usb-stick/or/thumbdrive>"

 # Line 141: Update instructions
-	aba_info "then move the image set archive file(s) into the aba/mirror/save/ directory & continue by installing & running 'aba', for example, with the commands:"
+	aba_info "then move the image set archive file(s) into the aba/mirror/data/ directory & continue by installing & running 'aba', for example, with the commands:"

 # Line 143: Update command example
-	aba_info "  mv mirror_*.tar aba/mirror/save"
+	aba_info "  mv mirror_*.tar aba/mirror/data"
```

---

### 9. scripts/make-bundle.sh

```diff
 # Lines 90-96: Update save/ references
-if [ -d mirror/save -a "$(ls mirror/save 2>/dev/null)" ]; then
-	aba_debug "Deleting existing mirror/save directory contents"
-	aba_warning "Deleteing all files under aba/mirror/save! (--force set)" >&2
-	rm -rf mirror/save
-	aba_debug "mirror/save directory removed"
+if [ -d mirror/data -a "$(ls mirror/data 2>/dev/null)" ]; then
+	aba_debug "Deleting existing mirror/data directory contents"
+	aba_warning "Deleting all files under aba/mirror/data! (--force set)" >&2
+	rm -rf mirror/data
+	aba_debug "mirror/data directory removed"
 else
-	aba_debug "mirror/save directory is empty or doesn't exist"
+	aba_debug "mirror/data directory is empty or doesn't exist"
 fi

 # Lines 129-154: Update config file checks
-if [ -d mirror/save ]; then
-	aba_debug "mirror/save directory exists, checking for existing files"
-	if [ mirror/save/imageset-config-save.yaml -nt mirror/save/.created ]; then
-		aba_debug "imageset-config-save.yaml has been modified since creation"
+if [ -d mirror/data ]; then
+	aba_debug "mirror/data directory exists, checking for existing files"
+	if [ mirror/data/imageset-config.yaml -nt mirror/data/.created ]; then
+		aba_debug "imageset-config.yaml has been modified since creation"
 		# Detect if any image-set archive files exist
-		ls mirror/save/mirror_*\.tar >/dev/null 2>&1 && image_set_files_exist=1
+		ls mirror/data/mirror_*\.tar >/dev/null 2>&1 && image_set_files_exist=1
 		aba_debug "Image-set archive files exist: ${image_set_files_exist:-no}"
 
-		if [ -s mirror/save/imageset-config-save.yaml -o -f mirror/mirror.conf -o "$image_set_files_exist" ]; then
+		if [ -s mirror/data/imageset-config.yaml -o -f mirror/mirror.conf -o "$image_set_files_exist" ]; then
 			aba_debug "Repository appears to be in use - prompting user"
-			aba_warning "This repo is already in use!  Modified files exist under: mirror/save"
-			echo -n "         " >&2;  ls mirror/save >&2
+			aba_warning "This repo is already in use!  Modified files exist under: mirror/data"
+			echo -n "         " >&2;  ls mirror/data >&2
 			[ "$image_set_files_exist" ] && \
 			echo_red "         Image set archive file(s) also exist." >&2
-			echo_red "         Back up any required files and try again with the '--force' flag to delete all existing files under mirror/save" >&2
+			echo_red "         Back up any required files and try again with the '--force' flag to delete all existing files under mirror/data" >&2
 			echo_red "         Or, use a fresh Aba repo and try again!" >&2 
 			ask "         Files will be overwirtten. Continue anyway" >&2 || exit 1
 			aba_debug "User confirmed to continue with existing files"
@@ -148,11 +148,11 @@
 			aba_debug "No conflicting files found"
 		fi
 	else
-		aba_debug "imageset-config-save.yaml not modified or doesn't exist"
+		aba_debug "imageset-config.yaml not modified or doesn't exist"
 	fi
 else
-	aba_debug "mirror/save directory doesn't exist - fresh installation"
+	aba_debug "mirror/data directory doesn't exist - fresh installation"
 fi

 # Line 226: Update message
-			"aba/mirror/save/mirror_000001.tar, and then a full copy of the Aba repository will be written" \
+			"aba/mirror/data/mirror_000001.tar, and then a full copy of the Aba repository will be written" \
```

---

### 10. scripts/aba.sh

```diff
 # Lines 875-884: Update path check
-	if [ ! "$(ls mirror/save/mirror_*tar 2>/dev/null)" ]; then
+	if [ ! "$(ls mirror/data/mirror_*tar 2>/dev/null)" ]; then
 		aba_abort \
 			"Cannot continue! This bundle is configured to load images into a registry (disconnect/airgapped mode)." \
 			"Images must be saved to disk on a 'connected' host using 'aba -d mirror save'." \
-			"Then the image archive file(s): mirror_*.tar (often large, 10+ GB each) must be" \
-			"moved or copied into the install bundle under the aba/mirror/save directory before continuing!"
+			"The image archive file(s): mirror_*.tar (often large, 10+ GB each) must be" \
+			"moved or copied into the install bundle under the aba/mirror/data directory before continuing!"
 
-		echo_white "  cp /path/to/portable/media/mirror_*.tar aba/mirror/save/" 
+		echo_white "  cp /path/to/portable/media/mirror_*.tar aba/mirror/data/" 
```

---

### 11. scripts/verify-release-image.sh

```diff
 # Line 44: Update comment
-			"Did you complete running a 'sync' or 'save/load' operation to copy the images into your registry?" \
+			"Did you complete running a 'sync' or 'save & load' operation to copy the images into your registry?" \
```

---

### 12. tui/abatui.sh

```diff
 # Line 2140: Update config path
-	local isconf_file="$ABA_ROOT/mirror/save/imageset-config-save.yaml"
+	local isconf_file="$ABA_ROOT/mirror/data/imageset-config.yaml"

 # Line 2920: Update cleanup path
-	rm -f "$ABA_ROOT/mirror/save/imageset-config-save.yaml" 2>/dev/null || true
+	rm -f "$ABA_ROOT/mirror/data/imageset-config.yaml" 2>/dev/null || true
```

---

### 13. mirror/Makefile

**Action:** Review and update all targets that reference save/ or sync/

Changes needed:
- Update `.save` target to use `data/`
- Update `.sync` target to use `data/`
- Update calls to `reg-create-imageset-config-save.sh` → `reg-create-imageset-config.sh`
- Update calls to `reg-create-imageset-config-sync.sh` → `reg-create-imageset-config.sh sync`
- Update any directory creation targets
- Update cleanup targets

---

### 14. Template Files

**Actions:**

1. **Rename:**
   - `templates/imageset-config-save-v1.yaml.j2` → `templates/imageset-config-v1.yaml.j2`
   - `templates/imageset-config-save-v2.yaml.j2` → `templates/imageset-config-v2.yaml.j2`

2. **Delete:**
   - `templates/imageset-config-sync-v1.yaml.j2` (functionality merged)
   - `templates/imageset-config-sync-v2.yaml.j2` (functionality merged)

3. **Template Content:**
   - Review if save vs sync templates have any differences
   - If differences exist, make unified template handle both cases
   - Likely they're identical or nearly identical

---

### 15. Test Files

**Files to update** (replace all save/ and sync/ references with data/):

- `test/test5-airgapped-install-local-reg.sh`
- `test/test2-airgapped-existing-reg.sh`
- Any other test files that reference `save/` or `sync/`

Search and replace:
- `mirror/save/imageset-config-save.yaml` → `mirror/data/imageset-config.yaml`
- `mirror/sync/imageset-config-sync.yaml` → `mirror/data/imageset-config.yaml`
- `save/imageset-config-save.yaml` → `data/imageset-config.yaml`
- `sync/imageset-config-sync.yaml` → `data/imageset-config.yaml`
- References to `save/` and `sync/` directories

---

## Implementation Checklist

### Phase 1: Preparation
- [ ] Read mirror/Makefile to understand all targets
- [ ] Read template files to compare save vs sync differences
- [ ] Identify all test files affected
- [ ] Create comprehensive test plan

### Phase 2: Core Scripts
- [ ] Update reg-save.sh
- [ ] Update reg-sync.sh
- [ ] Update reg-load.sh
- [ ] Consolidate reg-create-imageset-config-*.sh → reg-create-imageset-config.sh
- [ ] Delete reg-create-imageset-config-sync.sh
- [ ] Update check-version-mismatch.sh

### Phase 3: Support Scripts
- [ ] Update day2.sh
- [ ] Update backup.sh
- [ ] Update make-bundle.sh
- [ ] Update aba.sh
- [ ] Update verify-release-image.sh

### Phase 4: UI & Config
- [ ] Update tui/abatui.sh
- [ ] Update mirror/Makefile

### Phase 5: Templates
- [ ] Rename template files
- [ ] Delete obsolete sync templates
- [ ] Verify template content

### Phase 6: Tests
- [ ] Update all test files
- [ ] Run comprehensive tests
- [ ] Verify save workflow
- [ ] Verify sync workflow
- [ ] Verify load workflow
- [ ] Verify bundle creation

### Phase 7: Finalization
- [ ] Update README.md
- [ ] Update any other documentation
- [ ] Final testing
- [ ] Commit with detailed message
- [ ] Push to dev branch

---

## Testing Plan

### Test Scenarios

1. **Save Workflow (Connected → Disk)**
   - `aba -d mirror save`
   - Verify `data/imageset-config.yaml` created
   - Verify `data/mirror_*.tar` created
   - Verify working-dir structure

2. **Sync Workflow (Connected → Registry)**
   - `aba -d mirror install`
   - `aba -d mirror sync`
   - Verify `data/imageset-config.yaml` created
   - Verify images synced to registry
   - Verify working-dir structure

3. **Load Workflow (Disk → Registry)**
   - Copy `data/` from connected host
   - `aba -d mirror load`
   - Verify images loaded to registry
   - Verify working-dir used correctly

4. **Bundle Creation**
   - `aba bundle`
   - Verify `data/` included correctly
   - Verify archive files included
   - Test bundle extraction and usage

5. **Operator Addition**
   - Add operators to `data/imageset-config.yaml`
   - Re-run save/sync/load
   - Verify operators included

6. **Day2 Operations**
   - Install cluster
   - Run `aba day2`
   - Verify working-dir resources applied correctly

---

## Breaking Changes

**User Impact:**
- Users must re-install aba or manually migrate data
- Old `save/` and `sync/` directories will be ignored
- Existing imageset configs must be recreated

**Migration Note for Users:**
```bash
# No automatic migration provided
# Users must either:
# 1. Re-install aba fresh (recommended)
# 2. Manually recreate imageset configs with new aba commands
```

---

## Commit Message Template

```
Consolidate mirror/save and mirror/sync into mirror/data

BREAKING CHANGE: Unified oc-mirror v2 workspace

- Consolidate save/ and sync/ directories into single data/ directory
- Merge imageset config generation into reg-create-imageset-config.sh
- Remove duplicate code paths for v2 workflows
- Simplify user experience with single working directory
- Update all scripts, templates, and tests

Migration: Users must re-install aba. Old save/sync directories ignored.

Files changed:
- Core scripts: reg-save.sh, reg-sync.sh, reg-load.sh
- Config generation: Consolidated into reg-create-imageset-config.sh
- Support: day2.sh, backup.sh, make-bundle.sh, aba.sh
- Templates: Renamed and consolidated imageset configs
- Tests: Updated all test files
- Makefile: Updated mirror/ targets

Rationale:
- oc-mirror v2 uses unified workspace concept
- Reduces code duplication significantly
- Cleaner architecture
- Easier to maintain
```
