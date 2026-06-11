# Session State

## Current goal
E2E TUI Full Workflow test on conno/disco (following ai/E2E_TUI_FULL_WORKFLOW.md)

## Done this session
1. **SIGPIPE fix proven and applied** — include_all.sh, tui/v2/tui-mirror.sh, tui/abatui.sh, make-bundle.sh
2. **VMs restarted** on new IPs: conno=10.0.0.10, disco=10.0.0.20
3. **Phase 1-2** — clean conno, TUI wizard, full bundle created (30GB, all tarballs valid)
4. **Phase 3-5** — bundle transferred to disco, ABA installed
5. **Phase 6 in progress** — had to uninstall stale registry from previous session, then reinstalled fresh on disco.example.com:8443. Image load now running (~20-40 min)

## Next steps
- Wait for image load to complete on disco
- Phase 7: Install SNO cluster (ocp.example.com, IP 10.0.1.100) via TUI
- Phase 8: Day-2 operations
- Phase 9: Delete cluster

## Decisions / notes
- conno=10.0.0.10, disco=10.0.0.20
- SNO domain: ocp.example.com, DNS: api + *.apps → 10.0.1.100
- Mirror hostname: disco.example.com:8443
- Bug found: TUI showed "(loaded)" falsely when mirror_000001.tar existed but images weren't pushed
- Bug found: `aba --dir mirror install` reported "Success" when it detected existing running registry without actually re-installing
- SIGPIPE fix NOT yet committed (pending user permission)
- Lesson: always uninstall stale registry before fresh bundle install on a host that had a previous session
