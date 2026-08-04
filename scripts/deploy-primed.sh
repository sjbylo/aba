#!/bin/bash -e
# INTENT:      One-command pipeline for primed cluster deployment on the disconnected side
# CALLED BY:   aba deploy-primed (or aba deploy), from within a cluster directory
# CWD:         A cluster directory (via aba -d <cluster>)
# ARGS:        None
# REQUIRES:    .primed marker (fully pre-configured cluster dir), mirror dir with images
# PRODUCES:    Installed cluster with day-2 configuration applied
# SIDE EFFECTS:
#   - Installs/connects mirror registry (if not already available)
#   - Loads images into registry (if not already loaded)
#   - Generates ISO, boots VMs, monitors installation
#   - Applies day-2 config (CatalogSources, IDMS, custom manifests)
# IDEMPOTENT:  Yes (each step uses Make markers; safe to re-run after interruption)

source scripts/include_all.sh

aba_debug "Starting: $0 $*"

source <(normalize-aba-conf)
source <(normalize-cluster-conf)

mirror_dir="../${mirror_name:-mirror}"

[ ! -d "$mirror_dir" ] && aba_abort "Mirror directory not found: $mirror_dir"
[ ! -f cluster.conf ] && aba_abort "Not in a cluster directory (no cluster.conf found)"

aba_info "Starting primed deployment pipeline for cluster: $(basename "$PWD")"

# Step 1: Ensure mirror registry is installed/connected
aba_info "Step 1/4: Mirror registry ..."
make -C "$mirror_dir" install

# Step 2: Load images (also extracts transfer tars)
aba_info "Step 2/4: Loading images ..."
make -C "$mirror_dir" load

# Step 3: Install cluster (ISO generation, VM boot, monitor)
aba_info "Step 3/4: Installing cluster ..."
make install

# Step 4: Day-2 configuration
aba_info "Step 4/4: Applying day-2 configuration ..."
../scripts/day2.sh

aba_success "Primed deployment complete for cluster: $(basename "$PWD")"
