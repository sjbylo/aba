#!/bin/bash
# sync-images.sh — Sync images to registry
# Emits START/DONE for each sync step. PLANs come from plan.sh.
source "$(dirname "$0")/progress.sh"

# ─── Background CLI download ─────────────────────────────────────
# Real run_once, the same shape ABA uses: kick off now, wait at the end.
# The dialog keeps "Download CLI tools" In Progress while the sync
# steps run, then shows "Wait for CLI tools" until run_once -w returns.
# The runner dir stays in the demo tmp so this does not touch ~/.aba/runner.
_bg_task=""
_bg_done_file=""
if [ -n "${SIMULATE_BG_DOWNLOAD:-}" ]; then
	_bg_done_file="${ABA_DEMO_TMP:-/tmp}/bg-cli-done"
	rm -f "$_bg_done_file"
	aba_progress "START|cli_dl"
	printf '\033[1;34m[ABA]\033[0m Downloading CLI tools (background) ...\n'
	# Simulate a background download — plain sleep, fully detached from PTY
	# so pty-run.py can detect make exit without waiting for this to finish.
	# 20s: long enough to overlap most of the heavy oc-mirror simulation.
	(sleep 20; touch "$_bg_done_file") </dev/null >/dev/null 2>&1 &
	_bg_task=$!
	disown $_bg_task 2>/dev/null || true
fi

# catalogs_dl — only emits if catalogs need downloading
if [ -n "${FORCE_CATALOG_DOWNLOAD:-}" ]; then
	aba_progress "START|catalogs_dl"
	printf '\033[1;34m[ABA]\033[0m Downloading operator catalogs ...\n'
	sleep 2.0
	echo "       redhat-operator-index v4.17: downloaded"
	echo "       certified-operator-index v4.17: downloaded"
	echo "       community-operator-index v4.17: downloaded"
	printf '\033[1;32m[ABA]\033[0m Catalogs ready.\n'
	aba_progress "DONE|catalogs_dl"
else
	printf '\033[0;90m[ABA] All operator catalogs cached\033[0m\n'
fi

aba_progress "START|versions"
printf '\033[1;34m[ABA]\033[0m Verifying release versions ...\n'
sleep 0.4
echo "       OCP 4.17.6 — available in candidate channel"
printf '\033[1;32m[ABA]\033[0m Versions verified.\n'
aba_progress "DONE|versions"

aba_progress "START|tools"
printf '\033[1;34m[ABA]\033[0m Preparing tools ...\n'
sleep 0.3
echo "       oc-mirror: 4.17.6 (/usr/local/bin/oc-mirror)"
printf '\033[1;32m[ABA]\033[0m Tools ready.\n'
aba_progress "DONE|tools"

aba_progress "START|registry"
printf '\033[1;34m[ABA]\033[0m Checking registry access ...\n'
sleep 0.3
echo "       bastion.example.com:8443 — authenticated"
printf '\033[1;32m[ABA]\033[0m Registry access OK.\n'
aba_progress "DONE|registry"

aba_progress "START|sync"
printf '\033[1;34m[ABA]\033[0m Now syncing (mirror2mirror) images from external network to registry bastion.example.com:8443/ocp4/openshift4.\n'
printf '\033[1;34m[ABA]\033[0m This can take 5 to 20 minutes or more to complete, much longer for large image sets.\n'
echo ""
printf '\033[1;34m[ABA]\033[0m Attempt (1/3) using oc-mirror v4.22.0.\n'

# ═══════════════════════════════════════════════════════════════════
# Simulated oc-mirror output — realistic block-redraw with concurrent
# image transfers, ESC[nA+ESC[J redraws, size/speed progress bars.
#   SKIP_OC_MIRROR=1 — fast placeholder for scenarios that don't need
#   the heavy output (fresh-all, fresh-bg, etc.)
# ═══════════════════════════════════════════════════════════════════

_reg="bastion.example.com:8443/ocp4/openshift4"
_ts_base="2026/10/31 21:36"

