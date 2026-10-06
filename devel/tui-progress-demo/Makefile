# Demo Makefile — mirrors ABA's mirror/Makefile structure
#
# Marker files (.init, .rpmsext, data/imageset-config.yaml) control
# caching.  Pre-create them for "cached" mode (Make skips the recipe).
# Delete them for "fresh" mode (Make builds everything).

.DELETE_ON_ERROR:
.SILENT:

SCRIPTS := scripts

# ─── save workflow ───────────────────────────────────────
# Dependencies mirror the real ABA save target:
#   save: _plan-save .init .rpmsext status-preflight data/imageset-config.yaml
#
# _plan-save is PHONY — always runs, emits PLAN events.
# .init, .rpmsext, data/ISC are marker-file targets — skipped when cached.
# status-preflight is PHONY — always runs.
# The recipe calls save.sh for the actual work.

.PHONY: save
save: _plan-save .init .rpmsext data/imageset-config.yaml status-preflight
	bash $(SCRIPTS)/save.sh

.PHONY: _plan-save
_plan-save:
	bash $(SCRIPTS)/plan.sh save

.init:
	echo "[ABA] Initializing workspace ..."
	sleep 0.5
	touch .init

.rpmsext: .init
	echo "[ABA] Installing required packages ..."
	sleep 0.8
	touch .rpmsext

data/imageset-config.yaml: .init
	mkdir -p data
	echo "[ABA] Generating image set config ..."
	sleep 0.5
	touch data/imageset-config.yaml

.PHONY: status-preflight
status-preflight: .init
	bash $(SCRIPTS)/preflight.sh

# ─── housekeeping ────────────────────────────────────────
.PHONY: clean
clean:
	rm -f .init .rpmsext
	rm -rf data
