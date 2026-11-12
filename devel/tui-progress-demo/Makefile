# Demo Makefile — mirrors ABA's mirror/Makefile structure
#
# ─── Key design decisions ───────────────────────────────────────────
#
# 1. _progress_plan-install is a PREREQ of install (consistent, always).
#    The TUI just calls "make install" — no need to chain
#    "_progress_plan-install install" from the caller.
#
# 2. A parent that always runs a child asks the child for its plan
#    (`script plan`) and emits the whole list before any work.
#    Upgrade asks day2.  Bundle asks save.  The child lists only its
#    own steps and does not know the parent.
#    Sync does not ask install: install runs only when the mirror is
#    missing, so install PLANs and sync PLANs still arrive separately.
#
# 3. Prerequisite ORDER in sync matters for PLAN timing.
#    "install" is listed BEFORE "_progress_plan-sync" so that:
#      a. _progress_plan-install fires first (install PLANs appear)
#      b. install runs (install work happens)
#      c. _progress_plan-sync fires (sync PLANs appear — dialog grows)
#      d. sync work runs
#    If _progress_plan-sync were listed first, sync PLANs would appear before
#    install PLANs — wrong visual order.
#
# 4. Marker files control caching (.init, .rpmsext, .rpmsint, .available).
#    Pre-create them for "cached" mode (Make skips the recipe).
#    Delete them for "fresh" mode (Make builds everything).
#
# ────────────────────────────────────────────────────────────────────

.DELETE_ON_ERROR:
.SILENT:

SCRIPTS := scripts

# ─── install workflow ────────────────────────────────────
# _progress_plan-install checks .available internally and emits nothing
# when the registry is already installed.  This prevents 7 Skipped
# items cluttering the sync dialog for a cached install.

.PHONY: install
install: _progress_plan-install .available

.PHONY: _progress_plan-install
_progress_plan-install:
	WORK_DIR=. bash $(SCRIPTS)/plan.sh install

# Order-only prereqs (|) — .init and .rpmsext must exist but their
# timestamps don't trigger a rebuild of .available.
.available: | .init .rpmsext
	bash $(SCRIPTS)/install-registry.sh
	touch .available

# ─── sync workflow ───────────────────────────────────────
# Prereq order: .init → .rpmsint → install → _progress_plan-sync → preflight → sync
# "install" comes BEFORE "_progress_plan-sync" — see design decision #3 above.

.PHONY: sync
sync: .init .rpmsint install _progress_plan-sync status-preflight data/imageset-config.yaml
	bash $(SCRIPTS)/sync-images.sh

.PHONY: _progress_plan-sync
_progress_plan-sync:
	bash $(SCRIPTS)/plan.sh sync

# ─── save workflow ───────────────────────────────────────

.PHONY: save
save: _progress_plan-save .init .rpmsext data/imageset-config.yaml status-preflight
	bash $(SCRIPTS)/save.sh

.PHONY: _progress_plan-save
_progress_plan-save:
	bash $(SCRIPTS)/plan.sh save

# ─── bundle workflow ─────────────────────────────────────
# One plan, up front. plan.sh bundle asks save.sh for its steps and
# appends Pack bundle. save.sh is not asked again when the work runs.

.PHONY: bundle
bundle: _progress_plan-bundle .init .rpmsext data/imageset-config.yaml status-preflight
	bash $(SCRIPTS)/bundle.sh

.PHONY: _progress_plan-bundle
_progress_plan-bundle:
	bash $(SCRIPTS)/plan.sh bundle

# ─── uninstall workflow ──────────────────────────────────

.PHONY: uninstall
uninstall: _progress_plan-uninstall
	bash $(SCRIPTS)/uninstall-registry.sh

.PHONY: _progress_plan-uninstall
_progress_plan-uninstall:
	bash $(SCRIPTS)/plan.sh uninstall

# ─── upgrade workflow ────────────────────────────────────
# One plan, up front. plan.sh upgrade asks day2.sh for its steps and
# places them between preflight and trigger/wait. No wrapper row.
# `make day2` is the child on its own: it submits only its own plan.

.PHONY: upgrade
upgrade: _progress_plan-upgrade
	bash $(SCRIPTS)/upgrade-preflight.sh
	bash $(SCRIPTS)/day2.sh
	bash $(SCRIPTS)/upgrade-finish.sh

.PHONY: _progress_plan-upgrade
_progress_plan-upgrade:
	bash $(SCRIPTS)/plan.sh upgrade

.PHONY: day2
day2: _progress_plan-day2
	bash $(SCRIPTS)/day2.sh

.PHONY: _progress_plan-day2
_progress_plan-day2:
	bash $(SCRIPTS)/plan.sh day2

# ─── shared prerequisites ────────────────────────────────

.init:
	bash $(SCRIPTS)/init.sh
	touch .init

.rpmsext: .init
	bash $(SCRIPTS)/install-rpms.sh external
	touch .rpmsext

.rpmsint: .init
	bash $(SCRIPTS)/install-rpms.sh internal
	touch .rpmsint

data/imageset-config.yaml: .init
	bash $(SCRIPTS)/generate-isc.sh
	touch data/imageset-config.yaml

.PHONY: status-preflight
status-preflight: .init
	bash $(SCRIPTS)/preflight.sh

# ─── housekeeping ────────────────────────────────────────
.PHONY: clean
clean:
	rm -f .init .rpmsext .rpmsint .available
	rm -rf data