if [ -n "${SKIP_OC_MIRROR:-}" ]; then
	echo "2026/10/31 21:36:09 [INFO] : 👋 Hello, welcome to oc-mirror"
	echo "2026/10/31 21:36:09 [INFO] : 🔀 workflow mode: mirrorToMirror"
	sleep 0.5
	echo "2026/10/31 21:36:10 [INFO] : 📌 images to copy 12"
	sleep 1
	echo "2026/10/31 21:36:12 [INFO] : ✓ 12 / 12 images mirrored"
	echo "2026/10/31 21:36:13 [INFO] : mirror time     : 0m3.201s"
	echo "2026/10/31 21:36:13 [INFO] : 👋 Goodbye, thank you for using oc-mirror"
else   # Full heavy simulation

_ts() { printf "%s:%02d" "$_ts_base" "$1"; }

echo "$(_ts 9) [INFO] : 👋 Hello, welcome to oc-mirror"
echo "$(_ts 9) [INFO] : ⚙️  oc-mirror version 4.22.0 (build: a2b3c4d)"
echo "$(_ts 9) [INFO] : 🔀 workflow mode: mirrorToMirror"
echo "$(_ts 9) [INFO] : Verified we can authenticate against registry \"$_reg\""
echo "$(_ts 9) [INFO] : using ImageSetConfiguration file \"mirror/imageset-config.yaml\""
echo "$(_ts 9) [INFO] : 🕵  going to discover the necessary images..."
echo "$(_ts 10) [INFO] : total OCP channels to mirror: 1"
echo "$(_ts 10) [INFO] : total Operator catalogs to mirror: 3"
echo "$(_ts 10) [INFO] : total Additional images to mirror: 6"
sleep 0.15
echo "$(_ts 11) [INFO] : 🔍 collecting release images..."
printf '  \033[1;32m✓\033[0m  () Collecting release quay.io/openshift-release-dev/ocp-release:4.17.6-x86_64\n'
sleep 0.1
echo "$(_ts 12) [INFO] : 🔍 collecting operator catalog images..."
printf '  \033[1;32m✓\033[0m  () Collecting catalog registry.redhat.io/redhat/redhat-operator-index:v4.17\n'
printf '  \033[1;32m✓\033[0m  () Collecting catalog registry.redhat.io/redhat/certified-operator-index:v4.17\n'
printf '  \033[1;32m✓\033[0m  () Collecting catalog registry.redhat.io/redhat/community-operator-index:v4.17\n'
sleep 0.1
echo "$(_ts 13) [INFO] : 🔍 collecting additional images..."
printf '  \033[1;32m✓\033[0m  () Collecting additional registry.redhat.io/ubi9/ubi-minimal:latest\n'
printf '  \033[1;32m✓\033[0m  () Collecting additional registry.redhat.io/rhel9/support-tools:latest\n'
sleep 0.05

# ── Image inventory ───────────────────────────────────────────────
# 160 release images + 42 operator images + 6 additional = 208 total
# This is realistic for an OCP 4.17 + 4 operators + extras mirror set.

