# Dell iDRAC9 vendor overlay for Phase 8 BMC-driven boot.
# Sourced (not executed): no shebang, not chmod +x.
# MUST be sourced AFTER scripts/bmc-adapter-generic.sh.
#
# This overlay targets iDRAC9 only. iDRAC10 is hard-failed at preflight by
# _bm_probe_l5_idrac (uses /Systems/System.Embedded.1/Settings for boot override
# patch - structurally different from iDRAC9; deferred to v1.2).
#
# Vendor-specific behavior (no adapter-level overrides needed in v1.1):
#   - Standard /Managers and /Systems collections published; generic discovery
#     populates MANAGER_ID_<node> = iDRAC.Embedded.1, SYSTEM_ID_<node> = System.Embedded.1.
#   - InsertMedia uses standard POST + Actions/VirtualMedia.InsertMedia path.
#   - Stale-media HTTP 500 tolerance: already in generic bmc_eject_media (Phase 6).
#   - URL <=255 char guard: enforced in preflight (PRE-05 extension; D-05c).
#   - iDRAC9 firmware floor (4.40.10.00 Intel / 6.00.00.00 AMD): enforced in
#     _bm_probe_l5_idrac (D-05b).
#
# Hardcoded conventions per Dell iDRAC9 Redfish API Guide:
#   ManagerId = iDRAC.Embedded.1 (discovered, not hardcoded here)
#   MediaId   = CD (discovered)
#   SystemId  = System.Embedded.1 (discovered)
#
# 401 taxonomy: iDRAC9 typically returns 401 for either wrong password or
# session-limit exhaustion (default 8 sessions). Override the taxonomy helper
# so UX-02 reason is clearer than the generic "unknown".

_bm_401_taxonomy() { printf '%s' "iDRAC role lacks LICENSE privileges or session limit (default 8) exhausted"; }

# MAC discovery: generic _bm_get_ethernetinterfaces is sufficient (iDRAC9 publishes standard EthernetInterfaces with NIC.Integrated.<n>-style ids).
