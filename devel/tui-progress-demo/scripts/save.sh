#!/bin/bash
# save.sh — Main save workflow script (equivalent of reg-save.sh)
# Runs AFTER Make prerequisites (.init, .rpmsext, ISC, preflight).
#
# Env vars control test modes:
#   SKIP_ASK=1       — skip the interactive prompt
#   SKIP_OC_MIRROR=1 — simulate mirror with sleep (fast)
#   SIMULATE_FAIL=1  — fail during catalog step

source "$(dirname "$0")/progress.sh"

ask() {
	aba_progress "PROMPT|$1"
	read -rp "$1" _reply
	aba_progress "PROMPT_DONE|"
	echo "$_reply"
}

# ─── Ask to continue (unless skipped) ───
if [ -z "${SKIP_ASK:-}" ]; then
	printf '\033[1;33m[ABA]\033[0m Total images to mirror: 47 (estimated 12.3 GiB)\n'
	_answer=$(ask "[ABA] Continue with mirroring? (y/N): ")
	_answer="${_answer,,}"
	if [[ "$_answer" != "y" && "$_answer" != "yes" ]]; then
		printf '\033[1;31m[ABA]\033[0m Aborted by user.\n'
		aba_progress "ABORT|Aborted by user"
		exit 0
	fi
	echo
fi

# ─── Mirror step ───
aba_progress "START|mirror"
printf '\033[1;34m[ABA]\033[0m Mirroring images (oc-mirror)\n'

if [ -n "${SKIP_OC_MIRROR:-}" ]; then
	# Fast mode: simulate oc-mirror
	echo "       [demo: simulating oc-mirror]"
	sleep 1.5
	echo "       Mirrored 47 images (12.3 GiB)"
	aba_progress "DONE|mirror"
	printf '\033[1;32m[ABA]\033[0m Mirror — OK\n\n'
else
	# Real oc-mirror with UBI image
	_work_dir=$(mktemp -d "${ABA_DEMO_TMP:-/tmp}/aba-demo-mirror.XXXXXX")
	cat > "$_work_dir/imageset-config.yaml" <<'ISC'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  additionalImages:
  - name: registry.access.redhat.com/ubi9/ubi-micro:latest
ISC

	echo "       Using ISC: $_work_dir/imageset-config.yaml"
	echo "       Image: registry.access.redhat.com/ubi9/ubi-micro:latest"
	echo

	oc-mirror --config "$_work_dir/imageset-config.yaml" \
		file://"$_work_dir/output" \
		--v2 2>&1

	_rc=$?
	rm -rf "$_work_dir"

	if [ $_rc -eq 0 ]; then
		aba_progress "DONE|mirror"
		printf '\033[1;32m[ABA]\033[0m Mirror — OK\n\n'
	else
		aba_progress "FAIL|mirror"
		aba_progress "ERROR|mirror|oc-mirror failed (rc=$_rc)"
		exit 1
	fi
fi

# ─── Catalog step ───
aba_progress "START|catalog"
printf '\033[1;34m[ABA]\033[0m Building operator catalog\n'
sleep 0.5; echo "       Processing redhat-operator-index"
sleep 0.4; echo "       Filtering 12 operators from 287 available"

if [ -n "${SIMULATE_FAIL:-}" ]; then
	sleep 0.5
	printf '\033[1;31m[ABA] Error: Failed to push catalog to mirror.example.com:8443\033[0m\n' >&2
	printf '\033[1;31m       error: denied: requested access to the resource is denied\033[0m\n' >&2
	printf '\033[1;31m       error: unable to push catalog image\033[0m\n' >&2
	echo >&2
	aba_progress "FAIL|catalog"
	aba_progress "ERROR|catalog|Failed to push catalog: access denied"
	aba_progress "DETAIL|error: denied: requested access to the resource is denied"
	aba_progress "DETAIL|error: unable to push catalog image"
	aba_progress "NEXT|Check registry credentials: podman login mirror.example.com:8443"
	aba_progress "NEXT|Verify registry is writable: skopeo list-tags docker://mirror.example.com:8443/test"
	aba_progress "NEXT|Review mirror.conf: reg_ssh_user, reg_host, reg_port"
	exit 1
fi

sleep 0.5; echo "       Pushing catalog to mirror.example.com:8443"
aba_progress "DONE|catalog"
printf '\033[1;32m[ABA]\033[0m Catalog — OK\n\n'

# ─── Verify step ───
aba_progress "START|verify"
printf '\033[1;34m[ABA]\033[0m Verifying mirror content\n'
sleep 0.4; echo "       Checking release image: 4.22.3 — present"
sleep 0.3; echo "       Checking upgrade path: 4.22.3 → 4.22.6 — present"
sleep 0.3; echo "       Checking operator catalog — present"
sleep 0.3; echo "       All content verified"
aba_progress "DONE|verify"
printf '\033[1;32m[ABA]\033[0m Verify — OK\n\n'

echo
printf '\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
printf '\033[1;32m  ABA Mirror completed successfully!\033[0m\n'
printf '\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