_release_images=(
	"ocp-v4.0-art-dev@sha256:02115f30d516f981b278e00721163dfc5c4a51c951fd03bc636268c892e7338c"
	"ocp-v4.0-art-dev@sha256:a3b8c1d2e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f90123"
	"ocp-v4.0-art-dev@sha256:1a2b3c4d5e6f7890abcdef1234567890abcdef1234567890abcdef1234567890"
	"ocp-v4.0-art-dev@sha256:fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321"
	"ocp-v4.0-art-dev@sha256:0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff"
	"ocp-v4.0-art-dev@sha256:ffff0000eeee1111dddd2222cccc3333bbbb4444aaaa555599998888777766665555"
	"ocp-v4.0-art-dev@sha256:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
	"ocp-v4.0-art-dev@sha256:9876543210fedcba9876543210fedcba9876543210fedcba9876543210fedcba"
	"ocp-v4.0-art-dev@sha256:deadbeefcafe0123deadbeefcafe0123deadbeefcafe0123deadbeefcafe0123"
	"ocp-v4.0-art-dev@sha256:c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00"
	"ocp-v4.0-art-dev@sha256:baadf00dbaadf00dbaadf00dbaadf00dbaadf00dbaadf00dbaadf00dbaadf00d"
	"ocp-v4.0-art-dev@sha256:12345678abcdef0012345678abcdef0012345678abcdef0012345678abcdef00"
	"ocp-v4.0-art-dev@sha256:e5c3b1a9f8d7e6c5b4a3928170605f4e3d2c1b0a9f8e7d6c5b4a392817060504"
	"ocp-v4.0-art-dev@sha256:4040404050505050606060607070707080808080909090901a1a1a1a2b2b2b2b"
	"ocp-v4.0-art-dev@sha256:0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9"
	"ocp-v4.0-art-dev@sha256:5555aaaa6666bbbb7777cccc8888dddd9999eeee0000ffff1111222233334444"
	"ocp-v4.0-art-dev@sha256:a1a1b2b2c3c3d4d4e5e5f6f60a0a1b1b2c2c3d3d4e4e5f5f6a6a7b7b8c8c9d9d"
	"ocp-v4.0-art-dev@sha256:1f2e3d4c5b6a09f8e7d6c5b4a3928170fedcba9876543210abcdef1234567890"
	"ocp-v4.0-art-dev@sha256:ff11ee22dd33cc44bb55aa6699887766ff00ee11dd22cc33bb44aa5599887766"
	"ocp-v4.0-art-dev@sha256:001122334455667788990011aabbccddeeff00112233445566778899aabbccdd"
	"ocp-v4.0-art-dev@sha256:aabb00cc11dd22ee33ff44aa55bb66cc77dd88ee99ff00aa11bb22cc33dd44ee"
	"ocp-v4.0-art-dev@sha256:10203040506070809010a0b0c0d0e0f010203040506070809010a0b0c0d0e0f0"
	"ocp-v4.0-art-dev@sha256:f0e0d0c0b0a0908070605040302010f0e0d0c0b0a0908070605040302010f0e0"
	"ocp-v4.0-art-dev@sha256:1234abcd5678efab9012cdef3456abcd7890efab1234cdef5678abcd9012efab"
	"ocp-v4.0-art-dev@sha256:abcdef01abcdef01abcdef01abcdef01abcdef01abcdef01abcdef01abcdef01"
	"ocp-v4.0-art-dev@sha256:11111111222222223333333344444444555555556666666677777777aaaaaaaa"
	"ocp-v4.0-art-dev@sha256:aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888"
	"ocp-v4.0-art-dev@sha256:9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a0"
	"ocp-v4.0-art-dev@sha256:cafe0000babe1111dead2222beef3333cafe4444babe5555dead6666beef7777"
	"ocp-v4.0-art-dev@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	"ocp-v4.0-art-dev@sha256:face0123face0123face0123face0123face0123face0123face0123face0123"
	"ocp-v4.0-art-dev@sha256:b00b1e55b00b1e55b00b1e55b00b1e55b00b1e55b00b1e55b00b1e55b00b1e55"
	"ocp-v4.0-art-dev@sha256:da7aba5eda7aba5eda7aba5eda7aba5eda7aba5eda7aba5eda7aba5eda7aba5e"
	"ocp-v4.0-art-dev@sha256:5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e5ca1ab1e"
	"ocp-v4.0-art-dev@sha256:dec0de01dec0de01dec0de01dec0de01dec0de01dec0de01dec0de01dec0de01"
	"ocp-v4.0-art-dev@sha256:ca5cade5ca5cade5ca5cade5ca5cade5ca5cade5ca5cade5ca5cade5ca5cade5"
	"ocp-v4.0-art-dev@sha256:5eed1e555eed1e555eed1e555eed1e555eed1e555eed1e555eed1e555eed1e55"
	"ocp-v4.0-art-dev@sha256:f100d1e5f100d1e5f100d1e5f100d1e5f100d1e5f100d1e5f100d1e5f100d1e5"
	"ocp-v4.0-art-dev@sha256:c001d00dc001d00dc001d00dc001d00dc001d00dc001d00dc001d00dc001d00d"
	"ocp-v4.0-art-dev@sha256:d15c0de5d15c0de5d15c0de5d15c0de5d15c0de5d15c0de5d15c0de5d15c0de5"
	"ocp-v4.0-art-dev@sha256:5e1ec7ed5e1ec7ed5e1ec7ed5e1ec7ed5e1ec7ed5e1ec7ed5e1ec7ed5e1ec7ed"
	"ocp-v4.0-art-dev@sha256:ca11ab1eca11ab1eca11ab1eca11ab1eca11ab1eca11ab1eca11ab1eca11ab1e"
	"ocp-v4.0-art-dev@sha256:de1e7e01de1e7e01de1e7e01de1e7e01de1e7e01de1e7e01de1e7e01de1e7e01"
	"ocp-v4.0-art-dev@sha256:acc01adaacc01adaacc01adaacc01adaacc01adaacc01adaacc01adaacc01ada"
	"ocp-v4.0-art-dev@sha256:ba5eba11ba5eba11ba5eba11ba5eba11ba5eba11ba5eba11ba5eba11ba5eba11"
	"ocp-v4.0-art-dev@sha256:b01dface01b01dface01b01dface01b01dface01b01dface01b01dface01b01d"
	"ocp-v4.0-art-dev@sha256:5a1ad00d5a1ad00d5a1ad00d5a1ad00d5a1ad00d5a1ad00d5a1ad00d5a1ad00d"
	"ocp-v4.0-art-dev@sha256:abad1deaabad1deaabad1deaabad1deaabad1deaabad1deaabad1deaabad1dea"
	"ocp-v4.0-art-dev@sha256:ca7f00d0ca7f00d0ca7f00d0ca7f00d0ca7f00d0ca7f00d0ca7f00d0ca7f00d0"
	"ocp-v4.0-art-dev@sha256:f005ba11f005ba11f005ba11f005ba11f005ba11f005ba11f005ba11f005ba11"
	"ocp-v4.0-art-dev@sha256:decea5eddecea5eddecea5eddecea5eddecea5eddecea5eddecea5eddecea5ed"
	"ocp-v4.0-art-dev@sha256:c0de5afec0de5afec0de5afec0de5afec0de5afec0de5afec0de5afec0de5afe"
	"ocp-v4.0-art-dev@sha256:b105f00db105f00db105f00db105f00db105f00db105f00db105f00db105f00d"
	"ocp-v4.0-art-dev@sha256:a110ca7ea110ca7ea110ca7ea110ca7ea110ca7ea110ca7ea110ca7ea110ca7e"
	"ocp-v4.0-art-dev@sha256:fabaceae fabaceae fabaceae fabaceae fabaceae fabaceae fabaceae fabaceae"
	"ocp-v4.0-art-dev@sha256:e5ca1a7ee5ca1a7ee5ca1a7ee5ca1a7ee5ca1a7ee5ca1a7ee5ca1a7ee5ca1a7e"
	"ocp-v4.0-art-dev@sha256:d0d0b1rdd0d0b1rdd0d0b1rdd0d0b1rdd0d0b1rdd0d0b1rdd0d0b1rdd0d0b1rd"
	"ocp-v4.0-art-dev@sha256:f1a7bed5f1a7bed5f1a7bed5f1a7bed5f1a7bed5f1a7bed5f1a7bed5f1a7bed5"
	"ocp-v4.0-art-dev@sha256:5ca7ched5ca7ched5ca7ched5ca7ched5ca7ched5ca7ched5ca7ched5ca7ched"
	"ocp-v4.0-art-dev@sha256:0bfae50bfae50bfae50bfae50bfae50bfae50bfae50bfae50bfae50bfae50bfa"
	"ocp-v4.0-art-dev@sha256:0ff1ce010ff1ce010ff1ce010ff1ce010ff1ce010ff1ce010ff1ce010ff1ce01"
)

