# Demo Makefile — mirrors ABA's mirror/Makefile structure
#
# ─── Key design decisions ───────────────────────────────────────────
#
# 1. _progress_plan-install is a PREREQ of install (consistent, always).
#    The TUI just calls "make install" — no need to chain
#    "_progress_plan-install install" from the caller.
#
# 2. Each _progress_plan-* target only knows its OWN steps.
#    _progress_plan-sync emits sync PLANs.  It knows nothing about install.
#    When sync depends on install, _progress_plan-install fires first
#    (as install's prereq), emitting install PLANs.
#    Then _progress_plan-sync fires, emitting sync PLANs.
#    The TUI dialog grows as new PLANs arrive.
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
# Bundle wraps save.  _progress_plan-bundle fires first, pre-declaring ALL shared IDs.
# Then _progress_plan-save fires — ALL its IDs already exist, so ZERO new rows appear.
# This demonstrates GLOBAL ID dedup: the receiver discards duplicates silently.

.PHONY: bundle
bundle: _progress_plan-bundle _progress_plan-save .init .rpmsext data/imageset-config.yaml status-preflight
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
