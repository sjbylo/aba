# Demo Makefile — mirrors ABA's mirror/Makefile structure
#
# ─── Key design decisions ───────────────────────────────────────────
#
# 1. _plan-install is a PREREQ of install (consistent, always).
#    The TUI just calls "make install" — no need to chain
#    "_plan-install install" from the caller.
#
# 2. Each _plan-* target only knows its OWN steps.
#    _plan-sync emits sync PLANs.  It knows nothing about install.
#    When sync depends on install, _plan-install fires first
#    (as install's prereq), emitting install PLANs.
#    Then _plan-sync fires, emitting sync PLANs.
#    The TUI dialog grows as new PLANs arrive.
#
# 3. Prerequisite ORDER in sync matters for PLAN timing.
#    "install" is listed BEFORE "_plan-sync" so that:
#      a. _plan-install fires first (install PLANs appear)
#      b. install runs (install work happens)
#      c. _plan-sync fires (sync PLANs appear — dialog grows)
#      d. sync work runs
#    If _plan-sync were listed first, sync PLANs would appear before
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
# _plan-install checks .available internally and emits nothing
# when the registry is already installed.  This prevents 7 Skipped
# items cluttering the sync dialog for a cached install.

.PHONY: install
install: _plan-install .available

.PHONY: _plan-install
_plan-install:
	WORK_DIR=. bash $(SCRIPTS)/plan.sh install

# Order-only prereqs (|) — .init and .rpmsext must exist but their
# timestamps don't trigger a rebuild of .available.
.available: | .init .rpmsext
	bash $(SCRIPTS)/install-registry.sh
	touch .available

# ─── sync workflow ───────────────────────────────────────
# Prereq order: .init → .rpmsint → install → _plan-sync → preflight → sync
# "install" comes BEFORE "_plan-sync" — see design decision #3 above.

.PHONY: sync
sync: .init .rpmsint install _plan-sync status-preflight data/imageset-config.yaml
	bash $(SCRIPTS)/sync-images.sh

.PHONY: _plan-sync
_plan-sync:
	bash $(SCRIPTS)/plan.sh sync

# ─── save workflow ───────────────────────────────────────

.PHONY: save
save: _plan-save .init .rpmsext data/imageset-config.yaml status-preflight
	bash $(SCRIPTS)/save.sh

.PHONY: _plan-save
_plan-save:
	bash $(SCRIPTS)/plan.sh save

# ─── uninstall workflow ──────────────────────────────────

.PHONY: uninstall
uninstall: _plan-uninstall
	bash $(SCRIPTS)/uninstall-registry.sh

.PHONY: _plan-uninstall
_plan-uninstall:
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