_operator_images=(
	"redhat-operator-index@sha256:3fa1e2b3c4d5e6f708192a3b4c5d6e7f80a1b2c3d4e5f60718293a4b5c6d7e8"
	"ose-local-storage-operator@sha256:aabb1122ccdd3344eeff5566aabb1122ccdd3344eeff5566aabb1122ccdd3344"
	"ose-local-storage-diskmaker@sha256:11aa22bb33cc44dd55ee66ff77889900aabbccddeeff00112233445566778899"
	"ose-local-storage-mustgather@sha256:ff00ee11dd22cc33bb44aa5599887766ff00ee11dd22cc33bb44aa5599887766"
	"ose-local-storage-operator-bundle@sha256:dead0001beef0002cafe0003babe0004dead0005beef0006cafe0007babe"
	"ose-odf-operator@sha256:9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b"
	"ose-odf-console@sha256:1122aabb3344ccdd5566eeff7788aabb1122ccdd3344eeff5566aabb7788ccdd00"
	"ose-odf-csi-addons-operator@sha256:aa11bb22cc33dd44ee55ff66aa77bb88cc99dd00ee11ff22aa33bb44cc55dd66"
	"ose-odf-multicluster-orchestrator@sha256:1234000056780000abcd0000efab00001234000056780000abcd0000efab"
	"ose-odf-operator-bundle@sha256:face1111face2222face3333face4444face5555face6666face7777face8888"
	"ose-csi-driver-nfs@sha256:abab1212cdcd3434efef5656abab1212cdcd3434efef5656abab1212cdcd3434"
	"ose-csi-driver-shared-resource@sha256:1a2a3a4a5a6a7a8a1b2b3b4b5b6b7b8b1c2c3c4c5c6c7c8c1d2d3d4d5d6d7d8d"
	"certified-operator-index@sha256:7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b"
	"community-operator-index@sha256:b0a1c2d3e4f5061728394a5b6c7d8e9f0a1b2c3d4e5f60718293a4b5c6d7e8f9"
	"ose-compliance-operator@sha256:aaffbb1122ccdd3344eeff5566778899aabbccddeeff00112233445566778899aa"
	"ose-compliance-content@sha256:11ff22ee33dd44cc55bb66aa77990088112233445566778899aabbccddeeff0011"
	"ose-compliance-operator-bundle@sha256:beef0001cafe0002babe0003dead0004beef0005cafe0006babe0007dead"
	"ose-file-integrity-operator@sha256:cc11dd22ee33ff44aa55bb6600771188cc22dd33ee44ff55aa66bb7700881199"
	"ose-file-integrity-operator-bundle@sha256:0000aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb"
	"ose-kube-rbac-proxy@sha256:a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1"
	"ose-oauth-proxy@sha256:1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b"
	"ose-prometheus-alertmanager@sha256:ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00"
	"ose-prometheus-node-exporter@sha256:00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff"
)

