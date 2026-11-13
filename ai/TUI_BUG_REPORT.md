# ABA TUI Bug Report — Hackathon Session October 2026

**Date:** 2026-11-06 (session continued)
**Tester:** AI Agent (Cursor)
**Hosts:** conno.example.com, disco.example.com
**Branch:** dev (bastion HEAD `7a6de7e3`, v1.4.4). conno working tree is behind that commit and was left untouched because `tui-test` was already installing `sno`.
**Focus:** TUI workflows, core code bugs, recent code changes

## Test Flows Attempted

| Flow | Status | Notes |
|------|--------|-------|
| CONNO: TUI startup from scratch | PASSED | Splash, domain, wizard all work |
| CONNO: Wizard (channel → version → platform → operators) | PASSED | stable/4.22.18/vmw/cincinnati-operator |
| CONNO: Mirror install (Docker, local) | PASSED | Docker registry installed on conno.example.com:8443 |
| CONNO: Sync images | PASSED | Synced 4.22.18 + cincinnati-operator |
| CONNO: Cluster install (sno, vmw) | PASSED | sno.example.com installed, 10.0.1.201 |
| CONNO: Day-2 OperatorHub | PASSED | All 8 steps succeeded |
| CONNO: Day-2 NTP | PASSED | Applied and verified on nodes |
| CONNO: Day-2 OSUS | PASSED | Cincinnati operator installed + UpdateService deployed |
| CONNO: Graceful shutdown and startup (sno2) | PASSED | 2026-11-09. `aba -d sno2 shutdown -y` shut the node down over SSH. `aba -d sno2 startup -y` powered it back on. Node `sno2` was Ready, the console answered, and all cluster operators were available. |
| CONNO: Bundle creation (Light) | PASSED | /tmp/ocp-bundle-4.22.18-amd64-lite-op1.tar (2.76GB) |
| CONNO: Install standard (TUI) | FAILED | 2026-11-09. Wizard: standard.example.com, 3 masters + 2 workers, starting 10.0.1.81, API 10.0.1.217, ingress 10.0.1.227, DNS/NTP 10.0.1.8, gateway 10.0.0.1, ens160, mirror. VMs powered on. Bootstrap timed out and 6443 never listened. Deleted from the TUI; the five VMs are gone. |
| CONNO: Install ocp SNO (TUI) | PASSED | 2026-11-09. ocp.example.com, 10.0.1.100, DNS/NTP 10.0.1.8, gateway 10.0.0.1, ens160, mirror. Node Ready. ClusterVersion 4.21.40 Available. OperatorHub: all 8 steps succeeded. |
| CONNO: Full bundle (TUI) | PASSED | 2026-11-09. Incremental full bundle. File `/tmp/ocp-bundle-4.21.40-amd64-rel-op1.tar` (32G). All eight steps succeeded, including Pack bundle. Disk warning said 49G free; 14G remained after the tar. |
| DISCO: Load full bundle (TUI) | PASSED | 2026-11-09. The image archive and transfer tar from that bundle replaced disco `mirror/data`. Load of 4.21.40 plus cincinnati-operator succeeded. Day-2 on sno applied the catalog and signatures. |
| CONNO: Direct install compact2 (TUI) | PASSED | 2026-11-09. Fully Connected. compact2.example.com, 3 masters, starting 10.0.1.91, API 10.0.1.212, ingress 10.0.1.222. The lab gateway did not route to quay.io, so the bastion forwarded the lab subnet and the node gateway was pointed at the bastion. Release images pulled from quay.io. Three masters Ready. ClusterVersion 4.21.40 Available. |
| CONNO: Upgrade sno2 (TUI) | PASSED | 2026-11-09. Prepare Upgrade synced 4.21.40 to 4.21.42 (383 release images, 5 operator images). Day-2 OperatorHub on sno2, then Upgrade to 4.21.42 with Force left off. ClusterVersion history Completed 4.21.42, Available, Progressing false. Node Ready. |
| CONNO: Virtualization day-2 (TUI) | PASSED | 2026-11-09. Mirrored the virt operator set (mtv and volsync left out so the sync would fit) plus the 5 guest images. Subscribed kubevirt-hyperconverged on ocp; CSV 4.21.24 Succeeded and HyperConverged was healthy. Day-2 Virtualization Boot Sources then succeeded: CentOS, Fedora, and RHEL 9/10 boot sources point at conno.example.com:8443. |
| DISCO: TUI startup + bundle detection | PASSED | Light bundle correctly detected, asked for archives |
| DISCO: Bundle transfer + TUI | SKIPPED | 23GB transfer too slow for session; light bundle detection worked |
| DISCO: Mirror install + load | PENDING | Requires full bundle or archive transfer |
| DISCO: Cluster install | PENDING | |
| DIRECT: Install cluster | PENDING | |
| Upgrade workflow (TUI) | CODE-REVIEWED | Upgrade version picker, conditional version warnings, manual entry, force toggle — all solid |
| CONNO: sno2 TUI upgrade 4.21.40→4.21.42 | PASSED | 2026-11-09 22:57. ClusterVersion Available=True Progressing=False at **4.21.42**. All ClusterOperators Available on 4.21.42; node sno2 Ready. Mid-upgrade API briefly unreachable (~22:43–22:47) while waiting on machine-config (expected node reboot). TUI pane afterward showed an unrelated mirror sync at 25% (not the upgrade dialog). Day-2 Virtualization is next. |
| CONNO: sno2 Day-2 Virtualization (post-upgrade) | PENDING | Starts after 4.21.42 upgrade (per hackathon plan). |
| VMware config from scratch | CODE-REVIEWED | _configure_vmw_form: test connection, field validation, all fields saved correctly |
| KVM config from scratch | CODE-REVIEWED | _configure_kvm_form: same pattern, libvirt URI test, all fields saved |
| Delete installing cluster | NOT RUN | conno `sno` install was already in progress in tmux `tui-test` (another session). Did not delete it. |
| ESC key behavior | PASSED | disco `tui-debugging`: ESC from Day-2 and from the cluster wizard returns to the parent menu. ESC from the wizard does not undo a platform toggle (Bug #1012). |
| DISCO: main menu with Quay already loaded | PASSED | mirror ready, `(loaded 4.21.40)`, registry `(installed)`. Switch to connected is blocked when internet is down. |
| DISCO: cluster wizard name + platform | FAILED | Bugs #1012 and #1014. Platform restored to `vmw` afterwards. |
| DISCO: Refresh on never-installed cluster | FAILED | Bug #1013. Dialog cancelled (default No). |
| DISCO: wizard networking | FAILED | Bug #1015. Out-of-CIDR starting IP accepted and written, then restored to 10.0.1.201. |
| DISCO: wizard image source | FAILED | Bug #1016. Selecting mirror in DISCO does nothing. |
| Menu status labels | PARTIAL | Sync/install labels correct; Bug #1001 FIXED |
| Help text accuracy | FAILED | Prepare Upgrade help on conno, 2026-11-07. Bug #1017. |
| CONNO: main menu vs mirror version | PASSED | Payload 4.21.40, sync label `(synced 4.22.22)`. Bug #945 now shows the mirrored version. |
| CONNO: rc version in Prepare Upgrade | FAILED | Manual `4.21.0-rc.2` on fast. Bug #1018. Cancelled; config unchanged. |
| CONNO: Create Install Bundle | FAILED | Summary said `4.21.40 → 4.22.22` (Bug #1019). Light bundle completed: `/tmp/ocp-bundle-4.21.40-amd64-lite.tar` (4.3G). Menu then says saved 4.22.22. Bug #1044. |
| CONNO: Advanced Clean ABA copy | FAILED | Help, menu, and confirm disagree. Bug #1020. Confirm cancelled. |
| CONNO: OCP version list and rc entry | FAILED | Latest 5.0.1, Previous 4.22.22. Bugs #1021 and #1022. Config unchanged. |
| CONNO: EUS channel | FAILED | Version screen has no EUS. Prepare Upgrade channel list does. Bug #1023. Channel stayed fast. |
| CONNO: Confirm Exit default | FAILED | ESC focuses Exit. Bug #1024. Continue was selected. |
| CONNO: main menu help | FAILED | Help lists Monitor Installation. The menu does not. Bug #1025. |
| DISCO: wizard machine network | FAILED | `10.0.1.5/20` accepted and written. Bug #1026. Restored `10.0.0.0/20`. |
| DISCO: wizard VLAN leading zero | FAILED | `09` accepted. Bug #1027. Cleared before exit. `vlan=` stayed empty. |
| DISCO: wizard master memory | FAILED | `08` accepted below the 16 GB minimum. Bug #1028. Row restored to 20 GB. File unchanged. |
| DISCO: wizard gateway | FAILED | `192.168.9.1` accepted and written. Bug #1015. Restored `next_hop_address=10.0.0.1`. |
| DISCO: wizard MAC template | FAILED | Prompt example `52:54:00` rejected. Bug #1029. `mac_prefix` unchanged. |
| CONNO: operator name search | FAILED | Search `operator` stops at `rook-ceph-operator`. Bug #1030. Nothing added. |
| DISCO: install review default | FAILED | Review focuses Install. Bug #1031. Back was selected. No install started. |
| CONNO: Additional Images help | FAILED | Empty menu is Add, Recommended, Edit. Help lists List, Remove, and Delete all. Bug #1032. |
| DISCO: wizard base domain | FAILED | `_lab.example.com` accepted. Bug #1033. Restored `example.com`. File unchanged. |
| DISCO: interfaces help | FAILED | VMware menu has SSH key and no MACs row. Help is the reverse. Bug #1034. |
| DISCO: Advanced help vs uninstall | FAILED | Help says uninstall deletes all images and describes Clean. Bug #1035. Uninstall cancelled. |
| DISCO: wizard basics help | FAILED | Menu has Base domain. Page 1 help does not. Bug #1036. |
| DISCO: wizard port name length | FAILED | 16-character name accepted. Bug #1037. Restored `ens160`. File unchanged. |
| DISCO: wizard MAC template cleared | FAILED | Empty value shows `(auto)`. Bug #1038. Prefix restored. File unchanged. |
| DISCO: wizard DNS leading zero | FAILED | `10.0.1.08` accepted. Bug #1039. Restored `10.0.1.8`. File unchanged. |
| DISCO: Day-2 SSH with no install | FAILED | Says "Create an ISO first." Bug #1040. No `iso-agent-based` directory. |
| DISCO: Delete never-installed cluster | FAILED | Confirm says it destroys VMs. Command says config files are missing. Bug #1041. `cluster.conf` kept. |
| DISCO: sno install (vmw) | FAILED then retried | Timed out at 17:24 (Bugs #1042, #1043, #1045, #1046, #1047). Retry waited for the dead agent (Bug #1048), then Monitor succeeded at 17:58. |
| DISCO: Day-2 OperatorHub | PASSED | All 8 steps succeeded. No operators were configured, so CatalogSources were skipped. |
| DISCO: Day-2 NTP | PASSED | All 3 steps succeeded. Chrony MachineConfigs applied without a reboot. |
| DISCO: Day-2 OSUS | FAILED | No mirrored operators. Continue re-ran day2, then failed. Dialog says Access cluster failed. Bug #1049. |
| DISCO: Day-2 cluster status | PASSED | Node sno Ready, operators Available. Three installer pods are Error. |
| DISCO: Day-2 SSH | PASSED | core@10.0.1.201, hostname sno. chronyc shows 10.0.1.8 selected. |
| DISCO: Day-2 login | PASSED | kube:admin. ClusterVersion 4.21.40 Available, not progressing. |
| DISCO: Day-2 upgrade | FAILED | No versions, which matches the 4.21.40 mirror. The hint says press U on the connected host. Bug #1050. |
| DISCO: Day-2 virtualization | FAILED | Operator is absent. The command exits 0. The dialog says Stopped. Bug #1051. |
| DISCO: Day-2 shutdown | PASSED | All 4 steps succeeded. Nodes powered off. Confirm had defaulted to Cancel. |
| DISCO: Day-2 startup | PASSED | All 6 steps succeeded. Console is up. Operators are available. |
| DISCO: Day-2 Clean on installed cluster | FAILED | Row says retry install. Dialog refuses because `.install-complete` exists. Bug #1052. |
| DISCO: Delete installed cluster | PASSED | Picker says installed. Confirm says it destroys the VMs. Cancel was focused. Help matches. Cancelled. |
| DISCO: internet up, switch mode | PASSED | `internet.sh up` brought up ens192. Switch to partially disconnected was offered. Switch was focused. Cancelled. `.bundle` kept. Internet put back down. |
| CONNO: Stop and start mirror | PASSED | Quay stopped, then started. `https://conno.example.com:8443` returned 200. Menu still says installed. |
| CONNO: Switch to fully disconnected | PASSED | Warning explains the bundle workflow. No was focused (`--defaultno`). Cancelled. Mode stayed partially disconnected. Section headers are selectable. Bug #1056. |
| CONNO: Switch to fully connected and back | PASSED | Direct menu has Install and Day-2 only. Help matches that menu. Switched back. Mirror rows returned. Title is Partially Disconnected again. |
| CONNO: Rerun Wizard resume | PASSED | Resume showed fast, 4.21.40, platform vmw. Continue was focused. Returned to the menu. `aba.conf` unchanged. |
| CONNO: direct install sno2 | FAILED | VM booted and answered ping. The agent never started. The console shows DNS for quay.io works and there is no route to it (Bug #1057). The VM was then deleted. Confirm named sno2 and said it destroys the VMs. Cancel was focused. Delete destroyed folder `/Datacenter/vm/sno2`. `cluster.conf` remains. |
| CONNO: Configure settings | PASSED | Settings shows Registry Type Auto and Retry Count 1. Help matches. Back left `reg_vendor=auto`. |
| CONNO: Mirror Payload headers | FAILED | `──── Include / Exclude ─────` can be highlighted. Enter does nothing. Release Images stayed included. Same as Bug #1056. |
| CONNO: Day-2 with no install | FAILED | SSH says "Create an ISO first" (Bug #1040). Status and OperatorHub say "No installed clusters found." Clean for sno2 names the artifacts and keeps Cancel focused. Delete for sno2 says it destroys the VMs (Bug #1041). Both confirms were cancelled. |
| CONNO: Refresh never-installed sno2 | FAILED | Confirm says it will destroy existing VMs and start a fresh install (Bug #1058). sno2 has no VMs. Cancel was focused. Cancelled. |
| CONNO: View ImageSet | PASSED | Advanced → View shows fast-4.21 min and max 4.21.40. Operators are commented out. The main menu still says synced and saved 4.22.22 (Bug #1044). Edit and Reset were not used. |
| CONNO: Advanced help | FAILED | Help lists `F` Monitor Cluster Installation. The menu has no F row, because nothing is installing. Help also names Y. This menu has X and Z only. Bug #1059. |
| CONNO: Sync confirm | PASSED | Confirm says OCP 4.21.40 fast, operators none. Continue was focused. Back was selected. No sync started. The menu still says synced 4.22.22 (Bug #1044). |
| DISCO: Day-2 section header | FAILED | `──── Cleanup ────` can be highlighted. Enter does nothing. Same as Bug #1056. |
| CONNO: reinstall mirror prompt | PASSED | "Mirror registry is already installed. Reinstall it?" No was focused. Cancelled. The registry was left installed. |
| DISCO: Day-2 help | FAILED | Help says startup powers on VMs and delete destroys them. Bare metal does neither. Bug #1060. |
| CONNO: Create Install Bundle recheck | PASSED | Summary now says OCP 4.21.40 fast, operators none. ImageSet max is 4.21.40. The 4.22.22 arrow from Bug #1019 is gone. Dialog cancelled. No bundle started. Menu still says saved 4.22.22 (Bug #1044). |
| DISCO: View Mirror Payload | PASSED | Read-only ImageSet is fast-4.21, min and max 4.21.40. Operators are commented out. The menu says loaded 4.21.40. |
| DISCO: Load confirm | PASSED | The log says the confirm was taken from `aba-transfer.tar`. It says OCP 4.21.40 fast, operators none, which matches the menu `(loaded 4.21.40)`. Continue was focused. Back was selected. No load started. |
| DISCO: Refresh deleted sno2 | FAILED | No `state.sh`. The dialog says sno2 was installed on bare metal, so there are no VMs to recreate. It did not offer a new install. That text comes from `aba.conf` `platform=bm`. Same fallback as Bug #1058. Dismissed. The installed `sno` cluster was not selected. |
| DISCO: sno cluster status | PASSED | Node sno is Ready, 12h, v1.34.9. Operators are Available at 4.21.40, including openshift-samples. Three installer pods are Error. Cluster version is 4.21.40, channel stable-4.21, upstream unset. |
| DISCO: Configure settings | PASSED | Settings shows Registry Type Auto and Retry Count 1. Back left `reg_vendor=auto`. |
| DISCO: Install wizard resume | PASSED | Basics showed platform bm, name sno2, domain example.com, OpenShift 4.21.40 fast from the mirror. Back left `cluster.conf` and `platform=bm` unchanged. |
| DISCO: main menu help | PASSED | Help lists Install Registry, Load Images, Install Cluster, Day-2, Configure, View Mirror Payload, Advanced, and Feedback. Those are the rows on the menu. |
| DISCO: Feedback | PASSED | The dialog lists the GitHub issues, discussions, and repository URLs. Nothing was submitted. |
| DISCO: Advanced menu | FAILED | Menu is Platform (bm), Stop, Start, Uninstall, X, Y, and Refresh. No Monitor row and no Clean row. Help still lists F, X/Y/Z, and Clean ABA. Bugs #1059 and #1035. |
| DISCO: startup confirm for installed sno | PASSED | Confirm names sno.example.com and says it will power on the cluster VMs, even though `aba.conf` is `platform=bm`. Start was focused. Cancel was selected. The cluster was left running. |
| CONNO: Save confirm | PASSED | Confirm says OCP 4.21.40 fast, operators none. Continue was focused. Back was selected. No save started. The menu still says saved 4.22.22 (Bug #1044). |
| CONNO: Sync images (rerun) | PASSED | Finished 2026-11-08 10:17. All eight steps succeeded. state.sh is last_action=sync, ocp_version=4.21.40, mirror_ocp_version=4.21.40. Menu now says synced 4.21.40 and saved 4.21.40. |
| CONNO: Install sno2 from mirror | PASSED | Finished 2026-11-08 11:07. All six steps succeeded. ClusterVersion is Completed at 4.21.40. `.install-complete` is present. Console is https://console-openshift-console.apps.sno2.example.com. |
| CONNO: sno2 OperatorHub | PASSED | Finished 2026-11-08 11:19. All eight steps succeeded. Done was focused. The TUI returned to the main menu. |
| CONNO: sno2 NTP | PASSED | Finished 2026-11-08 11:24. Access, apply, and verify all succeeded. Done was focused. |
| CONNO: sno2 graceful shutdown | PASSED | Finished 2026-11-08 12:22. All four steps succeeded. 10.0.1.202 stopped answering ping. Done was focused. |
| CONNO: sno2 graceful startup | PASSED | Finished 2026-11-08 12:27. All six steps succeeded. 10.0.1.202 answers ping again. Done was focused. |
| CONNO: sno2 cluster status | PASSED | 2026-11-08 13:22. Node sno2 is Ready, v1.34.9. Operators are Available at 4.21.40. Five installer pods are Error. Cluster version is 4.21.40, channel stable-4.21, upstream unset, update lookup RemoteFailed. Back was focused. |
| KVM: Install kvmsno direct | FAILED | Stopped at Generate configs. `api.kvmsno.example.com` is not a lab name and did not resolve. Dismissed. No VM was created. The directory was removed. |
| KVM: Install sno3 direct | PASSED | Finished 2026-11-08 11:54. All six steps succeeded. `.install-complete` is present. Console is https://console-openshift-console.apps.sno3.example.com. Done was focused. |
| KVM: sno3 OperatorHub | PASSED | Direct install. The command said OperatorHub already uses public registries and no mirror integration is needed. The dialog cut the sentence off at "no" (#1063). OK was focused. |
| KVM: sno3 NTP | PASSED | Finished 2026-11-08 12:07. Access, apply, and verify all succeeded. Done was focused. |
| KVM: sno3 OSUS | FAILED | Direct cluster. The command exited 0 and said OSUS is not needed. The dialog said Stopped before all steps finished. Same progress path as #1051. OK was focused. |
| KVM: sno3 graceful shutdown | PASSED | Finished 2026-11-08 12:37. All four steps succeeded. 10.0.1.203 stopped answering ping. The VM sno3 is shut off. Done was focused. |
| KVM: sno3 graceful startup | PASSED | Finished 2026-11-08 12:42. All six steps succeeded. 10.0.1.203 answers ping again. Done was focused. |
| VLAN: conno and disco on Private Network | PASSED | Tag 100, 10.10.100.0/24. conno 10.10.100.1, disco 10.10.100.2. They ping each other. No cluster installed yet. |
| CONNO: sno2 upgrade list | PASSED | 2026-11-08 13:25. Menu offered 4.22.22 and 4.22.21 as a minor upgrade. Header said current 4.21.40, channel stable-4.21, no OSUS. Upgrade was focused. Back was selected. No upgrade started. |
| VLAN: install sno4 | PASSED | Finished 2026-11-08 14:17. All six steps succeeded. Tag 100, 10.10.100.0/24, node 10.10.100.201, DNS/NTP/gateway 10.10.100.1, ens160, mirror. `.install-complete` is present. Console is https://console-openshift-console.apps.sno4.example.com. The gauge stayed at 43% during monitor. Done was focused. `GOVC_NETWORK` is `Lab Network` again. |
| VLAN: sno4 OperatorHub | PASSED | Finished 2026-11-08 14:32. All eight steps succeeded. Done was focused. |
| VLAN: sno4 NTP | PASSED | Finished 2026-11-08 14:37. Access, apply, and verify all succeeded. Done was focused. |
| VLAN: sno4 cluster status | PASSED | 2026-11-08 14:37. Node sno4 is Ready, 43m, v1.34.9. Cluster version is 4.21.40, channel stable-4.21, upstream unset. Five installer pods are Error. Back was focused. |
| VLAN: sno4 OSUS | PASSED | 2026-11-08 14:42. Warning said the Cincinnati/OSUS operator is not on the cluster and the operation may fail. Continue was focused. Cancel was selected. Nothing was applied. |
| VLAN: sno4 virt boot sources | PASSED | 2026-11-08 14:47. Warning said kubevirt-hyperconverged is not on the cluster and must be mirrored first. Continue was focused. Cancel was selected. Nothing was applied. |
| VLAN: sno4 upgrade list | PASSED | 2026-11-08 14:52. Menu offered 4.22.22 and 4.22.21. Header said current 4.21.40, channel stable-4.21, no OSUS. Upgrade was focused. Back was selected. No upgrade started. |
| VLAN: sno4 graceful shutdown | PASSED | Finished 2026-11-08 15:02. Preflight, access, shutdown, and power-off all succeeded. 10.10.100.201 stopped answering. Done was focused. |
| VLAN: sno4 graceful startup | PASSED | Finished 2026-11-08 15:07. Power on, API, uncordon, nodes, console, and operators all succeeded. 10.10.100.201 answers again. Done was focused. |
| VLAN: sno4 clean refused | PASSED | 2026-11-08 15:12. Clean named sno4.example.com and refused because `.install-complete` exists. It said to delete first. OK was focused. The cluster was left installed. |
| VLAN: sno4 delete | PASSED | Finished 2026-11-08 15:18. The VM `sno4` was destroyed and the folder removed. DNS records were removed. `.install-complete` is gone. `cluster.conf` remains. OK was focused. |
| CONNO: light bundle | PASSED | Finished 2026-11-08 15:34. All eight steps succeeded. File is `/tmp/ocp-bundle-4.21.40-amd64-lite.tar` (4.3G). Done was focused. |
| DISCO: sno virt boot sources | PASSED | Warning said kubevirt-hyperconverged is not on the cluster and must be mirrored first. Continue was focused. Cancel was selected. Nothing was applied. |
| DISCO: bare-metal sno2 install | PASSED | `.install-complete` at 23:33. Installer said install complete. Every ClusterOperator was Available. Same release-image warning as #1042. |
| DISCO: sno2 OperatorHub | PASSED | All 8 steps succeeded. No CatalogSources were created. `idms-release-0` maps the two quay.io release repos, same shape as #1042. |
| DISCO: sno2 NTP | PASSED | All 3 steps succeeded. chronyc on 10.0.1.202 selected 10.0.1.8. |
| DISCO: sno2 graceful shutdown | PASSED | All 4 steps succeeded. 10.0.1.202 stopped answering ping. |
| DISCO: sno2 graceful startup | PASSED | All 6 steps succeeded. The node answered ping before the console step finished. |
| DISCO: sno2 delete | PASSED | `bm-sim-delete.sh` destroyed VM `sno2`. The TUI confirm said state files only, because the installed platform is bare metal. Cancel was focused. Delete then reported no VMs to delete and removed the cluster state. `cluster.conf` remains. `.install-complete` is gone. |
| CONNO: Additional Images empty | PASSED | 0 images. Menu offers Add, Recommended, Edit. Recommended lists AI 52, OCP 3, Virt 5. Cancelled. |
| CONNO: Delete cluster confirmation | FIXED | Bug #1002 fixed (now reads cluster's own platform via normalize) |
| Day-2: Status, Login, SSH | CODE-REVIEWED | API probe, KUBECONFIG handling, flock FD close — solid |
| Day-2: Shutdown/Startup | CODE-REVIEWED | Startup uses correct normalize pattern (Bug #1002 fix) |
| Day-2: Upgrade flow | CODE-REVIEWED | Version picker, z-stream vs minor grouping, conditional warnings, OSUS detection — solid |
| Day-2: Clean/Refresh | CODE-REVIEWED | --defaultno safety, .install-complete warning — correct |
| Advanced: Stop/Start/Uninstall mirror | CODE-REVIEWED | delete-data checklist, _invalidate_mirror_cache hooks — correct |
| Advanced: Mode switching | CODE-REVIEWED | CONNO↔DIRECT instant, CONNO→DISCO warns, DISCO→CONNO checks inet — correct |
| Bundle creation flow | CODE-REVIEWED | Light/full choice, same-device detection, low disk warning, incremental vs fresh — solid |
| DISCO: Load images | CODE-REVIEWED | Light bundle detection, archive re-check loop, d2m command — correct |
| DISCO: Install cluster gate | CODE-REVIEWED | Missing mirror → auto install+load chain — correct |
| Mirror payload menu | CODE-REVIEWED | Operator selection, ISC regen, exclusion toggles, contradiction warnings — complex but correct |
| cluster_install_flow (full wizard) | CODE-REVIEWED | 4-page form, persist after each page, platform gating, review page, post-install day2 offer — solid |
| _exec_in_tui (TUI mode) | CODE-REVIEWED | SIGINT handling (#942 partial fix), output review, retry flow — mostly correct |
| _exec_in_terminal (terminal mode) | CODE-REVIEWED | ask= logic investigated — confirmed correct (TUI overrides ask=true with --yes since TUI provides its own confirmations) |
| CONNO: sync cincinnati-operator | PASSED | Finished 2026-11-08 20:27. All eight steps succeeded (package and catalog steps were no-ops). ImageSet names cincinnati-operator. The follow-up prompt named sno2.example.com and offered Run Day-2 now. |
| CONNO: sno2 OperatorHub after operator sync | PASSED | Finished 2026-11-08 20:32. All eight steps succeeded for sno2.example.com. cincinnati-operator is now a packagemanifest on the cluster, channel v1. |
| CONNO: sno2 OSUS | PASSED | Finished 2026-11-08 20:42. All four steps succeeded. Status then showed version 4.21.40, channel fast-4.21, and upstream set to the cluster OSUS route. No updates were offered. Node sno2 is Ready, v1.34.9. Operators are Available. Five installer pods are Error. |
| CONNO: sno2 upgrade list after OSUS | FAILED | 2026-11-08 20:47. Header said current 4.21.40 (fast-4.21) [OSUS]. The menu offered 4.22.22 (newest) and 4.22.21 as a minor upgrade. Upgrade was focused. Back was selected. No upgrade started. Bug #1065. |
| CONNO: sno2 SSH | PASSED | 2026-11-08 20:52. Session opened as core@10.0.1.202. hostname was sno2. oc whoami was system:admin. Cluster version 4.21.40, channel fast-4.21. exit returned to the Day-2 menu. |
| CONNO: sno2 login | PASSED | 2026-11-08 20:53. Cluster terminal for sno2.example.com. oc whoami was kube:admin. Cluster version 4.21.40, channel fast-4.21. exit returned to the Day-2 menu. |
| CONNO: compact install | PASSED | Finished 2026-11-08 22:27. All six steps succeeded. `.install-complete` is present. Console is https://console-openshift-console.apps.compact.example.com. The follow-up prompt named compact.example.com. |
| CONNO: compact OperatorHub | PASSED | Finished 2026-11-08 22:45. All eight steps succeeded for compact.example.com. Done was focused. |
| CONNO: compact NTP | PASSED | Finished 2026-11-08 22:52. Access, apply, and verify all succeeded for compact.example.com. Done was focused. |
| CONNO: compact cluster status | PASSED | 2026-11-08 22:53. master1, master2, and master3 are Ready, v1.34.9. Cluster version is 4.21.40, channel stable-4.21, upstream unset. Back was focused. |
| CONNO: compact OSUS | PASSED | Finished 2026-11-08 23:07. All four steps succeeded for compact.example.com. Cluster version is 4.21.40, channel fast-4.21, upstream set to the cluster OSUS route. Done was focused. |
| CONNO: compact upgrade list | FAILED | 2026-11-08 23:13. Header said 4.21.40 (fast-4.21) [OSUS]. The graph had no updates. The menu offered 4.22.22 (newest) and 4.22.21. Upgrade was focused. Back was selected. Same as Bug #1065. |
| CONNO: compact SSH | PASSED | 2026-11-08 23:18. Session opened as core@10.0.1.71. hostname was master1. oc whoami was system:admin. Cluster version 4.21.40, channel fast-4.21. exit returned to the Day-2 menu. The picker also listed uninstalled sno4 and sno. |
| CONNO: compact login | PASSED | 2026-11-08 23:23. Cluster terminal for compact.example.com. oc whoami was kube:admin. Cluster version 4.21.40, channel fast-4.21. exit returned to the Day-2 menu. |
| CONNO: compact graceful shutdown | PASSED | Finished 2026-11-08 23:37. All four steps succeeded. 10.0.1.71, .72, and .73 stopped answering ping. Done was focused. |
| CONNO: compact graceful startup | PASSED | Finished 2026-11-08 23:42. All six steps succeeded. 10.0.1.71, .72, .73, and the API .216 answer ping again. Done was focused. |
| DISCO: cluster channel after day-2 | FAILED | 2026-11-09 00:26. aba.conf is fast 4.21.40. The ImageSet channel is fast-4.21. `oc get clusterversion` on sno is channel stable-4.21, upstream unset, version 4.21.40. OperatorHub already succeeded and left the channel unchanged. Bug #1068. |
| KVM1: sno3 channel after direct install | FAILED | 2026-11-09 00:26. aba.conf is fast 4.21.40. `oc get clusterversion` on sno3 is channel stable-4.21, upstream unset, version 4.21.40. Bug #1068. |
| CONNO: aba status --all | FAILED | 2026-11-09 00:32. compact and sno2 are running 4.21.40. `aba.conf` is `platform=vmw`, and both `vmware.conf` and `kvm.conf` exist. The summary says `Platform: kvm`. Bug #1069. |
| CONNO: network and gateway guess | FAILED | 2026-11-09 00:36. Default route is ens192 192.168.2.33/24. Lab NIC is ens224 10.0.0.10/20. `get_machine_network` returns 192.168.2.0/24 and `get_next_hop` returns 192.168.2.1. Installed clusters use 10.0.0.0/20 and gateway 10.0.0.1. Bug #1070. |
| CLI: VIP equal to the gateway | FAILED | 2026-11-09 00:40. `starting_ip=10.0.0.3` on `10.0.0.0/20` makes the auto-allocator pick `api_vip=10.0.0.1`, the gateway. `verify-cluster-conf` accepts that. A node IP of `10.0.0.1` is rejected. Bug #1071. |
| CLI: VMware MAC prefix xx | FAILED | 2026-11-09 00:43. `verify-cluster-conf` accepts `mac_prefix=00:50:56:xx:xx:`. The generator then produced addresses such as `00:50:56:fd:95:01`. 34 of 40 were above `00:50:56:3f`. Bug #1072. |
| CLI: last node is the broadcast | FAILED | 2026-11-09 00:48. Three masters at `10.0.15.253` on `10.0.0.0/20` pass `verify-cluster-conf`. The third address is the broadcast `.255`. `generate_ip_array` returns only two addresses and exits 0. The agent template renders the third IP empty. Bug #1073. |
| CONNO: preflight registry hint | FAILED | 2026-11-09 00:54. `preflight_check_dns` with a DNS server that does not know `conno.example.com` says the name resolves locally to `192.168.2.33` and says to set `dns_servers=192.168.2.33`. The A record is `10.0.0.10`. Bug #1074. |
| CLI: missing minor becomes the previous one | FAILED | 2026-11-09 01:05. Fast has no 4.23 releases. `fetch_latest_z_version fast 4.23` returns `4.22.22` and exits 0. The TUI resolver does the same and exits 0. `verify_release_version_exists` then accepts `4.22.22` on fast. Asking for `4.99` fails, because `4.98` is also empty. Bug #1075. |
| CONNO: NTP reachability fallback | FAILED | 2026-11-09 01:08. `chronyd -Q` against `192.0.2.1` times out. With `chronyd` off `PATH`, `preflight_check_ntp` prints `NTP server 192.0.2.1 is reachable (UDP port 123)` and records no warning and no error. Bug #1076. |
| CLI: upgrade list skips a reachable minor | FAILED | 2026-11-09 01:18. On channel `eus`, `4.16.73` can reach `4.18.60` in 2 hops. `fetch_upgrade_targets` offers only z-stream `4.16.75`. The `eus-4.17` graph is empty, and the walk jumps to `5.0` and stops. Bug #1077. |
| CONNO: node-update check with no API | FAILED | 2026-11-09 01:22. `mcp_is_updated` with `KUBECONFIG=/dev/null` exits 0. `oc get mcp` exits 1. Compact's pools are `updating=False`, so a live check also exits 0. Bug #1078. |
| CONNO: upgrade progress check while idle | FAILED | 2026-11-09 01:27. Compact is 4.21.40, Available=True, Progressing=False. `oc adm upgrade status` prints `The cluster is not updating.` The progress check, aimed at 4.22.22, exits 0. No upgrade was started. Bug #1079. |
| CLI: machine network with host bits | FAILED | 2026-11-09 01:32. `normalize_cidr 10.0.1.0/20` prints `10.0.1.0/20` and exits 0. `verify-cluster-conf` exits 0. A strict parse rejects it: host bits are set. The network address is `10.0.0.0/20`. Bug #1080. |
| CLI: NTP value of only dots | FAILED | 2026-11-09 01:32. `verify-aba-conf` with `ntp_servers=....` exits 0. `validate_ntp_servers` rejects that value, and nothing calls it. Bug #1081. |
| CLI: base domain with an underscore | FAILED | 2026-11-09 01:37. `_valid_domain my_lab.com` exits 0. After normalize, `verify-cluster-conf` exits 0. The base-domain dialog uses that same check and only rejects an IP-shaped name. Bug #1082. |
| CLI: image source dot-dot | FAILED | 2026-11-09 01:42. `_valid_image_source ..` exits 0 and `verify-cluster-conf` exits 0. From `~/aba/compact` that name is the home directory. `../x` is rejected. No make command was run. Bug #1083. |
| CLI: mirror data_dir with dot-dot | FAILED | 2026-11-09 01:47. `_valid_abs_path` accepts `/tmp/foo/../../home/steve/aba-escape`. `verify-mirror-conf` exits 0. `reg_setup_data_dir` sets the docker root to that path, which is `/home/steve/aba-escape/docker-reg`. Nothing was created. Bug #1084. |
| CLI: hostPrefix of 0 or 14 | FAILED | 2026-11-09 01:52. `verify-cluster-conf` accepts `hostPrefix` 0, 14, 15, 23, 26, 27, and 32. It rejects 33. The install template fixes the pod network at `10.128.0.0/14`. Bug #1085. |
| CLI: machine network overlaps pod or service network | FAILED | 2026-11-09 01:57. `verify-cluster-conf` accepts `10.0.0.0/8`, `10.128.0.0/20`, and `172.30.0.0/24`. The lab `10.0.0.0/20` also passes and does not overlap. Bug #1086. |
| CLI: disk hint quote | FAILED | 2026-11-09 02:02. A path containing a quote exits 0 and the renderer sees `minSizeGigabytes` and `vendor` as hint fields. A quote in `model` exits 0 and the renderer drops the hints. Bug #1087. |
| CLI: disk hint minimum above maximum | FAILED | 2026-11-09 02:02. `minSizeGigabytes=500,maxSizeGigabytes=100` exits 0 and prints both numbers. Bug #1088. |
| CLI: node name longer than 63 characters | FAILED | 2026-11-09 02:07. A 63-character `master_prefix` passes `verify-cluster-conf`. The node name is that prefix plus `1`, which is 64 characters. Bug #1089. |
| CLI: uppercase cluster name | FAILED | 2026-11-09 02:07. `verify-cluster-conf` accepts `cluster_name=MyCluster`. `_valid_cluster_name` rejects it. Bug #1090. |
| CLI: data disk of 0 | FAILED | 2026-11-09 02:12. `data_disk=0` passes `verify-cluster-conf`. The VM scripts still request a 0GB disk. An empty value does not. Bug #1091. |
| CLI: 1 CPU and 1 GB memory | FAILED | 2026-11-09 02:12. `master_cpu_count=1` and `master_mem=1` pass. `worker_cpu_count=1` and `worker_mem=1` pass. Bug #1092. |
| CLI: multicast MAC prefix | FAILED | 2026-11-09 02:17. `mac_prefix=01:22:33:44:55:` passes. The generator appends `01` and the group bit stays set. `ff:ff:ff:ff:ff:` also passes. Bug #1093. |
| CLI: duplicate port name | FAILED | 2026-11-09 02:17. `ports=ens224,ens224` passes. The bond port list is `ens224,ens224`. Bug #1094. |
| CLI: VIP or gateway is the network or broadcast | FAILED | 2026-11-09 02:22. `api_vip=10.0.0.0`, `ingress_vip=10.0.15.255`, `next_hop_address=10.0.0.0`, and `next_hop_address=10.0.15.255` each pass on `10.0.0.0/20`. A starting IP of `10.0.0.0` is rejected. Bug #1095. |
| CLI: DNS server 0.0.0.0 | FAILED | 2026-11-09 02:22. `dns_servers=0.0.0.0` passes `verify-cluster-conf`. Bug #1096. |
| CLI: registry hostname | FAILED | 2026-11-09 02:27. `my_reg.example.com` and a 64-character label pass `_valid_fqdn` and `verify-mirror-conf`. A 63-character label also passes. Bug #1097. |
| CLI: registry user and password | FAILED | 2026-11-09 02:27. `reg_user=1bad` and `reg_pw=bad pass` pass `verify-mirror-conf`. `_valid_username` and `_valid_password` reject them. `reg_pw=abc` also passes. Bug #1098. |
| CLI: proxy without a scheme | FAILED | 2026-11-09 02:32. `http_proxy=10.0.1.8:3128` passes `verify-cluster-conf`. The install template writes that value as `httpProxy`. Bug #1099. |
| CLI: empty no_proxy | FAILED | 2026-11-09 02:32. An empty `no_proxy` renders as `noProxy: ,10.0.0.0/20,10.128.0.0/14,172.30.0.0/16`. Bug #1100. |
| CLI: NTP server 0.0.0.0 | FAILED | 2026-11-09 02:37. `ntp_servers=0.0.0.0` passes `verify-aba-conf` and `validate_ntp_servers`. The agent template lists it under `additionalNTPSources`. Bug #1101. |
| CLI: vSphere password quote | FAILED | 2026-11-09 02:37. A password containing a single quote renders inside single quotes and the YAML parser rejects the file. Bug #1102. |
| CLI: vSphere TLS check | FAILED | 2026-11-09 02:42. `_vsphere_probe_tls` prints that the trust chain is verified and exits 0 when openssl exits 0, even if the verify line says code 21. A non-zero openssl exit still counts as a failure. Bug #1103. |
| CLI: vSphere role with a space | FAILED | 2026-11-09 02:47. A space-aligned `No access` row is reported as no role assigned, with errors left at 0. The same row with tabs records a missing privilege. Bug #1104. |
| CLI: startup operator check | FAILED | 2026-11-09 02:52. The ready check prints fields 3 and 5. A row that is Available True, Progressing True, Degraded False still passes. An empty result also passes. Bug #1105. |
| CLI: startup node ready check | FAILED | 2026-11-09 02:57. `all_nodes_ready` exits 0 when the node query fails and when the Ready field is blank. A `False` row exits 1. Bug #1106. |
| CLI: startup uncordon with no nodes | FAILED | 2026-11-09 02:57. `uncordon_all_nodes` exits 0 and uncordons nothing when the node query fails. A query that prints two names uncordons those names. Bug #1107. |
| CLI: shutdown pairs nodes by position | FAILED | 2026-11-09 03:02. API order `master2 master1 master3` with config IPs `.71 .72 .73` assigns master1 to `.72` and master2 to `.71`. Compact's live order currently matches the config. Bug #1108. |
| CLI: shutdown with an empty node list | FAILED | 2026-11-09 03:02. A failed node query leaves the list empty and the script takes the success branch. Bug #1109. |
| CLI: startup after a failed VM start | FAILED | 2026-11-09 03:07. A failing `aba start` marks the power step done and exits 0. Uncordon never runs. Bug #1110. |
| CLI: startup when operators stay unready | FAILED | 2026-11-09 03:07. A failed operator wait marks the operator step done and exits 0. Bug #1111. |
| CLI: day2 after a failed stability wait | FAILED | 2026-11-09 03:12. Both stability waits return failure and day2 still prints success and exits 0. Bug #1112. |
| CLI: startup CSR approval | FAILED | 2026-11-09 03:12. The pending filter approves a user CSR and an already approved CSR whose name contains pending. Bug #1113. |
| CLI: NTP check with no nodes | FAILED | 2026-11-09 03:17. An empty node list makes both NTP checks exit 0. A failed node query also leaves the list empty. Bug #1114. |
| CLI: NTP API wait | FAILED | 2026-11-09 03:17. A failed API wait warns, then prints that the API server is available, and exits 0. Bug #1115. |
| CLI: unstick with a failed pod query | FAILED | 2026-11-09 03:22. A failed pod query leaves the list empty and unstick says the cluster looks healthy. Bug #1116. |
| CLI: rescue with failed queries | FAILED | 2026-11-09 03:22. A failed node query and a failed CSR query both take the nothing-to-do branches, then rescue says it is complete. Bug #1117. |
| CLI: upgrade monitor already-at check | FAILED | 2026-11-09 03:27. Desired version plus Progressing False says the cluster is already at the target while Available is False, Failing is True, and the completed history is the old version. Bug #1118. |
| CLI: upgrade monitor completion check | FAILED | 2026-11-09 03:27. Available True and Progressing False say the upgrade is complete while Failing is True. Bug #1119. |
| CLI: upgrade list parser | FAILED | 2026-11-09 03:32. Recommended lines in the `Version:` form are dropped. A known-issue line is kept. Bug #1120. |
| CLI: upgrade complete check | FAILED | 2026-11-09 03:32. Desired version plus Progressing False says the upgrade is complete while Failing is True and the completed history is older. Bug #1121. |
| CLI: cluster status health | FAILED | 2026-11-09 03:37. Failing True with no Degraded condition is reported as available. Bug #1122. |
| CLI: cluster status version | FAILED | 2026-11-09 03:37. The printed version is the desired version, so 4.22.22 is shown while the completed history is 4.21.40. Bug #1123. |
| CLI: mirror runtime status | FAILED | 2026-11-09 03:42. HTTP 000 writes `reg_running=false`. The next status then says stopped and does not probe. Bug #1124. |
| CLI: cluster type with a missing count | FAILED | 2026-11-09 03:42. A missing master count is passed as 3, so the type is compact. Bug #1125. |
| CLI: status of a stopped install | FAILED | 2026-11-09 03:47. A directory with `iso-agent-based` and no install marker is reported as installing. Bug #1126. |
| CLI: mirror archive age | FAILED | 2026-11-09 03:47. An unparseable load time becomes epoch 0, so every archive is newer than the last load. Bug #1127. |
| CLI: image reference check | FAILED | 2026-11-09 03:52. A registry host with a port is rejected. A reference with no tag is accepted. Bug #1128. |
| CLI: image set target file | FAILED | 2026-11-09 03:52. `image set add` writes the repo `images.conf`, not the directory selected with `-d`. Bug #1129. |
| CLI: operator name lookup | FAILED | 2026-11-09 03:57. `amq-broker-rhel.` selects `amq-broker-rhel8` from the 4.21 index. Bug #1130. |
| CLI: additional image JSON | FAILED | 2026-11-09 03:57. A quote in an image name makes the image list invalid, and the imageset template omits every additional image. Bug #1131. |
| CLI: operator display JSON | FAILED | 2026-11-09 04:00. A quote in an operator display name makes the package list invalid, and the imageset template omits every operator. Bug #1132. |
| CLI: catalog YAML line endings | FAILED | 2026-11-09 04:00. A package.yaml with CRLF produces no index line. The syntax check reports no bad lines. Bug #1133. |
| CLI: catalog folded package name | FAILED | 2026-11-09 04:00. A folded `name:` value is stored as `>`. Bug #1134. |
| CLI: day2 mirror-set collision check | FAILED | 2026-11-09 04:07. The live IDMS file has `idms-release-0` and `idms-operator-0`. Day-2 reads only the first name. Bug #1135. |
| CLI: day2 OSUS restart | FAILED | 2026-11-09 04:07. An empty OSUS pod start time is older than the graph file, so day-2 deletes the pod. Bug #1136. |
| CLI: day2 ClusterCatalog apply | FAILED | 2026-11-09 04:13. The mirror ClusterCatalog file is not applied. Compact's catalogs still point at registry.redhat.io. Bug #1137. |
| CLI: day2 default ClusterCatalogs | FAILED | 2026-11-09 04:13. Disabling default catalog sources leaves the four default ClusterCatalogs on the public registry. Bug #1138. |
| CLI: VM refresh after a failed delete | FAILED | 2026-11-09 04:14. Delete exits 1, the install marker is removed, and create still starts. Bug #1139. |
| CLI: VM stop when the hypervisor is unreachable | FAILED | 2026-11-09 04:14. A failed power query makes stop and kill return 0. Bug #1140. |
| CLI: VM commands with no hypervisor config | FAILED | 2026-11-09 04:18. Missing vmware.conf makes exists and start exit 0. Bug #1141. |
| CLI: VM stop after a failed power-off | FAILED | 2026-11-09 04:18. The power-off command fails and stop still returns 0. Bug #1142. |
| CLI: KVM start after virsh fails | FAILED | 2026-11-09 04:24. `virsh start` exits 1 and `vm_start` returns 0. Bug #1143. |
| CLI: MAC list that does not divide evenly | FAILED | 2026-11-09 04:24. Four MACs for three nodes are stored as one port. Bug #1144. |
| CLI: missing IP in a node list | FAILED | 2026-11-09 04:28. A missing address is kept as `null` and the list still counts as present. Bug #1145. |
| CLI: extra compute pool | FAILED | 2026-11-09 04:28. Two compute pools of 2 and 3 replicas export 2. Bug #1146. |
| CLI: agent IP lower bound | FAILED | 2026-11-09 04:33. A start address below the CIDR is still handed out, including the network address. Bug #1147. |
| CLI: agent IP list shorter than the node count | FAILED | 2026-11-09 04:33. Asking for 3 addresses at .254 returns one address. Bug #1148. |
| CLI: agent IP with a leading zero | FAILED | 2026-11-09 04:38. `10.0.0.08` becomes `0.0.0.0 0.0.0.1 0.0.0.2`. Bug #1149. |
| CLI: disk hint with a quote | FAILED | 2026-11-09 04:38. The hint JSON is invalid and the template drops every disk hint. Bug #1150. |
| CLI: install-config render failure | FAILED | 2026-11-09 04:43. A failed render leaves a 0-byte file and the next line is the success message. Bug #1151. |
| CLI: vSphere password quote | FAILED | 2026-11-09 04:43. A single quote in the vCenter password makes install-config invalid YAML. Bug #1152. |
| CLI: empty no_proxy | FAILED | 2026-11-09 04:43. The rendered noProxy value starts with a comma. Bug #1153. |
| CLI: vSphere network name | FAILED | 2026-11-09 04:48. `Site: Lab` is stored as a map, not a network name. Bug #1154. |
| CLI: invalid public pull secret | FAILED | 2026-11-09 04:48. `jq` fails, the secret is emptied, and generation continues. Bug #1155. |
| CLI: short macs.conf on a VM platform | FAILED | 2026-11-09 04:55. Missing addresses are written as empty MAC fields and generation succeeds. Bug #1156. |
| CLI: failed SSH public key | FAILED | 2026-11-09 04:55. `ssh-keygen` fails, the public key is empty, and install-config omits `sshKey`. Bug #1157. |
| CLI: registry password quote in state.sh | FAILED | 2026-11-09 05:01. A docker password with a single quote is accepted, and the written state file is invalid shell. Bug #1158. |
| CLI: remote registry package check | FAILED | 2026-11-09 05:01. A failed SSH query is treated as every package already being installed. Bug #1159. |
| CLI: registry stop when the port check fails | FAILED | 2026-11-09 05:04. SSH failure and a missing `ss` are both reported as already stopped. Bug #1160. |
| CLI: Quay uninstall probe without systemctl | FAILED | 2026-11-09 05:04. A missing `systemctl` makes the Quay stale report empty. Bug #1161. |
| CLI: remote Docker registry password | FAILED | 2026-11-09 05:09. A password with a single quote makes the remote install script invalid. Bug #1162. |
| CLI: registry certificate hostname check | FAILED | 2026-11-09 05:09. A certificate for `reg-example.com` is kept for host `reg.example.com`. Bug #1163. |
| CLI: registry install skip | FAILED | 2026-11-09 05:13. An HTTP 404 from a non-registry is treated as an existing registry. Bug #1164. |
| CLI: registry auth check | FAILED | 2026-11-09 05:13. An HTTP 200 whose body is `not-a-registry` passes authentication. Bug #1165. |
| CLI: registry firewall open | FAILED | 2026-11-09 05:18. A failed `firewall-cmd` is recorded as the port having been opened. Bug #1166. |
| CLI: registry firewall close | FAILED | 2026-11-09 05:18. A failed port removal still returns success. Bug #1167. |
| CLI: registry DNS address | FAILED | 2026-11-09 05:23. A CNAME containing `10.0.0.10` is used as the registry address. Bug #1168. |
| CLI: Quay resource check | FAILED | 2026-11-09 05:23. 3 vCPUs and 7GB RAM do not warn, while the message requires 4 and 8GB. Bug #1169. |
| CLI: registry data_dir tilde | FAILED | 2026-11-09 05:28. `~other/reg` is accepted and stored without being expanded. Bug #1170. |
| CLI: Docker debug port | FAILED | 2026-11-09 05:28. Registry port 60000 produces debug port 70000, which is not a valid port. Bug #1171. |
| CLI: import API address | FAILED | 2026-11-09 05:34. `dig +short` of a CNAME keeps the name, not the address. Bug #1172. |
| CLI: import machine network | FAILED | 2026-11-09 05:34. A node at 10.0.1.71 becomes network 10.0.1.0/24, which excludes 10.0.2.10. Bug #1173. |
| CLI: import platform None | FAILED | 2026-11-09 05:38. sno2 reports platform type None, and import records that as bare metal. Bug #1174. |
| CLI: import rendezvous address | FAILED | 2026-11-09 05:38. The lowest address is a worker at 10.0.1.10, not a master. Bug #1175. |
| CLI: import base domain | FAILED | 2026-11-09 05:43. Cluster `example` and domain `example.com` become FQDN `example.com`. Bug #1176. |
| CLI: import missing cluster name | FAILED | 2026-11-09 05:43. Domain `example.com` becomes cluster `example` and domain `com`. Bug #1177. |
| CLI: import mirror detection | FAILED | 2026-11-09 05:43. A failed mirror-object query is counted as zero and the source becomes direct. Bug #1178. |
| CLI: import dual-stack node count | FAILED | 2026-11-09 05:49. One master with an IPv4 and an IPv6 address is counted as two masters and typed standard. Bug #1179. |
| CLI: import IPv6-only node | FAILED | 2026-11-09 05:49. An IPv6 master address is dropped and import aborts with no node IP. Bug #1180. |
| CLI: DNS and NTP server order | FAILED | 2026-11-09 05:53. `10.0.0.8` then `10.0.0.10` is stored as `10.0.0.10,10.0.0.8`. Bug #1181. |
| CLI: IPv6 DNS servers | FAILED | 2026-11-09 05:53. An IPv6 nameserver is dropped, and a list of only IPv6 nameservers becomes empty. Bug #1182. |
| CLI: resolved DNS parse | FAILED | 2026-11-09 05:58. `resolvectl` output is parsed as `2,8.8.8.8`, then the whole list is discarded. Bug #1183. |
| CLI: NTP list validation | FAILED | 2026-11-09 05:58. `ntp.example.com,fd00::1` is discarded, while the name alone is kept. Bug #1184. |
| CLI: machine network on a bridge | FAILED | 2026-11-09 06:03. A route on `br-ex` is skipped and `192.168.2.0/24` is selected. Bug #1185. |
| CLI: empty host domain | FAILED | 2026-11-09 06:03. A hostname with no domain becomes `example.com`. Bug #1186. |
| CLI: cluster argument loading | FAILED | 2026-11-09 06:09. A semicolon in a `name=` value is executed while the arguments are loaded. Bug #1187. |
| CLI: interface state UNKNOWN | FAILED | 2026-11-09 06:09. A link whose state is UNKNOWN is rejected even when its flags include UP. Bug #1188. |
| CLI: node range outside the subnet | FAILED | 2026-11-09 06:14. Nodes starting at 10.0.1.250 include 10.0.2.4, and the network check returns success. Bug #1189. |
| CLI: suggested starting address | FAILED | 2026-11-09 06:14. `10.0.1.200/24` suggests `10.0.2.44`, which is outside the subnet. Bug #1190. |
| CLI: API address outside the subnet | FAILED | 2026-11-09 06:18. `api_vip=1.2.3.4` on `10.0.1.0/24` passes the network check. Bug #1191. |
| CLI: node address equals DNS | FAILED | 2026-11-09 06:18. A node at `10.0.1.20` matches `dns_servers` and the check still succeeds. Bug #1192. |
| CLI: mirror name dot-dot | FAILED | 2026-11-09 06:23. `image_source=..` is accepted and the mirror link target is `../..`. Bug #1193. |
| CLI: standard worker default | FAILED | 2026-11-09 06:23. One script writes 3 workers and the caller then writes 2. Bug #1194. |
| CLI: duration with a leading zero | FAILED | 2026-11-09 06:33. `010m` is 480 seconds, the same as 8 minutes. `08m` raises a base error. Bug #1195. |
| CLI: VIP on the gateway | FAILED | 2026-11-09 06:33. Auto-allocation sets `api_vip` to `10.0.1.1`, the gateway, and the network check returns 0. Bug #1196. |
| CLI: DNS check stops at the bastion | FAILED | 2026-11-09 06:38. A matching bastion answer returns success and never asks the cluster DNS. Bug #1197. |
| CLI: bundle keeps one hypervisor file | FAILED | 2026-11-09 06:38. When both files exist, the bundle list keeps `vmware.conf` and drops `kvm.conf`. Bug #1198. |
| CLI: config replace leaves the old tail | FAILED | 2026-11-09 06:41. `starting_ip=old true` becomes `starting_ip=new true`, and sourcing runs the leftover word. Bug #1199. |
| CLI: config read uses the first value | FAILED | 2026-11-09 06:41. `fetch_value` returns `10.0.1.1` and sourcing the same file returns `10.0.1.99`. Bug #1200. |
| CLI: config replace follows one quoting style | FAILED | 2026-11-09 06:42. A quoted line is updated, the plain line stays `10.0.1.2`, and the write returns 0. Bug #1201. |
| CLI: config replace skips an empty file | FAILED | 2026-11-09 06:42. Writing a key into an empty file returns 1 and leaves it empty. Bug #1202. |
| CLI: config replace skips a different value | FAILED | 2026-11-09 06:47. `base_domain=exampleXcom` is left in place when the new value is `example.com`. Bug #1203. |
| CLI: config replace takes the next flag as the value | FAILED | 2026-11-09 06:47. `-v -f` stores `base_domain=-f`. Bug #1204. |
| CLI: ask reloads aba.conf | FAILED | 2026-11-09 06:53. After `ask`, `machine_network`, `domain`, and `ocp_version` were the file values, not the caller's. Bug #1205. |
| CLI: config table splits on spaces | FAILED | 2026-11-09 06:53. `cluster_name=hello world` is shown as two columns and the next key moves. Bug #1206. |
| CLI: ask default depends on flag order | FAILED | 2026-11-09 06:58. `ask --always -n` shows default yes, and Enter returns success. Bug #1207. |
| CLI: zero retries reports success | FAILED | 2026-11-09 06:58. `try_cmd -n 0 false` returns 0. One attempt returns 1. Bug #1208. |
| CLI: failed task is treated as done | FAILED | 2026-11-09 07:05. A task that exited 1 is not run again, and start and peek both return 0. Bug #1209. |
| CLI: hash in a config value is removed | FAILED | 2026-11-09 07:05. `reg_pw="p#assword"` becomes `reg_pw="p`, and `disk_hint=/dev/sda#1` becomes `/dev/sda`. Bug #1210. |
| CLI: task id leaves the runner directory | FAILED | 2026-11-09 07:07. Work id `../escaped` writes the task under the parent of the runner directory. Bug #1211. |
| CLI: export prefix hides a config key | FAILED | 2026-11-09 07:07. `export num_masters=1` loads as 1, and `fetch_value` returns failure. Bug #1212. |
| CLI: catalog name is a filesystem path | FAILED | 2026-11-09 07:14. Catalog `../../tmp/aba-cat` makes the index file `/home/steve/tmp/aba-cat-index-v4.21`. Bug #1213. |
| CLI: first minor has no previous version | FAILED | 2026-11-09 07:14. Version `5.0.1` sets the previous minor to `-1`. Bug #1214. |
| CLI: YAML catalog display name | FAILED | 2026-11-09 07:19. A catalog whose operator name is `Demo Operator` is indexed as `Demo CR`. Bug #1215. |
| CLI: JSON catalog display name | FAILED | 2026-11-09 07:19. The last bundle name `Old Demo Name` is kept and the default channel's `Demo Operator` is dropped. Bug #1216. |
| CLI: catalog file with Windows line endings | FAILED | 2026-11-09 07:26. The same catalog indexes on Unix line endings and is rejected when the lines end with a carriage return. Bug #1217. |
| TUI: registry port with a leading zero | FAILED | 2026-11-09 07:26. Port `0177777` is accepted and port `08` is rejected. Bug #1218. |
| TUI: export prefix hides cluster size | FAILED | 2026-11-09 07:30. `export num_masters=3` and `export num_workers=2` load as SNO. The same lines without `export` load as standard with 2 workers. Bug #1219. |
| TUI: hash in a quoted config value is cut | FAILED | 2026-11-09 07:30. `data_disk='/dev/sda#1'` loads as `'/dev/sda`. Bug #1220. |
| TUI: quoted cluster size is not a type | FAILED | 2026-11-09 07:33. `num_masters='3'` and `num_workers='2'` leave the type blank. The same lines without quotes load as standard. Bug #1221. |
| TUI: prefix before the network is dropped | FAILED | 2026-11-09 07:33. `prefix_length=20` before `machine_network=10.0.0.0` loads as `10.0.0.0`. The reverse order loads as `10.0.0.0/20`. Bug #1222. |
| CLI: extra MAC digits are kept | FAILED | 2026-11-09 07:39. `00:11:22:33:44:5566` is stored as `00:11:22:33:44:55` and reported READY. Bug #1223. |
| TUI: MAC help example is rejected | FAILED | 2026-11-09 07:39. The help example `00:50:56:xx` fails the prefix check. `00:50:56:1a:2b:` is accepted. Bug #1224. |
| CLI: MAC case is ignored by one check | FAILED | 2026-11-09 07:44. `AA:BB:CC:DD:EE:FF` and `aa:bb:cc:dd:ee:ff` count as two addresses in the install check. The MAC report calls them duplicates. Bug #1225. |
| CLI: disk minimum above the maximum | FAILED | 2026-11-09 07:44. `minSizeGigabytes=100,maxSizeGigabytes=10` is accepted. Bug #1226. |
| CLI: disk hint breaks JSON | FAILED | 2026-11-09 07:48. `deviceName=/dev/disk"1` is accepted and `jq` cannot parse it. A backslash-n in a model becomes a newline. Bug #1227. |
| CLI: space after a disk-hint comma | FAILED | 2026-11-09 07:48. `path=/dev/sda, minSizeGigabytes=200` is rejected. The same hint without the space is accepted. Bug #1228. |
| CLI: disk hint value breaks YAML | FAILED | 2026-11-09 07:54. Model `Site: Lab` renders as invalid YAML. Model `foo # bar` is read back as `foo`. Bug #1229. |
| CLI: failed agent-config render says success | FAILED | 2026-11-09 07:54. A failed render leaves a 0-byte `agent-config.yaml` and the next line says it was generated. Bug #1230. |
| CLI: NTP servers separated by spaces | FAILED | 2026-11-09 08:00. `10.0.0.8 10.0.0.9` becomes `10.0.0.810.0.0.9`. A comma between the same addresses stays two servers. Bug #1231. |
| CLI: worker NTP config serves time to anyone | FAILED | 2026-11-09 08:00. The worker chrony file contains `allow all` and `local stratum 3 orphan`. Bug #1232. |
| CLI: stopping the NTP wait reports success | FAILED | 2026-11-09 08:03. A wait result of 130 prints `Aborted by user.` and exits 0. Bug #1233. |
| CLI: NTP render failure is ignored | FAILED | 2026-11-09 08:03. `butane` on an invalid file exits 1 and creates no output. The script continues. Bug #1234. |
| CLI: virt image deleted before import | FAILED | 2026-11-09 08:08. An ImageStream with no digest 5 seconds after creation is deleted and skipped. Bug #1235. |
| CLI: virt verify failure says success | FAILED | 2026-11-09 08:08. A failed DataImportCron wait warns and the script still exits 0 with a success line. Bug #1236. |
| CLI: waved day2 skips other manifest dirs | FAILED | 2026-11-09 08:15. With a numbered wave present, `extra/foo.yaml` is not applied. `top.yaml` and `10-ns/bar.yaml` are. Bug #1237. |
| CLI: signature patch can be null | FAILED | 2026-11-09 08:15. A signature file with no `binaryData` key produces the patch `{"binaryData": null}`. Bug #1238. |
| CLI: ten operators still counts as zero | FAILED | 2026-11-09 08:27. Status text `10 operators updated` and `20 operators updated` still matches `0 operators updated`, so the progress wait does not end. Bug #1239. |
| TUI: prerelease upgrade is the wrong group | FAILED | 2026-11-09 08:27. `4.22.0-rc.1` is labeled `4.21 → 4.22.0-rc`. `4.21.41-rc.1` is grouped as a minor upgrade. Bug #1240. |
| CLI: version is resolved before the channel flag | FAILED | 2026-11-09 08:36. `--version 4.21` on fast stores `4.21.42`. A following `--channel eus` leaves that version. Channel first stores `4.20.46`. Bug #1241. |
| TUI: version trim drops one space | FAILED | 2026-11-09 08:36. `  4.22.1` still has a leading space after the trim, so the version check rejects it. Bug #1242. |
| CLI: image set name is a prefix match | FAILED | 2026-11-09 08:38. A block named `ai-extra` makes `ai` look present. Removing `ai` exits 0 and leaves `ai-extra`. Bug #1243. |
| CLI: missing image-set end wipes the rest | FAILED | 2026-11-09 08:38. Removing `virt` with no end marker deletes the following `ocp` block too. The file is left empty. Bug #1244. |
| CLI: RHOAI release candidate is the latest GA | FAILED | 2026-11-09 08:43. The picker keeps `3.5.2-rc.1` and drops `3.5.0-ea.1`. `3.5.1` is not the result. Bug #1245. |
| CLI: RHOAI version cache never expires | FAILED | 2026-11-09 08:43. A cached `1.0.0` is returned for OpenShift `4.21` and the function exits 0. Bug #1246. |
| CLI: RHOAI channel named stable is rejected | FAILED | 2026-11-09 08:49. The 4.16 index channel is `stable`. `detect_rhoai_version 4.16` exits 1. Bug #1247. |
| TUI: operator search keeps 100 lines | FAILED | 2026-11-09 08:50. Query `er` matches 135 lines in the 4.21 Red Hat index. `rhacs-operator` is not in the first 100. Bug #1248. |
| TUI: unchecking a set drops a searched operator | FAILED | 2026-11-09 08:53. `rhods-operator` was in the basket and in the AI set. Unchecking the set removed it. Bug #1249. |
| TUI: ODF set skips an operator and still shows on | FAILED | 2026-11-09 08:54. `ocs-tls-profiles` is not in the 4.21 indexes. The set is still marked added. 16 other names are kept. Bug #1250. |
| CLI: op_sets all ignores other operators | FAILED | 2026-11-09 09:00. `op_sets=all,virt` with `ops=3scale-community-operator` returns the redhat `all` catalog only. That operator is community-only and is not in the JSON. Bug #1251. |
| CLI: a longer operator display name is dropped | FAILED | 2026-11-09 09:00. `3scale-operator` with display `Red Hat Integration - 3scale` is treated as the same name. `eap` / `JBoss EAP` is too. Bug #1252. |
| CLI: export verify_conf=off becomes all | FAILED | 2026-11-09 09:06. A throwaway file `export verify_conf=off` normalizes to off and then to all. Sourcing it leaves `verify_conf=all`. Bug #1253. |
| CLI: False does not turn a flag off | FAILED | 2026-11-09 09:07. `excl_platform=False` stays `False` and counts as set, so platform images would be excluded. `ask=False` leaves prompts on. Lowercase `false` turns both off. Bug #1254. |
| CLI: exported image source and host prefix are replaced | FAILED | 2026-11-09 09:10. `export image_source=direct` loads as `mirror`. `export hostPrefix=26` loads as `23`. Bug #1255. |
| CLI: a tilde registry path gains a leading slash | FAILED | 2026-11-09 09:10. `reg_path=~/registry` becomes `/~/registry`. That path fails the check that accepts `~/registry`. Bug #1256. |
| CLI: KVM host keeps a URI port | FAILED | 2026-11-09 09:14. `qemu+ssh://steve@kvm1.example.com:2222/system` sets `KVM_HOST` to `steve@kvm1.example.com:2222`. A local URI replaces an explicit host with `qemu:///system`. Bug #1257. |
| CLI: a stray BMC discovery variable aborts the file | FAILED | 2026-11-09 09:14. `mac_discovery_stray=yes` in the environment aborts `bmc.conf` that does not set it. The same file loads when that variable is absent. Bug #1258. |
| CLI: exported BMC host is not in the inventory | FAILED | 2026-11-09 09:18. `export bmc_host_n0=10.1.1.1` loads into the environment. The host list is empty and `bmc_has_hosts` is false. Bug #1259. |
| CLI: a quote in a BMC value breaks the snapshot | FAILED | 2026-11-09 09:18. User `o'reilly` is written as `export bmc_user_n0='o'reilly'`. Sourcing that snapshot exits 2. Bug #1260. |
| CLI: exported BMC password is printed | FAILED | 2026-11-09 09:22. `export bmc_password_n0` is printed with a second `export`. The same line without `export` is removed. Bug #1261. |
| CLI: a space in the datacenter name is dropped | FAILED | 2026-11-09 09:25. `Lab Datacenter` loads as `Lab`. The resource pool becomes `/Lab/host/Cluster/Resources`. Bug #1262. |
| CLI: a value passed to process_args is executed | FAILED | 2026-11-09 09:31. `name=foo;uname` is printed as `export name=foo;uname`. Loading it runs `uname` and sets `name` to `foo`. Bug #1263. |
| CLI: a spaced value becomes an extra table column | FAILED | 2026-11-09 09:31. `note=two words` is shown as `note=two` and `words`. Bug #1264. |
| CLI: an unknown cluster type is counted as one node | FAILED | 2026-11-09 09:34. `--type bogus --masters 3 --workers 2` reports 1 node. `SNO` does the same. Bug #1265. |
| CLI: standard worker count depends on whether type was set | FAILED | 2026-11-09 09:34. An explicit standard sets 2 workers. A standard created without `type` keeps 3. Bug #1266. |
| CLI: an IPv6 API address is parsed into the wrong host and port | FAILED | 2026-11-09 09:38. `https://[fd00::10]:6443` becomes host `[fd00:` and port `10` plus `6443`. A hostname and an IPv4 address stay intact. Bug #1267. |
| CLI: kubeconfig lookup returns the current directory | FAILED | 2026-11-09 09:38. Asking for `other.example.com` from a directory that has its own kubeconfig returns that local file. From a directory without one, the named cluster's file is returned. Bug #1268. |
| CLI: a stored prefix replaces the one in the network | FAILED | 2026-11-09 09:43. `machine_network=10.0.0.0/20` is split to prefix 20, then `prefix_length=24` replaces it. The loaded prefix is 24. Bug #1269. |
| CLI: the suggested aba -d name is the current directory | FAILED | 2026-11-09 09:43. After `aba -d`, changing to `/tmp` makes the hint `aba -d tmp install`. Bug #1270. |
| CLI: mirror drift warning names the current directory | FAILED | 2026-11-09 09:48. The mirror is `mirror` and the port in use is 5000. The warning says `aba -d notmirror uninstall`. Bug #1271. |
| CLI: recreating a cluster succeeds when init fails | FAILED | 2026-11-09 09:48. `make init` exits 1. `_recreate_cluster_dir` still returns 0. Bug #1272. |
| CLI: restoring a cluster picks the first saved domain | FAILED | 2026-11-09 09:53. Saved domains `aaa.example` and `zzz.example` both match directory `sno`. The restore loop keeps `aaa.example` and stops. Bug #1273. |
| CLI: delete can remove the ABA state directory | FAILED | 2026-11-09 09:59. `cluster_name=../../` and `base_domain=aba` make the delete path the same directory as `~/.aba`. The name is rejected by the name check, which delete does not call. Bug #1274. |
| CLI: status of a missing directory reports the current one | NOT COUNTED | 2026-11-09 11:28. `aba` changes into the directory before status, so this fallback is not what `aba status` runs. Bug #1275. |
| CLI: a cluster with no replica counts is compact | FAILED | 2026-11-09 11:28. `aba -d aba-cli-proof-st status --shell` printed `type=compact`. Bug #1276. |
| CLI: cluster.conf accepts names the name check rejects | FAILED | 2026-11-09 11:28. `aba -d <dir> info` for `SNO` and `1sno` passed verification and stopped at the missing kubeconfig. Bug #1277. |
| CLI: cluster DNS cleanup can leave /etc/dnsmasq.d | NOT COUNTED | 2026-11-09 11:28. Not run through `aba delete`. Bug #1278. |
| CLI: a quote in the cluster name breaks the DNS command | NOT COUNTED | 2026-11-09 11:28. Not run through `aba`. Bug #1279. |
| CLI: an upgrade to the current version has no path | NOT COUNTED | 2026-11-09 11:28. `aba` skips that check when the two versions are the same. Bug #1280. |
| CLI: a conditional upgrade risk is reported as unknown | NOT COUNTED | 2026-11-09 11:28. Not run through `aba` or the TUI. Bug #1281. |
| CLI: aba_cmd_for treats two directories with the same name as one | NOT COUNTED | 2026-11-09 11:28. No `aba` or TUI command calls `aba_cmd_for`. Bug #1282. |
| CLI: mirror status prints an error for a missing image set | FAILED | 2026-11-09 11:29. `aba -d notmirror status` printed `integer expression expected` and then `Operators: none`. Exit code was 0. Bug #1283. |
| CLI: a truncated address is accepted as an NTP server | NOT COUNTED | 2026-11-09 11:28. No `aba` or TUI command calls `validate_ntp_servers`. Bug #1284. |

---

## Previous Bugs — Re-verification Status

### Bug #500: DIRECT mode Help text mentions "Monitor Cluster" as top-level step
**Status:** FIXED ✅
**Verified:** 2026-10-26 — tui-direct.sh line 867 now says "1. Install Cluster" and "2. Day-2" without mentioning "Monitor Cluster" as a top-level step.

### Bug #602: Day-2 menu label says "after mirror load/sync" in DIRECT mode
**Status:** FIXED ✅
**Verified:** 2026-10-26 — tui-cluster.sh line 2210: `[[ "$_TUI_MODE" != "DIRECT" ]]` correctly hides "(after mirror load/sync)" in DIRECT mode.

### Bug #935: `aba-get-version.sh` broken error message URL
**Status:** FIXED ✅
**Verified:** 2026-10-26 — line 32 now reads `"Cannot access https://mirror.openshift.com."` — no more space in URL.

### Bug #940: Platform Settings — arrow key navigation selects wrong platform
**Status:** FIXED ✅
**Verified:** 2026-10-26 — TUI testing: used Down+Space+Enter to select VMware, confirmed `platform=vmw` written to aba.conf correctly. Code now uses radiolist with Space selection.

### Bug #942: TUI shows "Success" when `openshift-install` is interrupted by SIGINT
**Status:** FIXED ✅ (re-verified 2026-10-27)
**Re-verified:** The `_got_int` trap at line 677 fires on the PARENT bash (not the child), so it triggers whenever Ctrl+C is pressed regardless of how the child handles SIGINT. Even if `openshift-install` catches SIGINT and exits 0, the parent's `_got_int=true` flag overrides `exit_code` to 130 at line 689-691. The original concern ("might not trigger") was incorrect — SIGINT is delivered to the entire process group, so the parent always receives it.

### Bug #945: Stale "(synced)" and "(saved)" labels after version change
**Status:** FIXED ✅ (re-verified 2026-11-07 on conno `tui-debugging`)
**Re-verified:** Main menu shows `Sync images to mirror (synced 4.22.22)` while Mirror Payload stays `4.21.40 fast`. The label now includes `mirror_ocp_version`, so a mismatch with aba.conf is visible. Save was not re-checked.

### Bug #946: Upgrade version duplicate detection uses substring match
**Status:** FIXED ✅
**Verified:** 2026-10-26 — tui-mirror.sh lines 878-880 now use `*"|$_fb_n|"*` format with pipe delimiters for exact matching.

### Bug #947: Cluster status TCP probe fails when API URL has no explicit port
**Status:** FIXED ✅
**Verified:** 2026-10-26 — tui-cluster.sh lines 2356-2361 now check `if [[ "$_api_host" == *:* ]]` before extracting port, defaulting to 6443.

### Bug #949: ocp_channel defaults to "fast" instead of "stable" in upgrade flow
**Status:** FIXED ✅ (commit 79ad04de — fixed as part of Bug #1003)
**Verified:** 2026-10-27 — all 9 call sites now use `${ocp_channel:-stable}`.

### Bug #950: `aba import --force --name <dangerous>` can delete ABA directories
**Status:** NOT A BUG ✅ (re-verified 2026-10-27)
**Re-verified:** `_valid_cluster_name "$_dir_name" || exit 1` at line 162 runs BEFORE the `rm -rf` at line 205. The reserved-name list (`mirror|scripts|cli|templates|tui|build|...`) prevents dangerous names from reaching the rm.

### Bug #956: `excl_platform` flag not reset on crash/kill during save operation
**Status:** FIXED ✅
**Verified:** 2026-10-26 — tui-mirror.sh lines 782-791 now use `trap _restore_excl_platform EXIT` guard.

### Bug #959: Operator Sets selection adds no operators to the basket
**Status:** INCONCLUSIVE — needs TUI re-testing with from-scratch wizard

### Bug #964: Startup message uses global platform instead of selected cluster's platform
**Status:** FIXED ✅ (improved in commit 79ad04de)
**Verified:** 2026-10-27 — tui-cluster.sh `_day2_startup()` now uses the standard two-source normalize pattern (replaced awk).

### Bug #965: `mirror_save` missing `_invalidate_mirror_cache` callback
**Status:** FIXED ✅
**Verified:** 2026-10-26 — tui-mirror.sh line 806 now uses `_exec_with_progress "$_cmd --yes" "$TUI2_LABEL_SAVE" _invalidate_mirror_cache`.

---

## New Bugs Found

### Bug #1001: "Configure" summary displays "Auto" after installing Docker registry
**File:** `tui/v2/abatui2.sh`, `tui/v2/tui-disco.sh`
**Severity:** Low — cosmetic, incorrect display
**Status:** FIXED ✅ (commit 79ad04de)
**Root cause:** `_tui_settings_summary()` reads from the in-memory `_TUI_REG_VENDOR` variable, which was initialized at TUI startup from `mirror/mirror.conf` but never refreshed after mirror install/recheck.
**Fix:** Added `_TUI_REG_VENDOR` refresh (via `normalize-mirror-conf`) after the `_TUI_NEED_MIRROR_RECHECK` handler in both the CONNO and DISCO menu loops.

### Bug #1002: Delete cluster confirmation uses global platform instead of cluster's platform
**File:** `tui/v2/tui-cluster.sh` — `cluster_delete()` and `_day2_startup()`
**Severity:** Medium — misleading confirmation dialog
**Status:** FIXED ✅ (commit 79ad04de)
**Root cause:** `cluster_delete()` read `${platform:-bm}` from global scope instead of the selected cluster's `cluster.conf`. `_day2_startup()` used awk to parse cluster.conf instead of the standard normalize pattern.
**Fix:** Both functions now use the canonical two-source pattern: `source <(normalize-aba-conf)` + `source <(cd "$ABA_ROOT/$SELECTED_CLUSTER" && normalize-cluster-conf)`.

### Bug #1003: Inconsistent default channel ("fast" vs "stable") across functions
**File:** `scripts/include_all.sh`, `tui/v2/tui-mirror.sh`, `scripts/reg-save.sh`, `scripts/tui-mirror.sh`
**Severity:** Low — only affects edge case when `ocp_channel` is empty
**Status:** FIXED ✅ (commit 79ad04de)
**Root cause:** Multiple functions used `${ocp_channel:-fast}` as the default channel, while others used `${ocp_channel:-stable}`. The inconsistency could lead to unexpected behavior if `ocp_channel` is ever empty.
**Fix:** Standardized all 9 call sites to `${ocp_channel:-stable}` across `scripts/include_all.sh` (6), `scripts/reg-save.sh` (1), `scripts/tui-mirror.sh` (1), `tui/v2/tui-mirror.sh` (1). Also fixed 2 stale doc comments.

---

### Bug #1004: Subshell-echo antipattern for normalize-conf in multiple TUI functions
**Files:** `tui/v2/tui-cluster.sh`, `tui/v2/tui-lib.sh`, `tui/v2/abatui2.sh`, `tui/v2/tui-direct.sh`
**Severity:** Low — stylistic inconsistency, fragile for future maintenance
**Status:** FIXED ✅ (commit 2b0af65d)
**Root cause:** Six call sites used `$(source <(normalize-*-conf) && echo "$var")` to extract a single variable, instead of sourcing directly.
**Fix:** All 6 sites replaced with direct `source <(normalize-*-conf) 2>/dev/null || true` then `$var` usage.

### Bug #1005: DISCO menu case statement has inconsistent indentation
**File:** `tui/v2/tui-disco.sh` — lines 335-354
**Severity:** Cosmetic — no functional impact
**Status:** FIXED ✅ (commit 2b0af65d)
**Fix:** Re-indented 3 case branches (SETTINGS, FEEDBACK, ADVANCED) and closing esac/done to match surrounding code.

---

### Bug #1011: DISCO Day-2 label says "after mirror load/sync"
**File:** `tui/v2/tui-cluster.sh` — Day-2 menu item `R` (~line 2217)
**Severity:** Low — wrong action name in the disconnected menu
**Status:** OPEN — verified 2026-11-06 in tmux `tui-debugging` on disco
**What happened:** Fully Disconnected main menu → Day-2. The first item reads `Configure OperatorHub (after mirror load/sync)`. The suffix is hidden only when `_TUI_MODE == DIRECT`. DISCO has Load, not Sync.
**Suggested fix:** In DISCO, say `(after mirror load)`. Keep `(after mirror load/sync)` for CONNO only.

### Bug #1012: Wizard platform toggle writes aba.conf before Next or ESC
**File:** `tui/v2/tui-cluster.sh` — `_cluster_page_basics`, platform case `P`
**Severity:** Medium — a cancelled wizard still changes the install platform
**Status:** OPEN — verified 2026-11-06 in tmux `tui-debugging` on disco
**What happened:** Cluster wizard page 1, platform was `vmw (VMware/ESXi) ✓`. Pressing `P` then Enter switched the row to `kvm (libvirt/KVM) ⚠` and immediately wrote `platform=kvm` in `~/aba/aba.conf`. Wizard help says ESC returns to the main menu. ESC does that, and it does not put the old platform back. Restored `platform=vmw` with two more toggles (kvm → bm → vmw) so the host was not left on kvm.
**Suggested fix:** Keep the new platform in wizard state until Next persists the draft. On ESC from page 1, leave `aba.conf` unchanged.

### Bug #1013: Refresh offers to destroy VMs for a cluster that was never installed
**File:** `tui/v2/tui-lib.sh` `tui_cluster_menu_flags`; `tui/v2/tui-cluster.sh` `_day2_refresh` and `cluster_delete`
**Severity:** Medium — the confirm dialog describes VM destruction that does not match this cluster
**Status:** OPEN — verified 2026-11-06 (Refresh) and 2026-11-07 (Delete) in tmux `tui-debugging` on disco. Both dialogs cancelled (Cancel was focused).
**Delete, 2026-11-07:** Day-2 → Delete lists `sno.example.com` with no status. Confirm text: "This removes all cluster state and destroys the VMs." The directory has never been installed.
**Clean, 2026-11-07, conno:** Day-2 → Clean lists the same never-installed `sno.example.com` with no status. Confirm text says it removes an ISO and install-config so you can retry a failed install. There is no ISO. Cancel was focused. Same missing "not installed" tag as Delete and Refresh.
**What happened:** disco `sno/` has `cluster.conf` only (no ISO, no `.install-complete`). Advanced still lists `Refresh Cluster (recreate VMs, new install)` because `_CLUSTER_DAY2_AVAIL` is true for any cluster directory. The picker shows `sno.example.com` with no status. Confirm text: "This will destroy existing VMs and trigger a fresh installation. All current cluster data will be lost." `cluster_installed_platform` is empty, so the code uses `aba.conf` `platform=vmw` and assumes VMs exist. `cluster_delete` uses that same fallback.
**Suggested fix:** If there is no install state (no ISO, no kubeconfig, no `.install-complete`), say there is nothing to destroy. Annotate the picker with `not installed`. Do not offer Refresh until an install has been started.

### Bug #1014: Invalid cluster name error does not say why
**File:** `scripts/aba.sh` early `--name` check (~line 147); prompt in `tui/v2/tui-strings2.sh` `TUI2_MSG_CLUSTER_NAME_PROMPT`
**Severity:** Low — the wizard rejects a name and does not explain the rule
**Status:** OPEN — verified 2026-11-06 in tmux `tui-debugging` on disco
**What happened:** Name prompt: `Enter cluster name (DNS label: a-z, 0-9, hyphens, max 63)`. Entering `1bad` shows only `Error: invalid cluster name '1bad'`. That string is the early check in `aba.sh`, which exits before `_valid_cluster_name`. The later function's message says "must be a DNS label (lowercase letters, digits, hyphens; start with letter; max 63 chars)". A regex-valid reserved name (`scripts`) does reach that function and shows `Error: 'scripts' is a reserved ABA directory name — choose a different cluster name`.
**Suggested fix:** Use that same explanation in the early `--name` check. Say "must start with a letter" in the wizard prompt.

### Bug #1015: Wizard accepts a starting IP outside the machine network
**File:** `tui/v2/tui-cluster.sh` — `_cluster_page_network` (Starting IP and Next)
**Severity:** Medium — Next writes a cluster.conf the installer will reject
**Status:** OPEN — verified 2026-11-06 in tmux `tui-debugging` on disco. Restored `starting_ip=10.0.1.201` afterwards. Gateway path verified 2026-11-07: `192.168.9.1` was accepted and Next wrote `next_hop_address=192.168.9.1`, then restored to `10.0.0.1`.
**What happened:** Networking page showed machine network `10.0.0.0/20` and starting IP `10.0.1.201`. Replacing the starting IP with `192.168.9.9` was accepted (format-only check). Next advanced to Interfaces and wrote `starting_ip=192.168.9.9` into `sno/cluster.conf`. No warning that the address is outside the CIDR. The gateway row does the same: `192.168.9.1` was accepted and written while the subnet stayed `10.0.0.0/20`. `verify-cluster-conf` does that check later, at install time.
**Suggested fix:** On Next, reject a starting IP that is outside `machine_network`, and reject a gateway outside that CIDR the same way.

### Bug #1016: DISCO image-source row does nothing when it is already "mirror"
**File:** `tui/v2/tui-cluster.sh` — `_cluster_page_iface` case `C` for DISCO
**Severity:** Low — the row looks editable and gives no feedback
**Status:** OPEN — verified 2026-11-06 in tmux `tui-debugging` on disco
**What happened:** Interfaces page, `Image source: mirror (disco.example.com:8443)`. Selecting it left the same screen. The code only pops a message when the value is not already `mirror`. Page 1 help still lists `mirror | proxy | direct` for every mode.
**Suggested fix:** Always show "In disconnected mode only mirror is available" when the row is selected. Limit that help line to the modes that actually offer a choice.

### Bug #1017: Prepare Upgrade help says Next downloads, and calls aba.conf the mirrored version
**File:** `tui/v2/tui-mirror.sh` — `mirror_prep_upgrade` help text (~line 1009)
**Severity:** Low — the dialog itself is usable; the help steers the next key wrong
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on conno
**What happened:** Payload → Prepare Upgrade, then Help. The help says "Next downloads it. Cancel changes nothing." and "Base version (b) is the version already mirrored." On this host Next only opens a second menu (sync, save, or set the target and skip the download). The dialog labels the base as `aba.conf` `4.21.40`, while the main menu says the mirror is `(synced 4.22.22)`.
**Suggested fix:** Say that Next asks how to mirror, and that the base version is `aba.conf`, not whatever is already in the registry.

### Bug #1018: rc target on the fast channel is reported as unreleased
**File:** `tui/v2/tui-mirror.sh` — `mirror_prep_upgrade` (~line 1141)
**Severity:** Medium — the input box invites `x.y.z-rc.N`, then the error hides where that version actually is
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on conno
**What happened:** Prepare Upgrade → manual entry `4.21.0-rc.2` on channel `fast`. Dialog: "Version 4.21.0-rc.2 not found in 'fast' channel. This version may not have been released yet." Cincinnati `candidate-4.21` does list `4.21.0-rc.2`. `aba` itself says a pre-release is published on the candidate channel. The TUI drops that hint. Nothing was saved.
**Suggested fix:** When the version string is a pre-release and it is missing from the current channel, say it is published on `candidate` and offer to switch. Do not say it may be unreleased when the candidate graph contains it.

### Bug #1019: Main menu hides an upgrade the bundle dialog still shows
**File:** `tui/v2/abatui2.sh` status line (~line 648); bundle summary in `tui/v2/tui-mirror.sh` `mirror_create_bundle`
**Severity:** Medium — the two screens disagree about what the next sync or bundle will mirror
**Status:** OPEN — first seen 2026-11-07. Rechecked 2026-11-08: the dialog now says `OCP: 4.21.40 (fast)` and the ImageSet max is `4.21.40`. The arrow is gone. The menu still says synced and saved `4.22.22` (Bug #1044). Dialog cancelled. No bundle was started.
**What happened:** Main menu: `Mirror Payload (4.21.40 fast)`, `Sync (synced 4.22.22)`, status `mirror ready`, no upgrade target. Create Install Bundle says `OCP: 4.21.40 → 4.22.22 (fast)`. `mirror.conf` has no `ocp_upgrade_to`. `mirror/data/imageset-config.yaml` (00:01) still has `minVersion: 4.21.40` and `maxVersion: 4.22.22`. `mirror.conf` was written later (00:26) without regenerating that file. The menu reads `ocp_upgrade_to`. The bundle dialog reads the ImageSet.
**Suggested fix:** Show the ImageSet range on the main menu when `maxVersion` is newer than `ocp_version`. Regenerating the ImageSet when the upgrade target is cleared would make the two screens match.

### Bug #1020: Clean ABA help, menu, and confirm describe three different actions
**File:** `tui/v2/tui-cluster.sh` Advanced menu (~lines 2032, 2063, 2081); `README.md` command table; `Makefile` `clean` and `mirror/Makefile` `clean`
**Severity:** Medium — the confirm is the last text before a destructive command, and it does not match the command
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on conno. Confirm cancelled (Cancel was focused).
**What happened:** Advanced shows `Clean ABA (remove config and state)`. Help says it removes configuration and state and keeps mirror installers. The confirm says it removes configuration, state files, and mirror installers, and that this is `aba clean`. README says `aba clean` removes generated files and preserves configuration. Top-level `make clean` does not remove `aba.conf`. `mirror/Makefile` `clean` keeps `mirror.conf` and `data/` tarballs, and deletes `mirror-registry`, `image-archive.tar`, `execution-environment.tar`, and `sqlite3.tar`.
**Suggested fix:** Make the menu, help, and confirm match `aba clean`: generated files go, configuration stays, say exactly which installer files are deleted.

### Bug #1021: Version help says Previous is one release back
**File:** `tui/v2/tui-direct.sh` — `_direct_version` help (~line 620)
**Severity:** Medium — the help describes a z-stream step, and the menu is showing another minor
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on conno. Nothing was saved (`ocp_version` stayed `4.21.40`).
**What happened:** Mirror Payload → OCP Version, channel `fast`. The list is Current `4.21.40`, Latest `5.0.1`, Previous `4.22.22`, Older `4.21.42`. Help says "Previous: one release back (good for stability)" and "Older: the one before Previous". `4.22.22` is not one release before `5.0.1`.
**Suggested fix:** Say Previous and Older are the latest builds of the two previous minors, not the previous z-stream.

### Bug #1022: Version manual-entry error ignores its own help about candidate
**File:** `tui/v2/tui-direct.sh` — `_direct_version` (~line 589); menu label ~line 552
**Severity:** Medium — same miss as #1018, on the version screen whose help already has the right sentence
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on conno. Confirm was declined. `aba.conf` unchanged.
**What happened:** The version row says `Manual entry (x.y or x.y.z)`. The input box accepts `x.y.z-rc.N`. Entering `4.21.0-rc.2` on `fast` shows "Version 4.21.0-rc.2 not found in the fast channel. Check the version number and try again." The help on that same screen says a pre-release is accepted only when the channel lists it, and that this is the candidate channel. Cincinnati `candidate-4.21` lists `4.21.0-rc.2`.
**Suggested fix:** Use that help sentence in the error, and mention `rc` on the menu row.

### Bug #1023: Install channel list has no EUS, upgrade channel list does
**File:** `tui/v2/tui-direct.sh` `_direct_channel` (~line 392); `tui/v2/tui-mirror.sh` `mirror_prep_upgrade` channel menu (~line 1078)
**Severity:** Medium — an EUS cluster cannot be selected from the version screen
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on conno. Channel left at `fast`.
**What happened:** Mirror Payload → OCP Version lists only stable, fast, and candidate. Help on that screen lists the same three. Prepare Upgrade → Change channel lists those three plus `eus — Extended Update Support`. Choosing EUS there writes `aba.conf` immediately. The version screen never offers it.
**Suggested fix:** Offer EUS on the version channel screen, with the same four-line help.

### Bug #1024: Confirm Exit defaults to Exit, and a second ESC quits
**File:** `tui/v2/tui-lib.sh` `confirm_quit` (~line 415)
**Severity:** Medium — ESC then Enter, or ESC twice, leaves the TUI
**Status:** OPEN — the focused Exit button was verified 2026-11-07 in tmux `tui-debugging` on conno. Continue was selected, so the session stayed up. The second-ESC path was not pressed.
**What happened:** ESC on the main menu asks "Exit ABA TUI?" The focused button is Exit, not Continue. Clean, Delete, and Refresh use `--defaultno`, so Enter cancels. This dialog does not. The same function treats a second ESC (dialog rc 255) as quit. A key that arrives late, or a second ESC, ends the session.
**Suggested fix:** Use `--defaultno` so Enter and ESC stay in the TUI. Quit only from the Exit button.

### Bug #1025: CONNO help lists Monitor Installation when that item is hidden
**File:** `tui/v2/abatui2.sh` CONNO help (~line 703); menu item added only when `_CLUSTER_MON_AVAIL` is true (~line 666)
**Severity:** Low — the help names a step that is not on the menu
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on conno
**What happened:** Main menu help under Cluster says "Monitor Installation — watch install progress". The menu on screen has Install Cluster and Day-2, and no Monitor row. That row is added only while a cluster is installing. Bug #500 fixed the same claim in the DIRECT help.
**Suggested fix:** Say Monitor appears on the menu only while an install is in progress.

### Bug #1026: Wizard accepts a machine network that is not a network address
**File:** `tui/v2/tui-lib.sh` `_valid_cidr` (~line 87); `tui/v2/tui-cluster.sh` `_cluster_page_network` case `M` and Next (`rc == 3`)
**Severity:** Medium — Next writes a CIDR the installer will not treat as the subnet base
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on disco. Restored `machine_network=10.0.0.0/20` afterwards. `starting_ip` stayed `10.0.1.201`.
**What happened:** Networking page showed `10.0.0.0/20`. Replacing it with `10.0.1.5/20` was accepted. Next advanced to Interfaces and wrote `machine_network=10.0.1.5/20` into `sno/cluster.conf`. `_valid_cidr` checks dotted-quad form and a prefix of 0–32. It does not require the address to be the base of that prefix (`10.0.0.0` for a `/20`). Help only says "cluster subnet in CIDR (e.g. 10.0.0.0/24)".
**Suggested fix:** On the machine-network row and on Next, reject a CIDR whose host bits are set.

### Bug #1027: VLAN tag 09 is accepted
**File:** `tui/v2/tui-cluster.sh` — `_cluster_page_iface` case `V` (~line 1435)
**Severity:** Low — a tag with a leading zero is stored, and the range check never runs
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on disco. Cleared back to `(none)` before leaving. `sno/cluster.conf` `vlan=` stayed empty.
**What happened:** Interfaces page, VLAN was `(none)`. Entering `09` produced no error and the row became `VLAN: 09`. The check is `[[ "$vlan_val" -lt 1 || "$vlan_val" -gt 4094 ]]`. Bash treats a leading zero as octal, so `09` and `08` make that comparison fail with "value too great for base". The `if` then does not reject the value.
**Suggested fix:** Compare with `10#$vlan_val` so the number is decimal. Reject anything other than a decimal integer from 1 to 4094.

### Bug #1028: Master memory 08 GB is accepted
**File:** `tui/v2/tui-cluster.sh` — `_cluster_page_vm` cases `C`, `R`, `W`, `E`, `D` (~lines 1580–1640)
**Severity:** Medium — a value below the stated minimum is kept
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on disco. Restored the row to `20 GB` before ESC. `sno/cluster.conf` stayed `master_mem=20`.
**What happened:** VM Resources, Master Memory was `20 GB`. Help says the minimum is 16 GB. Entering `08` produced no "Must be at least 16 GB" dialog. The row became `Master Memory: 08 GB`. Same octal comparison as #1027: `08` makes `[[ "$val" -lt 16 ]]` fail, so the minimum is not applied. The same pattern is on master CPU (min 4), worker CPU (min 2), worker memory (min 8), and data disk.
**Suggested fix:** Use `10#$val` for these minimum checks. Reject a leading zero. On vSphere, `cluster.conf` comments say master memory minimum is 20 GB, while this page enforces 16.

### Bug #1029: MAC template prompt shows an example the field rejects
**File:** `tui/v2/tui-strings2.sh` `TUI2_MSG_VM_MAC_PROMPT`; `tui/v2/tui-cluster.sh` VM page help (~line 1561) and case `A` (~line 1648)
**Severity:** Medium — the example in the input box cannot be saved
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on disco. Error dismissed. `sno/cluster.conf` stayed `mac_prefix=00:50:56:0x:xx:`.
**What happened:** VM Resources → MAC template. The box says `MAC address prefix (e.g. 52:54:00):`. Entering `52:54:00` shows "Invalid MAC prefix. Expected: 5 hex octets with trailing colon" and examples `00:50:56:1a:2b:` and `00:50:56:xx:xx:`. The page help gives a third shape, `00:50:56:xx`, and says the last 3 octets are auto-filled. The stored prefix is five octets plus a trailing colon. The generator appends one more octet.
**Suggested fix:** Use `00:50:56:xx:xx:` in the prompt and in the page help. Say the last octet is filled per VM.

### Bug #1030: Operator search stops after 100 catalog lines and does not say so
**File:** `tui/v2/tui-mirror.sh` — `_operator_search` (~line 2035)
**Severity:** Medium — a broad search looks complete and omits later operators
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on conno. Back was used. `ops=` and `op_sets=` stayed empty.
**What happened:** Select Operators → Search, query `operator`. The list scrolled to 100% and the last row was `rook-ceph-operator` (Rook-Ceph, redhat). The dialog says only "Select to add/remove from selection:". The three 4.21 indexes have 492 lines containing `operator`. The next unique match, `run-once-duration-override-operator`, was not in the list. The search pipeline keeps `head -100` lines before building the checklist.
**Suggested fix:** Drop the 100-line cap, or say how many matches were left out and offer a narrower search.

### Bug #1031: Install review focuses Install, so Enter starts the cluster
**File:** `tui/v2/tui-cluster.sh` — `_cluster_execute` review (~line 1782)
**Severity:** Medium — the last confirm before VMs are created treats Enter as yes
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on disco. Back was selected. `sno/cluster.conf` stayed on `10.0.0.0/20`, `10.0.1.201`, `10.0.0.1`, `master_mem=20`. No install process was started.
**What happened:** The wizard review says "Review — Confirm before installing:" for `sno.example.com`, `4.21.40 (fast)`, Fully Disconnected, mirror `disco.example.com:8443`. The focused button is Install. Back is not focused. Delete, Clean, and Refresh use `--defaultno`, so Enter cancels those. This dialog does not. Enter here runs `aba cluster --name sno`.
**Suggested fix:** Use `--defaultno` so Enter and ESC return to the VM page. Start the install only from the Install button.

### Bug #1032: Additional Images help lists rows the empty menu does not have
**File:** `tui/v2/tui-mirror.sh` — additional-images help (~line 2520); menu built ~line 2492
**Severity:** Low — the help names actions that are not on the screen
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on conno. `images.conf` was left empty.
**What happened:** Mirror Payload → Additional Images, with 0 images. The menu is Add image, Recommended Images, and Edit images.conf. Help also lists List, Remove, and "Delete all". Those rows are added only when `images.conf` has images, and the row is "Clear all images", not "Delete all". Help also describes the include/exclude toggle, which is hidden while the file is empty.
**Suggested fix:** Say List, Remove, Clear, and the include toggle appear after an image is added. Call that row Clear, matching the menu.

### Bug #1033: Base domain may start with an underscore
**File:** `scripts/include_all.sh` — `_valid_domain` (~line 1313); `tui/v2/tui-cluster.sh` case `D` (~line 1057)
**Severity:** Medium — Next would write a name that is not a DNS hostname
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on disco. The row was put back to `example.com` before ESC. `sno/cluster.conf` stayed `base_domain=example.com`.
**What happened:** Cluster Basics → Base domain. The prompt says a valid domain such as `example.com` or `ocp.local`. Entering `_lab.example.com` produced no error and the row became `_lab.example.com`. `_valid_domain` allows `_` in any label, including the first character. An API name built from that domain is not a DNS hostname.
**Suggested fix:** Use the same hostname rules as a cluster name: letters, digits, and hyphens, no leading or trailing hyphen, and no underscores.

### Bug #1034: Interfaces help describes MACs and skips SSH key
**File:** `tui/v2/tui-cluster.sh` — `_cluster_page_iface` help (~line 1387); menu rows ~line 1348
**Severity:** Low — the help does not match the rows on a VMware cluster
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on disco. Help closed. `ports` stayed `ens160` and `ssh_key_file` stayed `~/.ssh/id_rsa`.
**What happened:** Interfaces on platform vmw shows Ports, VLAN, Image source, and SSH key. There is no MACs row. Help covers Ports, VLAN, Image source, and "MACs (bare-metal only)". It never mentions the SSH key row. The MACs row is added only when the platform is bare-metal.
**Suggested fix:** Describe SSH key on this page. Describe MACs only when the platform is bare-metal.

### Bug #1035: Advanced help says uninstall deletes every image
**File:** `tui/v2/tui-cluster.sh` — Advanced help (~line 2051); uninstall dialog (~line 2134); Clean row omitted on DISCO (~line 2031)
**Severity:** Medium — the help describes a different uninstall than the confirm, and a row this menu does not have
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on disco. Uninstall was cancelled. Registry row still says `(installed)` and load still says `(loaded 4.21.40)`.
**What happened:** Advanced help says uninstall "Removes the mirror registry container and ALL mirrored data" and that you must re-sync afterward. The uninstall dialog says "The data directory is preserved by default (images survive for reinstall)." Delete-data was unchecked. The same help describes `R - Clean ABA`. The DISCO Advanced menu has no Clean row. That row is added only when the mode is not DISCO. The focused button on the uninstall dialog is Uninstall.
**Suggested fix:** Say the data directory is kept unless delete-data is checked. Drop the Clean paragraph on DISCO, where that row is hidden. Make Cancel the default button.

### Bug #1036: Cluster wizard help skips the base domain
**File:** `tui/v2/tui-cluster.sh` — wizard help on page 1 (~line 963); menu row ~line 940
**Severity:** Low — a required field is on the page and not in the help
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on disco. Help closed. `base_domain` stayed `example.com`.
**What happened:** Cluster Basics shows Platform, Cluster name, Base domain `example.com`, and Type. Help for page 1 lists Cluster name, Type, Worker count, and Platform. It does not mention Base domain.
**Suggested fix:** Add a base-domain line to that help: the DNS suffix, such as `example.com`, with no underscores.

### Bug #1037: Port name longer than 15 characters is accepted
**File:** `tui/v2/tui-lib.sh` — `_valid_port_names` (~line 152); `scripts/include_all.sh` — `_valid_port_name` (~line 1339)
**Severity:** Medium — Next would write a name the node cannot assign to a NIC
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on disco. The row was put back to `ens160` before ESC. `sno/cluster.conf` stayed `ports=ens160`.
**What happened:** Interfaces → Ports was `ens160`. Entering `longifacename001` (16 characters) produced no error and the row showed that name. The check allows letters, digits, dots, dashes, and underscores, with no length limit. A Linux interface name is at most 15 characters.
**Suggested fix:** Reject any port name longer than 15 characters, and say so in the error.

### Bug #1038: Clearing the MAC template shows (auto) and would save it empty
**File:** `tui/v2/tui-cluster.sh` — VM page case `A` (~line 1648) and the row label (~line 1533); `scripts/create-cluster-conf.sh` (~line 66)
**Severity:** Medium — Next writes a blank prefix, and an existing cluster file is not filled back in
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on disco. The prefix was typed back before ESC. `sno/cluster.conf` stayed `mac_prefix=00:50:56:0x:xx:`.
**What happened:** VM Resources showed `MAC template: 00:50:56:0x:xx:`. Clearing the input produced no error and the row became `(auto)`. An empty value is treated as "auto" only in the label. Next writes that empty value. For a cluster.conf that already exists, `create-cluster-conf.sh` fills empty network fields and exits. It does not restore `mac_prefix`. `verify-cluster-conf` then reports that `mac_prefix` is required for VMware. The default `00:50:56:0x:xx:` is applied only when the file is first created.
**Suggested fix:** If the field is cleared on vmw or kvm, keep the previous prefix or write the platform default. Do not label an empty value `(auto)` unless a later step fills it.

### Bug #1039: DNS accepts an octet with a leading zero
**File:** `tui/v2/tui-lib.sh` — `_valid_ip` (~line 75); `tui/v2/tui-cluster.sh` — DNS, starting IP, gateway, and VIP cases
**Severity:** Medium — Next would write an address a strict IPv4 parser rejects
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on disco. The row was put back to `10.0.1.8` before ESC. `sno/cluster.conf` stayed `dns_servers=10.0.1.8`.
**What happened:** Networking → DNS servers was `10.0.1.8`. Entering `10.0.1.08` produced no error and the row became `10.0.1.08`. `_valid_ip` accepts any octet from 0 to 255, including a leading zero. The same check is used for the starting IP, the gateway, and the API and ingress VIPs. NTP uses it too, and then also allows a hostname.
**Suggested fix:** Reject an octet that has a leading zero. Keep a single `0` as valid.

### Bug #1040: SSH says to create an ISO when the cluster was never installed
**File:** `tui/v2/tui-cluster.sh` — `_day2_ssh` (~line 2474)
**Severity:** Low — the next step it names is not a menu item on VMware
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on disco. Dialog dismissed. `sno/` has no `iso-agent-based` directory.
**What happened:** Day-2 → SSH into Rendezvous Server. The dialog says "No clusters with a rendezvous IP found. Create an ISO first." Platform is vmw. The main menu has Install Cluster, not Create ISO. The install wizard generates the ISO while it installs. This `sno` directory has only `cluster.conf`.
**Suggested fix:** On vmw and kvm, say to run Install Cluster. Mention an ISO only for bare metal, where the user boots the image.

### Bug #1041: Delete of a not-yet-installed cluster says the config files are missing
**File:** `scripts/vmw-delete.sh` (~line 16); `tui/v2/tui-cluster.sh` — `cluster_delete` (~line 1959)
**Severity:** Medium — the confirm says the VMs will be destroyed, then the command reports success and deletes nothing
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on disco. Delete was confirmed and run in the TUI. `sno/cluster.conf` is still there. No `install-config.yaml` or `agent-config.yaml`. `10.0.1.201` did not answer arping.
**What happened:** Day-2 → Delete, cluster `sno.example.com`, no status on the picker. The confirm says "This removes all cluster state and destroys the VMs." Run in TUI then showed Success: `[ABA] Cluster config files missing -- nothing to delete`. `vmw-delete.sh` prints that when `install-config.yaml` or `agent-config.yaml` is absent, and exits 0. `cluster.conf` is the file the wizard already wrote. Those two YAML files are created later, during install.
**Suggested fix:** If only `cluster.conf` exists, say there is no install to delete. Do not call that a missing-config success, and do not tell the user the VMs were destroyed.

### Bug #1042: Installer warns that image digest sources do not match the release image
**File:** `templates/install-config.yaml.j2` (~line 102); `templates/image-content-sources.yaml.j2`
**Severity:** Medium — the generated install config does not satisfy the installer's own check
**Status:** OPEN — verified 2026-11-07 in tmux `tui-debugging` on disco, during `aba cluster --name sno --step install`. The ISO build continued after the warning.
**What happened:** `openshift-install agent create image` printed: the imageDigestSources configuration should have at least one source matching `disco.example.com:8443/ocp4/openshift4/openshift/release-images@sha256:81e06ac11f83bba175fa3cd1693521c37e67eb343b66c1137c232df6fc32e67d`. `sno/install-config.yaml` has `ImageDigestSources` whose sources are `quay.io/openshift-release-dev/ocp-v4.0-art-dev` and `quay.io/openshift-release-dev/ocp-release`. The mirror URLs are under `mirrors`, not `source`. After install, the cluster's ImageDigestMirrorSet does contain those two mappings, so the field was applied. `image.config` spec is empty.
**Suggested fix:** Add a source equal to the mirrored release-images repository so the installer warning goes away. The release mirrors themselves did land in the cluster.

### Bug #1043: vSphere install tells the user to boot the nodes by USB or BMC
**File:** `scripts/bmc-boot.sh` (~line 39); `templates/Makefile.cluster` `.bm-bmc-boot-done` (~line 196)
**Severity:** Low — the install continues, but the log gives bare-metal instructions during a vSphere install
**Status:** OPEN — verified 2026-11-07 in the disco `sno` install log, after the VM was powered on
**What happened:** Platform is vmw. The VM `sno` was created and powered on. The next log line is `[ABA] BMC: bmc.conf absent - using manual virtual-media flow. Boot each node from the generated agent ISO (see bare-metal install instructions) via USB or BMC UI, then run aba mon.` There is no `bmc.conf`. The Makefile runs `bmc-boot.sh` for every platform and calls that path a no-op on vmw/kvm. The agent then came up on its own. The NTP warning cleared, and the host moved to preparing-for-installation.
**Suggested fix:** On vmw and kvm, write the stamp quietly. Print the USB/BMC instructions only when the platform is bare metal.

### Bug #1044: Save label stays on the old sync version
**File:** `scripts/reg-save.sh` (~line 262); `tui/v2/abatui2.sh` (~line 604)
**Severity:** Medium — the menu reports a saved version the ImageSet does not contain
**Status:** OPEN — verified 2026-11-07 on conno after the light bundle finished. Rechecked 2026-11-08 10:17: a sync of 4.21.40 wrote `mirror_ocp_version=4.21.40`, and both menu labels then showed 4.21.40. Save still does not update that field.
**What happened:** The bundle rewrote `imageset-config.yaml` to fast-4.21, min and max 4.21.40. The file is `/tmp/ocp-bundle-4.21.40-amd64-lite.tar`. `~/.aba/mirror/mirror/state.sh` then has `last_action=save` at 16:35, but `mirror_ocp_version` is still `4.22.22` from the earlier sync. `reg-save.sh` updates `last_action` and does not update `mirror_ocp_version`. The menu uses that field for both labels, so it shows `Sync images to mirror (synced 4.22.22)` and `Save images to disk (saved 4.22.22)`. The archive `mirror/data/mirror_000001.tar` (26G) contains 4.21.40 and also 4.22.18, 4.22.20, 4.22.21, and 4.22.22. The transfer tar's ImageSet is only 4.21.40.
**Suggested fix:** When a save finishes, set `mirror_ocp_version` from the ImageSet that was saved. Do not pack releases that ImageSet does not list.

### Bug #1045: Install progress stays still for the whole cluster bootstrap
**File:** `scripts/monitor-install.sh` (~line 43); `tui/v2/tui-progress.sh`
**Severity:** Medium — the dialog looks stuck during the longest part of the install
**Status:** OPEN — verified 2026-11-07 on disco from 16:44 to 17:22
**What happened:** After bootstrap completed, the TUI stayed on Monitor installation, In Progress, overall 36%. The output log's last line is `Waiting up to 40m0s (until 5:24PM +08) for the cluster at https://api.sno.example.com:6443 to initialize...` and that file was not updated after 16:44. In the same window `iso-agent-based/.openshift_install.log` recorded disk write to 100%, bootstrap complete, then cluster init from 0% to about 70%, and `https://api.sno.example.com:6443/readyz` returned 200. `monitor-install.sh` emits `START|ci_mon` and then runs `openshift-install` at the default log level. The init percentages are debug lines, so they never reach the dialog.
**Suggested fix:** Pass the installer's progress through to the dialog while Monitor is in progress, and move the overall percentage as those stages complete.

### Bug #1046: Install is reported failed while the cluster is up
**File:** `scripts/monitor-install.sh` (~line 72); `tui/v2/tui-progress.sh` (~line 540)
**Severity:** High — a live cluster is left without `.install-complete`, and the dialog does not say it is still coming up
**Status:** OPEN — verified 2026-11-07 on disco at 17:24
**What happened:** `openshift-install agent wait-for install-complete` timed out: `Cluster operators authentication, console, openshift-samples are not available`. The TUI then showed `Install Cluster: sno.example.com: Error`, `Failed: Monitor installation`, `A step failed.` The buttons are Dismiss, Retry, and View Output. About a minute later `authentication` and `console` were Available at 4.21.40. By 17:52 every ClusterOperator was Available, including `openshift-samples`, and node `sno` was Ready. The error dialog was still up. `sno/.install-complete` was still missing. The resume hint (`The cluster may need more time`) is only in the output log.
**Suggested fix:** When the API is up at the timeout, say the cluster is installed and still settling, and keep monitoring instead of a bare failure.

### Bug #1047: Disconnected install leaves openshift-samples unable to become Available
**File:** `templates/install-config.yaml.j2` (~line 102); `templates/image-content-sources.yaml.j2`
**Severity:** High — the install times out on this operator, which only becomes Available afterward
**Status:** OPEN — verified 2026-11-07 on the disco `sno` cluster. At 17:52 the ClusterOperator was Available and `managementState` was still `Removed`. Rechecked 2026-11-08 06:52: `managementState` is still `Removed`. Day-2 status shows the operator Available at 4.21.40.
**What happened:** `configs.samples.operator.openshift.io/cluster` has `managementState: Removed` and an empty `samplesRegistry`. At the timeout the ClusterOperator had no version and no conditions. Its log says imagestream creation from quay.io is blocked, then `test connection with timeout failed` while dialing public addresses (`34.236.223.30:443`, `100.61.213.81:443`, `52.20.26.193:443`). Disco has no internet. The install timed out on this operator. About five minutes later the ClusterOperator became Available at 4.21.40 while `managementState` stayed `Removed`. The cluster ImageDigestMirrorSet only maps the two release repositories (`ocp-v4.0-art-dev` and `ocp-release`). It does not cover the registries the samples operator probes.
**Suggested fix:** Point samples at the mirror, or set the operator so it reports Available without calling the public registry. The install-complete wait should not depend on an operator that has removed itself.

### Bug #1048: Retry waits five minutes for an agent that is already gone
**File:** `scripts/wait-agent-up.sh` (~line 44); `templates/Makefile.cluster` `.install-complete` (~line 240)
**Severity:** Medium — Retry on a running cluster sits on a dead port before it will monitor
**Status:** OPEN — verified 2026-11-07 on disco. Retry was pressed after every ClusterOperator was Available and node `sno` was Ready.
**What happened:** The error dialog's Retry button is focused after one Tab from Dismiss. Enter started `aba cluster --name sno --step install` again. The stamps `.vms-ready` and `.bm-bmc-boot-done` were already present, so Make went to `.install-complete`. That recipe always runs `wait-agent-up.sh` first. The log is `Waiting for Agent at http://10.0.1.201:8090/ (max 5m)`. The progress dialog went back to 0% with every step N/A. Port 8090 is the agent API from before bootstrap. The node has been Ready for about an hour.
**Suggested fix:** Skip the agent wait when the Cluster API is already answering. Retry should continue at Monitor.

### Bug #1049: OSUS failure is labeled as an access failure
**File:** `scripts/day2-config-osus.sh` (~line 162); `tui/v2/tui-progress.sh`
**Severity:** Medium — the dialog names the wrong step, and Continue runs day2 again before the same error
**Status:** OPEN — verified 2026-11-07 on disco after OperatorHub and NTP had succeeded
**What happened:** Day-2 → OSUS. The warning says the Cincinnati operator is not available and asks "Continue anyway?" Continue is the focused button. Enter started `aba --dir sno day2-osus --yes`. There were no CatalogSources, so the script asked to run day2 and `--yes` answered yes. Day2 completed again and still created no catalogs, because no operators are mirrored. The script then printed `No operator catalogs are mirrored. OSUS requires the 'redhat-operators' catalog.` The TUI error dialog says `Failed: Access cluster`. Access had succeeded. `DONE|osus_access` is emitted only after the catalog check, so the abort is charged to the step that was still open.
**Suggested fix:** Finish the access step before the catalog check. When no catalogs are mirrored, stop there instead of running day2 again. Name the missing catalog in the dialog.

### Bug #1050: Disconnected upgrade help points at a key the connected menu does not have
**File:** `tui/v2/tui-cluster.sh` (~line 2610)
**Severity:** Low — the cluster correctly has no upgrade, and the next step tells you to press the wrong key
**Status:** OPEN — verified 2026-11-07 on disco, Day-2 → Upgrade, for `sno.example.com` at 4.21.40
**What happened:** The dialog says no upgrade versions are available. The connected-host step is `1. Prepare Upgrade for Transfer (U)`. On the connected menu, U is not a top-level key. Prepare Upgrade is Mirror Payload (P), then U. The same file's connected hint says `Mirror Payload (P) → Prepare Upgrade (U)`.
**Suggested fix:** Use the same P → U path in the disconnected hint.

### Bug #1051: Missing virtualization is reported as Stopped
**File:** `scripts/day2-config-virt.sh` (~line 93); `tui/v2/tui-progress.sh` (~line 561)
**Severity:** Medium — the dialog does not say that OpenShift Virtualization is absent
**Status:** OPEN — verified 2026-11-07 on disco, Day-2 → Virtualization Boot Sources. The same Stopped dialog appeared 2026-11-08 on kvm1 for direct OSUS: `day2-config-osus.sh` exits 0 on purpose when the cluster is not using a mirror, and it does not emit DONE. The reason is only in the output log.
**What happened:** The warning says kubevirt-hyperconverged is not available and asks "Continue anyway?" Continue is focused. The command then printed `OpenShift Virtualization is not installed` and exited 0. It never emitted DONE for the steps. The TUI showed `Day-2: day2-virt: Stopped` and `Stopped before all steps finished.` The reason is only in the output log.
**Suggested fix:** Exit non-zero with that reason so the dialog shows it. Do not use exit 0 for a missing operator.

### Bug #1052: Clean still says retry install after the cluster is installed
**File:** `tui/v2/tui-cluster.sh` (~line 2228 and ~line 2881)
**Severity:** Low — Clean is refused, and the refusal text is accurate
**Status:** OPEN — verified 2026-11-07 on disco after sno.example.com was installed, shut down, and started again
**What happened:** The Day-2 row is `Clean (remove artifacts, retry install)`. The picker shows `sno.example.com (installed)`. Selecting it says Clean is refused while `.install-complete` exists, because it would remove install config and leave the VMs running, and to use Delete first. The row still describes a retry of a failed install.
**Suggested fix:** Hide Clean when the selected cluster is installed, or change the row to say Clean is only for a failed install.

### Bug #1053: Bare-metal review allows Install when no MAC addresses are set
**File:** `tui/v2/tui-cluster.sh` review (~line 1765); `scripts/bm-ask-edit.sh` (~line 156)
**Severity:** Medium — Install starts, then stops, and the stop question defaults to re-checking an empty list
**Status:** OPEN — verified 2026-11-07 on disco for `sno2` (platform bm)
**What happened:** Interfaces showed `MACs: (none — paste to add)`. Next was accepted. The review for `sno2.example.com` listed ports, image source, and SSH key, and did not mention MACs. Install was focused. Enter started the install. It stopped on `Have all 1 required MAC addresses been added?` with Yes focused. Yes only re-checks. No stopped the run. The error dialog then said the MAC addresses are not ready. After one MAC was saved, the review showed it.
**Suggested fix:** On bare metal, block Next and Install until every required MAC is present, and show `MACs: (none)` on the review. Point the empty-list question at No.

### Bug #1054: An arrow key quits the install progress screen
**File:** `tui/v2/tui-progress.sh` (~line 789)
**Severity:** High — a navigation key abandons a running install
**Status:** OPEN — verified 2026-11-07 on disco during the `sno2` bare-metal install
**What happened:** The gauge was up (`Review/generate configs` in progress, 0%). `bm-ask-edit.sh` was blocked on `Are the MAC addresses correct?` and that question was only in the output log. The gauge subtitle was still `Output (Space)` / `Quit (Q/ESC)`, not the "needs input" line. Pressing Down returned to the main menu. The install process was gone. The key reader takes one byte and treats ESC as Quit. Arrow keys start with ESC.
**Suggested fix:** Ignore a lone ESC unless it is a complete key, and read the rest of an arrow sequence. Show the pending Yes/No as soon as the PROMPT event arrives.

### Bug #1055: Bare-metal boot question defaults to Yes before anything is booted
**File:** `scripts/bm-ask-boot.sh` (~line 135)
**Severity:** Medium — Enter starts monitoring when the nodes are still off
**Status:** OPEN — verified 2026-11-07 on disco after the `sno2` ISO was built
**What happened:** The ISO `sno2/iso-agent-based/agent.x86_64.iso` (1.3G) had just been written. The dialog asks `Have the servers been booted with the ISO file?` and explains USB, BMC, and PXE. Yes is focused. Nothing had been booted. `ask -y` is the default. No is the answer that stops so the servers can be booted.
**Suggested fix:** Default this question to No.

### Bug #1056: Section headers can be selected
**File:** `tui/v2/tui-cluster.sh` (~lines 2011, 2025, and 2216); `tui/v2/tui-mirror.sh` (~lines 1533 and 1537)
**Severity:** Low — Enter on the header does nothing
**Status:** OPEN — verified 2026-11-07 on conno Advanced, 2026-11-08 on Mirror Payload, and 2026-11-08 on disco Day-2
**What happened:** The rows `──── Switch Mode ────` and `──── Danger Zone ────` are menu items with an empty tag. Down from Switch to Fully Disconnected landed on Danger Zone, and that row was highlighted. Enter left the menu where it was. The same construction is on Mirror Payload: `──── Include / Exclude ─────` was highlighted, Enter left the menu where it was, and Release Images stayed `included`. On disco Day-2, `──── Cleanup ────` was highlighted and Enter left the menu where it was. An empty choice is ignored. The upgrade menu builds the same kind of row.
**Suggested fix:** Draw those labels as text, not as menu rows.

### Bug #1057: Direct install reports a rendezvous failure when the node cannot reach the release registry
**File:** `scripts/preflight-check.sh`; `scripts/monitor-install.sh`
**Severity:** Medium — preflight passes, then the install sits on a message that does not name the real failure
**Status:** OPEN — verified 2026-11-08 on conno, direct install of `sno2`
**What happened:** The review was fully connected, image source direct, machine network `10.0.0.0/20`, gateway `10.0.0.1`, DNS `10.0.1.8`. Preflight succeeded and the VM booted at 01:42. By 02:22 the node answered ping at `10.0.1.202` with the MAC from `agent-config.yaml`, and ports 22 and 8090 were connection refused. The monitor line, repeated 61 times, is `Cannot access Rendezvous Host. There may be a network configuration problem`. The VM console says `nslookup quay.io` works and `ping quay.io` fails with `Destination Host Unreachable`, then `https://quay.io` fails with `no route to host`. The release image URL on that screen is `quay.io/openshift-release-dev/ocp-release@sha256:81e06ac11f83bba175fa3cd1693521c37e67eb343b66c1137c232df6fc32e67d`.
**Suggested fix:** Before a direct install, check that the machine-network gateway can reach the release registry. While monitoring, say that the node is up and the agent port is closed when that is the case.

### Bug #1058: Refresh offers to destroy VMs for a cluster that was never installed
**File:** `tui/v2/tui-cluster.sh` — `_day2_refresh` (~line 2844)
**Severity:** Medium — Confirm would start a new install, and the dialog says VMs exist
**Status:** OPEN — verified 2026-11-08 on conno. Cancel was focused. Cancelled. No refresh was run. The same missing state file on disco, where `aba.conf` is `platform=bm`, shows a different dialog: "`sno2.example.com` was installed on bare metal, so there are no VMs to recreate." That dialog does not start an install. `sno2` had been installed and then deleted, so the sentence matches that history, but the code is reading the current `aba.conf` platform because `state.sh` is gone.
**What happened:** `sno2` has `cluster.conf` only. There is no `state.sh`, no ISO, and no VM named `sno2`. Advanced → Refresh Cluster. The confirm says "This will destroy existing VMs and trigger a fresh installation. All current cluster data will be lost." `cluster_installed_platform` finds no state file, so the dialog uses `aba.conf` `platform=vmw` and skips the bare-metal explanation.
**Suggested fix:** If the cluster has never been installed, say there are no VMs to refresh. Do not offer a fresh install from this dialog.

### Bug #1059: Advanced help lists Monitor when that row is hidden
**File:** `tui/v2/tui-cluster.sh` — Advanced help (~line 2056); menu row added only when `_CLUSTER_MON_AVAIL` is true (~line 2007)
**Severity:** Low — the help names a key that is not on the menu
**Status:** OPEN — verified 2026-11-08 on conno and on disco. Help closed. No install is running.
**What happened:** On conno, Advanced shows Platform, Stop, Start, Uninstall, X, Z, Refresh, and Clean. There is no `F` row and no `Y` row. On disco, Advanced shows Platform (bm), Stop, Start, Uninstall, X, Y, and Refresh. There is no `F` row, no `Z` row, and no Clean row. Help on both says `F - Monitor Cluster Installation` and `X/Y/Z - Switch Mode`. That Monitor row is added only while a cluster is installing.
**Suggested fix:** Describe Monitor only while that row is shown. Name the switch keys that this mode actually has.

### Bug #1060: Day-2 help says startup powers on VMs and delete destroys them
**File:** `tui/v2/tui-cluster.sh` — Day-2 help (~lines 2252 and 2256)
**Severity:** Low — the help describes a different action than bare metal performs
**Status:** OPEN — help text verified 2026-11-08 on disco. Bare-metal startup and delete were verified 2026-11-07 on `sno2`.
**What happened:** Day-2 help says "Startup: graceful cluster startup (powers on VMs)" and "Delete: destroy VMs and remove cluster state." On bare metal, startup tells the operator to power the servers and does not call the hypervisor. Delete says it removes state files only and leaves the servers running. `aba.conf` on disco is `platform=bm`. The installed `sno` cluster is vmw, so those two lines happen to match that one cluster.
**Suggested fix:** Say that vmw and kvm startup powers on VMs, and bare-metal startup waits for the servers. Say that delete destroys VMs only on vmw and kvm.

### Bug #1061: KVM reuse dialog shows OK and Cancel instead of the action names
**File:** `tui/v2/tui-cluster.sh` (~lines 265–269)
**Severity:** Low — OK does reuse the existing connection, but the other button does not say what it does
**Status:** OPEN — verified 2026-11-08 on kvm1.example.com (`dialog` 1.3-20210117)
**What happened:** The dialog argv is `--yes-label "Use Existing" --no-label "Configure New" --extra-label "Skip"`. The screen shows `<  OK  >`, `< Skip >`, and `<Cancel>`. OK was focused. Enter copied `~/.kvm.conf` into the tree and continued. Cancel is the "Configure New" action, not a cancel.
**Suggested fix:** Pass `--ok-label "Use Existing"` as well as `--yes-label`, and give the no button a label this dialog version actually draws.

### Bug #1062: setup dns points the host at 127.0.0.1 when dnsmasq never listens there
**File:** `tools/setup-dns.sh` (~lines 113–162)
**Severity:** High — the host loses DNS resolution and the script still says it succeeded
**Status:** OPEN — verified 2026-11-08 on kvm1.example.com
**What happened:** `/etc/dnsmasq.d/kvm-vlan.conf` already set `listen-address=10.10.123.1`. That listener is not a hackathon cluster VLAN. VLAN clusters belong on ESXi `10.0.1.40`. `aba setup dns -y --bastion-ip 10.0.1.10 --upstream 10.0.1.8` rewrote `/etc/resolv.conf` to `nameserver 127.0.0.1` and added `bind-dynamic`. dnsmasq stayed bound only to `10.10.123.1`. `dig @127.0.0.1` timed out. The script printed the warning and then "dnsmasq configured successfully." Adding `listen-address=127.0.0.1` and `listen-address=10.0.1.10` made it answer, including `quay.io` and `api.sno.example.com`.
**Suggested fix:** If another drop-in sets `listen-address`, add `127.0.0.1` and the bastion IP before the verify query. Do not report success when that query fails.

### Bug #1063: Day-2 success box cuts off the end of the direct-install message
**File:** `scripts/day2.sh` (~line 33); the TUI success dialog that shows that output
**Severity:** Low — the reason for the skip is the part that is missing
**Status:** OPEN — verified 2026-11-08 on kvm1 after `aba --dir sno3 day2`
**What happened:** The script prints `OperatorHub is already configured to pull from public registries — no mirror integration needed.` The success box shows the line through `— no` and the next line is blank. OK was focused.
**Suggested fix:** Wrap that sentence so the dialog shows `no mirror integration needed.`

### Bug #1064: setup dns publishes the mirror hostname on the default-route address
**File:** `scripts/infra-dns.sh` (`add-mirror`, ~lines 98–108), using `_pick_install_iface` in `scripts/include_all.sh` (~lines 4114–4119)
**Severity:** High — a node on the machine network is given an address it cannot route to
**Status:** OPEN — verified 2026-11-08 on conno.example.com
**What happened:** conno's default route is `ens192` `192.168.2.33`. The lab address is `ens224` `10.0.0.10`. `aba setup dns -y --bastion-ip 10.0.0.10 --upstream 10.0.1.8` wrote `dns_servers=10.0.0.10`, then `add-mirror` wrote `address=/conno.example.com/192.168.2.33` in `/etc/dnsmasq.d/aba-mirror.conf`. `dig @10.0.0.10 conno.example.com` returned `192.168.2.33`. On 2026-11-08 21:33 the compact nodes, which use that DNS server, stopped at the agent network screen: `conno.example.com` resolved to `192.168.2.33`, and `10.0.1.71` reported destination host unreachable for the release image on port 8443. The hackathon VLAN resolver on `10.10.100.1` was already answering `10.10.100.1` and was left as it is. After this confirmation, the lab record was changed to `10.0.0.10` so the compact install could continue. The product still writes the default-route address.
**Suggested fix:** Publish the registry name on the address passed as `--bastion-ip`, or on the interface that owns the machine network, rather than on the interface used for the default route.

### Bug #1065: OSUS with an empty update graph still offers every higher mirror tag
**File:** `scripts/cluster-upgrade.sh` (`--dry-run --shell`, ~lines 157–167)
**Severity:** High — Upgrade is the default button, and the highlighted target is a minor version the graph did not offer
**Mode:** CONNO
**Status:** OPEN — verified 2026-11-08 on conno, cluster sno2
**What happened:** After OSUS was installed, cluster status said version 4.21.40, channel fast-4.21, upstream set to the local OSUS route, and no updates available. Day-2 Upgrade then showed `Current: 4.21.40 (fast-4.21) [OSUS]` and listed 4.22.22 (newest) and 4.22.21 under Minor upgrade. Those tags are leftover registry tags. The classifier treats an empty graph (`_has_graph` unset) the same as OSUS not being configured, so every higher mirror tag becomes a recommended version. Back was selected. No upgrade started. The same list appeared on compact.example.com at 23:13, after OSUS was installed there. `oc` showed no available or conditional updates. The menu still offered 4.22.22 and 4.22.21, with Upgrade focused. Back was selected.
**Suggested fix:** When `spec.upstream` is set and both `availableUpdates` and `conditionalUpdates` are empty after the short poll, do not put higher mirror tags into `upgrade_versions`.

### Bug #1066: IP math treats octets 08 and 09 as invalid octal
**File:** `scripts/include_all.sh` (`ip_to_int` ~line 1123, `_valid_ipv4` ~line 1249, `ip_in_cidr` ~line 1136). `verify-cluster-conf` calls `ip_in_cidr` for `api_vip` after a regex check (~lines 2122–2124) that allows a leading zero.
**Severity:** Medium — a VIP inside the machine network is reported as outside it, and the user sees a bash error
**Mode:** ALL
**Status:** OPEN — verified 2026-11-08 by `verify-cluster-conf` with `api_vip=10.0.1.08` and `machine_network=10.0.0.0/20`
**What happened:** `ip_to_int 10.0.1.8` returns 167772424. `ip_to_int 10.0.1.08` and `10.0.1.09` print `value too great for base` and return nothing. `verify-cluster-conf` then says `api_vip (10.0.1.08) is outside the machine_network (10.0.0.0/20)`. 10.0.1.8 is inside that network. Re-checked 2026-11-09: `validate_ip` and `normalize_ipv4` now accept a leading zero and print `10.0.1.8`, but `ip_to_int` still does not use base 10. A `starting_ip` of `10.0.1.08` therefore passes `validate_ip` and is then reported as outside `10.0.0.0/20`. The node-fit check also fails and says the last node IP would be `0.0.0.2`.
**Suggested fix:** Force base 10 in `ip_to_int` (`10#${octet}`). `normalize_ipv4` already does this. Call it before `ip_in_cidr` for `starting_ip`, `api_vip`, and `ingress_vip`.

### Bug #1067: SSH picker lists clusters that have no rendezvous IP
**File:** `tui/v2/tui-cluster.sh` (`_day2_ssh` ~lines 2502–2513), `tui/v2/tui-lib.sh` (`select_cluster` ~lines 1417–1426)
**Severity:** Medium — the menu offers a cluster the command cannot SSH to
**Mode:** CONNO
**Status:** OPEN — verified 2026-11-08 on conno
**What happened:** `_day2_ssh` builds a list of directories that contain `iso-agent-based/rendezvousIP`. When that list has more than one entry it calls `select_cluster` with no filter, and that dialog lists every cluster directory. The picker showed compact and sno2 as installed, plus `sno4.example.com` and `sno.example.com`. Those two directories have no `.install-complete` and no `rendezvousIP`. compact was selected. The other two were not.
**Suggested fix:** Pass the rendezvous candidates into the picker, or give `select_cluster` a filter that skips directories without `rendezvousIP`.

### Bug #1068: Install leaves the cluster on stable-4.21 when aba.conf says fast
**File:** `scripts/day2.sh` (no channel update after the API is reachable; a direct install returns at ~line 35). `scripts/day2-config-osus.sh` (~lines 319–336) and `scripts/cluster-upgrade.sh` (~lines 429–438) are the only places that run `oc adm upgrade channel`. `resolve_cluster_channel` in `scripts/include_all.sh` (~lines 3704–3777) describes `ocp_channel` as the install-time default.
**Severity:** Medium — the cluster runs, but its channel is not the channel selected in aba.conf
**Mode:** ALL
**Status:** OPEN — verified 2026-11-08 on the compact status screen, and 2026-11-09 with `oc` on disco sno and kvm1 sno3
**What happened:** Compact status, before OSUS, showed version 4.21.40, channel stable-4.21, upstream unset. The TUI payload was fast 4.21.40. OSUS later changed that cluster to fast-4.21. On disco, OSUS never succeeded. `aba.conf` is `ocp_channel=fast` and `ocp_version=4.21.40`. The ImageSet channel is `fast-4.21` with maxVersion 4.21.40. `oc get clusterversion` on sno.example.com still reports channel `stable-4.21`, upstream unset, version 4.21.40. Day-2 OperatorHub already completed and did not change it. The direct install sno3 on kvm1 has the same aba.conf and the same cluster result: stable-4.21, upstream unset, 4.21.40. `day2.sh` returns before any channel change when the cluster is not using a mirror. Nothing in install calls `resolve_cluster_channel`.
**Suggested fix:** Once the API is reachable after install, set the channel from `resolve_cluster_channel` when it differs. Do that for a direct install as well as a mirror install. Do not wait for OSUS or an upgrade.

### Bug #1069: aba status reports kvm when both hypervisor configs exist
**File:** `scripts/repo-status.sh` (~lines 86–88 and 219)
**Severity:** Medium — the status summary names the wrong hypervisor
**Mode:** CONNO
**Status:** OPEN — verified 2026-11-09 on conno with `aba status --all`
**What happened:** `aba.conf` is `platform=vmw`. `vmware.conf` and `kvm.conf` are both present. compact and sno2 are VMware clusters and both report running. `aba status --all` prints `Platform: kvm`. The script sets the platform to vmware when `vmware.conf` exists, then overwrites it to kvm when `kvm.conf` exists. It never reads `platform` from `aba.conf`.
**Suggested fix:** Use `platform` from `aba.conf` when it is set. When both config files exist and `platform` is unset, do not let `kvm.conf` replace vmware.

### Bug #1070: Cluster network and gateway guesses follow the default route
**File:** `scripts/include_all.sh` (`_pick_install_iface` ~lines 4126–4165, `get_machine_network` ~lines 4231–4270, `get_next_hop` ~lines 4195–4226)
**Severity:** High — a new cluster is aimed at the management LAN
**Mode:** CONNO
**Status:** OPEN — verified 2026-11-09 on conno by running those functions
**What happened:** conno's default route is `ens192` `192.168.2.33/24` via `192.168.2.1`. The lab NIC is `ens224` `10.0.0.10/20`. compact and sno2 use `10.0.0.0/20` and gateway `10.0.0.1`. `_pick_install_iface` returns `ens192`. `get_machine_network` returns `192.168.2.0/24`. `get_next_hop` returns `192.168.2.1`. Those are the values a new cluster gets when the fields are empty. This is the same interface choice as Bug #1064, which publishes the registry name on that address. The network and gateway guesses are a separate result.
**Suggested fix:** Prefer an address on the configured machine network when `aba.conf` already has one. When it does not, do not use the default-route NIC if another NIC has an RFC1918 address that is not the management LAN the default route uses. Ask when more than one NIC is up.

### Bug #1071: A VIP may be the gateway
**File:** `scripts/resolve-vips.sh` (~lines 104–113), `scripts/include_all.sh` (`_validate_network_consistency` ~lines 1208–1240)
**Severity:** High — the API address can be the subnet gateway
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `verify-cluster-conf` and the same address math `resolve-vips.sh` uses
**What happened:** For `machine_network=10.0.0.0/20`, `starting_ip=10.0.0.3`, and `next_hop_address=10.0.0.1`, the auto-allocator sets `api_vip` to `starting_ip-2`, which is `10.0.0.1`. That is the gateway. `verify-cluster-conf` exits 0 with `api_vip=10.0.0.1` and `ingress_vip=10.0.0.2`. The same function rejects a node IP that is the gateway (`starting_ip=10.0.0.1` reports a collision). It never compares `api_vip` or `ingress_vip` with `next_hop_address`.
**Suggested fix:** Reject a VIP that equals `next_hop_address`. When auto-allocating, skip the gateway and the network and broadcast addresses.

### Bug #1072: VMware MAC prefix xx can generate an address vSphere rejects
**File:** `scripts/create-agent-config.sh` (`replace_hash_with_random_hex` ~lines 86–102, MAC loop ~lines 201–206). `scripts/create-cluster-conf.sh` (~line 113) states the VMware range. `scripts/include_all.sh` `verify-cluster-conf` (~line 2208) accepts the prefix.
**Severity:** Medium — VM creation fails when the fourth octet is above 3F
**Mode:** CONNO
**Status:** OPEN — verified 2026-11-09 by running the generator and `verify-cluster-conf`
**What happened:** VMware MACs must be `00:50:56:00:00:00` through `00:50:56:3f:ff:ff`. `verify-cluster-conf` accepts `mac_prefix=00:50:56:xx:xx:` and exits 0. That string is also the example in the validator's error text. The generator replaces each `x` with a random hex digit, then appends the node index. In 40 runs, 34 addresses were outside the range, including `00:50:56:c4:bd:01` and `00:50:56:fd:95:01`. The built-in prefixes `00:50:56:0x:xx:`, `1x`, and `2x` stay inside the range. `vmw-create.sh` passes the generated address to govc with no range check.
**Suggested fix:** For `platform=vmw`, keep the fourth octet in `00`–`3f` when expanding `x`. Reject a saved prefix that can produce a byte above `3f`.

### Bug #1073: The last node may be the broadcast address
**File:** `scripts/include_all.sh` (`_validate_network_consistency` ~lines 1190–1198, the node-fit check in `verify-cluster-conf` ~lines 2138–2148). `scripts/create-agent-config.sh` (`generate_ip_array` ~lines 54–77, the render at ~line 327).
**Severity:** High — validation accepts the range, then the generated agent config has an empty address
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `verify-cluster-conf`, `generate_ip_array`, and the agent template
**What happened:** On `10.0.0.0/20`, broadcast is `10.0.15.255`. Three masters starting at `10.0.15.253` use `.253`, `.254`, and `.255`. `verify-cluster-conf` exits 0. It rejects a starting IP that is the broadcast, and it rejects a last IP outside the CIDR. `.255` is inside the CIDR, so the fit check passes. `generate_ip_array` stops at the last usable address, prints `Reached the end of the CIDR range.`, and returns only `10.0.15.253` and `10.0.15.254` with exit 0. The agent template's third `arr_ips` entry renders as an empty IP, and the render still succeeds.
**Suggested fix:** Reject a node range that includes the network or broadcast address. If generation cannot fill every node, abort before writing `agent-config.yaml`.

### Bug #1074: Preflight says the registry name resolves to the first host address
**File:** `scripts/preflight-check.sh` (`preflight_check_dns` ~lines 76–85)
**Severity:** High — the hint tells you to point cluster DNS at the management NIC
**Mode:** CONNO
**Status:** OPEN — verified 2026-11-09 on conno by running `preflight_check_dns`
**What happened:** With `dns_servers=192.168.2.1`, preflight warned that the server cannot resolve `conno.example.com`, then printed `resolves locally (-> 192.168.2.33)` and `set dns_servers=192.168.2.33`. `192.168.2.33` is the first address from `hostname -I` (`ens192`). The code stores the `getent` result in `_local_ip` and does not print it. `getent` returns an IPv6 address first. `dig` of the name returns `10.0.0.10`, which is `ens224`, where dnsmasq answers. Nodes on `10.0.0.0/20` cannot use `192.168.2.33` as their DNS server.
**Suggested fix:** Print the address the lookup returned. Recommend the address dnsmasq is listening on, or the bastion address on the machine network.

### Bug #1075: A missing minor version is saved as the previous minor
**File:** `scripts/include_all.sh` (`fetch_latest_z_version` ~lines 3302–3318). Callers: `scripts/aba.sh` (~lines 692, 762, 2172–2177), `tui/v2/tui-lib.sh` (`_resolve_minor_to_patch` ~lines 1599–1619), `tui/v2/tui-direct.sh` (~lines 496–507 and 594–603), `tui/v2/tui-mirror.sh` (~lines 1055–1061).
**Severity:** High — the version that is stored is not the minor that was typed
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by running `fetch_latest_z_version`, `_resolve_minor_to_patch`, and `verify_release_version_exists`
**What happened:** Fast `4.22` ends at `4.22.22`. Fast `4.23` has no releases. `fetch_latest_z_version fast 4.23` still returns `4.22.22` and exits 0, because an empty minor walks back one step. The TUI resolver prints `4.22.22` and exits 0, so the "no releases for this minor" dialog does not open. The direct-install and upgrade dialogs then keep that version. On the CLI path, `aba --version 4.23` expands the same way, and `verify_release_version_exists` accepts `4.22.22` because that build does exist. The substitution is only written to the debug log on the interactive prompt. `4.99` returns empty and exits 1, because `4.98` is empty too, so only a one-step gap is hidden. Nothing was written to `aba.conf`.
**Suggested fix:** When the requested minor has no releases, return failure. Do not substitute the previous minor. The callers already show "not found" when the function fails.

### Bug #1076: NTP preflight calls a server reachable when it never answers
**File:** `scripts/preflight-check.sh` (`preflight_check_ntp` ~lines 111–140)
**Severity:** High — a dead NTP server does not fail preflight
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 on conno by running `preflight_check_ntp`
**What happened:** The check uses `chronyd -Q` when `chronyd` is on `PATH`. Otherwise it runs `echo >/dev/udp/<host>/123` and treats a successful write as a reply. UDP does not wait for an NTP response. `chronyd -Q "server 192.0.2.1 iburst"` timed out (exit 124). The same address with `chronyd` removed from `PATH` printed `[ABA] NTP server 192.0.2.1 is reachable (UDP port 123)` and left warnings at 0 and errors at 0. The "all NTP servers are unreachable" error never runs. On this host `chronyd` is `/usr/sbin/chronyd`, so a `PATH` without `sbin` takes the same fallback even though chrony is installed.
**Suggested fix:** Count the server as reachable only after an NTP reply. If `chronyd` is not on `PATH`, say the check could not query NTP.

### Bug #1077: The upgrade list skips a reachable minor when the next one is empty
**File:** `scripts/include_all.sh` (`fetch_upgrade_targets` ~lines 3594–3621). The Prepare Upgrade menu reads this list.
**Severity:** High — a reachable next minor is left off the menu
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by running `fetch_upgrade_targets` and `verify_upgrade_path_exists`
**What happened:** Channel `eus-4.18` has `4.18.60`, and `4.16.73` is in that graph. `verify_upgrade_path_exists 4.16.73 4.18.60 eus` prints `REACHABLE=1 HOPS=2`. `fetch_upgrade_targets 4.16.73 eus` prints only `zstream 4.16.75`. The walk's first forward minor is `4.17`. That graph is empty (`nodes` is an empty list). Because this is the first probe, the code tries the next major, `5.0`, finds that empty too, and stops. It never reads `eus-4.18`. The same function from `4.21.40` on `fast` still shows `4.22.22`, because `4.22` has a graph. Nothing was written to `aba.conf`.
**Suggested fix:** Keep walking later minors after an empty one, up to the probe limit. Jump to the next major only after the current major has no further minors.

### Bug #1078: A failed node-update check is treated as finished
**File:** `scripts/include_all.sh` (`mcp_is_updated` ~lines 639–641). Callers: `scripts/day2.sh` (~lines 691–697), `scripts/day2-config-ntp.sh` (~lines 366–367), `scripts/day2-config-osus.sh` (~lines 369–370).
**Severity:** High — Day-2 reports success when it could not read the node pools
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 on conno by running `mcp_is_updated`
**What happened:** The function is `! oc get mcp ... | grep -q True`. The exit status is grep's, and `!` turns "no match" into success. With `KUBECONFIG=/dev/null`, `oc get mcp` exits 1 and prints that the config is missing. `mcp_is_updated` still exits 0. Each caller uses `if ! mcp_is_updated` to decide whether to wait, so a failed query skips the wait. Day-2 then prints that configuration completed successfully. On compact the pools really are `updating=False`, so a good kubeconfig also exits 0. `pipefail` is commented out in `include_all.sh`. With `pipefail` on, a failed `oc` would still make the pipeline fail, and `!` would still turn that into success.
**Suggested fix:** If `oc get mcp` fails, return failure. Treat the pools as settled only when the command succeeds and no pool is Updating.

### Bug #1079: The upgrade progress check succeeds when the cluster is not updating
**File:** `scripts/cluster-upgrade.sh` (`_upgrade_status_ready` ~lines 619–629, the result at ~lines 632–649)
**Severity:** High — the script says the upgrade is in progress when status says it is not
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 on compact by running the check. No upgrade was started.
**What happened:** The check is supposed to wait until the status text is no longer `0 operators updated`. It is `! oc adm upgrade status | grep -q "0 operators updated"`. Any other text counts as progress. On compact, `oc adm upgrade status` exits 0 and prints `The cluster is not updating.` ClusterVersion is 4.21.40, Available=True, Progressing=False. With the target set to 4.22.22, the check prints those three values and exits 0. The wait that calls it then misses the "upgrade complete" test and prints `Upgrade ... is in progress!` and exits 0. A missing kubeconfig still fails the earlier `oc get`, so that path returns 1. The oc 4.21.40 client does contain the template `N operators updated`, so a running update that still has zero operators updated would keep waiting. The not-updating message does not. An earlier wait requires Progressing=True before this check runs; once this check is reached, the not-updating text ends it.
**Suggested fix:** Return success only when the status shows an update and at least one operator has updated, or when the desired version is the target and Progressing is False. `The cluster is not updating` must not end the wait.

### Bug #1080: A machine network with host bits is accepted
**File:** `scripts/include_all.sh` (`normalize_cidr` ~lines 5490–5501, `apply_cidr_split` ~lines 541–546, `verify-cluster-conf` ~lines 2118–2120). `tui/v2/tui-lib.sh` (`_normalize_cidr` ~lines 115–118) and `tui/v2/tui-cluster.sh` (~line 1199) save that result. `templates/install-config.yaml.j2` (~line 28) writes `cidr: {{ machine_network }}/{{ prefix_length }}`.
**Severity:** High — the install config is given a CIDR that is not a network address
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `normalize_cidr` and `verify-cluster-conf`
**What happened:** `10.0.1.0/20` has host bits set. The network address for that prefix is `10.0.0.0/20`. `normalize_cidr` prints `10.0.1.0/20` and exits 0. `10.0.0.0/20` and `10.0.1.0/24` are accepted too, and those are real network addresses. A throwaway `cluster.conf` with `machine_network=10.0.1.0/20`, `starting_ip=10.0.1.10`, and gateway `10.0.0.1` makes `verify-cluster-conf` exit 0. After the split, the address is still `10.0.1.0` and the prefix is `20`. The install template writes that pair into `machineNetwork.cidr`. No live `cluster.conf` was changed.
**Suggested fix:** Reject a CIDR whose address has host bits set, or store the masked network address (`10.0.1.0/20` becomes `10.0.0.0/20`) before writing the install config.

### Bug #1081: The config check accepts an NTP name that is only dots
**File:** `scripts/include_all.sh` (`verify-aba-conf` ~lines 758–759). `validate_ntp_servers` (~lines 5595–5623) is not called from anywhere else.
**Severity:** Medium — a bad NTP list passes the check ABA runs on `aba.conf`
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by running `verify-aba-conf` and `validate_ntp_servers`
**What happened:** The config check uses a regex whose first alternative is `[A-Za-z0-9.-]+`. That matches `....`. A throwaway `aba.conf` with `ntp_servers=....` and otherwise valid fields makes `verify-aba-conf` exit 0. `validate_ntp_servers` returns failure for `....` and for `-bad`. Nothing in the repo calls `validate_ntp_servers`. The same regex test accepts `999.999.999.999`, and `validate_ntp_servers` accepts that too, because `validate_domain` allows numeric labels. No live `aba.conf` was changed.
**Suggested fix:** Call `validate_ntp_servers` from `verify-aba-conf`. Reject a name that is not a hostname and not an IP.

### Bug #1082: A base domain with an underscore is accepted
**File:** `scripts/include_all.sh` (`_valid_domain` ~lines 1345–1348, `verify-cluster-conf` uses it for `base_domain`). `tui/v2/tui-cluster.sh` (~lines 1057–1070) uses the same check for the base-domain dialog.
**Severity:** High — the saved domain cannot be used as an OpenShift API hostname
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `_valid_domain` and `verify-cluster-conf`
**What happened:** `_valid_domain my_lab.com` exits 0. The comment on that function says underscores are allowed for Active Directory names. `example.com` exits 0 as well. The base-domain dialog rejects a value that looks like an IP, then calls `_valid_domain`, then lowercases the text. `my_lab.com` gets through. A throwaway `cluster.conf` with that base domain passes `normalize-cluster-conf` unchanged and `verify-cluster-conf` exits 0. The cluster API name would be `api.<name>.my_lab.com`. A DNS label cannot contain `_`. No live `cluster.conf` was changed.
**Suggested fix:** Reject `_` in `base_domain`. Do not use the Active Directory allowance for the OpenShift base domain.

### Bug #1083: The image source `..` is accepted and points outside the mirror
**File:** `scripts/include_all.sh` (`_valid_image_source` ~lines 1365–1367, `verify-cluster-conf` ~line 2205, `resolve_cluster_channel` ~line 3745). `scripts/aba.sh` (`--image-source` ~lines 1124–1127, `--mirror-name` ~lines 1269–1273). `scripts/deploy-primed.sh` (~lines 22–35). `scripts/day2.sh` and `scripts/create-install-config.sh` set `regcreds_dir=$HOME/.aba/mirror/${image_source}`.
**Severity:** High — mirror commands are aimed at the home directory
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `_valid_image_source` and `verify-cluster-conf`. No `make` command was run.
**What happened:** `_valid_image_source ..` exits 0. `_valid_image_source .` exits 0. `_valid_image_source ../x` exits 1 because `/` is not allowed. A throwaway `cluster.conf` with `image_source=..` passes normalize and `verify-cluster-conf` exits 0. From `~/aba/compact`, `deploy-primed.sh` sets `mirror_dir=../..`, which is `/home/steve`. That directory exists, so the "mirror directory not found" check does not stop it, and the next commands are `make -C` that directory `install` and `load`. The channel lookup reads `../../data/imageset-config.yaml`, which is `/home/steve/data/imageset-config.yaml`. Registry credentials are taken from `$HOME/.aba/mirror/..`, which is `$HOME/.aba`. The value `.` points `mirror_dir` at `/home/steve/aba` instead of `/home/steve/aba/mirror`. The cluster wizard only toggles `mirror`, `proxy`, and `direct`. The CLI flags use `_valid_image_source`. No live `cluster.conf` was changed.
**Suggested fix:** Reject `.` and `..` as an image source. Keep the name a single directory segment under the mirror parent.

### Bug #1084: A mirror data directory may contain `..`
**File:** `scripts/include_all.sh` (`_valid_abs_path` ~lines 1294–1296, `verify-mirror-conf` ~lines 840–844). `scripts/reg-common.sh` (`reg_setup_data_dir` ~lines 323–346). The same path check is used for `reg_path` and `reg_ssh_key`.
**Severity:** High — the registry data directory can land outside the directory named in the path
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `_valid_abs_path`, `verify-mirror-conf`, and `reg_setup_data_dir`. No directory was created.
**What happened:** `_valid_abs_path /tmp/foo/../../home/steve/aba-escape` exits 0. A normal path `/var/lib/quay` exits 0. A path with a space is rejected. A throwaway `mirror.conf` with `reg_host=registry.example.com`, `reg_port=8443`, `reg_vendor=docker`, and that `data_dir` passes `verify-mirror-conf` with exit 0. `reg_setup_data_dir docker` then sets `reg_root` to `/tmp/foo/../../home/steve/aba-escape/docker-reg`. That path is `/home/steve/aba-escape/docker-reg`. Quay and the mirror cache use this directory. No live `mirror.conf` was changed.
**Suggested fix:** Reject a path segment that is `.` or `..` in `_valid_abs_path`.

### Bug #1085: A host prefix of 0 or 14 is accepted
**File:** `scripts/include_all.sh` (`verify-cluster-conf` ~line 2173). `scripts/aba.sh` (`--host-prefix` ~lines 1242–1246) says the value must be 0–32. `templates/install-config.yaml.j2` (~lines 24–26) writes `cidr: 10.128.0.0/14` and `hostPrefix: {{ hostPrefix }}`.
**Severity:** High — the pod network cannot give each node a prefix that is not more specific than /14
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `verify-cluster-conf`
**What happened:** A throwaway `cluster.conf` was checked once for each prefix. `hostPrefix` 0, 14, 15, 23, 26, 27, and 32 all exit 0. `33` exits 1 with `hostPrefix is invalid`. The install template always uses pod network `10.128.0.0/14`. A node prefix has to be greater than 14, so 0 and 14 cannot be used. `32` is one address per node. The bare-metal adjustment only changes 23 to 22. No live `cluster.conf` was changed.
**Suggested fix:** Accept a host prefix only when it is greater than 14 and small enough to leave more than one address per node. Change the `--host-prefix` message to that range.

### Bug #1086: The machine network may overlap the pod or service network
**File:** `scripts/include_all.sh` (`verify-cluster-conf` and `_validate_network_consistency` ~lines 1179–1240). `templates/install-config.yaml.j2` (~lines 24–31) always adds pod network `10.128.0.0/14` and service network `172.30.0.0/16`.
**Severity:** High — the install config contains two networks that cover the same addresses
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `verify-cluster-conf`
**What happened:** Nothing in the cluster check compares the machine network with those two fixed ranges. A throwaway SNO config was accepted for each of these: `10.0.0.0/20` with node `10.0.1.10` (this does not overlap), `10.0.0.0/8` with node `10.0.1.10` (this contains the pod network), `10.128.0.0/20` with node `10.128.1.10` (this sits inside the pod network), and `172.30.0.0/24` with node `172.30.0.10` (this sits inside the service network). Each one exited 0. No live `cluster.conf` was changed.
**Suggested fix:** Reject a machine network that overlaps `10.128.0.0/14` or `172.30.0.0/16`.

### Bug #1087: A quote in a disk hint becomes extra fields or drops the hint
**File:** `scripts/include_all.sh` (`_parse_disk_hint` ~lines 970–982 and ~1074–1075). `scripts/create-agent-config.sh` (~lines 246–254 and 284–285) embeds the result. `scripts/j2` (~lines 38–42) parses `json_disk_hints`. `templates/agent-config.yaml.j2` (~lines 40–44) writes every key.
**Severity:** High — the rendered root-device hint is not the value that was set
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `_parse_disk_hint` and `scripts/j2`
**What happened:** A device path is wrapped in JSON with no escaping. `_parse_disk_hint` of a path that contains a quote exits 0. `scripts/j2` then renders `deviceName` `/dev/sda` plus `minSizeGigabytes` 50 and `vendor` `x`, which were not separate hint keys. `model=WD"foo` also exits 0 and produces `{"model": "WD"foo"}`. That is not valid JSON, so `scripts/j2` does not define `disk_hints` and the template prints no hint. No agent config was written for a live cluster.
**Suggested fix:** Build the hint with a JSON encoder. If the result is not valid JSON, abort before rendering.

### Bug #1088: A disk hint may set the minimum size above the maximum
**File:** `scripts/include_all.sh` (`_parse_disk_hint` ~lines 1047–1053)
**Severity:** Medium — no disk can satisfy the hint, and the parser still succeeds
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `_parse_disk_hint`
**What happened:** `minSizeGigabytes=500,maxSizeGigabytes=100` exits 0 and prints `{"minSizeGigabytes": 500, "maxSizeGigabytes": 100}`. Each number is checked only to be a positive integer. The agent template writes both into `rootDeviceHints`.
**Suggested fix:** When both sizes are set, reject a minimum that is greater than the maximum.

### Bug #1089: A node prefix of 63 characters makes a node name of 64
**File:** `scripts/include_all.sh` (`verify-cluster-conf` ~line 2175). `scripts/aba.sh` (`--master-prefix` ~lines 1250–1251, `--worker-prefix` ~lines 1256–1257). `scripts/create-agent-config.sh` (~line 233) and `templates/agent-config.yaml.j2` (~line 33) set the hostname to the prefix plus the index.
**Severity:** High — the agent config gets a hostname that is not a DNS label
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `verify-cluster-conf` on a throwaway compact config
**What happened:** A `master_prefix` of 63 `a` characters matches the prefix check, and `verify-cluster-conf` exits 0. Compact and standard hostnames are that prefix plus `1`, `2`, or `3`. The result is 64 characters. A DNS label is at most 63. `master_prefix=Master` is rejected, so this is only the length. No live `cluster.conf` was changed. SNO uses `cluster_name` as the hostname, and that name is already limited to 63.
**Suggested fix:** Reject a prefix whose length plus the digits of the node index is greater than 63.

### Bug #1090: The cluster config check accepts an uppercase cluster name
**File:** `scripts/include_all.sh` (`verify-cluster-conf` ~line 2114). `_valid_cluster_name` (~lines 2071–2073) is what `aba cluster --name` and the TUI name field use.
**Severity:** High — install, day-2, and agent-config generation call `verify-cluster-conf` and then keep the mixed-case name
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `verify-cluster-conf` and `_valid_cluster_name` on a throwaway config
**What happened:** `cluster_name=MyCluster` makes `verify-cluster-conf` exit 0. The check is `grep -i`, so capitals match the lowercase pattern. `_valid_cluster_name MyCluster` exits 1. `create-install-config.sh` and `create-agent-config.sh` call only `verify-cluster-conf`. A DNS label must be lowercase. No live `cluster.conf` was changed.
**Suggested fix:** Use the same check as `_valid_cluster_name` in `verify-cluster-conf`. Do not pass `-i` to `grep`.

### Bug #1091: A data disk size of 0 still creates a disk
**File:** `scripts/include_all.sh` (`verify-cluster-conf` ~line 2219). `scripts/aba.sh` (`--data-disk` ~lines 1117–1119). `scripts/vm-vmw.sh` (~lines 169–176). `scripts/kvm-create.sh` (~lines 84–85). `tui/v2/tui-cluster.sh` (~lines 1672–1673) and `tui/v2/tui-strings2.sh` (`TUI2_MSG_VM_DISK_PROMPT`).
**Severity:** Medium — the VM create step asks for a 0GB disk after the user chose no extra disk
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `verify-cluster-conf` on a throwaway config. No VM was created.
**What happened:** `data_disk=0` makes `verify-cluster-conf` exit 0. `normalize_uint 0` exits 0. The TUI error text says `0 = no extra disk`, and the prompt says an empty value means none. `vmp_create_vm` attaches a disk whenever the size string is non-empty, so `0` becomes `-size 0GB`. The KVM script adds `--disk ...,size=0`. An empty value skips the disk. No live `cluster.conf` was changed.
**Suggested fix:** Treat 0 the same as empty in the VMware and KVM create paths. Do not call disk create for size 0.

### Bug #1092: One CPU and one gigabyte of memory pass the cluster check
**File:** `scripts/include_all.sh` (`verify-cluster-conf` ~lines 2213–2217). `scripts/aba.sh` (`--master-cpu` ~lines 1066–1070, `--master-memory` ~lines 1072–1076, and the worker flags ~lines 1078–1088). The TUI minimums are in `tui/v2/tui-cluster.sh` (~lines 1596–1598, 1616–1618, 1636–1638, and 1656–1658).
**Severity:** High — install creates a VM that cannot run OpenShift
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `verify-cluster-conf` on throwaway configs. No VM was created.
**What happened:** `master_cpu_count=1` and `master_mem=1` make `verify-cluster-conf` exit 0. With three masters, `worker_cpu_count=1` and `worker_mem=1` also exit 0. The CLI uses `normalize_uint`, which accepts 1. The TUI rejects a master below 4 CPUs or 16 GB, a worker below 2 CPUs or 8 GB. No live `cluster.conf` was changed.
**Suggested fix:** Use the same minimums in `verify-cluster-conf` and the CLI flags as the TUI uses.

### Bug #1093: A multicast MAC prefix is accepted
**File:** `scripts/include_all.sh` (`verify-cluster-conf` ~line 2208, `_valid_mac` ~lines 1401–1403). `scripts/create-agent-config.sh` (~lines 201–206) appends the index with `printf "%s%02x"`.
**Severity:** High — vSphere and KVM reject a multicast address as a NIC MAC, and the install check lets it through
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `verify-cluster-conf` and `_valid_mac` on a throwaway config. No VM was created.
**What happened:** `mac_prefix=01:22:33:44:55:` makes `verify-cluster-conf` exit 0 with `platform=vmw`. The generator produces `01:22:33:44:55:01`. The low bit of the first octet is 1, which marks a multicast address. `_valid_mac` also returns 0 for that address. `mac_prefix=ff:ff:ff:ff:ff:` exits 0 as well and generates `ff:ff:ff:ff:ff:01`. A unicast prefix `00:50:56:1a:2b:` also exits 0. No live `cluster.conf` was changed.
**Suggested fix:** Reject a prefix whose first octet has the group bit set. Reject a generated address that is multicast or broadcast.

### Bug #1094: The same port name may be listed twice
**File:** `scripts/include_all.sh` (`verify-cluster-conf` ~lines 2196–2200, `_valid_port_name` ~lines 1371–1373). `templates/agent-config-bond.yaml.j2` (~lines 36–38 and 63–66) writes each entry into the bond.
**Severity:** Medium — the bond lists one NIC twice, so nmstate cannot apply the node network
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `verify-cluster-conf` and `scripts/j2` on a throwaway config
**What happened:** `ports=ens224,ens224` makes `verify-cluster-conf` exit 0. Each name matches the port pattern. Splitting on commas gives `ens224` twice. The bond template renders the port list as `ens224,ens224`. No live `cluster.conf` was changed.
**Suggested fix:** Reject a repeated port name before the bond config is rendered.

### Bug #1095: The API address, ingress address, or gateway may be the network or broadcast address
**File:** `scripts/include_all.sh` (`ip_in_cidr` ~lines 1136–1141, `_validate_network_consistency` ~lines 1200–1239, `verify-cluster-conf` ~lines 2152–2163)
**Severity:** High — those addresses cannot be assigned, and the install check still accepts the config
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `verify-cluster-conf` on throwaway compact configs
**What happened:** On `10.0.0.0/20`, a starting IP of `10.0.0.0` is rejected. These four configs exit 0: `api_vip=10.0.0.0` with ingress `10.0.1.226`, `ingress_vip=10.0.15.255` with API `10.0.1.216`, `next_hop_address=10.0.0.0`, and `next_hop_address=10.0.15.255`. Nodes start at `10.0.1.71`, so the VIP range check does not see the network or broadcast address. `ip_in_cidr` treats both as inside the CIDR. No live `cluster.conf` was changed.
**Suggested fix:** Reject an API VIP, ingress VIP, or gateway that is the network address or the broadcast address.

### Bug #1096: A DNS server of 0.0.0.0 is accepted
**File:** `scripts/include_all.sh` (`verify-cluster-conf` ~lines 2188–2191)
**Severity:** Medium — name lookup during install is pointed at an address that is not a DNS server
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `verify-cluster-conf` on a throwaway compact config
**What happened:** `dns_servers=0.0.0.0` matches the IPv4 pattern and `verify-cluster-conf` exits 0. The other fields were a normal compact layout on `10.0.0.0/20`. No live `cluster.conf` was changed.
**Suggested fix:** Reject `0.0.0.0` and `255.255.255.255` as a DNS server.

### Bug #1097: A registry hostname may contain an underscore or a label longer than 63 characters
**File:** `scripts/include_all.sh` (`_valid_fqdn` ~lines 1303–1305, `verify-mirror-conf` ~line 829). The registry hostname dialog in `tui/v2/tui-mirror.sh` (~lines 224–227) uses `_valid_fqdn`.
**Severity:** High — the registry certificate and the pull secret are built from this name
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `_valid_fqdn` and `verify-mirror-conf` on throwaway mirror configs
**What happened:** `_valid_fqdn my_reg.example.com` exits 0, and `verify-mirror-conf` exits 0. A label of 64 `a` characters plus `.example.com` also exits 0. A label of 63 `a` characters exits 0, and that length is a valid DNS label. The pattern allows `_` and does not limit a label to 63 characters. The comment says underscores are for Active Directory. A DNS label cannot contain `_`. No live `mirror.conf` was changed.
**Suggested fix:** Reject `_` in `reg_host`. Reject a label longer than 63 characters and a name longer than 253 characters.

### Bug #1098: The mirror check accepts a bad registry user and a bad password
**File:** `scripts/include_all.sh` (`verify-mirror-conf` ~lines 820–860). `_valid_username` (~lines 1287–1289) and `_valid_password` (~lines 1313–1339) are used by `scripts/aba.sh` (`--reg-user` ~line 844, `--reg-password` ~lines 855–858) and by the TUI password prompt.
**Severity:** High — install uses the user and password from `mirror.conf` after this check
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `verify-mirror-conf` on throwaway mirror configs
**What happened:** A throwaway file with `reg_user=1bad` and `reg_pw='bad pass'` loads those values and `verify-mirror-conf` exits 0. `_valid_username 1bad` exits 1. `_valid_password` rejects `bad pass` because of the space. A password of `abc` also makes `verify-mirror-conf` exit 0, and `_valid_password` rejects it for length. The Quay check in `verify-mirror-conf` only looks for a backtick, quote, or dollar sign. No live `mirror.conf` was changed.
**Suggested fix:** Call `_valid_username` and `_valid_password` from `verify-mirror-conf` for any vendor.

### Bug #1099: A proxy address without a scheme is accepted
**File:** `scripts/include_all.sh` (`verify-cluster-conf`). `scripts/create-install-config.sh` (~lines 113–132) sets the proxy when `http_proxy` or `https_proxy` is non-empty. `templates/install-config.yaml.j2` (~lines 5–9) writes the values.
**Severity:** High — the install config gets a proxy value that is not a URL
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `verify-cluster-conf` and `scripts/j2` on a throwaway config
**What happened:** A throwaway `cluster.conf` with `image_source=proxy`, `http_proxy=10.0.1.8:3128`, and `https_proxy=10.0.1.8:3128` makes `verify-cluster-conf` exit 0. Nothing in that check looks at the proxy fields. The install template renders `httpProxy: 10.0.1.8:3128` and `httpsProxy: 10.0.1.8:3128`. A proxy URL needs a scheme such as `http://`. No live `cluster.conf` was changed and no install config was written for a cluster.
**Suggested fix:** Require `http://` or `https://` on both proxy values before rendering. Reject a value with no scheme.

### Bug #1100: An empty no_proxy becomes a leading comma
**File:** `templates/install-config.yaml.j2` (~line 9)
**Severity:** Medium — the first no-proxy entry is empty
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `scripts/j2` on a throwaway config
**What happened:** With `no_proxy` empty, `machine_network=10.0.0.0`, and `prefix_length=20`, the template renders `noProxy: ,10.0.0.0/20,10.128.0.0/14,172.30.0.0/16`. The line always inserts a comma after `no_proxy`, including when that value is empty. No live `cluster.conf` was changed.
**Suggested fix:** Add the machine, pod, and service networks only when they are not already listed. Do not write a comma when `no_proxy` is empty.

### Bug #1101: An NTP server of 0.0.0.0 is accepted
**File:** `scripts/include_all.sh` (`verify-aba-conf` ~lines 758–759, `validate_ntp_servers` ~lines 5595–5623). `scripts/create-agent-config.sh` (~line 219) copies `ntp_servers` into `arr_ntp_servers`. `templates/agent-config.yaml.j2` (~lines 8–12) writes `additionalNTPSources`.
**Severity:** Medium — the node clock is pointed at an address that is not an NTP server
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `verify-aba-conf`, `validate_ntp_servers`, and `scripts/j2` on a throwaway config
**What happened:** A throwaway `aba.conf` with `ntp_servers=0.0.0.0` makes `verify-aba-conf` exit 0. `validate_ntp_servers 0.0.0.0` also exits 0 because `validate_ip` accepts that address. The agent template renders `additionalNTPSources` with the entry `0.0.0.0`. No live `aba.conf` was changed.
**Suggested fix:** Reject `0.0.0.0` and `255.255.255.255` as an NTP server.

### Bug #1102: A vSphere password that contains a single quote breaks the install config
**File:** `templates/install-config.yaml.j2` (~line 65)
**Severity:** High — `install-config.yaml` is not valid YAML, so the install cannot read it
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by rendering the vCenter block with `scripts/j2`. A fake password was used. The live vCenter password was not read.
**What happened:** The template writes `password: '{{ GOVC_PASSWORD }}'`. A password containing one single quote renders as `password: 'p@ss'word'`. The YAML parser rejects that file. No install config was written for a cluster.
**Suggested fix:** Quote the password with a YAML encoder, or double any single quote inside the value.

### Bug #1103: The vSphere TLS check succeeds when openssl exits 0 and the verify line does not
**File:** `scripts/preflight-check-vsphere.sh` (`_vsphere_probe_tls` ~lines 135–160)
**Severity:** High — preflight says the vCenter certificate is trusted when the verify result says it is not
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling `_vsphere_probe_tls` with a stand-in openssl. No vCenter was contacted.
**What happened:** The comment above the function says some openssl builds exit 0 even when the trust check fails, and that the probe must also read `Verify return code`. The function returns success as soon as the exit code is 0. A stand-in that prints `Verify return code: 21 (unable to verify the first certificate)` and exits 0 makes the probe print `TLS trust chain verified` and return 0, with the error count left at 0. The same stand-in with exit 1 returns 1 and increments the error count. `GOVC_URL` was `vcenter.example.com`.
**Suggested fix:** Treat the chain as trusted only when the exit code is 0 and the verify line says code 0. An exit code of 0 with any other verify code is a failure.

### Bug #1104: A vSphere role whose name contains a space is ignored
**File:** `scripts/preflight-check-vsphere.sh` (`_vsphere_check_privileges` ~lines 537–546 and 555–561)
**Severity:** High — an explicit deny is only a warning, and preflight still passes when the error count stays 0
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling `_vsphere_check_privileges` with a stand-in `govc`. No vCenter was contacted.
**What happened:** The function first splits the permissions table on tabs. If that finds no role, it splits on spaces and reads field 3 as the user and field 1 as the role. A space-aligned row `No access  /DC  builder@lab.example  true` makes field 1 `No` and field 3 `/DC`, so the user is not found. The probe warns that the user has no role assigned, increments the D-12 count, leaves the error count at 0, and returns 0. The same row with tab separators sets the role to `No access` and records a missing privilege. The function's own comment says a role name with a space breaks the space split, and that split is still the fallback. No live `vmware.conf` was changed.
**Suggested fix:** Read the role and the principal from a parser that keeps a role name with spaces. Do not use a space split for this table.

### Bug #1105: The startup operator check ignores Progressing and a failed query
**File:** `scripts/cluster-startup.sh` (`_cluster_startup_cos_ready` ~lines 265–267). A true result skips the wait and prints `All cluster operators are fully available!` (~lines 288–297).
**Severity:** High — startup reports the cluster ready while an operator is still progressing, or when the query produced no rows
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same pipeline the function runs. Startup was not run.
**What happened:** `oc get co --no-headers` on compact puts Available in field 3, Progressing in field 4, and Degraded in field 5. The check prints fields 3 and 5 and keeps a row only when it is not `True False`. A row `etcd 4.21.40 True True False` is Progressing, and the pipeline still exits 0. A row with Available False exits 1. Settled rows exit 0. A command that prints nothing, which is what a failed `oc get co` leaves on stdout, also exits 0 because the last command sees zero bad lines. No startup was started.
**Suggested fix:** Require Available True, Progressing False, and Degraded False. If `oc get co` fails or prints no rows, return failure.

### Bug #1106: The startup node check says the nodes are ready when the query is empty
**File:** `scripts/cluster-startup.sh` (`all_nodes_ready` ~line 212). A true result prints `All nodes are ready!` (~lines 247–248).
**Severity:** High — startup skips the node wait when the query failed
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same test the function runs. Startup was not run.
**What happened:** The test is `[ -z "$(oc get nodes ... | grep -v ^True$)" ]`. Two `True` lines exit 0. A `False` line exits 1. A blank line, which is what a node with no Ready condition contributes, exits 0. A command that exits 1 and prints nothing also exits 0, so a failed query is treated as every node being ready. No nodes were changed.
**Suggested fix:** If `oc get nodes` fails or returns no nodes, return failure. Treat a missing Ready condition as not ready.

### Bug #1107: Uncordon succeeds when the node list query fails
**File:** `scripts/cluster-startup.sh` (`uncordon_all_nodes` ~line 198). The wait at ~lines 203–205 treats a zero exit as finished.
**Severity:** High — nodes can stay cordoned while startup continues
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same loop the function runs. Startup was not run and no node was uncordoned.
**What happened:** The loop is `for node in $(oc get nodes ...)`. When that command exits 1 and prints nothing, the loop body never runs and the function exits 0. The same loop with the names `master1` and `master2` visits both names. A failed query therefore ends the uncordon wait immediately. No live cluster was contacted.
**Suggested fix:** If the node list command fails, or the list is empty, return failure. Do not treat an empty loop as a finished uncordon.

### Bug #1108: Shutdown pairs node names with IP addresses by list position
**File:** `scripts/cluster-graceful-shutdown.sh` (~lines 185–207 and 216–228). Node names come from `oc get nodes`. Addresses come from `CP_IP_ADDRESSES` and `WKR_IP_ADDR`, which `scripts/cluster-config.sh` reads in agent-config host order (~lines 121 and 156).
**Severity:** High — SSH shutdown is sent to the wrong machine, and that success skips the debug shutdown of the intended node
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same pairing loop. Shutdown was not run.
**What happened:** The loop stores IP address N against node name N. With API names `master2 master1 master3` and config addresses `10.0.1.71 10.0.1.72 10.0.1.73`, master1 is paired with `.72` and master2 with `.71`. SSH to that address is treated as success for the name in the loop, so `oc debug` is not used. Compact's API order and agent-config order are both `master1 master2 master3` right now. The pairing does not sort either list. No node was shut down.
**Suggested fix:** Pair each node name with the address stored for that name. Do not zip the two lists by position.

### Bug #1109: An empty node list is reported as a successful shutdown
**File:** `scripts/cluster-graceful-shutdown.sh` (~lines 185 and 216–258). `scripts/include_all.sh` (~lines 20–22) leaves `set -e` commented out.
**Severity:** High — the script says every node is shutting down when it did not send a shutdown to any node
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same loop and success test. Shutdown was not run.
**What happened:** `_all_nodes=$(oc get nodes ...)` with a failing command leaves the variable empty and returns 1. The script does not stop. The shutdown loop does not run, `_shutdown_failed` stays empty, and the success branch is taken: `All nodes will complete shutdown and power off shortly!` When a power-off wait is not requested, the script then prints `Cluster shutdown completed successfully.` and exits 0. No node was shut down.
**Suggested fix:** If the node query fails, or the list is empty, stop with a failure before the success message.

### Bug #1110: Startup exits 0 when the VM start fails
**File:** `scripts/cluster-startup.sh` (~lines 107–110)
**Severity:** High — nodes that were cordoned for shutdown stay cordoned, and the command still exits 0
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same branch. Startup was not run.
**What happened:** On VMware and KVM, startup runs `aba start`. When that command returns non-zero, the script prints `Aborted. Power on VMs with 'aba start' and re-run 'aba startup'.`, marks step `su_power` done, and exits 0. The uncordon loop later in the script does not run. A stand-in `aba start` that returns 1 takes this branch and the process exit code is 0.
**Suggested fix:** Mark the power step failed and exit non-zero when `aba start` fails. Leave exit 0 for a startup that finished the uncordon.

### Bug #1111: Startup exits 0 when operators are still not ready
**File:** `scripts/cluster-startup.sh` (~lines 288–293). `aba_wait_show` in `scripts/include_all.sh` (~lines 2729 and 2775) returns 1 when the wait ends without a successful check.
**Severity:** High — the operator step is marked done and the command exits 0 while operators are not ready
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same branch. Startup was not run.
**What happened:** When `_cluster_startup_cos_ready` returns failure and the wait also returns failure, the script prints `Not all cluster operators are available yet. The cluster may still be settling.`, marks step `su_cos` done, and exits 0. It does not reach `Cluster startup completed successfully.` A check that keeps failing and a wait that returns 1 take this branch, and the process exit code is 0.
**Suggested fix:** Mark the operator step failed and exit non-zero when the wait ends with operators still not ready.

### Bug #1112: Day-2 reports success when the cluster does not settle
**File:** `scripts/day2.sh` (~lines 687–699). `aba_wait_show` returns 1 when the wait ends without a successful check.
**Severity:** High — the command says day-2 completed after the operators or the node pools stayed unsettled
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same two waits. Day-2 was not run.
**What happened:** The operator wait is `aba_wait_show ... cluster_is_ready || true`. The node-pool wait is the same with `mcp_is_updated`. `|| true` keeps the script going when a wait returns failure. The script then marks step `stabilize` done, prints `Day-2 configuration completed successfully.`, and exits 0. A `cluster_is_ready` that returns 1 and an `mcp_is_updated` that returns 1 both make their waits return 1, and the process exit code is still 0. This is the timeout path. Bug #1078 is the node-pool check returning success when the query itself fails.
**Suggested fix:** If either wait ends without a settled cluster, exit non-zero. Do not print the success line.

### Bug #1113: Startup approves every CSR line that contains "pending"
**File:** `scripts/cluster-startup.sh` (~lines 214–225)
**Severity:** High — a pending user certificate request is approved, and so is an already approved request whose name contains that word
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same selection. No certificate request was approved on a cluster. Compact had no requests.
**What happened:** The loop runs `oc get csr -A --no-headers | grep -i pending | awk '{print $1}'` and passes every selected name to `oc adm certificate approve`. It does not look at the signer. A user request (`kubernetes.io/kube-apiserver-client`, condition Pending), a node request, and an already Approved request named `pending-extra` are all selected. An Approved kubelet request whose name does not contain `pending` is not selected. The approve command receives `csr-user`, `csr-node`, and `pending-extra`. The loop keeps doing this for about an hour.
**Suggested fix:** Approve only requests whose condition is Pending and whose signer is a kubelet client or kubelet serving signer.

### Bug #1114: NTP says every node is configured when the node list is empty
**File:** `scripts/day2-config-ntp.sh` (`nodesIPs` ~line 248, `_ntp_config_applied` ~lines 252–265, `_ntp_source_synced` ~lines 291–302)
**Severity:** High — the script reports chrony and NTP sync as complete when it did not check any node
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same two checks. NTP was not configured.
**What happened:** `nodesIPs` comes from `oc get nodes -owide --no-headers | awk '{print $6}'`. `pipefail` is off, so a failed `oc` still leaves the pipeline successful and the list empty. Both checks loop over that list and then return 0. With an empty list, the chrony check exits 0 and the sync check exits 0. Those results are what the script treats as `chrony.conf applied on all nodes` and `NTP configured and all sources synced on all nodes`.
**Suggested fix:** If the node query fails, or the list is empty, return failure from both checks.

### Bug #1115: NTP says the API is available when the API wait fails
**File:** `scripts/day2-config-ntp.sh` (~lines 350–360)
**Severity:** High — callers are told the API is back when the wait did not see it
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same branch. NTP was not configured.
**What happened:** The wait result is saved in `_wait_rc`. A timeout takes the warning branch: `API server not available after 5 min. Cluster may still be recovering.` The next line is unconditional: `aba_success "API server available."` A wait that returns 1 prints the warning, then prints that the API server is available, and the process exits 0.
**Suggested fix:** Print the available line only when the wait returns 0. On timeout, exit non-zero.

### Bug #1116: Unstick says the cluster is healthy when the pod query fails
**File:** `scripts/cluster-unstick.sh` (~lines 31–74)
**Severity:** High — a failed query is reported as no stuck pods, and the command exits 0
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same pipeline. No pod was deleted.
**What happened:** The pod list is `oc get po -A -o json` piped into Python, with `|| true` on the pipeline. When `oc` fails, Python reads empty input, raises `JSONDecodeError`, and prints nothing on stdout. `_stuck` is empty. The script prints `No stuck pods found — cluster looks healthy (or pods are still starting up).` and exits 0.
**Suggested fix:** If `oc get po` fails, or the output is not JSON, exit non-zero. Print the healthy line only when the query succeeds and the list is empty.

### Bug #1117: Rescue says it is complete when the node and CSR queries fail
**File:** `scripts/cluster-rescue.sh` (~lines 36–60)
**Severity:** High — a failed query is reported as nothing to do, and rescue exits 0
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same two branches. Rescue was not run.
**What happened:** `oc get nodes | grep -q SchedulingDisabled` takes the else branch when `oc` fails, and the script prints `No nodes set to 'SchedulingDisabled'. Nothing to do!` The CSR test is `[ "$(oc get csr ...)" ]`. A failed `oc` leaves that empty, so the script prints `No CSRs exist. Nothing to do!` It then prints `Rescue complete.` and exits 0. `pipefail` is off, so the node pipeline's status is grep's.
**Suggested fix:** If either query fails, exit non-zero. Do not print `Rescue complete.`

### Bug #1118: Upgrade monitor says the cluster is already at the target when the update has not completed
**File:** `scripts/cluster-upgrade-mon.sh` (~lines 60–69)
**Severity:** High — the monitor exits 0 before an upgrade whose desired version already matches the target
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same test. No upgrade was started. Compact's live conditions are Available, Progressing, and Failing. There is no Degraded condition.
**What happened:** The test is desired version equals the target and Progressing is False. It does not read Available, Failing, or the completed history entry. A status with desired `4.22.22`, Progressing False, Available False, Failing True, and completed history `4.21.40` prints `Cluster is already at version 4.22.22` and exits 0.
**Suggested fix:** Compare the completed history version with the target. Require Available True and Failing False.

### Bug #1119: Upgrade monitor says the upgrade is complete while the version is failing
**File:** `scripts/cluster-upgrade-mon.sh` (~lines 109 and 133–141)
**Severity:** High — a failing update is reported as complete
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same test. No upgrade was started.
**What happened:** The loop reports complete when desired equals the target, Available is True, and Progressing is False. It reads a Degraded condition that this cluster does not have, and it never reads Failing. A status with desired `4.22.22`, Available True, Progressing False, Failing True, and completed history `4.21.40` takes the complete branch and exits 0.
**Suggested fix:** Require Failing False and a completed history entry for the target version. Do not treat Degraded as the failure condition on this cluster version.

### Bug #1120: The upgrade list parser drops recommended versions
**File:** `scripts/cluster-upgrade.sh` (~lines 424–427, and the same awk at ~lines 344–345 and 444–447)
**Severity:** High — a recommended update is treated as missing from the graph
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same awk. No upgrade was started. The oc 4.21.40 client contains the format `Version:` then `Image:` for a release, and a second block that also prints `Reason:` and `Message:`.
**What happened:** The recommended parser keeps a line only when it starts with two spaces and a digit. The current client prints `  Version: 4.21.42`. That line is dropped, and so is `  Version: 4.21.41`. The known-issue parser keeps `  Version:` lines, so `  Version: 4.21.39` under `Updates with known issues:` is the only version returned. An older table line `  4.21.42 quay.io/example` is still returned. With the `Version:` form, a recommended target is not in either list, and an OSUS upgrade then aborts with `Version <target> is not available in the OSUS update graph.`
**Suggested fix:** Read the version from a `Version:` line in the recommended block as well as from the older table row.

### Bug #1121: The upgrade command says the upgrade is complete while the version is failing
**File:** `scripts/cluster-upgrade.sh` (~lines 635–645)
**Severity:** High — the command exits 0 and says the cluster is on the target while the completed history is still the old version
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same test. No upgrade was started.
**What happened:** After the progress wait, the script reads the desired version and the Progressing condition. When the desired version equals the target and Progressing is False, it prints `Upgrade complete! Cluster is now at version <target>` and exits 0. It does not read Failing or the completed history. Desired `4.22.22`, Progressing False, Failing True, and completed history `4.21.40` take that branch. This is the upgrade command. Bugs #1118 and #1119 are the monitor.
**Suggested fix:** Require Failing False and a completed history entry for the target before printing that the upgrade is complete.

### Bug #1122: Cluster status says running when the version is failing
**File:** `scripts/cluster-status.sh` (~lines 152–164 and 196–198)
**Severity:** High — a failing cluster is shown as running
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same health test. Compact's live conditions are Available, Progressing, and Failing. There is no Degraded condition.
**What happened:** Health becomes `degraded` only when a Degraded condition is True. It never reads Failing. Available True and Progressing False then become `available`, which the output shows as `running`. A status with Failing True, Available True, Progressing False, and no Degraded condition produces `health=available`.
**Suggested fix:** Treat Failing True as degraded. Do not use Degraded as the only failure condition.

### Bug #1123: Cluster status shows the desired version instead of the completed version
**File:** `scripts/cluster-status.sh` (~line 137)
**Severity:** High — status shows the target version before that version has completed
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same version read. No upgrade was started. Compact's desired and completed versions are both 4.21.40 right now.
**What happened:** The version is `status.desired.version`. A status whose desired version is `4.22.22` and whose completed history is `4.21.40` prints `4.22.22`. Together with Bug #1122, that status is shown as running at 4.22.22.
**Suggested fix:** Print the newest completed history version.

### Bug #1124: Mirror status records the registry as stopped when the probe cannot connect
**File:** `scripts/mirror-status.sh` (~lines 74–85 and 114–119). `check_release_image` in `scripts/include_all.sh` (~lines 5906–5908) sets the HTTP code to `000` when the connection check has no code.
**Severity:** High — one failed probe makes later status say the registry is stopped
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same branch on a throwaway state file. The live registry state was not changed.
**What happened:** The runtime status path is what the TUI menu uses. When the release probe returns HTTP `000`, it writes `reg_running=false` into `state.sh`. The next run sees `reg_running=false` and prints `reg_state=stopped` without probing again. A throwaway file that started as `reg_running=true` was rewritten to `reg_running=false`, and the following read took the stopped branch.
**Suggested fix:** Do not write `reg_running` from a status probe. Report unreachable for that probe, and probe again on the next status.

### Bug #1125: A missing master count is reported as a compact cluster
**File:** `scripts/cluster-status.sh` (~line 49). `cluster_type` in `scripts/include_all.sh` (~lines 552–561)
**Severity:** Medium — status gives the wrong cluster type when a count is missing
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `cluster_type`
**What happened:** The status script calls `cluster_type` with `${num_masters:-3}` and `${num_workers:-0}`. An empty master count is therefore 3, and an empty worker count is 0. `cluster_type 3 0` prints `compact`. A missing master count prints `compact`. Three masters with a missing worker count also print `compact`. One master with a missing worker count still prints `sno`.
**Suggested fix:** Leave a missing count empty and report the type as unknown. Do not substitute 3 and 0.

### Bug #1126: Cluster status says installing when no install is running
**File:** `scripts/cluster-status.sh` (~lines 52–60)
**Severity:** Medium — a stopped or failed install is shown as if it is still installing
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same decision. No install was started.
**What happened:** The status is `installed` when `.install-complete` exists. Otherwise a directory named `iso-agent-based` makes the status `installing`. Nothing checks that an install process is running. A throwaway directory with that folder and no install marker was reported as `installing`. Conno `sno` and `sno4` do not have that folder, so they are not showing this now.
**Suggested fix:** Report `installing` only while an install is running. A leftover install directory with no marker should be a stopped or failed install.

### Bug #1127: An unreadable load time makes every archive look new
**File:** `scripts/mirror-status.sh` (~lines 808–821)
**Severity:** Medium — status tells the user to load again when the load time could not be read
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same comparison. The live mirror was not changed.
**What happened:** The load time is `date -d "$last_action_at" +%s`. If that fails, the time becomes `0`. Every `data/mirror_*.tar` whose modification time is greater than 0 is then reported as `New archives: detected (copied after last load)`, and the next step says to run `aba -d mirror load`. A load time of `not-a-date` produced epoch 0, and one archive was reported as new. The day-2 reminder uses the same 0 and does not match, because an install marker's time is not less than 0.
**Suggested fix:** If the load time cannot be parsed, skip the archive comparison. Do not use epoch 0.

### Bug #1128: The image reference check rejects a registry port and accepts a missing tag
**File:** `scripts/aba.sh` (~lines 554–560)
**Severity:** High — an image from a registry on a non-default port cannot be added, and a reference with no tag is stored
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same check. `images.conf` was not changed.
**What happened:** `registry.redhat.io/ubi9/ubi:latest` is accepted. `mirror.example.com:8443/ubi9/ubi:latest` is rejected. `registry.redhat.io/ubi9/ubi` is accepted even though the error text says the form is `registry/repo/image:tag`. The host part of the pattern has no port, and the tag is optional.
**Suggested fix:** Allow an optional `:port` on the registry host. Require a tag or a digest.

### Bug #1129: Adding an image set ignores the selected directory
**File:** `scripts/aba.sh` (~lines 499–518). `image_set_add` in `scripts/image-sets.sh` (~line 286). `image_set_remove` is called the same way (~line 528).
**Severity:** High — `aba -d <mirror> image set add` changes the repo-wide image list
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `image_set_add` in a throwaway root. The repo `images.conf` was not changed.
**What happened:** `aba image` sets the file to `<dir>/images.conf` when a directory was selected, and to the repo `images.conf` otherwise. `image add` uses that file. `image set add` calls `image_set_add`, which always writes `${ABA_ROOT}/images.conf`. A selected directory of `/tmp/aba-mirror` stayed empty, and the throwaway root `images.conf` received the `virt` block.
**Suggested fix:** Pass the selected `images.conf` path into `image_set_add` and `image_set_remove`.

### Bug #1130: An operator name is used as a regular expression
**File:** `scripts/reg-create-imageset-config.sh` (`_resolve_op` ~lines 140–145)
**Severity:** High — the lookup can select a different operator from the one that was requested
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 against `catalogs/redhat-operator-index-v4.21`. No imageset was written.
**What happened:** The lookup is `grep "^$_op "`. The name is a regular expression. In the 4.21 Red Hat index, `amq-broker-rhel.` matches `amq-broker-rhel8` and `amq-broker-rhel9`. The function keeps the first match, so the request selects `amq-broker-rhel8`. A fixed-string search for `amq-broker-rhel.` finds no line.
**Suggested fix:** Match the operator name as a fixed string.

### Bug #1131: One quote in an image name drops every additional image
**File:** `scripts/include_all.sh` (`_merge_images_conf` ~lines 1036–1044). `scripts/j2` (~lines 38–42). `templates/imageset-config.yaml.j2` (~lines 25–29)
**Severity:** High — the imageset is generated with no additional images
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same JSON build and `scripts/j2`. No imageset was written.
**What happened:** The merger inserts the image name between quotes. An image `quay.io/org/img":tag` becomes `[{"name":"quay.io/org/img":tag","source":"images.conf"}]`, which is not valid JSON. `scripts/j2` keeps invalid `json_` values under the original name, so `additional_images` is missing. The template then prints no `additionalImages` section. The same template keeps `quay.io/org/img:tag` when the JSON is valid.
**Suggested fix:** Encode the image list with a JSON encoder. Stop imageset generation if that value is not valid JSON.

### Bug #1132: One quote in an operator display name drops every operator
**File:** `scripts/reg-create-imageset-config.sh` (~lines 166–168). `scripts/j2` (~lines 38–42). `templates/imageset-config.yaml.j2` (operators section)
**Severity:** High — the imageset is generated with no operators
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same `printf` the script uses and `scripts/j2`. No imageset was written. The 4.21 index lines do not currently contain a quote.
**What happened:** The package object is built with `printf '{"name":"%s","channel":"%s","comment":"%s","group":"%s"}'`. A display name `Red Hat "Special"` becomes `"comment":"Red Hat "Special""`, which is not valid JSON. `scripts/j2` keeps that value under the original name, so `operators_data` is missing. The template then prints no operators. The same template keeps `my-operator` when the JSON is valid.
**Suggested fix:** Encode each package with a JSON encoder. Stop imageset generation if the operator list is not valid JSON.

### Bug #1133: A package.yaml with Windows line endings is left out of the catalog index
**File:** `scripts/catalog-extract-functions.sh` (`_extract_from_yaml` ~lines 158–168)
**Severity:** High — that operator is missing from the index, and the syntax check does not report a bad line
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by sourcing the extractor. No catalog download was run.
**What happened:** The extractor reads `name`, `defaultChannel`, and `schema` with awk `$2`. A CRLF file leaves a carriage return on the schema, so `olm.package` does not match. The function prints no index line. `_index_syntax_bad_lines` reports nothing for that empty result. A plain LF file for the same package prints `my-operator - stable`.
**Suggested fix:** Strip the carriage return before comparing the schema. Parse the YAML values instead of taking awk field 2.

### Bug #1134: A folded package name is stored as `>`
**File:** `scripts/catalog-extract-functions.sh` (`_extract_from_yaml` ~lines 163–164, `_index_print`)
**Severity:** High — the index line names the operator `>`
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by sourcing the extractor. The syntax check flags the line `> - stable`. No catalog download was run.
**What happened:** A package file with `name:` followed by a folded scalar `>` stores `$2`, which is `>`. The index line is `> - stable`. The same file written as `name: my-operator` prints `my-operator - stable`.
**Suggested fix:** Parse the YAML name. Reject a package name that is not a package token before writing the index.

### Bug #1135: Day-2 checks only the first mirror set in a multi-document file
**File:** `scripts/day2.sh` (~lines 417–441)
**Severity:** High — a second ImageDigestMirrorSet in the same file can be overwritten, or left in place when the first one is renamed
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 against `mirror/data/working-dir/cluster-resources/idms-oc-mirror.yaml` on conno. Day-2 was not run.
**What happened:** That file is two ImageDigestMirrorSet documents, `idms-release-0` and `idms-operator-0`. The collision check is `awk '/^  name:/{print $2; exit}'`, so it reads `idms-release-0` and stops. A different registry on `idms-operator-0` does not ask for a rename. When the first name is renamed, the same sed leaves `idms-operator-0` unchanged, and `oc apply` still sends that document under the original name.
**Suggested fix:** Walk every document in the file. Rename each one whose existing mirror points at a different registry.

### Bug #1136: Day-2 deletes the OSUS pod when the pod start time is missing
**File:** `scripts/day2.sh` (~lines 82–93)
**Severity:** High — a failed pod query restarts the update service
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's timestamp test. The pod was not deleted.
**What happened:** The graph file time is compared with the OSUS pod start time. A failed `oc get pod`, or a pod list with no start time, leaves that time at 0. The graph file is newer than 0, so the script prints that the graph changed and runs `oc delete pod -n openshift-update-service -l app=osus`.
**Suggested fix:** Delete the pod only after a successful query that returns a start time, and only when the graph file is newer than that time.

### Bug #1137: Day-2 never applies the mirrored ClusterCatalog
**File:** `scripts/day2.sh` (~line 455)
**Severity:** High — OLMv1 keeps using the public catalog instead of the mirror
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 on compact. Day-2 was not run.
**What happened:** oc-mirror wrote `cluster-resources/cc-redhat-operator-index-sha256-a1b3b.yaml`. Its image host is `conno.example.com:8443`. Day-2 only collects `cs-*-index*yaml`, so that file is never applied. Compact has no ClusterCatalog with that name. Its `openshift-redhat-operators` ClusterCatalog still points at `registry.redhat.io`. The older CatalogSource `redhat-operators` is present.
**Suggested fix:** Apply each `cc-*.yaml` the same way the CatalogSource files are applied, with the mirror registry as the image.

### Bug #1138: Day-2 leaves the default ClusterCatalogs on the public registry
**File:** `scripts/day2.sh` (~lines 148–152)
**Severity:** High — a disconnected cluster still has OLMv1 catalogs aimed at `registry.redhat.io`
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 on compact. Day-2 was not run.
**What happened:** For a mirror install, day-2 sets OperatorHub `disableAllDefaultSources` and logs that default catalog sources are disabled. That flag covers CatalogSources. Compact still has four ClusterCatalogs, `openshift-certified-operators`, `openshift-community-operators`, `openshift-redhat-marketplace`, and `openshift-redhat-operators`, each pointing at `registry.redhat.io`.
**Suggested fix:** When default catalog sources are disabled, also disable or retarget those default ClusterCatalogs.

### Bug #1139: VM refresh continues after delete fails
**File:** `scripts/vmw-refresh.sh` (~line 20). `scripts/kvm-refresh.sh` (~line 19)
**Severity:** High — a failed delete still removes the install marker and starts creating VMs
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the refresh commands and a delete that exits 1. No VM was deleted or created.
**What happened:** When VMs exist, refresh runs `vmw-delete.sh || true` (and the same for KVM). A delete that exits 1 still continues. The next lines remove `.install-complete` and `.vms-ready`, then start create. In the test, delete printed failure, the marker was gone, and create started.
**Suggested fix:** If delete fails, stop the refresh. Leave the install marker in place.

### Bug #1140: Stop and kill succeed when the hypervisor cannot be queried
**File:** `scripts/vm-provider.sh` (`vm_on_any` ~lines 72–77, `vm_stop` ~line 123, `vm_kill` ~line 143). `scripts/vm-vmw.sh` (`vmp_is_on` ~lines 56–62). `scripts/vm-kvm.sh` (`vmp_is_on` ~lines 35–39)
**Severity:** High — shutdown is skipped while the VMs may still be running
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the real power checks. No VM was stopped.
**What happened:** `vm_stop` and `vm_kill` return 0 when `vm_on_any` finds nothing powered on. A failed vCenter query makes `vmp_is_on` return 1 and warn that vCenter may be unreachable. A failed `virsh domstate` does the same on KVM. `vm_on_any` treats that as not running. `vm_stop` and `vm_kill` then return 0 without sending a power-off.
**Suggested fix:** Propagate a failed power query the way `vm_exists_any` does. Do not return success from stop or kill when the hypervisor could not be queried.

### Bug #1141: A missing hypervisor config is reported as success
**File:** `scripts/vmw-exists.sh` (~lines 7–13), `scripts/vmw-start.sh` (~lines 12–18), and the matching `kvm-exists.sh` and `kvm-start.sh` branches
**Severity:** High — callers treat exit 0 from exists as "a VM was found", and start reports that it finished
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 from a directory with no `vmware.conf` or `kvm.conf`. No VM was contacted.
**What happened:** `vmw-exists.sh` prints that `vmware.conf` is not defined and exits 0. Its contract is that 0 means a VM exists. `vmw-start.sh` takes the same branch and exits 0, so `aba start` succeeds without powering anything on. `kvm-exists.sh` also exits 0 when `kvm.conf` is missing. Refresh treats exists exit 0 as "VMs are present" and continues into delete and create, which use the same exit 0 branch.
**Suggested fix:** Exit non-zero when the hypervisor config is missing. For exists, use the unreachable code (2), not the found code (0).

### Bug #1142: Stop returns success when the power-off command fails
**File:** `scripts/vm-vmw.sh` (`vmp_power_off` ~lines 87–90, `vmp_kill` ~lines 93–96). `scripts/vm-provider.sh` (`vm_stop` ~lines 131–135)
**Severity:** High — the VMs stay on and the caller is told they were stopped
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the real `vm_stop` and a power command that exits 1. No VM was stopped.
**What happened:** The power query says the VM is on, so stop sends `govc vm.power -s`. That command is run with `|| true`, so a failure is discarded. `vm_stop` then returns 0. `vmp_kill` hides a failed power-off the same way. This is the path where the hypervisor answered and the power command itself failed.
**Suggested fix:** Return the power command's failure from `vmp_power_off` and `vmp_kill`. Do not let `vm_stop` return 0 after that failure.

### Bug #1143: KVM start returns success when virsh fails
**File:** `scripts/vm-kvm.sh` (`vmp_power_on` ~lines 54–58). `scripts/vm-provider.sh` (`vm_start` ~lines 111–115)
**Severity:** High — the VM stays off and start reports that it finished
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the real `vm_start` and a `virsh` that exits 1. No VM was started.
**What happened:** `vmp_power_on` runs `virsh start` with `|| true`. `vm_start` does not set a wait, so it returns 0 after that command. The test printed `VIRSH -c start sno-master1` and `start_rc=0`.
**Suggested fix:** Return virsh's failure from `vmp_power_on`. Do not let `vm_start` return 0 when the start command failed.

### Bug #1144: A MAC list that is not a multiple of the node count is stored as one port
**File:** `scripts/cluster-config.sh` (`distribute_macs` ~lines 50–87)
**Severity:** High — later nodes can be given another node's interface address
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by running `distribute_macs`. No agent config was written.
**What happened:** The port count is integer division of MAC count by node count. Six MACs for three nodes correctly become two ports. Four MACs for three nodes become one port, and that port is `aa:1 aa:2 bb:1 cc:1`. The extra address is not rejected. A count smaller than the node count is rejected; a count that does not divide evenly is not.
**Suggested fix:** Abort when the MAC count is not an exact multiple of the node count.

### Bug #1145: A missing address in a node list is kept as the word null
**File:** `scripts/cluster-config.sh` (~lines 156–158, and the same `= "null"` test on the hostname and MAC lines above)
**Severity:** High — validation passes and later steps use `null` as an address
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's jq filter and its null test. No agent config was written.
**What happened:** The jq filter prints one address per master. A missing address is the line `null`. The script clears the list only when the whole value is exactly `null`. One missing address among `10.0.1.71`, `10.0.1.72`, and `null` is not cleared, and the empty check says the list is present. Three missing addresses, printed as three lines of `null`, are also kept. A single-node config whose only value is `null` is cleared.
**Suggested fix:** Reject the list when any line is `null`. Do not treat a multi-line null value as a present address list.

### Bug #1146: Only the first compute pool is counted
**File:** `scripts/cluster-config.sh` (~line 160)
**Severity:** High — worker replica count ignores every compute pool after the first
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's jq filter. No install config was written.
**What happened:** Worker replicas are `.compute[0].replicas`. An install config with a worker pool of 2 and an infra pool of 3 exports 2. The sum of the pools is 5.
**Suggested fix:** Sum every compute pool's replicas.

### Bug #1147: Agent IP generation ignores the first usable address
**File:** `scripts/create-agent-config.sh` (`generate_ip_array` ~lines 54–77, `calculate_cidr_range` ~lines 37–50)
**Severity:** High — a node can be given an address outside the machine network, including the network address
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by running these functions. No agent config was written.
**What happened:** `calculate_cidr_range` computes `first_usable`, and `generate_ip_array` reads it, but the loop only stops when the address is past `last_usable`. For `10.10.100.0/24`, starting at `10.10.99.254` and asking for 4 addresses returns `10.10.99.254`, `10.10.99.255`, `10.10.100.0`, and `10.10.100.1`. The first three are outside the CIDR or are the network address. Starting at `10.10.100.0` returns that network address.
**Suggested fix:** Reject a starting address below `first_usable`. Do not add the network address or any address outside the CIDR.

### Bug #1148: A short IP list is still written as a successful agent config
**File:** `scripts/create-agent-config.sh` (~lines 68–77 and 114, success at ~line 329)
**Severity:** High — the cluster is generated with fewer node addresses than nodes
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by running `generate_ip_array`. No agent config was written.
**What happened:** Asking for 3 addresses in `10.0.1.0/24` starting at `10.0.1.254` prints `Reached the end of the CIDR range.` and returns only `10.0.1.254`. The script exports that list and has no comparison with the node count. Its shebang does not enable `set -e`, and the success line is unconditional.
**Suggested fix:** Abort when the generated address count is not the node count. Do not write `agent-config.yaml` in that case.

### Bug #1149: A leading zero in a starting IP is turned into 0.0.0.0
**File:** `scripts/create-agent-config.sh` (`to_numeric` ~lines 23–28, `generate_ip_array` ~line 63)
**Severity:** High — the node addresses become 0.0.0.0, 0.0.0.1, and so on
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by running these functions. No agent config was written.
**What happened:** `to_numeric` evaluates the octets with bash arithmetic. `10.0.0.08` fails with `value too great for base` because `08` is an octal constant. The script has no `set -e`, so the empty result is used as 0. Asking for 3 addresses then returns `0.0.0.0 0.0.0.1 0.0.0.2`. `10.0.0.09` fails the same way.
**Suggested fix:** Read each octet with a base-10 conversion. Abort when the conversion fails.

### Bug #1150: A quote in a disk hint drops every disk hint
**File:** `scripts/include_all.sh` (`_parse_disk_hint` ~lines 1075–1076). `scripts/j2` (~lines 38–42). `templates/agent-config.yaml.j2` (~lines 40–44)
**Severity:** High — root device hints are omitted from the agent config
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `_parse_disk_hint` and `scripts/j2`. No agent config was written.
**What happened:** A hint `vendor=SEAGATE "X"` is returned as `{"vendor": "SEAGATE "X""}` with exit 0. That is not valid JSON. `scripts/j2` keeps invalid `json_` values under the original name, so `disk_hints` is missing and the template prints no `rootDeviceHints`. The same template keeps `SEAGATE` when the JSON is valid.
**Suggested fix:** Encode the hint with a JSON encoder. Abort agent-config generation when the hint is not valid JSON.

### Bug #1151: A failed install-config render is reported as success
**File:** `scripts/create-install-config.sh` (~lines 282–284)
**Severity:** High — `install-config.yaml` is emptied and the command says it was generated
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `scripts/j2` and the script's next line. The install-config script was not run, so no cluster file was written.
**What happened:** The content-sources render is checked and aborts on failure. The final `scripts/j2 templates/install-config.yaml.j2 > install-config.yaml` is not checked. The shell truncates the destination when the redirect opens. A template error exits 1 and leaves a 0-byte file. The next line is the success message. The script's shebang does not enable `set -e`.
**Suggested fix:** Abort when the final render exits non-zero. Do not print the success line, and do not replace an existing file until the render succeeds.

### Bug #1152: A single quote in the vCenter password makes install-config invalid
**File:** `templates/install-config.yaml.j2` (~line 65)
**Severity:** High — the generated file is not valid YAML, so install cannot read the vCenter password
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by rendering the template with a fake password. No cluster file was written.
**What happened:** The password is wrapped in single quotes: `password: '{{ GOVC_PASSWORD }}'`. A password containing a single quote renders as `password: 'p'ass'`. `scripts/j2` exits 0. PyYAML rejects the file.
**Suggested fix:** Quote the password with a YAML encoder that escapes single quotes. Abort the render when the result is not valid YAML.

### Bug #1153: An empty no_proxy becomes a leading comma in noProxy
**File:** `templates/install-config.yaml.j2` (~line 9)
**Severity:** High — the cluster proxy exclusion list starts with an empty entry
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by rendering the template with `use_proxy` set and `no_proxy` empty. No cluster file was written.
**What happened:** The line is `noProxy: {{ no_proxy }},{{ machine_network }}/{{ prefix_length }},...`. With an empty `no_proxy` the value is `,10.0.0.0/20,10.128.0.0/14,172.30.0.0/16`. Proxy mode is selected when either `http_proxy` or `https_proxy` is set, so `no_proxy` can be empty.
**Suggested fix:** Omit the user value when it is empty. Do not start the list with a comma.

### Bug #1154: A vSphere network name containing a colon becomes a map
**File:** `templates/install-config.yaml.j2` (~line 53)
**Severity:** High — the failure-domain network is not the name that was configured
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by rendering the template. No cluster file was written.
**What happened:** The network is inserted without quotes: `- {{ GOVC_NETWORK }}`. A name `Site: Lab` renders as `- Site: Lab`. PyYAML reads that list entry as a map, `{'Site': 'Lab'}`, not as the string `Site: Lab`. `scripts/j2` exits 0.
**Suggested fix:** Quote the network name as a YAML string. Abort the render when the networks list is not a list of strings.

### Bug #1155: An invalid public pull secret is cleared and generation continues
**File:** `scripts/create-install-config.sh` (~lines 219–223)
**Severity:** High — install-config is written with an empty pull secret
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's `jq` assignment and a render. No cluster file was written.
**What happened:** When no mirror secret is set, the public file is read with `jq .`. A file `{bad` makes `jq` exit 4 and leaves `pull_secret` empty. The script has no `set -e`, so it still logs that it is using that file. Rendering then exits 0 with `pullSecret` set to an empty string.
**Suggested fix:** Abort when `jq` cannot parse the pull secret. Do not render install-config with an empty pull secret.

### Bug #1156: A short MAC list on a VM platform is written as empty addresses
**File:** `scripts/create-agent-config.sh` (~lines 176–185), `templates/agent-config.yaml.j2` (~line 38)
**Severity:** High — generated agent-config has blank NIC addresses
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by rendering the template. No cluster file was written.
**What happened:** When `macs.conf` has fewer addresses than the cluster needs, only bare metal pads the list. On vmw or kvm the short list is kept. The template turns a missing index into an empty `macAddress`. A 3-master, 2-worker render given two addresses kept `aa:1` and `aa:2` on the first two masters and wrote an empty address for the third master and both workers. `scripts/j2` exited 0, and the script then reports that agent-config was generated successfully.
**Suggested fix:** Abort when the MAC count is below the node count on every platform. Do not write an empty `macAddress`.

### Bug #1157: A failed SSH public key is omitted and generation continues
**File:** `scripts/create-install-config.sh` (~lines 235–243)
**Severity:** High — install-config is written with no SSH key
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `ssh-keygen -y` and a render. No cluster file was written.
**What happened:** Regenerating the public key uses `ssh-keygen -y -f "$ssh_key_file" > "$ssh_key_file.pub"`. A corrupt private key makes `ssh-keygen` exit 255, and the redirect leaves a 0-byte public key. The script has no `set -e`, so it exports an empty key. The template then skips `sshKey`, and `scripts/j2` exits 0.
**Suggested fix:** Abort when `ssh-keygen` fails. Do not replace the public key with an empty file.

### Bug #1158: A single quote in a registry password makes state.sh invalid
**File:** `scripts/reg-common.sh` (`reg_mark_installing` ~line 160, `reg_post_install` ~line 666, `reg_finish_uninstall` ~line 1415), `scripts/include_all.sh` (`verify-mirror-conf` ~lines 851–857)
**Severity:** High — registry start, stop, and uninstall source a file that the shell rejects
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with a throwaway mirror.conf and the same heredoc the writer uses. No live registry state was changed.
**What happened:** For docker and omr, `verify-mirror-conf` skips the quote check that Quay uses. A password `p'ass` loads from mirror.conf and verification exits 0. The state file is then written as `reg_pw='p'ass'`. Sourcing that file exits 2 with a mismatched-quote syntax error. `reg-start.sh` has no `set -e`, so the failed source is ignored. The saved-login file written on uninstall has the same quoting, and sourcing it also exits 2.
**Suggested fix:** Shell-quote the password when writing `state.sh` and `.aba-reuse-creds`. Reject the file when it is not valid shell.

### Bug #1159: A failed remote package query is treated as success
**File:** `scripts/reg-common.sh` (`reg_ensure_remote_pkgs` ~lines 580–593)
**Severity:** High — a remote registry install continues when the package check never ran
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling the function with a stand-in SSH command. No host was contacted.
**What happened:** The package list comes from the SSH command's output, and the exit status is ignored. A command that exits 1 and prints nothing leaves the missing-package list empty, so the function returns 0 and does not try to install anything.
**Suggested fix:** Abort when the package query fails. Install only after a successful query that lists missing packages.

### Bug #1160: Registry stop succeeds when the port check cannot run
**File:** `scripts/reg-common.sh` (`reg_stop_vendor` ~lines 1594–1598), `scripts/reg-stop.sh` (~line 44)
**Severity:** High — stop reports success and records the registry as stopped
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling `reg_stop_vendor` with stand-ins. No registry was stopped.
**What happened:** The port check is `ss | grep`. Any non-zero result is treated as "already stopped", including a failed check. An SSH command that exits 255 prints `already stopped (port 8443 not listening)` and `reg_stop_vendor` returns 0. A local check whose `ss` exits 1 does the same. `reg-stop.sh` then writes `reg_running=false`.
**Suggested fix:** Abort when `ss` or SSH fails. Return success only when the port check itself reports that nothing is listening.

### Bug #1161: A missing systemctl makes a Quay registry look fully removed
**File:** `scripts/reg-common.sh` (`reg_stale_report` ~lines 845–849)
**Severity:** High — uninstall can treat a failed service probe as a clean host
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling `reg_stale_report` with `systemctl` absent from `PATH`. No registry was removed.
**What happened:** The Quay service probe runs `systemctl --user is-active quay-app.service || true`. With `systemctl` missing, that command exits 0 and prints nothing, so the service is not reported. The other probes reported the registry absent, and `reg_stale_report quay` returned 0 with an empty report. The same host makes `reg_stale_report omr` abort with `Registry probe failed (quay.service, rc=127)`.
**Suggested fix:** Do not append `|| true`. Abort on a failed service probe the way the omr branch does.

### Bug #1162: A single quote in the registry password breaks remote Docker install
**File:** `scripts/reg-install-docker-remote.sh` (~line 86)
**Severity:** High — the remote install script is invalid shell
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by syntax-checking the expanded remote command. No registry was installed.
**What happened:** Docker passwords may contain a single quote; `verify-mirror-conf` does not reject one. The remote command inserts that password in single quotes: `htpasswd -Bbn '$reg_user' '$reg_pw'`. With password `p'ass`, `bash -n` exits 2 with a mismatched quote. The local Docker install quotes the password with double quotes, and the remote Quay install uses `printf '%q'`.
**Suggested fix:** Quote the password with `printf '%q'` before placing it in the remote script. Abort before SSH when the generated script is not valid shell.

### Bug #1163: The registry certificate check treats the hostname as a regular expression
**File:** `scripts/reg-install-docker.sh` (~line 63), `scripts/reg-install-docker-remote.sh` (~line 70)
**Severity:** High — a certificate for a different name is reused
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's `grep` pattern. No certificate was generated.
**What happened:** The check is `grep -q "DNS:${reg_host}$"`. The hostname is not matched literally, so `.` matches any character. For host `reg.example.com`, a subject alternative name `DNS:reg-example.com` matches and the script keeps that certificate instead of generating a new one.
**Suggested fix:** Match the hostname as a fixed string. Generate a new certificate when the name is not an exact match.

### Bug #1164: Any HTTP response on /v2/ is treated as an existing registry
**File:** `scripts/include_all.sh` (`probe_host` ~lines 5439–5444), `scripts/reg-install-omr.sh` (~line 59), `scripts/reg-install-quay.sh` (~line 135), `scripts/reg-install-docker-remote.sh` (~line 39), and the matching remote install scripts
**Severity:** High — registry install is skipped and then recorded as installed
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling `probe_host` against a local stand-in. No registry was installed.
**What happened:** `probe_host --any` drops curl's `-f`, so any HTTP response is success. A stand-in on `127.0.0.1:18444` that returned 404 for `/v2/` with body `not-a-registry` made `probe_host` return 0. Quay, omr, and remote Docker install use that result to skip creating the registry, then still call `reg_post_install`, which writes `state.sh` and prints that the registry was installed.
**Suggested fix:** Treat only a registry response as an existing registry. Do not skip install or write `state.sh` when the endpoint is some other HTTP service.

### Bug #1165: Registry authentication succeeds on any HTTP 200
**File:** `scripts/reg-common.sh` (`reg_check_v2_auth` ~lines 1441–1445)
**Severity:** High — install accepts a host that is not a registry
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling `reg_check_v2_auth` against a local stand-in. No registry was installed.
**What happened:** The check returns 0 as soon as `/v2/` responds with HTTP 200. The same stand-in, now returning 200 and the body `not-a-registry`, made `reg_check_v2_auth` return 0 for user `init`. Combined with Bug #1164, the install's readiness probe and this auth check both pass, so the script finishes successfully without installing a registry.
**Suggested fix:** Require a registry response, not only status 200. Abort when the endpoint is not a registry.

### Bug #1166: A failed firewall command is recorded as the port being open
**File:** `scripts/reg-common.sh` (`reg_open_firewall` ~lines 489–492 and ~508–510)
**Severity:** High — install records a firewall change that did not happen
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling `reg_open_firewall` with stand-ins. No firewall rule was changed.
**What happened:** After `firewall-cmd` fails, the function still sets `_reg_fw_opened=1` and returns 0. A remote stand-in whose `firewall-cmd` exited 1 left `_reg_fw_opened=1`. The local path did the same when `firewall-cmd` exited 1. `reg_post_install` writes that flag into `state.sh`.
**Suggested fix:** Set the flag only when the firewall command exits 0. Abort when the port was not opened.

### Bug #1167: Closing the registry firewall port succeeds when removal fails
**File:** `scripts/reg-common.sh` (`reg_close_firewall` ~lines 552–555)
**Severity:** High — uninstall leaves the port open and reports success
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling `reg_close_firewall` with a stand-in. No firewall rule was changed.
**What happened:** The remove command is followed by `|| true`. With `reg_fw_opened=1`, a remote stand-in whose `firewall-cmd` exited 1 still made `reg_close_firewall` return 0.
**Suggested fix:** Abort when the port cannot be removed. Do not treat a failed `firewall-cmd` as a closed port.

### Bug #1168: Registry DNS resolution accepts a dotted name as an IPv4 address
**File:** `scripts/reg-common.sh` (`reg_check_fqdn` ~lines 81–90)
**Severity:** High — the registry is aimed at the wrong address
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling `reg_check_fqdn` with a stand-in `dig`. No DNS server was queried.
**What happened:** The answer is scanned with `grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}'` and the first match is kept. A stand-in that printed `10.0.0.10.example.com.` and then `192.0.2.1` set `fqdn_ip` to `10.0.0.10` and returned 0. The same pattern accepts `999.1.2.3`, which is not an IPv4 address.
**Suggested fix:** Accept only a line that is an IPv4 address, with each octet in the range 0–255. Do not take a match from inside a DNS name.

### Bug #1169: The Quay resource warning allows hosts below the stated minimum
**File:** `scripts/reg-common.sh` (`reg_check_quay_resources` ~lines 307–312)
**Severity:** High — install continues on a host Quay cannot run
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling `reg_check_quay_resources` with stand-in CPU and memory values. No host was changed.
**What happened:** The message says Quay needs at least 4 vCPUs and 8GB RAM. The condition warns only when CPUs are 2 or fewer, or memory is 4GB or less. A stand-in with 3 vCPUs and 7GB RAM returned 0 with no warning. A stand-in with 4 vCPUs and 5GB RAM did the same. A stand-in with 2 vCPUs did warn.
**Suggested fix:** Warn when the host has fewer than 4 vCPUs or less than 8GB RAM.

### Bug #1170: A `~user` registry data directory is accepted and not expanded
**File:** `scripts/include_all.sh` (`_expand_tilde` ~lines 771–776), `scripts/reg-common.sh` (`reg_setup_data_dir` ~lines 330–346)
**Severity:** High — registry data is stored at a literal tilde path
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling `reg_setup_data_dir`. No registry data was written.
**What happened:** `_expand_tilde` expands `~` and `~/...` only. `reg_setup_data_dir` then accepts any value that starts with `~` as an absolute path. With `data_dir=~other/reg` and no SSH key, the function returned 0 and set `reg_root` to the literal `~other/reg/docker-reg`. `~/reg` does expand to a home path.
**Suggested fix:** Expand `~user` to that user's home directory. Reject a data directory that is still not an absolute path after expansion.

### Bug #1171: A valid Docker registry port produces an invalid debug port
**File:** `scripts/reg-install-docker.sh` (~line 109)
**Severity:** High — the registry process is given a port it cannot bind
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's port arithmetic and `valid_port`. No container was started.
**What happened:** The container is started with `REGISTRY_HTTP_DEBUG_ADDR=localhost:$(( reg_port + 10000 ))`. `valid_port` accepts registry port `60000` and rejects the resulting debug port `70000`.
**Suggested fix:** Reject a debug port outside 1–65535. Do not start the container with that address.

### Bug #1172: Import stores the first DNS name as the API address
**File:** `scripts/cluster-import.sh` (~lines 113–114)
**Severity:** High — `api_vip` and `ingress_vip` are written as hostnames
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `dig +short` and the script's `head -1`. No cluster was imported.
**What happened:** For more than one master, the VIPs are `dig +short ... | head -1`. `dig +short www.github.com` printed `github.com.` and then `20.205.243.166`. The first line is the CNAME, so that pipeline keeps `github.com.` and never uses the address. The same pattern is used for the ingress name. The value is written into `cluster.conf`.
**Suggested fix:** Use the first line that is an IPv4 address. Leave the VIP empty when DNS returns only a name.

### Bug #1173: Import guesses a /24 that does not contain every node
**File:** `scripts/cluster-import.sh` (~lines 98–107)
**Severity:** High — the imported machine network excludes cluster nodes
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's address rewrite and `ip_in_cidr`. No cluster was imported.
**What happened:** When the host has no route to the first node, the network becomes that address with the last octet replaced by 0 and prefix 24, unless `machine_network` is already set. `10.0.1.71` becomes `10.0.1.0/24`. `ip_in_cidr` reports that `10.0.2.10` is outside that network. The route lookup is the importing host's routing table, so a jump host takes this branch.
**Suggested fix:** Derive the network from the cluster, not from the host route or a /24 around one node. Abort when a node address is outside the chosen network.

### Bug #1174: Import records a vSphere SNO as bare metal
**File:** `scripts/cluster-import.sh` (~lines 299–304)
**Severity:** High — shutdown, startup, and delete use the bare-metal path
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by reading the platform type and running the script's `case`. No cluster was imported.
**What happened:** The only types mapped to a VM platform are `VSphere`. Everything else, including `None` and `KubeVirt`, becomes `bm`. Compact reports `VSphere`, so that cluster would be `vmw`. sno2 reports `None`, which is what an agent-based SNO publishes, and the `case` stores `bm`.
**Suggested fix:** Do not default `None` to bare metal. Keep the platform used to create the VMs.

### Bug #1175: Import uses the lowest node address as the rendezvous address
**File:** `scripts/cluster-import.sh` (~lines 92–95 and ~331)
**Severity:** High — `aba ssh` and the starting IP point at a worker
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's sort. No cluster was imported.
**What happened:** Master addresses `10.0.1.71`, `10.0.1.72`, and `10.0.1.73` plus worker addresses `10.0.1.10` and `10.0.1.11` sort to `10.0.1.10`. That value is written as `starting_ip` and as `iso-agent-based/rendezvousIP`.
**Suggested fix:** Use the lowest master address. Do not choose a worker address for the rendezvous IP.

### Bug #1176: Import removes the cluster name from the base domain
**File:** `scripts/cluster-import.sh` (~lines 71–73)
**Severity:** High — the imported FQDN is the parent domain
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's prefix removal. No cluster was imported.
**What happened:** After the infrastructure name is found, the base domain is stripped with `${domain#cluster.}`. Cluster `example` and domain `example.com` become domain `com`, so the FQDN is `example.com`. Cluster `compact` and domain `example.com` stay `example.com`.
**Suggested fix:** Leave the DNS base domain unchanged. Abort when the cluster name is not a label in front of that domain.

### Bug #1177: A missing infrastructure name is taken from the base domain
**File:** `scripts/cluster-import.sh` (~lines 66–69)
**Severity:** High — the imported cluster name and domain are both wrong
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's empty-name branch. No cluster was imported.
**What happened:** When the infrastructure name is empty, the first label of the base domain becomes the cluster name and the remainder becomes the domain. `example.com` becomes cluster `example` and domain `com`.
**Suggested fix:** Abort when the infrastructure name is missing. Do not split the base domain into a cluster name.

### Bug #1178: A failed mirror query is imported as a direct cluster
**File:** `scripts/cluster-import.sh` (~lines 127–139)
**Severity:** High — a mirrored cluster is recorded as directly connected
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's `grep -c` pipeline. No cluster was imported.
**What happened:** Each mirror object list is `oc get ... | grep -c -v '^NAME' || true`. A command that fails and prints nothing makes each count 0. The sum is 0, the proxy field is empty, and `image_source` is set to `direct`.
**Suggested fix:** Abort when a mirror-object query fails. Set `direct` only after the queries succeed and return no mirror objects.

### Bug #1179: Import counts every node address as a node
**File:** `scripts/cluster-import.sh` (~lines 85–89 and 144–146)
**Severity:** High — a dual-stack SNO is imported as a standard cluster
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's `wc -w` count and type rules. No cluster was imported.
**What happened:** The master list is every InternalIP, and the count is the number of words. One master with `10.0.1.71` and `fd00::71` is 2 masters and 0 workers. The type stays `standard` because it is not 1 master and not at least 3 masters.
**Suggested fix:** Count nodes, not addresses. Use one IPv4 address per node for the replica count.

### Bug #1180: Import rejects a node that has only an IPv6 address
**File:** `scripts/cluster-import.sh` (~lines 93–95)
**Severity:** High — import stops after finding the master
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's address filter. No cluster was imported.
**What happened:** The starting address must match `^[0-9]`. A master list of `fd00::71` counts as one master, then the filter removes it. The starting address is empty and import aborts with "Could not detect node IP addresses."
**Suggested fix:** Accept an IPv6 address as a node address. Do not require the address to start with a digit.

### Bug #1181: DNS and NTP server lists are sorted out of their original order
**File:** `scripts/include_all.sh` (`get_dns_servers` ~lines 4282–4286, `get_ntp_servers` ~lines 4328–4334)
**Severity:** High — the first server, which clients try first, is replaced
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the scripts' `sort -u | paste` pipeline. No config file was written.
**What happened:** Both functions dedupe with `sort -u`. DNS servers `10.0.0.8` then `10.0.0.10` become `10.0.0.10,10.0.0.8`. NTP servers `ntp2.example.com` then `ntp1.example.com` become `ntp1.example.com,ntp2.example.com`. Import writes those values into `cluster.conf`.
**Suggested fix:** Remove duplicates without sorting. Keep the first occurrence of each server.

### Bug #1182: IPv6 DNS servers are discarded
**File:** `scripts/include_all.sh` (`get_dns_servers` ~lines 4284 and 4312)
**Severity:** High — a host that uses only IPv6 DNS imports and installs with no DNS servers
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's `grep` filter. No config file was written.
**What happened:** Each lookup keeps only lines matching `^[0-9.]+`. A list of `fd00::1` and `10.0.0.10` keeps `10.0.0.10`. A list of only `fd00::1` is empty.
**Suggested fix:** Keep IPv6 nameservers. Do not require a nameserver to be IPv4.

### Bug #1183: The systemd-resolved DNS parser keeps the link number and then drops every server
**File:** `scripts/include_all.sh` (`get_dns_servers` ~lines 4301–4318)
**Severity:** High — the host's DNS list becomes empty
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the function's `awk` and validator. No config file was written.
**What happened:** `resolvectl dns` lines look like `Global: 8.8.8.8` and `Link 2 (ens224): 10.0.0.10`. `awk '{print $2}'` prints `8.8.8.8` and `2`. The parsed list is `2,8.8.8.8`. That is not empty, so the `resolv.conf` fallback does not run. The IPv4 check then clears the list.
**Suggested fix:** Read the addresses after the colon. If that list is not valid, try the next DNS source instead of clearing a non-empty parse.

### Bug #1184: One unusable NTP entry clears the whole server list
**File:** `scripts/include_all.sh` (`get_ntp_servers` ~line 4337)
**Severity:** High — a cluster is configured with no NTP servers
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the function's validator. No config file was written.
**What happened:** The validator accepts only a comma-separated list of IPv4 addresses and plain hostnames. `ntp.example.com` passes. `10.0.0.8,ntp.example.com` passes. `ntp.example.com,fd00::1` fails, and the function sets the list to empty.
**Suggested fix:** Check each server on its own. Drop an entry that is not usable and keep the others. Accept an IPv6 address.

### Bug #1185: A machine network on a bridge is skipped
**File:** `scripts/include_all.sh` (`get_machine_network` ~lines 4261–4264)
**Severity:** High — the cluster is placed on the wrong network
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the function's route filter. No config file was written.
**What happened:** The fallback scan drops any route line matching `br-`. A connected route `10.0.0.0/20 dev br-ex` is dropped. The next private route, `192.168.2.0/24 dev ens192`, is the one that is returned.
**Suggested fix:** Match the bridge pattern against the device name only when that device is a container bridge. Keep a route on `br-ex`.

### Bug #1186: A host with no domain is given `example.com`
**File:** `scripts/include_all.sh` (`get_domain` ~lines 4176–4191)
**Severity:** High — new clusters are named under a domain the user does not own
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the function's empty-domain branch. No config file was written.
**What happened:** `hostname -f` of `localhost` has no dot, so no domain is derived. When the other lookups are also empty, the function prints `example.com`. `aba.conf` and the TUI use this value as the cluster domain.
**Suggested fix:** Leave the domain empty when none is found. Ask for it instead of writing `example.com`.

### Bug #1187: A semicolon in a cluster argument is executed
**File:** `scripts/include_all.sh` (`process_args` ~lines 4084–4092). Callers include `scripts/setup-cluster.sh`, `scripts/create-cluster-conf.sh`, `scripts/setup-mirror.sh`, and the VM start, stop, and refresh scripts.
**Severity:** High — text after the semicolon runs as a shell command
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by loading one argument through the function's check and `export` line. No cluster was created.
**What happened:** The checker accepts `name=sno;printf HIT`. The loader prints `export name=sno;printf HIT` and that line is sourced. The command after the semicolon ran and printed `HIT`, and `name` was still `sno`.
**Suggested fix:** Reject an argument that is not a single quoted assignment. Do not source generated text.

### Bug #1188: An interface in state UNKNOWN is treated as down
**File:** `scripts/include_all.sh` (`_pick_install_iface` ~line 4133)
**Severity:** High — the install interface is skipped and the cluster network comes from another NIC
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the function's `grep`. No network setting was changed.
**What happened:** A usable interface must match `state UP`. A link line with flags `UP,LOWER_UP` and `state UNKNOWN` does not match, so the interface is rejected. A line with `state UP` is accepted.
**Suggested fix:** Treat `state UNKNOWN` with the UP flag as usable. Do not require the word `UP` after `state`.

### Bug #1189: A node range that leaves the subnet passes the network check
**File:** `scripts/include_all.sh` (`_validate_network_consistency` ~lines 1190–1225)
**Severity:** High — the cluster is given addresses on the next network
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling the function. No cluster file was written.
**What happened:** The check rejects a starting address that is the network or broadcast address. It does not check the rest of the node range. Starting at `10.0.1.250` with 3 masters and 8 workers on `10.0.1.0/24` includes `10.0.2.4`. `ip_in_cidr` says that address is outside the subnet, and the check returns 0.
**Suggested fix:** Reject the range when any node address is outside the machine network.

### Bug #1190: The suggested starting address can fall outside the subnet
**File:** `scripts/include_all.sh` (`suggest_starting_ip` ~lines 1168–1176)
**Severity:** High — a new cluster starts on the wrong network
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling `suggest_starting_ip`. No cluster file was written.
**What happened:** The function adds 100 to the address it is given. It does not mask that address to the network. `suggest_starting_ip 10.0.1.200 24` returns `10.0.2.44`, which is outside `10.0.1.0/24`. The same call with `10.0.1.0` returns `10.0.1.100`, which is inside.
**Suggested fix:** Mask the address to the network before adding the offset. Reject a result that is outside the subnet.

### Bug #1191: An API address outside the machine network passes the network check
**File:** `scripts/include_all.sh` (`_validate_network_consistency` ~lines 1228–1239)
**Severity:** High — the cluster API is given an address the nodes cannot use
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling the function. No cluster file was written.
**What happened:** The VIP check only asks whether the address falls inside the node range. On `10.0.1.0/24`, with nodes starting at `10.0.1.20`, `api_vip=1.2.3.4` is outside the subnet and outside the node range. The check returns 0.
**Suggested fix:** Require `api_vip` and `ingress_vip` to be inside the machine network.

### Bug #1192: A node may use the DNS server address
**File:** `scripts/include_all.sh` (`_validate_network_consistency` ~lines 1208–1224)
**Severity:** High — a node is assigned the address the cluster uses for DNS
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling the function. No cluster file was written.
**What happened:** The reserved addresses are the gateway and, for more than one master, the API and ingress addresses. `dns_servers` is not reserved. With `dns_servers=10.0.1.20` and `starting_ip=10.0.1.20`, the check returns 0.
**Suggested fix:** Reserve each DNS server address. Reject a node address that matches one.

### Bug #1193: A mirror name of `..` is accepted and the mirror link points outside the repo
**File:** `scripts/include_all.sh` (`_valid_image_source` ~lines 1365–1367), `scripts/setup-cluster.sh` (~lines 101–104)
**Severity:** High — the cluster's `mirror` and `regcreds` links leave the repository
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `_valid_image_source`. No link was created.
**What happened:** Any value made of letters, digits, dots, underscores, and hyphens is a valid mirror name. `..` passes, and `foo/bar` is rejected. `setup-cluster.sh` then runs `ln -sfn ../$_mn mirror` and `ln -sfn ~/.aba/mirror/$_mn regcreds`. For `..` those targets are `../..` and `~/.aba/mirror/..`.
**Suggested fix:** Reject `.` and `..` as a mirror name. Use the same directory-name rules as a cluster name.

### Bug #1194: A new standard cluster is given 3 workers and then rewritten to 2
**File:** `scripts/create-cluster-conf.sh` (~line 120), `scripts/setup-cluster.sh` (~lines 66–90)
**Severity:** Medium — the cluster size changes after the file is created
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 from the two default assignments. No cluster directory was created.
**What happened:** `create-cluster-conf.sh` sets `num_workers=3` when it is empty and the type is standard, and writes that into `cluster.conf`. `setup-cluster.sh` then sets `num_workers` to 2 for a standard cluster and writes that over the file.
**Suggested fix:** Use one default for a standard cluster. Do not write 3 and then replace it with 2.

### Bug #1195: A duration with a leading zero is read as octal
**File:** `scripts/include_all.sh` (`parse_duration` ~lines 2847–2867)
**Severity:** Medium — a cache lifetime of `010m` lasts 8 minutes, and `08m` aborts the caller
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `parse_duration`. No cache file was written.
**What happened:** `parse_duration 8m` prints 480. `parse_duration 010m` also prints 480 and returns 0, so ten minutes is stored as eight. `parse_duration 08m` prints `value too great for base` and returns no number. The same arithmetic is used for hours and days.
**Suggested fix:** Parse the number with base 10 (`10#`). Reject a leading zero, or accept it as decimal.

### Bug #1196: Auto-allocated API address can be the gateway
**File:** `scripts/resolve-vips.sh` (~lines 104–136 and 173–191). `_validate_network_consistency` in `scripts/include_all.sh` (~lines 1208–1239) does not compare a VIP with the gateway.
**Severity:** High — the API address is placed on the gateway and the network check accepts it
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `ip_to_int`, `int_to_ip`, and `_validate_network_consistency`. No `cluster.conf` was written.
**What happened:** For network `10.0.1.0/24`, starting address `10.0.1.3`, and gateway `10.0.1.1`, the script's placement is `api_vip=10.0.1.1` and `ingress_vip=10.0.1.2`. The later collision check only rejects a VIP inside the node range (`10.0.1.3` through `10.0.1.5`). `_validate_network_consistency` returns 0 for this set.
**Suggested fix:** Do not place a VIP on the gateway. Reject a VIP that equals the gateway.

### Bug #1197: A matching bastion DNS answer skips the cluster DNS check
**File:** `scripts/verify-config.sh` (`_vc_check_dns` ~lines 81–94)
**Severity:** High — install continues when the DNS servers the nodes will use return a different address
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `_vc_check_dns` and a stand-in `dig`. No live DNS query was made.
**What happened:** The bastion answer for `api.compact.example.com` was `10.0.1.216`, which is the expected address. The function printed success and returned 0. The cluster DNS server `10.0.0.8` was not queried. That stand-in would have returned `10.9.9.9`.
**Suggested fix:** When `dns_servers` is set, compare that answer with the expected address. Do not return success from the bastion answer alone.

### Bug #1198: A bundle keeps `vmware.conf` and drops `kvm.conf` when both exist
**File:** `scripts/backup.sh` (~lines 112–114 and 193)
**Severity:** Medium — a primed bundle from a host that has both hypervisor files has no root `kvm.conf`
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same selection loop on throwaway files. No bundle was created.
**What happened:** The loop checks `vmware.conf`, then `kvm.conf`, and stops at the first file that exists. With both files present, the selected path is `vmware.conf`. With only `kvm.conf` present, the selected path is `kvm.conf`. The tar file list includes only that one path.
**Suggested fix:** Include each hypervisor file that exists. Do not stop after `vmware.conf`.

### Bug #1199: Replacing a config value leaves the rest of an unquoted line
**File:** `scripts/include_all.sh` (`replace-value-conf` ~lines 4018–4019)
**Severity:** High — the write returns success, and sourcing the file runs the leftover word
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `replace-value-conf` on a throwaway file. No live config was changed.
**What happened:** The file contained `starting_ip=old true`. Replacing `starting_ip` with `new` returned 0 and left `starting_ip=new true`. Sourcing that line set `starting_ip` to `new` and ran the leftover word.
**Suggested fix:** Replace the whole value, including text after the first space. Do not leave the old tail on the line.

### Bug #1200: Reading a config key returns the first copy, and loading the file uses the last
**File:** `scripts/include_all.sh` (`fetch_value` ~lines 517–518). Callers include `scripts/cluster-status.sh` (~lines 42–45) and `scripts/cli-download-all.sh` (~line 111).
**Severity:** High — status and download can use a different value from the one an install loads
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `fetch_value` and `_normalize_export` on a throwaway file. No live config was changed.
**What happened:** The file contained `starting_ip=10.0.1.1` and then `starting_ip=10.0.1.99`. `fetch_value` printed `10.0.1.1`. Loading the normalized file left `starting_ip` set to `10.0.1.99`.
**Suggested fix:** Use the last assignment of the key, which is the value loading the file keeps.

### Bug #1201: A config write updates only the quoting style it sees first
**File:** `scripts/include_all.sh` (`replace-value-conf` ~lines 4014–4019)
**Severity:** High — the write returns success and the value that gets loaded is unchanged
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `replace-value-conf` on throwaway files. No live config was changed.
**What happened:** One file had `starting_ip='10.0.1.1'` and then `starting_ip=10.0.1.2`. Setting `starting_ip` to `10.0.1.50` returned 0. The quoted line became `10.0.1.50` and the plain line stayed `10.0.1.2`. Loading the file left `starting_ip` set to `10.0.1.2`. A second file had `starting_ip=10.0.1.2` and then a commented `# starting_ip='example'`. The same write returned 0, left the plain line unchanged, and turned the comment into `starting_ip=10.0.1.50`. Loading that file used `10.0.1.50`.
**Suggested fix:** Update every assignment of the key, quoted or not. Leave comment lines commented.

### Bug #1202: A new key is not written into an empty config file
**File:** `scripts/include_all.sh` (`replace-value-conf` ~lines 3976–3979 and 4031–4040)
**Severity:** Medium — the call returns failure and the file stays empty
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `replace-value-conf` on a throwaway empty file. No live config was changed.
**What happened:** The file existed and was empty. Setting `starting_ip` to `10.0.1.50` returned 1. The file stayed 0 bytes. An empty file is skipped before it can be the file a missing key is appended to.
**Suggested fix:** Append a missing key to an empty file that was passed in.

### Bug #1203: A config write skips the update when a dot in the new value matches a different line
**File:** `scripts/include_all.sh` (`replace-value-conf` ~lines 3987–3991)
**Severity:** High — the call returns success and the stored value stays wrong
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `replace-value-conf` on a throwaway file. No live config was changed.
**What happened:** The file had a note containing `base_domain=example.com` and a live line `base_domain=exampleXcom`. Setting `base_domain` to `example.com` returned 0 and left both lines unchanged. The fixed-string search hits the note. The second search treats each `.` as any character, so `exampleXcom` matches `example.com`.
**Suggested fix:** Compare the live value as a fixed string. Escape it before using it in a regular expression.

### Bug #1204: A missing config value is taken from the next flag
**File:** `scripts/include_all.sh` (`replace-value-conf` ~lines 3909–3912). The name option rejects a following flag (~lines 3904–3906).
**Severity:** High — the flag is stored as the value
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `replace-value-conf` on a throwaway file. No live config was changed.
**What happened:** `replace-value-conf -n base_domain -v -f <file>` returned 0. The file then contained `base_domain=-f`.
**Suggested fix:** Reject a missing value after `-v`, the same way a missing name is rejected after `-n`.

### Bug #1205: A yes/no prompt reloads aba.conf and replaces the caller's values
**File:** `scripts/include_all.sh` (`ask` ~lines 2475–2483). Callers include `scripts/cluster-unstick.sh` (~line 84) and `vm_start` in `scripts/vm-provider.sh` (~line 110), which `scripts/kvm-start.sh` reaches after loading the cluster.
**Severity:** High — a prompt puts aba.conf values back over values the caller already loaded
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `ask` in a throwaway directory. No live config was changed.
**What happened:** The caller set `machine_network=10.0.0.0`, `domain=local.example.com`, and `ocp_version=4.21.40`. The throwaway `aba.conf` had `ask=false`, `machine_network=192.168.1.0`, `domain=fromfile.example.com`, and `ocp_version=9.9.9`. `ask` returned success and left those three variables set to the file values.
**Suggested fix:** Read only the `ask` flag. Do not source the rest of aba.conf inside `ask`.

### Bug #1206: The config table splits a value on spaces and shifts the later keys
**File:** `scripts/include_all.sh` (`output_table` ~lines 4064–4072). Callers: `scripts/aba.sh` (~line 1925) and `scripts/create-install-config.sh` (~line 82).
**Severity:** Medium — the review of aba.conf or cluster.conf shows values in the wrong columns
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `output_table`. No config file was written.
**What happened:** Three lines, `disk_hint=/dev/sda`, `cluster_name=hello world`, and `port=ens160`, plus `starting_ip=10.0.1.71`, were printed as `disk_hint=/dev/sda | world | starting_ip=10.0.1.71` and `cluster_name=hello | port=ens160`.
**Suggested fix:** Keep each input line as one cell. Do not split a value on spaces.

### Bug #1207: A default of no is ignored when it comes after `--always`
**File:** `scripts/include_all.sh` (`ask` ~lines 2462–2472)
**Severity:** High — Enter accepts a prompt that was supposed to default to no
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `ask`. No cluster was changed.
**What happened:** `ask --always -n "Delete these pods"` with Enter printed `-n Delete these pods? (y/n) [y]` and returned 0. `ask -n --always "Delete these pods"` printed `(y/n) [n]` and returned 1. The default-no flag is only recognized when it is the first argument.
**Suggested fix:** Accept `-n` and `-y` in either order with `--always`. Do not put an unrecognized flag into the question.

### Bug #1208: Zero retry attempts reports that the command succeeded
**File:** `scripts/include_all.sh` (`try_cmd` ~lines 2594–2621)
**Severity:** Medium — a caller that asks for no attempts gets success without the command running
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `try_cmd`. The failing command was `false`.
**What happened:** `try_cmd -n 0 -d 0 false` returned 0. `try_cmd -n 1 -d 0 false` returned 1. The attempt counter starts at 1, so a limit of 0 never enters the loop, and the saved status stays 0.
**Suggested fix:** Treat zero attempts as failure. Do not return success when the command was not run.

### Bug #1209: A failed one-time task is treated as finished
**File:** `scripts/include_all.sh` (`run_once` start ~lines 4735–4738, peek ~lines 4619–4622). `scripts/cli-download-all.sh` (~lines 148–150) treats a successful peek as a completed download.
**Severity:** High — a failed task is not run again, and the caller is told it succeeded
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `run_once` in a throwaway runner directory. The live runner was not used.
**What happened:** A task exited 1 after writing one line to a counter. The exit file contained `1`. Starting that task again returned 0 and the counter stayed at one line. Peeking the same task returned 0.
**Suggested fix:** On start, run the task again when the saved exit code is not 0. Peek should return failure when the saved exit code is not 0.

### Bug #1210: A `#` inside a config value is treated as a comment
**File:** `scripts/include_all.sh` (`_normalize_export` ~lines 500–502). `fetch_value` reads that output (~lines 517–526).
**Severity:** High — the stored value is cut off, and a double-quoted value becomes invalid shell
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `_normalize_export` and `fetch_value` on throwaway files. No live config was changed.
**What happened:** `reg_pw="p#assword"` was normalized to `export reg_pw="p`. `fetch_value` printed `"p`. `disk_hint=/dev/sda#1` was normalized to `export disk_hint=/dev/sda`, and loading it left `disk_hint` set to `/dev/sda`. A single-quoted value is the only form the comment strip keeps intact.
**Suggested fix:** Strip a `#` only when it starts a comment. Keep a `#` inside a quoted value and inside an unquoted word.

### Bug #1211: A task id can write outside the runner directory
**File:** `scripts/include_all.sh` (`run_once` ~lines 4428 and 4540)
**Severity:** High — the task directory, command, and logs are created outside `~/.aba/runner`
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `run_once` in a throwaway runner directory. The live runner was not used.
**What happened:** The runner directory was `<tmp>/runner`. The work id was `../escaped` and the command was `true`. The task directory and `cmd` file were created at `<tmp>/escaped`, which is the parent of the runner directory. The call returned 0.
**Suggested fix:** Reject a work id that contains `/` or `..`. Keep every task directory inside the runner directory.

### Bug #1212: A config line that already says `export` is invisible to readers
**File:** `scripts/include_all.sh` (`_normalize_export` ~line 503, `fetch_value` ~lines 517–518). `scripts/cluster-status.sh` (~lines 42–45) reads counts with `fetch_value`.
**Severity:** High — status treats a present master count as missing
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `_normalize_export` and `fetch_value` on a throwaway file. No live config was changed.
**What happened:** The file contained `export num_masters=1`. Normalization turned that into `export export num_masters=1`. Loading it set `num_masters` to 1. `fetch_value num_masters` printed nothing and returned 1.
**Suggested fix:** Accept a line that already starts with `export`. Do not add a second `export`.

### Bug #1213: A catalog name is used as a filesystem path
**File:** `scripts/download-catalog-index.sh` (~lines 71–74). `scripts/list-operators.sh` (~line 46) passes the name through with the same path shape (~line 58).
**Severity:** High — the index file can be written outside the repository
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by resolving the path the script assigns. The catalog download was not run.
**What happened:** The catalog name `../../tmp/aba-cat` and version `4.21` produce the index path `.index/../../tmp/aba-cat-index-v4.21`. That resolves to `/home/steve/tmp/aba-cat-index-v4.21`, which is outside `/home/steve/aba`. The helper YAML resolves under `mirror/tmp/`. The script does not check that the name is one of the three catalog names.
**Suggested fix:** Accept only `redhat-operator`, `certified-operator`, and `community-operator`. Reject a name that contains `/` or `..`.

### Bug #1214: The first minor of a major has no previous version
**File:** `scripts/aba-get-version.sh` (~lines 42–45)
**Severity:** Medium — the previous-version lookup asks for minor `-1`
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's minor arithmetic. No config was written.
**What happened:** For `5.0.1` the previous minor is `5.-1`. The following search looks for `5.-1.<number>` and finds nothing. For `4.21.40` the same arithmetic correctly produces `4.20`.
**Suggested fix:** When the minor is 0, look up the previous major instead of subtracting 1.

### Bug #1215: A YAML catalog index uses the last display name in the file
**File:** `scripts/catalog-extract-functions.sh` `_yaml_display_name` (~lines 97–101), used by `_extract_from_yaml` (~lines 154–180). `scripts/download-catalog-index.sh` (~line 361) sources these functions.
**Severity:** Medium — the operator list shows the wrong name
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by sourcing the functions and extracting a throwaway catalog. No catalog was downloaded.
**What happened:** The catalog file has `spec.displayName: Demo Operator` and a later custom-resource field `displayName: Demo CR`. `_extract_from_yaml` printed `demo-operator Demo CR stable`. The syntax check accepts that line. The package name and channel stay correct.
**Suggested fix:** Use the `displayName` under the ClusterServiceVersion `spec`. Ignore later `displayName` fields.

### Bug #1216: A JSON catalog index uses the last bundle display name
**File:** `scripts/catalog-extract-functions.sh` `_display_name_from_json_file` (~lines 86–88), used by `_extract_from_json` (~lines 126–151)
**Severity:** Medium — the operator list shows a name from a different bundle
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by sourcing the functions. No catalog was downloaded.
**What happened:** The package default channel is `stable`. The first bundle display name is `Demo Operator` and a later bundle display name is `Old Demo Name`. `_extract_from_json` printed `demo-operator Old Demo Name stable`. The default channel is not used to choose the name.
**Suggested fix:** Use the display name from the bundle that belongs to the default channel.

### Bug #1217: A catalog file with Windows line endings is rejected
**File:** `scripts/catalog-extract-functions.sh` `_extract_from_yaml` (~lines 158–168)
**Severity:** Medium — the catalog download cannot index that file
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by sourcing the functions. No catalog was downloaded.
**What happened:** A catalog whose package is `demo-operator`, channel `stable`, and display name `Demo Operator` printed `demo-operator Demo Operator stable` with Unix line endings. The same file with a carriage return at the end of each line made `_extract_from_yaml` return 1 and print nothing. The schema field still has the carriage return, so it does not match `olm.package`.
**Suggested fix:** Strip a trailing carriage return before comparing `schema`, `name`, and `defaultChannel`.

### Bug #1218: A registry port with a leading zero skips the range check
**File:** `tui/v2/tui-lib.sh` `_valid_port` (~lines 178–181). `tui/v2/tui-mirror.sh` (~lines 236–240) accepts the port when this function returns success.
**Severity:** Medium — an out-of-range port is treated as valid
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling the same function. No mirror config was written.
**What happened:** Port `0177777` returned success. That number is 177777 in decimal, which is above 65535. The comparison reads the leading zero as octal, and octal `0177777` is 65535, so the range check passes. Port `08` is rejected with `value too great for base` even though 8 is inside the range. Port `80` and port `65535` are accepted. Port `177777` is rejected.
**Suggested fix:** Compare the port in base 10.

### Bug #1219: The cluster wizard ignores a line that already says export
**File:** `tui/v2/tui-cluster.sh` `_cluster_load_conf` (~lines 73–121). `_persist_cluster_draft` (~lines 178–186) writes `num_masters` and `num_workers` from the type this function sets.
**Severity:** High — a standard cluster is loaded as SNO
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same parser. No cluster file was written.
**What happened:** A file containing `export num_masters=3` and `export num_workers=2` loaded as SNO (`num_masters` 1, `num_workers` 0). The key compared by the parser is `export num_masters`, which matches none of the settings. The same two lines without `export` loaded as standard with 2 workers. Saving the wizard writes the master and worker counts from that type.
**Suggested fix:** Accept a line that starts with `export`. Use the name after `export` as the key.

### Bug #1220: The cluster wizard cuts a quoted value at a hash
**File:** `tui/v2/tui-cluster.sh` `_cluster_load_conf` (~line 80)
**Severity:** Medium — a value that contains `#` is stored without the rest of the text
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same parser. No cluster file was written.
**What happened:** The line `data_disk='/dev/sda#1'` loaded as `'/dev/sda`. The opening quote is kept and the hash and the characters after it are removed. A single-quoted hash is the form the config normalizer leaves intact.
**Suggested fix:** Strip `#` only when it starts a comment. Keep the text inside quotes.

### Bug #1221: Quoted master and worker counts do not set the cluster type
**File:** `tui/v2/tui-cluster.sh` `_cluster_load_conf` (~lines 79–121). The Type row (~line 941) prints `cl_type`. The type toggle (~lines 1076–1080) only matches `sno`, `compact`, and `standard`.
**Severity:** Medium — the wizard shows a blank type
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same parser. No cluster file was written.
**What happened:** `num_masters='3'` and `num_workers='2'` leave the type unset. The values kept the quotes, and the numeric comparison printed `operand expected`. The same lines without quotes load as standard with 2 workers. Double quotes do the same. An unset type does not match the type toggle, so the Type row does not change.
**Suggested fix:** Remove matching quotes before the numeric comparison.

### Bug #1222: A prefix that appears before the network is dropped
**File:** `tui/v2/tui-cluster.sh` `_cluster_load_conf` (~lines 89–90). `_persist_cluster_draft` (~line 154) writes `machine_network` from the loaded value.
**Severity:** High — the subnet prefix is lost
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same parser. No cluster file was written.
**What happened:** `prefix_length=20` followed by `machine_network=10.0.0.0` loaded as `10.0.0.0`. The prefix is applied to the empty network first, and the later network line replaces it. The same two lines with the network first loaded as `10.0.0.0/20`.
**Suggested fix:** Apply `prefix_length` after both lines have been read.

### Bug #1223: A MAC with extra digits is stored as a shorter address
**File:** `scripts/include_all.sh` `macs_list_from_text` (~lines 1439–1442) and `macs_canonicalize_text` (~lines 1457–1459). `macs_report` (~line 1597) uses the shortened text. The bare-metal MAC editor in `tui/v2/tui-cluster.sh` (~lines 1493–1503) saves that text. `_valid_mac` (~lines 1401–1402) is a full-string check.
**Severity:** High — the saved address is not the address that was typed
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling these functions. No MAC file was written.
**What happened:** `00:11:22:33:44:5566` was listed and canonicalized as `00:11:22:33:44:55`. `macs_report` for an SNO cluster said READY and printed that shorter address. `_valid_mac` on the original text returned failure. Seven octets, `00:11:22:33:44:55:66`, were also reduced to the first six. A correct `00:11:22:33:44:55` is unchanged.
**Suggested fix:** Accept a token only when the whole token is a MAC. Do not take a match from the middle of a longer token.

### Bug #1224: The VM help example is rejected as a MAC prefix
**File:** `tui/v2/tui-cluster.sh` (~line 1572). `tui/v2/tui-lib.sh` `_valid_mac_prefix` (~lines 184–186) is the check used at ~lines 1686–1689.
**Severity:** Medium — the documented example cannot be saved
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling the prefix check. No cluster file was written.
**What happened:** The VM help says `00:50:56:xx`. That value fails `_valid_mac_prefix`. `00:50:56:1a:2b:` passes. The error dialog already asks for five octets and a trailing colon.
**Suggested fix:** Show a five-octet example with a trailing colon in the help text.

### Bug #1225: The install MAC check treats uppercase and lowercase as different addresses
**File:** `scripts/create-agent-config.sh` (~lines 163–168). `macs_list_from_text` in `scripts/include_all.sh` (~lines 1439–1442) keeps the original case. `macs_report` (~lines 1610–1632) compares addresses in lowercase.
**Severity:** High — the same address can be used twice
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the list function and the install check's `sort -u` count. No agent config was written.
**What happened:** `AA:BB:CC:DD:EE:FF` and `aa:bb:cc:dd:ee:ff` were listed as two addresses. The install check's unique count was 2, so it would not abort. `macs_report` for an SNO cluster printed `ERROR: duplicate MAC(s): aa:bb:cc:dd:ee:ff`.
**Suggested fix:** Compare MAC addresses in one case before the unique count.

### Bug #1226: A disk hint with a minimum above the maximum is accepted
**File:** `scripts/include_all.sh` `_parse_disk_hint` (~lines 1046–1082). `scripts/create-agent-config.sh` (~lines 245–250) uses this function.
**Severity:** Medium — the disk criteria cannot match a disk
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling the function. No agent config was written.
**What happened:** `minSizeGigabytes=100,maxSizeGigabytes=10` returned success and printed `{"minSizeGigabytes": 100, "maxSizeGigabytes": 10}`.
**Suggested fix:** Reject a hint whose minimum size is greater than its maximum size.

### Bug #1227: A disk hint string is copied into JSON without escaping
**File:** `scripts/include_all.sh` `_parse_disk_hint` (~lines 980–982 and 1074–1075). `scripts/create-agent-config.sh` (~line 285) exports the result as `json_disk_hints`.
**Severity:** High — one quote makes the disk-hint map invalid
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling the function. No agent config was written.
**What happened:** `deviceName=/dev/disk"1` returned success and printed `{"deviceName": "/dev/disk"1"}`. `jq` rejected that text. The path shorthand `/dev/disk"1` did the same. `model=abc\ndef` was stored with a backslash and an `n`, and `jq` read the model as `abc`, a newline, and `def`. `path=/dev/sda,minSizeGigabytes=200` still parses.
**Suggested fix:** Escape quotes, backslashes, and control characters in string values.

### Bug #1228: A space after a comma makes the next disk-hint key unknown
**File:** `scripts/include_all.sh` `_parse_disk_hint` (~lines 1002–1036)
**Severity:** Medium — a valid size hint is rejected
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling the function. No agent config was written.
**What happened:** `path=/dev/sda, minSizeGigabytes=200` returned failure. The error named the key ` minSizeGigabytes`, including the leading space. `path=/dev/sda,minSizeGigabytes=200` returned success and printed the device name and the size.
**Suggested fix:** Trim space around each key and value.

### Bug #1229: A disk hint value is written into YAML without quotes
**File:** `templates/agent-config.yaml.j2` (~lines 42–43). The vlan and bond templates print the same `{{ _hkey }}: {{ _hval }}` line.
**Severity:** High — the agent config is not valid YAML, or a value loses its tail
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by rendering those lines with `scripts/j2`. No cluster file was written.
**What happened:** A model `Site: Lab` rendered as `model: Site: Lab`. `scripts/j2` exited 0. PyYAML rejected the file because a mapping value is not allowed there. A model `foo # bar` rendered as `model: foo # bar`, and PyYAML read the model as `foo`. A numeric hint `minSizeGigabytes: 100` still renders.
**Suggested fix:** Quote string hint values as YAML. Leave numbers and booleans unquoted.

### Bug #1230: A failed agent-config render is reported as success
**File:** `scripts/create-agent-config.sh` (~lines 326–329)
**Severity:** High — `agent-config.yaml` is emptied and the command says it was generated
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's redirect and the following success line. The script was not run, so no cluster file was written.
**What happened:** The script copies an existing file to `agent-config.yaml.backup`, then runs `scripts/j2 templates/$template_file > agent-config.yaml`. The shell truncates the destination when the redirect opens. The script has no `set -e` and does not check the render status. A failing render leaves a 0-byte file, the backup still has the previous text, and the next line prints that the file was generated successfully.
**Suggested fix:** Abort when the render exits non-zero. Do not print the success line, and do not replace an existing file until the render succeeds.

### Bug #1231: NTP servers separated by spaces become one name
**File:** `scripts/day2-config-ntp.sh` (~line 38). The same value is written as `server <name> iburst` (~lines 64 and 108).
**Severity:** Medium — chrony is given a server name that does not exist
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's `tr` pipeline. The NTP script was not run, so no cluster file was written.
**What happened:** `10.0.0.8 10.0.0.9` becomes `10.0.0.810.0.0.9`. `time.example.com pool.ntp.org` becomes `time.example.compool.ntp.org`. A newline between the names is removed the same way. `10.0.0.8, 10.0.0.9` and `time.example.com,pool.ntp.org` stay two servers. Spaces are deleted before commas are turned into spaces.
**Suggested fix:** Split on commas and whitespace. Do not delete spaces before the split.

### Bug #1232: The worker NTP config serves time to any client
**File:** `scripts/day2-config-ntp.sh` (~lines 90–131)
**Severity:** Medium — every worker is an open NTP server
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 from the worker file this script writes. The NTP script was not run.
**What happened:** The worker MachineConfig is labeled `machineconfiguration.openshift.io/role: worker`. Its chrony text includes `allow all` and `local stratum 3 orphan`. The comment above those lines says the control plane nodes serve time to workers. The master file has the same two directives. A worker given this file answers NTP queries from any address and advertises itself as a local time source.
**Suggested fix:** Keep `allow all` and `local stratum` on masters. Omit them from the worker chrony file.

### Bug #1233: Stopping an NTP wait is reported as success
**File:** `scripts/day2-config-ntp.sh` (~lines 231–234, 269–272, 309–312, and 352–355). `aba_wait_show` (~line 2725) leaves the subshell with status 130 on Ctrl-C.
**Severity:** High — the NTP step exits 0 when the user stops it
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's status test. `aba_wait_show` was not called, and the NTP script was not run.
**What happened:** The wait text says Ctrl-C skips that wait. On status 130 or 143 the script prints `Aborted by user.` and exits 0. A copy of that test with status 130 printed the abort line and returned 0. The phases after that wait do not run. Make treats exit 0 as a finished NTP configuration.
**Suggested fix:** Return 130 when the user stops a wait. Do not exit 0.

### Bug #1234: A failed NTP file render does not stop the script
**File:** `scripts/day2-config-ntp.sh` (~lines 152–184)
**Severity:** Medium — the script keeps going after `butane` fails
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `butane` on a throwaway file. The NTP script was not run.
**What happened:** `butane` on a file that is not a Butane config exits 1 and does not create the output file. The script does not check that status. The next command runs. `oc diff` on a missing file fails, and a diff status above 1 is the branch that warns and applies anyway. The script has no `set -e`.
**Suggested fix:** Abort when `butane` exits non-zero. Do not apply a file that was not created.

### Bug #1235: A virtualization image is deleted before its import can finish
**File:** `scripts/day2-config-virt.sh` (~lines 180–194)
**Severity:** High — a boot source that is still importing is removed
**Mode:** CONNO, DISCO
**Status:** OPEN — verified 2026-11-09 from the script's one check. The virt script was not run, and no ImageStream was deleted.
**What happened:** The script creates the ImageStream, waits 5 seconds, and reads `status.tags[0].items[0].image`. An empty digest prints a skip warning and deletes that ImageStream. There is no later check. An import that has not finished in 5 seconds is removed, and that boot source is left out of the HyperConverged patch.
**Suggested fix:** Poll the ImageStream until the digest appears or a real timeout is reached. Do not delete it on the first empty read.

### Bug #1236: A failed virtualization check still reports success
**File:** `scripts/day2-config-virt.sh` (~lines 297–319)
**Severity:** Medium — the command exits 0 when no DataImportCron appeared
**Mode:** CONNO, DISCO
**Status:** OPEN — verified 2026-11-09 with the script's `||` status pattern. The virt script was not run.
**What happened:** `aba_wait_show` for DataImportCron is followed by `|| aba_warn`. The script has `set -e`, and that `||` keeps going after the wait fails. The last line then prints that boot source configuration completed successfully. A failing command followed by `|| echo warned` and a success line exits 0.
**Suggested fix:** Abort when the DataImportCron wait fails. Do not print the success line.

### Bug #1237: Waved day-2 mode skips manifests in other directories
**File:** `scripts/day2.sh` `apply_custom_manifests` (~lines 321–362)
**Severity:** Medium — manifests that flat mode would apply are left out
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's `find` commands in a throwaway directory. `day2` was not run.
**What happened:** The directory had `top.yaml`, `10-ns/bar.yaml`, and `extra/foo.yaml`. A numbered directory selects waved mode. The files selected were `top.yaml` and `10-ns/bar.yaml`. `extra/foo.yaml` was not selected, and the script does not warn about it. With no numbered directory, flat mode's recursive find would include `extra/foo.yaml`.
**Suggested fix:** In waved mode, warn about YAML files that are not at the top level and not inside a numbered wave. Apply them, or stop before the waves run.

### Bug #1238: A signature file with no binary data patches the cluster with null
**File:** `scripts/day2.sh` (~lines 619–624)
**Severity:** High — the patch sets `binaryData` to null
**Mode:** CONNO, DISCO
**Status:** OPEN — verified 2026-11-09 with the script's `jq` expression. `oc patch` was not run.
**What happened:** A signature file `{"kind":"ConfigMap"}` makes `jq '{binaryData: .binaryData}'` print `{"binaryData": null}`. That is the document the script passes to `oc patch --type=merge` when the signatures ConfigMap already exists. A file that has `binaryData` still produces a patch containing those keys.
**Suggested fix:** Skip the patch when `binaryData` is missing or null. Do not send null.

### Bug #1239: Ten operators updated still counts as zero
**File:** `scripts/cluster-upgrade.sh` `_upgrade_status_ready` (~line 628)
**Severity:** Medium — the progress wait stays open after operators have updated
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's `grep -q "0 operators updated"` test. `oc adm upgrade` was not run.
**What happened:** The wait ends when the status text does not contain `0 operators updated`. The phrase is not anchored. `10 operators updated` and `20 operators updated` both contain it, so the check keeps waiting. `3 operators updated` does not contain it, so that check returns ready. The oc 4.21.40 status template prints `N operators updated`. Bug #1079 is the other result of this grep: `The cluster is not updating.` ends the wait.
**Suggested fix:** Read the operator count and compare it as a number. A count of 10 must end the wait. A count of 0 must keep waiting.

### Bug #1240: A prerelease version is filed under the wrong upgrade group
**File:** `tui/v2/tui-cluster.sh` `_day2_upgrade` (~lines 2654, 2684, 2700)
**Severity:** Medium — the menu header and the z-stream group are wrong for a prerelease
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same `${ver%.*}` test the menu uses. The upgrade menu was not opened.
**What happened:** From current version `4.21.40`, the minor is `4.21`. `4.22.0-rc.1` does not match that minor, so it is listed as a minor upgrade, and the section title uses `${ver%.*}`, which is `4.22.0-rc`. The title becomes `4.21 → 4.22.0-rc`. `4.21.41-rc.1` becomes `4.21.41-rc`, which is not `4.21`, so that z-stream prerelease is listed as a minor upgrade too. `4.21.41` stays in the z-stream group.
**Suggested fix:** Take the minor from the first two numeric fields. Group `4.21.41-rc.1` with `4.21`, and title the next minor `4.22`.

### Bug #1241: A version flag is resolved before a later channel flag
**File:** `scripts/aba.sh` (`--version` ~lines 674–717, `--upgrade-to` ~line 762, `--channel` ~lines 656–658)
**Severity:** High — the saved version was looked up on the previous channel
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `fetch_latest_z_version` and the same variable order the flags use. `aba` was not run. `aba.conf` was not changed.
**What happened:** `--version` resolves a minor with `fetch_latest_z_version` and writes `ocp_version` before the next flag is read. `--channel` only changes `ocp_channel`. With the stored channel still `fast`, `--version 4.21` resolves to `4.21.42`. A following `--channel eus` leaves `4.21.42`. The other order, `--channel eus` first, resolves `4.21` to `4.20.46`. The eus graph for `4.21` is empty, so `4.21.42` is not an eus release. `--upgrade-to` uses the same lookup.
**Suggested fix:** Apply every channel flag before resolving a version. Resolve `--version` and `--upgrade-to` on the channel the command will save.

### Bug #1242: The version box trims only one space
**File:** `tui/v2/tui-direct.sh` (~lines 484–485 and 585–586)
**Severity:** Medium — a version with two spaces is rejected
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same trim the version box uses. The dialog was not opened.
**What happened:** The trim is `${ver##[[:space:]]}` and `${ver%%[[:space:]]}`. Each removes one whitespace character. `4.22.1` and ` 4.22.1` become `4.22.1`. `  4.22.1` becomes ` 4.22.1`, and the version check rejects it. `4.22.1  ` becomes `4.22.1 `. A leading space and a tab become a tab.
**Suggested fix:** Remove every leading and trailing whitespace character before the version check.

### Bug #1243: An image set is found by prefix, then remove says it worked
**File:** `scripts/image-sets.sh` (`_image_set_marker_exists` ~line 74, `image_set_remove` ~lines 347–366)
**Severity:** Medium — remove reports success and the other set stays
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's functions on a throwaway `images.conf`. The repo file was not used.
**What happened:** The file had blocks `ai-extra` and `virt`. `_image_set_marker_exists ai` exited 0 because the pattern is `^# image-set: ai` with no end. `image_set_remove ai` also exited 0. The awk compares the third field exactly, so it did not delete `ai-extra`. Both blocks were still in the file.
**Suggested fix:** Match the set name as a whole field. Return failure from remove when no block was deleted.

### Bug #1244: A missing end marker deletes the rest of images.conf
**File:** `scripts/image-sets.sh` (`image_set_remove` ~lines 357–366)
**Severity:** High — every later image is removed
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's function on a throwaway file. The repo `images.conf` was not used.
**What happened:** The file started with a `virt` block that had no `# end-image-set: virt` line, then an `ocp` block that did. `image_set_remove virt` exited 0. The skip flag stays on until an end line with that name, so the `ocp` block was deleted too. The file was empty afterward.
**Suggested fix:** Stop at the next image-set marker. If the end marker is missing, leave the rest of the file and return failure.

### Bug #1245: A RHOAI release candidate is chosen as the latest GA
**File:** `scripts/image-sets.sh` (`detect_rhoai_version` ~lines 151–159)
**Severity:** High — the image list is fetched for a pre-release
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the script's grep and sort. GitHub was not asked to pick a version.
**What happened:** The filter drops names containing `-ea` and then sorts the rest. From `3.4.9`, `3.5.0-ea.1`, `3.5.1`, and `3.5.2-rc.1`, the result is `3.5.2-rc.1`. The comment says the result is the latest GA. `3.5.1` is the GA build in that list.
**Suggested fix:** Drop every pre-release suffix, not only `-ea`. Choose the highest remaining GA version.

### Bug #1246: A cached RHOAI version is kept forever
**File:** `scripts/image-sets.sh` (`detect_rhoai_version` ~lines 124–129)
**Severity:** Medium — a newer GA release is never selected
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling `detect_rhoai_version 4.21` with the cache directory pointed at a throwaway file. The real cache under `~/.aba` was not used.
**What happened:** The cache file contained `1.0.0`. The function printed `1.0.0` and exited 0. It does not check the file's age, and it does not read the catalog or GitHub when the file exists.
**Suggested fix:** Honor the usual cache lifetime. When the file is older than that, detect the version again.

### Bug #1247: A RHOAI channel named stable is rejected
**File:** `scripts/image-sets.sh` (`detect_rhoai_version` ~lines 137–144)
**Severity:** Medium — automatic image selection fails for that OpenShift release
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the catalog index and `detect_rhoai_version`. The cache directory was a throwaway. GitHub was not queried.
**What happened:** `.index/redhat-operator-index-v4.16` has `rhods-operator` on channel `stable`. The same channel is in the 4.17 and 4.18 indexes. The parser only accepts a channel shaped like `stable-3.x`. `detect_rhoai_version 4.16` printed nothing and exited 1. For 4.21 the channel is `stable-3.x` and the series is `3`.
**Suggested fix:** Accept a channel with no version number. Use the OpenShift release to choose the matching OpenShift AI series.

### Bug #1248: Operator search shows only the first 100 matching lines
**File:** `tui/v2/tui-mirror.sh` (`_operator_search` ~lines 2035–2039)
**Severity:** Medium — a matching operator is left out of the results
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same `grep | head -100` the search uses. The search dialog was not opened.
**What happened:** The 4.21 Red Hat index has 135 lines containing `er`. The pipeline keeps 100. `rhacs-operator` contains `er` and is not one of those 100 lines. The dialog is given only the lines that remain.
**Suggested fix:** Keep every matching operator, or say that the list is truncated and offer a narrower search.

### Bug #1249: Unchecking an operator set removes an operator added by search
**File:** `tui/v2/tui-mirror.sh` (`_operator_sets` ~lines 1946–1964)
**Severity:** Medium — a selected operator disappears
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same remove loop. The checklist was not opened. The live basket was not changed.
**What happened:** `rhods-operator` was in the basket and is also a line in `templates/operator-set-ai`. With the AI set previously added and then left unchecked, the loop deletes every name in that file. `rhods-operator` was no longer in the basket.
**Suggested fix:** Remove a name only when no still-selected set and no individual selection still want it. Remember which names were added by search.

### Bug #1250: An operator set is marked on after it skips a name the index does not have
**File:** `tui/v2/tui-mirror.sh` (`_operator_sets` ~lines 1973–1986)
**Severity:** Medium — the set looks complete and one operator is missing
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same add loop against the 4.21 indexes. The checklist was not opened.
**What happened:** `templates/operator-set-odf` lists `ocs-tls-profiles`. That name is not in the 4.21 Red Hat, certified, or community indexes. The 4.22 index has it. The loop skipped it, added the other 16 names, and still set the ODF set to on.
**Suggested fix:** When a listed name is missing from this version's indexes, say so. Do not mark the set fully added.

### Bug #1251: op_sets all returns before other operators are added
**File:** `scripts/reg-create-imageset-config.sh` (`_resolve_operators_json` ~lines 103–107)
**Severity:** High — an operator named in ops is left out of the image set
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same early return. The image-set file was not generated.
**What happened:** `op_sets=all,virt` matches the `all` check. The function prints a redhat catalog with `all: true` and returns. `ops=3scale-community-operator` is never read. That package is in the 4.21 community index and not in the redhat index, so the redhat `all` catalog does not include it. The JSON has no package list.
**Suggested fix:** After the redhat `all` catalog, still resolve `ops` and any other set. Add certified and community packages that `all` does not cover.

### Bug #1252: A longer operator display name is treated as the same name
**File:** `scripts/reg-create-imageset-config.sh` (`_display_name_adds_info` ~lines 72–76)
**Severity:** Medium — the image-set comment drops the product name
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same function against the 4.21 Red Hat index. The image-set file was not generated.
**What happened:** The function returns "no extra info" as soon as every word of the package name appears in the display name. `3scale-operator` and `Red Hat Integration - 3scale` return 1. `eap` and `JBoss EAP` return 1. `web-terminal` and `Web Terminal` also return 1, which is the reformat case. `cincinnati-operator` and `OpenShift Update Service` return 0, so that comment is kept.
**Suggested fix:** Return "no extra info" only when the two names have the same words. Keep the comment when the display name has words the package name does not.

### Bug #1253: An exported verify_conf=off is replaced with all
**File:** `scripts/include_all.sh` (`normalize-aba-conf` ~line 596)
**Severity:** High — config checks run after the user turned them off
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by sourcing `normalize-aba-conf` on a throwaway file. No live config was changed.
**What happened:** The file was `export verify_conf=off`. Normalization printed `export export verify_conf=off` and then `export verify_conf=all`, because the default check looks for `^verify_conf=` in the raw file. Sourcing that output left `verify_conf=all`. The same file with `verify_conf=off` and no `export` stays `off`.
**Suggested fix:** Decide the default from the normalized key. Do not append `all` when the key is already set.

### Bug #1254: A capitalized False does not turn a boolean flag off
**File:** `scripts/include_all.sh` (`normalize-aba-conf` ~lines 583–592)
**Severity:** Medium — platform images are excluded and prompts stay on
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by sourcing `normalize-aba-conf` on a throwaway file. No live config was changed.
**What happened:** `excl_platform=False`, `ask=False`, `verify_conf=False`, and `excl_operators=FALSE` were unchanged. A set `excl_platform` excludes platform images, so `False` excludes them. A set `ask` leaves prompts on. The lowercase values `excl_platform=false` and `ask=false` become empty, which is off, and `verify_conf=off` stays `off`.
**Suggested fix:** Treat `true` and `false` without regard to case before the other flag rules run.

### Bug #1255: An exported image source and host prefix are replaced by the defaults
**File:** `scripts/include_all.sh` (`normalize-cluster-conf` ~lines 906–909)
**Severity:** High — a direct install is turned into a mirror install, and the node prefix changes
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by sourcing `normalize-cluster-conf` on a throwaway file. No live config was changed.
**What happened:** The file was `export image_source=direct` and `export hostPrefix=26`. Normalization printed those values and then `export image_source=mirror` and `export hostPrefix=23`, because the default checks look for `^image_source=` and `^hostPrefix=` in the raw file. Sourcing that output left `image_source=mirror` and `hostPrefix=23`. `base_domain` was lowercased to `example.com`.
**Suggested fix:** Decide both defaults from the normalized keys. Do not append a default when the key is already set.

### Bug #1256: A registry path that starts with a tilde gets a slash in front
**File:** `scripts/include_all.sh` (`normalize-mirror-conf` ~line 795, `_valid_abs_path` ~line 1295)
**Severity:** Medium — the registry path is rejected
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by sourcing `normalize-mirror-conf` on a throwaway file. No live config was changed.
**What happened:** `reg_path=~/registry` became `/~/registry`. `_valid_abs_path` accepts `~/registry` and rejects `/~/registry`. `reg_path=/registry` stays `/registry`. `data_dir=~/mirror` stays `~/mirror`.
**Suggested fix:** Add a leading slash only when the value is a relative name. Leave a value that starts with `~` unchanged.

### Bug #1257: The KVM host extracted from a URI keeps the port
**File:** `scripts/include_all.sh` (`normalize-kvm-conf` ~lines 2418–2421). `scripts/kvm-upload.sh` (~lines 31–33) uses that host for `ssh` and `scp`.
**Severity:** High — the upload goes to the wrong destination
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by sourcing `normalize-kvm-conf` on throwaway files. No SSH connection was made.
**What happened:** `LIBVIRT_URI=qemu+ssh://steve@kvm1.example.com:2222/system` set `KVM_HOST` to `steve@kvm1.example.com:2222`. The upload target is then `steve@kvm1.example.com:2222:/var/lib/libvirt/images/...`. A file with `LIBVIRT_URI=qemu:///system` and `KVM_HOST=root@kvm1.example.com` loads `KVM_HOST` as `qemu:///system`.
**Suggested fix:** Take the user and host only. Drop a `:port`. When the URI has no host, leave an existing `KVM_HOST` unchanged.

### Bug #1258: A discovery variable from the environment aborts bmc.conf
**File:** `scripts/include_all.sh` (`normalize-bmc-conf` ~lines 2332–2339)
**Severity:** Medium — BMC config will not load
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `normalize-bmc-conf` on a throwaway file. No BMC was contacted.
**What happened:** The file set `bmc_host_n0` and `bmc_user_n0` and did not set a discovery key. With `mac_discovery_stray=yes` in the environment, the function aborted: that value must be `disabled` or unset. The same file loaded when the variable was absent.
**Suggested fix:** Check only the discovery keys that came from `bmc.conf`.

### Bug #1259: An exported BMC host is missing from the host inventory
**File:** `scripts/include_all.sh` (`bmc_host_list` ~lines 2368–2371, `bmc_has_hosts` ~lines 2382–2384). `normalize-bmc-conf` (~lines 2316–2326) still loads the line.
**Severity:** High — BMC boot and unmount skip the node
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `normalize-bmc-conf` and `bmc_host_list` on a throwaway file. No BMC was contacted.
**What happened:** The file was `export bmc_host_n0=10.1.1.1`. Normalization exited 0 and left `bmc_host_n0` set to `10.1.1.1`. `bmc_host_list` printed nothing, the count was 0, and `bmc_has_hosts` was false. The same host without `export` was listed as `n0`.
**Suggested fix:** Accept an optional `export` before `bmc_host_`.

### Bug #1260: A single quote in a BMC value breaks the redacted snapshot
**File:** `scripts/include_all.sh` (`bmc_redact_env` ~line 2405)
**Severity:** Medium — the snapshot is not valid shell
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by sourcing `bmc_redact_env` output. No BMC was contacted.
**What happened:** `bmc_user_n0` was `o'reilly`. The snapshot line was `export bmc_user_n0='o'reilly'`. Sourcing it exited 2 with an unmatched quote. `iso_url` without a quote was written intact.
**Suggested fix:** Escape single quotes inside the value before wrapping it.

### Bug #1261: An exported BMC password is printed
**File:** `scripts/include_all.sh` (`normalize-bmc-conf` ~line 2360)
**Severity:** High — the password is included in the normalized output
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `normalize-bmc-conf` on a throwaway file. No BMC was contacted.
**What happened:** The file had `export bmc_password_n0`. Normalization exited 0 and printed `export export bmc_password_n0` with the value still on the line. The filter only drops a line that starts with `export bmc_password_`. The same password without `export` was removed.
**Suggested fix:** Drop every password line after the `export` prefix is normalized, including a line that already started with `export`.

### Bug #1262: A space in the vCenter datacenter name is dropped
**File:** `scripts/include_all.sh` (`normalize-vmware-conf` ~lines 2236–2268)
**Severity:** High — the resource pool path points at the wrong place
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `normalize-vmware-conf` and a stand-in `govc` that prints `VirtualCenter`. No live vCenter was contacted.
**What happened:** `GOVC_DATACENTER=Lab Datacenter` was printed as `export GOVC_DATACENTER=Lab Datacenter`. Sourcing that set the datacenter to `Lab`. The pool placeholder `/$GOVC_DATACENTER/host/$GOVC_CLUSTER/Resources` was then written as `/Lab/host/Cluster/Resources`.
**Suggested fix:** Quote each value when printing it. Expand the pool from the full datacenter name.

### Bug #1263: A value passed to process_args is executed
**File:** `scripts/include_all.sh` (`process_args` ~lines 4084–4092). Callers include `scripts/setup-cluster.sh` (~line 15) and `scripts/create-cluster-conf.sh` (~line 108), which load the result before checking the name.
**Severity:** High — text after a semicolon runs as a command
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by loading `process_args` output. No cluster directory was created.
**What happened:** `name=foo;uname` was accepted and printed as `export name=foo;uname`. Loading that ran `uname` and set `name` to `foo`.
**Suggested fix:** Quote the value. Reject a value that is not a plain assignment.

### Bug #1264: A value with a space becomes an extra column
**File:** `scripts/include_all.sh` (`output_table` ~lines 4064–4072). Callers include `scripts/create-install-config.sh` (~line 82) and `scripts/aba.sh` (~line 1925).
**Severity:** Medium — the summary shows the wrong cells
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling `output_table`. No config file was changed.
**What happened:** Three lines, `cluster_name=sno`, `base_domain=example.com`, and `note=two words`, were printed as `cluster_name=sno | base_domain=example.com | note=two | words`.
**Suggested fix:** Keep each input line as one cell. Split cells on newlines, not spaces.

### Bug #1265: An unknown cluster type is counted as one node
**File:** `scripts/include_all.sh` (`macs_nodes_from_type` ~lines 1406–1412, `macs_status` ~lines 1486–1488)
**Severity:** Medium — the MAC check plans a single node
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `macs_status`. No cluster was created.
**What happened:** `--type bogus --masters 3 --workers 2 --ports ens160` reported `mac_nodes=1` and `mac_expected=1`. The master and worker counts were ignored. `--type SNO` with two ports reported `mac_nodes=1` and `mac_expected=2`. `standard` reported 3 masters and 2 workers.
**Suggested fix:** Accept only `sno`, `compact`, and `standard`. Do not turn any other type into one node.

### Bug #1266: A standard cluster gets 2 workers or 3 depending on whether type was set
**File:** `scripts/create-cluster-conf.sh` (~lines 119–120 and 156–165). `scripts/setup-cluster.sh` (~lines 66–71)
**Severity:** Medium — the cluster is a different size
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 from those assignments. The cluster directory was not created.
**What happened:** `create-cluster-conf.sh` starts `num_workers` at 3 and changes it only for `sno` and `compact`. `setup-cluster.sh` sets 2 workers when `type` is `standard`. When `type` is empty, that case does not run, so the file keeps 3. `aba --type standard` is the path that writes 2.
**Suggested fix:** Use one worker count for standard in both scripts.

### Bug #1267: An IPv6 API address is split into the wrong host and port
**File:** `scripts/include_all.sh` (`cluster_api_reachable` ~lines 1807–1810)
**Severity:** High — the API check does not reach an IPv6 cluster
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with the same host and port lines. No cluster API was contacted.
**What happened:** `https://[fd00::10]:6443` became host `[fd00:` and port `10` followed by `6443`. `https://api.example.com:6443` stayed `api.example.com` port `6443`. `https://10.0.1.216:6443` stayed `10.0.1.216` port `6443`.
**Suggested fix:** Take the host inside brackets as the host, and take the port after those brackets.

### Bug #1268: A kubeconfig lookup returns the current directory's file
**File:** `scripts/include_all.sh` (`cluster_kubeconfig` ~lines 1753–1761). `scripts/aba.sh` (~line 1446) and `scripts/cluster-status.sh` (~line 123) call it with a cluster name.
**Severity:** High — a command can use another cluster's credentials
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with throwaway files. No live kubeconfig was read.
**What happened:** From a directory that already had `iso-agent-based/auth/kubeconfig`, `cluster_kubeconfig other example.com` returned that local file. From a directory without one, the same call returned `~/.aba/clusters/other.example.com/kubeconfig`.
**Suggested fix:** When a name and domain are passed, return that cluster's kubeconfig. Use the current directory only when no name was passed.

### Bug #1269: A stored prefix replaces the prefix taken from the network
**File:** `scripts/include_all.sh` (`_state_override_cluster` ~lines 1971–1996)
**Severity:** High — the loaded network is not the installed one
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `_state_override_cluster` on a throwaway state file. No live cluster state was changed.
**What happened:** The state had `machine_network=10.0.0.0/20` and `prefix_length=24`. The output set the network to `10.0.0.0` and the prefix to `20`, then set the prefix to `24`. Loading it left the prefix at 24.
**Suggested fix:** When the stored network includes a prefix, do not let a later prefix field replace it.

### Bug #1270: The suggested command names the current directory
**File:** `scripts/include_all.sh` (`aba_cmd` ~lines 1895–1897)
**Severity:** Medium — the printed command runs in the wrong directory
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by calling `aba_cmd`. No cluster command was run.
**What happened:** `ABA_TARGET_DIR` was set, which is how `aba -d` marks the shell. After moving to `/tmp`, `aba_cmd install` printed `aba -d tmp install`.
**Suggested fix:** Use the directory named by `ABA_TARGET_DIR`, not the current directory.

### Bug #1271: The mirror drift warning names the current directory
**File:** `scripts/include_all.sh` (`_state_override_mirror` ~lines 2034–2038)
**Severity:** Medium — the printed command targets the wrong directory
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `_state_override_mirror` on a throwaway mirror. No live mirror was changed.
**What happened:** The function was called for mirror name `mirror`. The installed port was 5000 and the config port was 8443. The output used port 5000. The warning said to run `aba -d notmirror uninstall`, which is the current directory, not `mirror`.
**Suggested fix:** Name the mirror that was passed in, not the current directory.

### Bug #1272: Recreating a cluster directory succeeds when init fails
**File:** `scripts/include_all.sh` (`_recreate_cluster_dir` ~lines 2059–2062)
**Severity:** Medium — the caller is told the directory is ready
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with a stand-in `make` that exits 1. No live cluster directory was changed.
**What happened:** The backup and `state.sh` were present. `make init` exited 1. `_recreate_cluster_dir` still returned 0 and left the directory in place.
**Suggested fix:** Return failure when `make init` fails.

### Bug #1273: Restoring a cluster directory keeps the first saved domain
**File:** `scripts/aba.sh` (`--dir` ~lines 103–105, missing `cluster.conf` ~lines 1418–1424)
**Severity:** High — the restored directory can belong to a different cluster
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with two throwaway state directories. `make` was not run and no live cluster directory was changed.
**What happened:** State existed for `sno.aaa.example` and `sno.zzz.example`. The loop used by `aba -d` and by a missing `cluster.conf` stopped at `sno.aaa.example`.
**Suggested fix:** When more than one saved domain matches the directory name, ask which domain to restore.

### Bug #1274: Delete can remove the ABA state directory
**File:** `scripts/aba.sh` (delete ~lines 1708–1715), `scripts/include_all.sh` (`cluster_state_dir` ~lines 1744–1749)
**Severity:** High — `aba delete` can remove `~/.aba`
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 by loading a throwaway `cluster.conf` and calling `cluster_state_dir`. The returned path is the same directory as `~/.aba`, and it is a directory. Delete was not run. The marker under that directory was still present.
**What happened:** `cluster_name=../../` and `base_domain=aba` produce `~/.aba/clusters/../../.aba`, which is `~/.aba`. `_valid_cluster_name` rejects `../../` and returns 1. The delete command does not call that check before `rm -rf`.
**Suggested fix:** Reject the name with `_valid_cluster_name` and require the resolved path to stay under `~/.aba/clusters`.

### Bug #1275: Status of a missing directory reports the current directory
**File:** `scripts/cluster-status.sh` (~lines 79–86)
**Severity:** High — status answers for a different cluster
**Mode:** ALL
**Status:** NOT COUNTED — `aba` changes into the directory before it runs status, and it passes that directory as `--dir`. The fallback was not reached by `aba` or the TUI.
**What happened:** Calling `cluster-status.sh --dir` directly for a missing directory printed `cluster=.`. `aba status` does not call it that way.
**Suggested fix:** When the requested directory has no `cluster.conf`, stop. Do not read the current directory instead.

### Bug #1276: A cluster with no replica counts is reported as compact
**File:** `scripts/cluster-status.sh` (~line 49)
**Severity:** High — the cluster type is wrong
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `aba -d aba-cli-proof-st status --shell`. The directory was removed afterwards. No live cluster was queried.
**What happened:** `cluster.conf` had a name and domain and no replica counts. The command printed `cluster=aba-cli-proof-st status=configured type=compact`.
**Suggested fix:** Leave the type unknown when the replica counts are missing. Do not substitute 3 masters and 0 workers.

### Bug #1277: cluster.conf accepts names the name check rejects
**File:** `scripts/include_all.sh` (`verify-cluster-conf` ~line 2114, `_valid_cluster_name` ~lines 2067–2073)
**Severity:** High — install verification and the CLI disagree
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `aba -d <dir> info` on throwaway directories named for `SNO` and `1sno`. Both directories were removed. No cluster was installed.
**What happened:** Both commands got past configuration verification. Each one then stopped with `Cluster not ready! Cannot find kubeconfig.` A name the CLI `--name` check rejects was accepted from `cluster.conf`.
**Suggested fix:** Use `_valid_cluster_name` in `verify-cluster-conf`.

### Bug #1278: Cluster DNS cleanup can leave /etc/dnsmasq.d
**File:** `scripts/infra-dns.sh` (remove-cluster ~lines 80–83, add-cluster ~line 58)
**Severity:** High — the dnsmasq file path is not confined to /etc/dnsmasq.d
**Mode:** ALL
**Status:** NOT COUNTED — the path was built from the script text. `aba delete` was not run, because that restarts dnsmasq.
**What happened:** Name `foo/../../../../tmp/aba-dns-not-a-file` and domain `y` produce `/etc/dnsmasq.d/aba-foo/../../../../tmp/aba-dns-not-a-file.y.conf`, which is `/tmp/aba-dns-not-a-file.y.conf`.
**Suggested fix:** Reject a name or domain that contains a slash, and require the resolved file to stay under `/etc/dnsmasq.d`.

### Bug #1279: A quote in the cluster name breaks the DNS command
**File:** `scripts/infra-dns.sh` (add-cluster ~lines 60–64)
**Severity:** High — the root shell command is no longer only the dnsmasq update
**Mode:** ALL
**Status:** NOT COUNTED — the command string was printed from the script text. `aba` was not run.
**What happened:** A cluster name containing a single quote ends the quotes around the dnsmasq path. The characters after that quote are outside the quotes, so they are a separate shell command.
**Suggested fix:** Write the dnsmasq file without placing the cluster name inside a shell string. Reject quotes in the name before building the command.

### Bug #1280: An upgrade to the current version has no path
**File:** `scripts/include_all.sh` (`verify_upgrade_path_exists` ~lines 3475–3513)
**Severity:** Medium — the installed version is reported as unreachable
**Mode:** ALL
**Status:** NOT COUNTED — `aba` calls this check only when the target version differs from the current version (`scripts/reg-save.sh`, `scripts/mirror-status.sh`). The same-version case was not reached by `aba` or the TUI.
**What happened:** The graph contained only `4.21.40`. Asking for a path from `4.21.40` to `4.21.40` returned `REACHABLE=0`, `REASON=no_path`, and exit 2.
**Suggested fix:** When the source and target are the same node, report that the version is already reached.

### Bug #1281: A conditional upgrade risk is reported as unknown
**File:** `scripts/include_all.sh` (`verify_upgrade_path_exists` ~lines 3490–3508)
**Severity:** Medium — the warning names the wrong risk
**Mode:** ALL
**Status:** NOT COUNTED — reproduced only by calling `verify_upgrade_path_exists` with a stand-in graph. Not run through `aba` or the TUI.
**What happened:** The hop from `1.0.0` to `1.0.1` was conditional and carried risk `AdminAck`. The hop from `1.0.1` to `1.0.2` was a normal edge. The result was `REACHABLE=1 HOPS=2 CONDITIONAL=1 RISKS=unknown`.
**Suggested fix:** Collect the risk names from every conditional hop on the path, not only the last hop.

### Bug #1282: aba_cmd_for treats two directories with the same name as one
**File:** `scripts/include_all.sh` (`aba_cmd_for` ~lines 1905–1914)
**Severity:** Medium — the printed command runs in the wrong directory
**Mode:** ALL
**Status:** NOT COUNTED — `aba_cmd_for` is not called by `aba` or the TUI. The only caller is a functional test.
**What happened:** The current directory was `a/sno` and the requested directory was `b/sno`. `ABA_TARGET_DIR` was unset. The function printed `aba install`.
**Suggested fix:** Compare the directory paths. Use `aba -d` when the requested directory is not the current directory.

### Bug #1283: Mirror status prints an error for a missing image set
**File:** `scripts/include_all.sh` (`_isc_operator_count` ~lines 5178–5182), `scripts/mirror-status.sh` (~lines 185, 712, and 744)
**Severity:** Medium — status completes, and prints an error on the way
**Mode:** ALL
**Status:** OPEN — verified 2026-11-09 with `aba -d aba-cli-proof-mir/notmirror status`. The directory was removed. The live mirror was not used.
**What happened:** The directory had no `data/imageset-config.yaml`. The command printed `integer expression expected` twice, then `Operators: none`, and exited 0. `aba status --shell` printed `operator_count=` with no error.
**Suggested fix:** Print `0` when the image set file is missing.

### Bug #1284: A truncated address is accepted as an NTP server
**File:** `scripts/include_all.sh` (`validate_ntp_servers` ~lines 5612–5617, `_valid_domain` ~line 1346)
**Severity:** Medium — a mistyped address is stored as a hostname
**Mode:** ALL
**Status:** NOT COUNTED — `validate_ntp_servers` has no caller in `aba` or the TUI.
**What happened:** `1.2.3` fails `validate_ip`. `_valid_domain` and `validate_domain` return 0. `validate_ntp_servers 1.2.3` returns 0. `1.2.3.4` also returns 0 because it is a real address.
**Suggested fix:** Reject a numeric name that is not a full IPv4 address.

## Documentation Bugs

(Will be added during testing)

---

## Score

| Category | Count |
|----------|-------|
| Previous bugs re-verified (FIXED) | 16 |
| Previous bugs re-verified (NOT A BUG) | 1 |
| Previous bugs re-verified (OPEN) | 0 |
| Previous bugs INCONCLUSIVE | 1 |
| **New bugs found (this session)** | **272** (#1001–#1005, #1011–#1274, #1276, #1277, #1283) |
| **New bugs fixed (this session)** | **5** (#1001–#1005) |
| **New bugs still open** | **267** (#1011–#1274, #1276, #1277, #1283). #1011–#1016, #1026–#1029, #1031, #1033–#1043, and #1045–#1055 on disco, #1017–#1025, #1030, #1032, #1044, #1056–#1274, #1276, #1277, and #1283 on conno and disco, #1061–#1063 and #1068 on kvm1. #1275, #1278–#1282, and #1284 are not counted: they were not reproduced by `aba` or the TUI. |
| Test flows completed | 12 |
| Code-review-only flows | 8 |
| Test flows remaining | ~5 |

---

## Observations

1. TUI startup from scratch works smoothly — splash, domain detection, wizard flow.
2. Mirror install with progress tracking is excellent UX.
3. Sync progress display at 25% matches "Mirror images" step being in progress.
4. Cluster install flow end-to-end works well — ISO creation, VM provisioning, agent detection, bootstrap, initialization all smooth.
5. Day-2 OperatorHub took ~5 min (registry CA trust propagation wait), NTP ~15s, OSUS ~3 min — all completed successfully.
6. Post-install Day-2 offer dialog is a nice UX touch.
7. Delete cluster confirmation message reads from global platform (Bug #1002) rather than the selected cluster's platform.
8. DISCO mode correctly detected the light bundle and asked for missing image archives — good UX flow.
9. Bundle creation (light) worked end-to-end: save images → pack config → pack bundle → 2.76GB output.
10. The `--defaultno` on delete confirmation is a good safety measure but confusing with tmux send-keys (Tab goes to Help, not Delete). This is correct dialog behavior.
11. Delete → sno cluster successfully destroyed VMs and removed state in TUI non-interactive mode.
12. Code review session 2026-10-27: Exercised ALL major TUI workflows via deep code review across CONNO, DISCO, and DIRECT modes. The codebase is impressively robust:
    - The install gate (`tui_install_cluster_gate`) correctly chains mirror install+sync/load when missing
    - The `_offer_day2_after_mirror_update` correctly probes installed clusters and offers targeted day2
    - Mode switching (Advanced menu) is well-guarded: DISCO→connected checks internet, CONNO→DISCO warns
    - Bundle creation handles same-device detection, low disk space, light/full choice, incremental updates
    - Upgrade flow correctly classifies z-stream vs minor vs conditional versions
    - The flock FD close pattern (`{ABA_TUI_FLOCK_FD}>&-`) is consistently applied on ssh/terminal/subshell boundaries
    - KUBECONFIG is correctly unset before child commands to prevent stale state
13. The subshell-echo pattern (`$(source <(normalize-...) && echo "$var")`) appears in 6 TUI call sites. While functionally correct today, it's inconsistent with the project's "source directly" convention and fragile for future maintenance.
14. The `_exec_in_terminal` `ask=true → --yes` logic appears inverted at first glance but is actually correct: the TUI provides its own confirmation dialogs, so it overrides aba.conf's ask=true with --yes to prevent double-prompting.
15. The `_state_override_mirror()` mechanism correctly merges `last_action` from `state.sh` into `normalize-mirror-conf` output, so `_mirror_last_action()` works correctly despite reading from state.sh indirectly.
16. 2026-11-06 disco `tui-debugging`: Quay on disco.example.com:8443 is up, images loaded for 4.21.40. Internet-down switch to connected is blocked ("Internet is not available") and `.bundle` is left in place. Day-2 → Status on the uninstalled `sno` directory correctly says "No installed clusters found."
17. conno tmux `tui-test` (not this session) is installing `sno.example.com` (4.21.40, fast, vmw). The gauge stays at 36% with `Review/generate configs` and `Boot nodes` as No-op while monitor runs. That tree's `progress-plan.sh`, `vmw-refresh.sh`, and `bm-ask-edit.sh` do not match bastion HEAD. HEAD closes those steps (`DONE|ci_config` for non-bm, `START/DONE|ci_boot` at the end of `vmw-refresh.sh`). Not filed as a new bug against HEAD. Did not reset or pull conno while that install is running.

---

## Core Code Bug Audit — 2026-10-29

**Scope:** `scripts/`, `cli/`, Makefiles, templates — ABA core (not TUI)
**Method:** Static analysis + verification on conno where possible

### Bug #1006: Unquoted `$ABA_ROOT` in `aba.sh` entry point
**File:** `scripts/aba.sh` — lines 238, 311, 330, 1835
**Severity:** Low — breaks ABA entirely if installed in a path with spaces
**Status:** FIXED — quoted all 4 occurrences
**Details:**
```
Line 238:  source $ABA_ROOT/scripts/include_all.sh        # unquoted
Line 311:  source <(cd $ABA_ROOT && normalize-aba-conf)    # unquoted
Line 330:  source <(cd $ABA_ROOT && normalize-aba-conf)    # unquoted
Line 1835: cd $ABA_ROOT                                    # unquoted
```
Compare with correctly quoted lines nearby:
```
Line 234:  cd "$ABA_ROOT" || exit 1                         # ✅ quoted
Line 236:  exec "$ABA_ROOT/tui/v2/abatui2.sh" "$@"         # ✅ quoted
```
**Impact:** If `$ABA_ROOT` resolves to a path containing spaces (e.g. `/home/user/My Projects/aba`), the CLI would fail at startup with "No such file or directory". The TUI path (line 234-236) is correctly quoted, so only the CLI is affected.
**Fix:** Quote all `$ABA_ROOT` references: `source "$ABA_ROOT/scripts/include_all.sh"`, `cd "$ABA_ROOT"`, etc.

### Bug #1007: Unquoted variables and eval construct in `generate-image.sh`
**File:** `scripts/generate-image.sh` — lines 56, 59, 63, 64, 70, 74
**Severity:** Low — `$ASSETS_DIR` is always `iso-agent-based` (no spaces)
**Status:** FIXED — quoted all `$ASSETS_DIR` uses; moved `|| exit 1` outside eval
**Details:**
```bash
# Line 56 — || exit 1 only applies to the LAST statement in the eval
eval "$config || exit 1"     # should be: eval "$config" || exit 1

# Lines 63-64, 70 — unquoted rm -rf and cp
rm -rf $ASSETS_DIR.backup    # should be: rm -rf "$ASSETS_DIR.backup"
cp -rp $ASSETS_DIR $ASSETS_DIR.backup
rm -rf $ASSETS_DIR           # should be: rm -rf "$ASSETS_DIR"
```
**Impact:** The eval construct is misleading but safe in practice since `export` statements rarely fail. The unquoted variables are safe because `ASSETS_DIR` is hardcoded to `iso-agent-based`. However, if the constant were ever changed to contain spaces, `rm -rf $ASSETS_DIR` could delete unintended files.
**Verified:** Confirmed `ASSETS_DIR` is always `iso-agent-based` (set in `cluster-config.sh` line 187).

### Bug #1008: `aba-get-version.sh` broken — `cd` to wrong directory + temp dir leak
**File:** `scripts/aba-get-version.sh` — lines 5-6, 27
**Severity:** Low — script is unused (listed in `analyze-unused-scripts.sh` as "probably safe" to remove)
**Status:** OPEN (legacy script)
**Verified:** ✅ Confirmed broken on conno — `source scripts/include_all.sh: No such file or directory`
**Details:**
```bash
# Lines 5-6: cd goes to scripts/, then source looks for scripts/scripts/include_all.sh
dir=$(dirname $0)    # returns "scripts" when called from repo root
cd $dir              # now in scripts/ — all relative paths break

# Line 27: export masks mktemp failure
export tmp_dir=$(mktemp -d "$ABA_TMP/ver-XXXX")  # $? is always 0

# No cleanup trap — tmp_dir is leaked
```
**Impact:** Script can never run successfully when called directly. No temp dir cleanup on any exit path. Since the script is unused, this is a code hygiene issue.
**Fix:** Remove the script (it's unused), or fix the `cd` and add `trap 'rm -rf "$tmp_dir"' EXIT`.

### Bug #1009: Remote SSH commands use unquoted shell variables in `reg-common.sh`
**File:** `scripts/reg-common.sh` — lines 788, 791, 792, 795, and 20+ other locations
**Severity:** Medium — remote registry operations could fail or misbehave with paths containing spaces
**Status:** FIXED — single-quoted path vars inside SSH command strings; left `echo $reg_root` unquoted (line 1489) for intentional remote ~ expansion
**Details:**
The remote SSH command pattern throughout `reg-common.sh` passes variables unquoted inside SSH command strings:
```bash
# Remote handling — BROKEN for paths with spaces:
$ssh_cmd "[ -d $dir ]"              # line 788
$ssh_cmd "$SUDO rm -rf $dir"        # line 791
$ssh_cmd "rm -rf $dir"              # line 792
$ssh_cmd "mkdir -p $remote_tmp"     # line 1288
$ssh_cmd "rm -rf $remote_tmp"       # line 1296
$ssh_cmd "mkdir -p $reg_root/../$_bin_dir"  # line 1211

# Compare with LOCAL handling — correct:
rm -rf "$dir"                        # line 801 ✅
```
The variable `$dir` is expanded by the LOCAL shell before being embedded in the SSH command string. The remote shell then receives `rm -rf /path/with spaces` (two arguments).
**Impact:** If `data_dir` in `mirror.conf` is set to a path with spaces:
- Remote registry install/uninstall would fail
- Remote data deletion (`rm -rf`) could silently delete wrong directories
- Default paths (`/opt/registry-data`, `~/.aba/registry-data`) are safe
**Fix:** Use single quotes for quoting within SSH: `$ssh_cmd "rm -rf '$dir'"`. Or use `printf '%q'` for escaping.

### Bug #1010: Unquoted `dirname` in `aba.sh` `--out` path validation
**File:** `scripts/aba.sh` — line 622
**Severity:** Low — `aba bundle --out` with paths containing spaces fails validation
**Status:** FIXED — properly quoted `$(dirname "$1")`
**Details:**
```bash
# Line 622: dirname arg and test both unquoted
[ "$1" ] && [ ! -d $(dirname $1) ] && aba_abort "directory: [$(dirname $1)] incorrect or missing!"
#                    ^^^^^^^^ ^^                       ^^^^^^^^ ^^
# Should be:
[ "$1" ] && [ ! -d "$(dirname "$1")" ] && aba_abort "..."
```
**Impact:** `aba bundle --out "/path/with spaces/bundle"` would fail with a confusing error message because `dirname` receives two arguments and `[ ! -d ... ]` tests the wrong path.
**Verified:** Code inspection confirmed.

---

## Audit Summary — Core Code

| Category | Count |
|----------|-------|
| Quoting bugs (unquoted variables) | 4 (#1006, #1007, #1009, #1010) |
| Broken legacy script | 1 (#1008) |
| **Total new bugs found** | **5** |
| Security-critical | 0 |
| Functional impact (common paths) | 0 |
| Functional impact (edge cases) | 3 (#1006, #1009, #1010) |

### Bug #1009a: Fallback uninstall path did not resolve `~` before calling uninstall functions
**File:** `scripts/reg-uninstall.sh` — fallback path (line ~72)
**Severity:** Medium — fallback uninstall of remote registry with default `data_dir` fails to remove data
**Status:** FIXED — added `~` resolution via SSH echo after `reg_setup_data_dir()`, matching `reg_remote_pre_install()` pattern
**Discovered:** During review of #1009 quoting fixes — the e2e `negative-paths` suite caught this immediately ("Data directory removed" EXHAUSTED retries)
**Details:**
In the fallback uninstall path (no state.sh), `reg_setup_data_dir()` keeps `~` literal for remote paths (`reg_root=~/docker-reg`). The original unquoted SSH commands (`rm -rf $dir`) allowed the remote shell to expand `~`. After the #1009 quoting fix (`rm -rf '$dir'`), single quotes prevented tilde expansion. The fix: resolve `~` to an absolute path via SSH echo in the fallback path, the same way `reg_remote_pre_install()` does during install. This makes all downstream single-quoting safe.

### Areas Reviewed (No Bugs Found)
- **`aba delete --force` safety**: Properly validates through `_valid_cluster_name()` (DNS label regex + reserved names list) and `cluster_state_dir()` before any `rm -rf`. The state dir `~/.aba/clusters/<name>.<domain>` is always under `~/.aba/` and validated non-empty.
- **`eval` usage in `aba.sh`**: The `BUILD_COMMAND` eval (line 1820) is protected by the `#1099` guard at line 1316 that rejects shell metacharacters (`^[a-zA-Z0-9._=-]+$`).
- **`cluster-config.sh` eval chain**: All scripts using `eval "$(scripts/cluster-config.sh)"` receive sanitized `export KEY=VALUE` output from a `set -e` script. The pattern is functionally correct.
- **`run_once` function**: Uses flock for mutual exclusion, atomic exit file writes (`mv -f`), proper TOCTOU avoidance (noted in code comment at line 4170). The self-healing validation runs under lock.
- **`_normalize_export` config injection**: The function strips comments and prepends `export`. A malicious config could inject commands via `$(...)` in values, but since config files are user-editable, this is self-inflicted (same as sourcing `.bashrc`).
- **Marker file lifecycle**: Makefiles own `.init`, `.install-complete`, etc. Scripts don't create/remove them — consistent with invariant #2 from AGENTS.md.
- **`_valid_cluster_name()` safety gate**: DNS label regex `^[a-z]([a-z0-9-]*[a-z0-9])?$` + reserved name list prevents path traversal or `rm -rf` of ABA directories.
- **`make-bundle.sh`**: Properly handles `--out -` (stdout) and file paths. The `aba bundle --out -` keeps stdout pure tar — verified by code inspection.
- **`bmc.conf` handling**: Mode-0600 permission check (`_bmc_conf_perm_check`) runs BEFORE `eval "$vars"` — defense against file poisoning.
- **Password handling**: `--reg-password` validates against injection characters (`"'\`$`) before writing to config. Password is always single-quoted in mirror.conf.
- **Temp file cleanup**: Most scripts using `mktemp` have corresponding `trap ... EXIT` or inline cleanup. Exception: `aba-get-version.sh` (Bug #1008, unused).
- **`(( var++ ))` under `set -e`**: No instances found — the project consistently uses `var=$(( var + 1 ))` per AGENTS.md conventions.