_additional_images=(
	"ubi9/ubi-minimal@sha256:5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b"
	"rhel9/support-tools@sha256:ee44ff55aa66bb7700881199cc22dd33ee44ff55aa66bb7700881199cc22dd33"
	"ubi9/ubi-init@sha256:4455667788990011223344556677889900aabbccddeeff00112233445566778899"
	"openshift4/ose-tools-rhel9@sha256:6c7d8e9f0a1b2c3d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1"
	"rhacm2/multicluster-engine-rhel9@sha256:a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
	"openshift-gitops-1/argocd-rhel8@sha256:dd33ee44ff55aa66bb7700881199cc22dd33ee44ff55aa66bb7700881199cc22"
)

_total=$(( ${#_release_images[@]} + ${#_operator_images[@]} + ${#_additional_images[@]} ))

echo ""
echo "$(_ts 14) [INFO] : ════════════════════════════════════════════════════════"
echo "$(_ts 14) [INFO] : 🚀 Start mirroring images..."
echo "$(_ts 14) [INFO] : 📌 total images to copy: $_total"
echo "$(_ts 14) [INFO] : ════════════════════════════════════════════════════════"
echo ""

# ── Block-redraw engine ───────────────────────────────────────────
# Emulates oc-mirror's real PTY behaviour:
#  • A sliding window of CONCURRENT (4-6) image transfers
#  • Each image progresses through stages with size/speed data
#  • The block is redrawn using ESC[nA (cursor up) + ESC[J (erase)
#  • Completed images scroll above the block as finished lines
#  • Random image sizes (50-500 MiB) and speeds (8-35 MiB/s)
#
# This produces heavy, realistic terminal output with control chars
# that exercise the cleanup pipeline.
CONCURRENT=5
_SPEEDS=(8 11 14 18 22 26 30 35)
_SIZES=(52 78 95 112 138 156 189 215 256 312 378 425 487)

_rand_from() {
	local _arr=("$@")
	echo "${_arr[RANDOM % ${#_arr[@]}]}"
}

_mirror_phase() {
	local _label=$1; shift
	local _phase_images=("$@")
	local _count=${#_phase_images[@]}
	local _done_count=0
	local _phase_n=$_global_n

	# Per-image state: size, speed, bytes_done, finished
	local -a _img_size _img_speed _img_done _img_fin
	for (( i=0; i<_count; i++ )); do
		_img_size[$i]=$(_rand_from "${_SIZES[@]}")
		_img_speed[$i]=$(_rand_from "${_SPEEDS[@]}")
		_img_done[$i]=0
		_img_fin[$i]=0
	done

	# Window state
	local _win_start=0
	local _win_drawn=0

	while [ "$_done_count" -lt "$_count" ]; do
		# Calculate visible window
		local _win_end=$(( _win_start + CONCURRENT ))
		[ "$_win_end" -gt "$_count" ] && _win_end=$_count
		local _win_size=$(( _win_end - _win_start ))

		# Erase previous block (cursor up + erase to end of screen)
		if [ "$_win_drawn" -gt 0 ]; then
			printf '\033[%dA\033[J' "$_win_drawn"
		fi

		_win_drawn=0

		# Advance and draw each slot in the window
		for (( i=_win_start; i<_win_end; i++ )); do
			if [ "${_img_fin[$i]}" -eq 1 ]; then
				# Already finished — show completion line
				local _gn=$(( _phase_n + i + 1 ))
				printf '  \033[1;32m✓\033[0m  (%ds) [%3d/%d] %s ➜ %s  %d MiB\n' \
					"$_global_elapsed" "$_gn" "$_total" "${_phase_images[$i]}" "$_reg" "${_img_size[$i]}"
				_win_drawn=$(( _win_drawn + 1 ))
				continue
			fi

			# Advance progress
			local _chunk=${_img_speed[$i]}
			_img_done[$i]=$(( ${_img_done[$i]} + _chunk ))

			if [ "${_img_done[$i]}" -ge "${_img_size[$i]}" ]; then
				_img_done[$i]=${_img_size[$i]}
				_img_fin[$i]=1
				_done_count=$(( _done_count + 1 ))
				local _gn=$(( _phase_n + i + 1 ))
				printf '  \033[1;32m✓\033[0m  (%ds) [%3d/%d] %s ➜ %s  %d MiB\n' \
					"$_global_elapsed" "$_gn" "$_total" "${_phase_images[$i]}" "$_reg" "${_img_size[$i]}"
			else
				local _gn=$(( _phase_n + i + 1 ))
				local _pct=$(( ${_img_done[$i]} * 100 / ${_img_size[$i]} ))
				printf '  \033[1;35m↑\033[0m  (%ds) [%3d/%d] %s  %d MiB / %d MiB  %d%%  %d MiB/s\n' \
					"$_global_elapsed" "$_gn" "$_total" "${_phase_images[$i]}" \
					"${_img_done[$i]}" "${_img_size[$i]}" "$_pct" "${_img_speed[$i]}"
			fi
			_win_drawn=$(( _win_drawn + 1 ))
		done

		# Slide window when all visible images are done
		local _all_vis_done=1
		for (( i=_win_start; i<_win_end; i++ )); do
			[ "${_img_fin[$i]}" -eq 0 ] && _all_vis_done=0 && break
		done
		if [ "$_all_vis_done" -eq 1 ] && [ "$_win_end" -lt "$_count" ]; then
			# Print finished block permanently then slide
			_win_start=$_win_end
			_win_drawn=0
			echo ""
		fi

		_global_elapsed=$(( _global_elapsed + 1 ))
		sleep 0.04
	done

	# Final print of completed window (no more erasing)
	echo ""

	_global_n=$(( _global_n + _count ))
}

_global_n=0
_global_elapsed=0

# ── Phase 1: Release images ──────────────────────────────────────
echo "$(_ts 14) [INFO] : ── Phase 1/3: Release images (${#_release_images[@]} images) ──"
echo ""

_mirror_phase "release" "${_release_images[@]}"

echo "$(_ts 39) [INFO] : === Release Results ==="
printf '%s [INFO] : \033[1;32m ✓ \033[0m %d / %d release images mirrored successfully\n' "$(_ts 39)" "${#_release_images[@]}" "${#_release_images[@]}"
printf '%s [INFO] : \033[1;33m ⚠ \033[0m 3 blobs already existed (skipped)\n' "$(_ts 39)"
echo "$(_ts 39) [INFO] : release mirror time: 4m52.318s"
echo ""

# ── Phase 2: Operator catalog images ─────────────────────────────
echo "$(_ts 40) [INFO] : ── Phase 2/3: Operator catalog + bundle images (${#_operator_images[@]} images) ──"
echo "$(_ts 40) [INFO] : 📦 operators: local-storage-operator, odf-operator, compliance-operator, file-integrity-operator"
echo "$(_ts 40) [INFO] : 📦 processing catalog: redhat-operator-index"
echo "$(_ts 40) [INFO] :    rendering declarative config for 4 packages..."
sleep 0.05
echo "$(_ts 41) [INFO] :    extracted 23 bundles (4 head, 19 upgrade-graph)"
echo "$(_ts 41) [INFO] : 📦 processing catalog: certified-operator-index"
echo "$(_ts 41) [INFO] :    rendering declarative config for 0 packages (none selected)"
echo "$(_ts 41) [INFO] : 📦 processing catalog: community-operator-index"
echo "$(_ts 41) [INFO] :    rendering declarative config for 0 packages (none selected)"
echo "$(_ts 42) [INFO] : 📌 operator images to copy: ${#_operator_images[@]}"
echo ""

_mirror_phase "operator" "${_operator_images[@]}"

echo "$(_ts 50) [INFO] : === Operator Results ==="
printf '%s [INFO] : \033[1;32m ✓ \033[0m %d / %d operator images mirrored successfully\n' "$(_ts 50)" "${#_operator_images[@]}" "${#_operator_images[@]}"
printf '%s [WARN] : \033[1;33m ⚠ \033[0m 5 images already existed (skipped)\n' "$(_ts 50)"
echo "$(_ts 50) [INFO] : operator mirror time: 1m45.771s"
echo ""

# ── Phase 3: Additional images ───────────────────────────────────
echo "$(_ts 51) [INFO] : ── Phase 3/3: Additional images (${#_additional_images[@]} images) ──"
echo "$(_ts 51) [INFO] : 📌 additional images to copy: ${#_additional_images[@]}"
echo ""

_mirror_phase "additional" "${_additional_images[@]}"

echo "$(_ts 53) [INFO] : === Additional Image Results ==="
printf '%s [INFO] : \033[1;32m ✓ \033[0m %d / %d additional images mirrored successfully\n' "$(_ts 53)" "${#_additional_images[@]}" "${#_additional_images[@]}"
echo ""

# ── Overall summary ───────────────────────────────────────────────
echo "$(_ts 54) [INFO] : ════════════════════════════════════════════════════════"
echo "$(_ts 54) [INFO] : === Overall Mirror Results ==="
echo "$(_ts 54) [INFO] : ════════════════════════════════════════════════════════"
printf '%s [INFO] : \033[1;32m ✓ \033[0m %d / %d total images mirrored successfully\n' "$(_ts 54)" "$_total" "$_total"
printf '%s [WARN] : \033[1;33m ⚠ \033[0m 8 blobs already existed (skipped)\n' "$(_ts 54)"
echo "$(_ts 54) [INFO] : ════════════════════════════════════════════════════════"
echo ""
echo "$(_ts 54) [INFO] : Generating pinned configurations..."
sleep 0.1
echo "$(_ts 55) [INFO] : 📄 Generating cluster resources..."
echo "$(_ts 55) [INFO] : 📄 Generating IDMS file..."
echo "$(_ts 55) [INFO] : working-dir/cluster-resources/idms-oc-mirror.yaml file created"
echo "$(_ts 55) [INFO] : 📄 Generating ITMS file..."
echo "$(_ts 55) [INFO] : working-dir/cluster-resources/itms-oc-mirror.yaml file created"
echo "$(_ts 55) [INFO] : 📄 Generating CatalogSource files..."
echo "$(_ts 55) [INFO] : working-dir/cluster-resources/cs-redhat-operator-index-v4_17.yaml file created"
echo "$(_ts 55) [INFO] : working-dir/cluster-resources/cs-certified-operator-index-v4_17.yaml file created"
echo "$(_ts 55) [INFO] : working-dir/cluster-resources/cs-community-operator-index-v4_17.yaml file created"
echo "$(_ts 56) [INFO] : 📄 Generating UpdateService file..."
echo "$(_ts 56) [INFO] : working-dir/cluster-resources/updateService.yaml file created"
echo "$(_ts 56) [INFO] : mirror time     : 7m32.906567007s"
echo "$(_ts 56) [INFO] : 👋 Goodbye, thank you for using oc-mirror"

fi  # end SKIP_OC_MIRROR check

# Graceful failure: script emits FAIL/ERROR/NEXT events before exiting
if [ -n "${SIMULATE_FAIL:-}" ]; then
	printf '\033[1;31m[ABA] Error: oc-mirror sync failed\033[0m\n' >&2
	aba_progress "FAIL|sync"
	aba_progress "ERROR|sync|oc-mirror sync failed after 3 retries"
	aba_progress "NEXT|Check registry connectivity: curl -k https://bastion.example.com:8443/v2/"
	aba_progress "NEXT|Review oc-mirror logs in mirror/data/"
	exit 1
fi

# Unexpected crash: script dies without emitting FAIL.
if [ -n "${SIMULATE_CRASH:-}" ]; then
	printf '\033[1;31m/usr/local/bin/oc-mirror: line 1: syntax error near unexpected token\033[0m\n' >&2
	printf '\033[1;31mError: oc-mirror exited with code 2\033[0m\n' >&2
	exit 2
fi

printf '\033[1;32m[ABA]\033[0m Sync complete.\n'
aba_progress "DONE|sync"

aba_progress "START|finalize"
printf '\033[1;34m[ABA]\033[0m Finalizing ...\n'
sleep 0.3
echo "       Updated state: last_action=sync, mirror_ocp_version=4.17.6"
printf '\033[1;32m[ABA]\033[0m Finalized.\n'
aba_progress "DONE|finalize"

# ─── Wait for the background download ────────────────────────────
if [ -n "$_bg_done_file" ]; then
	aba_progress "START|cli_wait"
	if [ -f "$_bg_done_file" ]; then
		printf '\033[1;32m[ABA]\033[0m CLI tools already ready.\n'
	else
		printf '\033[1;34m[ABA]\033[0m Waiting for CLI tools ...\n'
		while [ ! -f "$_bg_done_file" ]; do sleep 0.5; done
		printf '\033[1;32m[ABA]\033[0m CLI tools ready.\n'
	fi
	aba_progress "DONE|cli_dl"
	aba_progress "DONE|cli_wait"
fi

echo
printf '\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
printf '\033[1;32m  Images synced to bastion.example.com:8443\033[0m\n'
printf '\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
