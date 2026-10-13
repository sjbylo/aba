#!/bin/bash
# Without a blob index: platform + one catalog + sum(archive - catalog), then +5%.
# With a blob index: platform + each registry blob once. A missing operator
# uses the median of the measured operators' own blobs.

set -u
cd "$(dirname "$0")/../.."

fail=0
check() {
	local name=$1
	local got=$2
	local want=$3
	if [ "$got" = "$want" ]; then
		echo "  PASS: $name"
	else
		echo "  FAIL: $name (got $got want $want)"
		fail=$((fail + 1))
	fi
}

GIB=$((1024 * 1024 * 1024))
CATALOG=$((44 * GIB / 10))
PLATFORM=$((22 * GIB))
pad() {
	echo $(( $1 * 105 / 100 ))
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

run() {
	# shellcheck disable=SC2046
	eval "$(scripts/estimate-isc-size.sh --shell --sizes-dir "$tmp/sizes" --isc "$1")"
}

mkdir -p "$tmp/sizes"

echo "=== platform only ==="
cat > "$tmp/platform.yaml" << 'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
    - name: stable-4.22
      minVersion: 4.22.15
      maxVersion: 4.22.15
EOF
run "$tmp/platform.yaml"
check "platform bytes" "$platform_bytes" "$PLATFORM"
check "no catalog without operators" "$catalog_bytes" "0"
check "platform estimate is +5%" "$estimate_bytes" "$(pad "$PLATFORM")"
check "no operators estimated" "$estimated" "0"
# Save, sync, and load place this one number. They do not recompute it.
check "save archive is the estimate" "$save_archive_bytes" "$estimate_bytes"
check "save cache is the estimate" "$save_cache_bytes" "$estimate_bytes"
check "sync writes no archive" "$sync_archive_bytes" "0"
check "sync writes no cache" "$sync_cache_bytes" "0"
check "sync registry is the estimate" "$sync_registry_bytes" "$estimate_bytes"
check "load archive is already on disk" "$load_archive_bytes" "0"
check "load cache is the estimate" "$load_cache_bytes" "$estimate_bytes"
check "load registry is the estimate" "$load_registry_bytes" "$estimate_bytes"

echo "=== one known operator at the catalog floor ==="
printf '%s\n' "floor-operator $CATALOG" > "$tmp/sizes/redhat-operator-v4.22-amd64"
cat > "$tmp/one.yaml" << 'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
    - name: stable-4.22
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.22
    packages:
    - name: floor-operator
      channels:
      - name: stable
EOF
run "$tmp/one.yaml"
check "catalog counted once" "$catalog_bytes" "$CATALOG"
check "floor operator adds no extra" "$excess_bytes" "0"
check "known count" "$known" "1"
raw=$((PLATFORM + CATALOG))
check "floor total +5%" "$estimate_bytes" "$(pad "$raw")"

echo "=== missing operator uses the median extra ==="
{
	echo "small-op $((CATALOG + 100))"
	echo "mid-op $((CATALOG + 300))"
	echo "big-op $((CATALOG + 500))"
} > "$tmp/sizes/redhat-operator-v4.22-amd64"
cat > "$tmp/missing.yaml" << 'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.22
    packages:
    - name: not-measured
      channels:
      - name: stable
EOF
run "$tmp/missing.yaml"
check "missing excess is median 300" "$excess_bytes" "300"
check "missing counted" "$estimated" "1"
check "missing name" "$estimated_operators" "not-measured"
check "no platform in this ISC" "$platform_bytes" "0"
raw=$((CATALOG + 300))
check "missing total +5%" "$estimate_bytes" "$(pad "$raw")"

echo "=== duplicate operator is counted once ==="
cat > "$tmp/dup.yaml" << 'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.22
    packages:
    - name: small-op
      channels:
      - name: stable
    - name: small-op
      channels:
      - name: stable
EOF
run "$tmp/dup.yaml"
check "duplicate excess is 100 not 200" "$excess_bytes" "100"
check "duplicate known once" "$known" "1"

echo "=== mesh3 extra matches the real bundle delta within 5% ==="
# Kiali and Service Mesh 3 are the only operators mesh3 adds over ocp.
# Measured archives, and the mirror-tar difference 67.08 - 53.26 GiB.
KIALI=6832551936
MESH=17351147008
ACTUAL=$((1382 * GIB / 100))
printf '%s\n' "kiali-ossm $KIALI" "servicemeshoperator3 $MESH" > "$tmp/sizes/redhat-operator-v4.22-amd64"
cat > "$tmp/mesh.yaml" << 'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.22
    packages:
    - name: kiali-ossm
      channels:
      - name: stable
    - name: servicemeshoperator3
      channels:
      - name: stable
EOF
run "$tmp/mesh.yaml"
check "mesh extras both known" "$known" "2"
check "mesh extras none estimated" "$estimated" "0"
delta=$((excess_bytes > ACTUAL ? excess_bytes - ACTUAL : ACTUAL - excess_bytes))
pct=$((delta * 100 / ACTUAL))
if [ "$pct" -le 5 ]; then
	echo "  PASS: mesh extra within 5% (excess $excess_bytes actual $ACTUAL pct $pct)"
else
	echo "  FAIL: mesh extra off by ${pct}% (excess $excess_bytes actual $ACTUAL)"
	fail=$((fail + 1))
fi

echo "=== second catalog is charged once more ==="
printf '%s\n' "floor-operator $CATALOG" > "$tmp/sizes/redhat-operator-v4.22-amd64"
rm -f "$tmp/sizes/certified-operator-v4.22-amd64"
cat > "$tmp/two.yaml" << 'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.22
    packages:
    - name: floor-operator
      channels:
      - name: stable
  - catalog: registry.redhat.io/redhat/certified-operator-index:v4.22
    packages:
    - name: gpu-operator-certified
      channels:
      - name: stable
EOF
run "$tmp/two.yaml"
check "two catalogs" "$catalog_bytes" "$((CATALOG * 2))"
check "certified operator estimated" "$estimated" "1"
# No certified size file: missing extra falls back to 1 GiB.
check "fallback extra is 1 GiB" "$excess_bytes" "$GIB"

echo "=== shared blobs are counted once ==="
mkdir -p "$tmp/sizes"
cat > "$tmp/sizes/redhat-operator-v4.22-amd64.blobs" << 'EOF'
alpha	shared	1000
alpha	onlya	100
beta	shared	1000
beta	onlyb	400
EOF
cat > "$tmp/share.yaml" << 'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.22
    packages:
    - name: alpha
      channels:
      - name: stable
    - name: beta
      channels:
      - name: stable
EOF
run "$tmp/share.yaml"
check "shared union is 1500 not 2600" "$estimate_bytes" "1500"
check "shared raw has no pad" "$estimate_bytes_raw" "1500"
check "shared pad is off" "$pad_percent" "0"
check "catalog layer counted once" "$catalog_bytes" "1000"
check "operator bytes are the private layers" "$excess_bytes" "500"
check "both operators known" "$known" "2"

echo "=== missing operator adds the median private size ==="
cat > "$tmp/guess.yaml" << 'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.22
    packages:
    - name: gamma
      channels:
      - name: stable
EOF
run "$tmp/guess.yaml"
# Private sizes are 100 and 400, so the guess is 250. Catalog is added once.
check "guess is catalog plus median private" "$estimate_bytes" "1250"
check "guess counted" "$estimated" "1"
check "guess name" "$estimated_operators" "gamma"

echo "=== named extra images are added, unknown ones are not ==="
printf '%s\n' "registry.example/guest:1 5000" > "$tmp/sizes/additional-images"
cat > "$tmp/img.yaml" << 'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  additionalImages:
  - name: registry.example/guest:1
  - name: registry.example/already-in-platform:1
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.22
    packages:
    - name: alpha
      channels:
      - name: stable
EOF
run "$tmp/img.yaml"
check "guest image bytes" "$additional_bytes" "5000"
check "alpha plus guest, no pad" "$estimate_bytes" "6100"

echo "=== stale blob snapshot versus operators after they change ==="
# The blob file is a snapshot. Each case runs that snapshot, then a file
# that matches the operators after the change. The gap is the whole effect.
cat > "$tmp/pair.yaml" << 'EOF'
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  operators:
  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.22
    packages:
    - name: alpha
      channels:
      - name: stable
    - name: beta
      channels:
      - name: stable
EOF
pair_blobs() {
	cat > "$tmp/sizes/redhat-operator-v4.22-amd64.blobs"
	run "$tmp/pair.yaml"
}

echo "--- both rebuilt, old digest still listed for both ---"
pair_blobs << 'EOF'
alpha	cat	50
alpha	oldshared	1000
alpha	onlya	100
beta	cat	50
beta	oldshared	1000
beta	onlyb	400
EOF
stale=$estimate_bytes
pair_blobs << 'EOF'
alpha	cat	50
alpha	newshared	1100
alpha	onlya	100
beta	cat	50
beta	newshared	1100
beta	onlyb	400
EOF
check "stale rebuild still counts the layer once" "$stale" "1550"
check "fresh rebuild still counts the layer once" "$estimate_bytes" "1650"
check "stale rebuild misses only the growth" "$((estimate_bytes - stale))" "100"

echo "--- one operator moved on, the other kept the old layer ---"
pair_blobs << 'EOF'
alpha	cat	50
alpha	oldshared	1000
alpha	onlya	100
beta	cat	50
beta	oldshared	1000
beta	onlyb	400
EOF
stale=$estimate_bytes
pair_blobs << 'EOF'
alpha	cat	50
alpha	moved	1000
alpha	onlya	100
beta	cat	50
beta	oldshared	1000
beta	onlyb	400
EOF
check "one moved on, stale file still shares the layer" "$((estimate_bytes - stale))" "1000"

echo "--- two operators start sharing a layer the snapshot lists twice ---"
pair_blobs << 'EOF'
alpha	cat	50
alpha	olda	800
alpha	onlya	100
beta	cat	50
beta	oldb	800
beta	onlyb	400
EOF
stale=$estimate_bytes
pair_blobs << 'EOF'
alpha	cat	50
alpha	newshare	800
alpha	onlya	100
beta	cat	50
beta	newshare	800
beta	onlyb	400
EOF
check "newly shared layer, stale file counts it twice" "$((stale - estimate_bytes))" "800"

echo "--- a known operator gained a layer the snapshot does not list ---"
pair_blobs << 'EOF'
alpha	cat	50
alpha	oldshared	1000
alpha	onlya	100
beta	cat	50
beta	oldshared	1000
beta	onlyb	400
EOF
stale=$estimate_bytes
pair_blobs << 'EOF'
alpha	cat	50
alpha	oldshared	1000
alpha	onlya	100
alpha	newbig	5000
beta	cat	50
beta	oldshared	1000
beta	onlyb	400
EOF
check "missing new layer is absent from the stale total" "$((estimate_bytes - stale))" "5000"

echo "=== measured bundles stay within 1% of the mirror tar ==="
# These lists are the operators in the 4.22.15 ocp, mesh3, and opp bundles.
# The mirror tar sizes are 53.26, 67.08, and 113.60 GiB.
bundle_isc() {
	local out=$1
	shift
	{
		echo "kind: ImageSetConfiguration"
		echo "apiVersion: mirror.openshift.io/v2alpha1"
		echo "mirror:"
		echo "  platform:"
		echo "    channels:"
		echo "    - name: stable-4.22"
		echo "  operators:"
		echo "  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.22"
		echo "    packages:"
		for op in "$@"; do
			echo "    - name: $op"
		done
	} > "$out"
}
within_one() {
	local name=$1
	local actual=$2
	local got=$3
	local delta=$((got > actual ? got - actual : actual - got))
	if [ $((delta * 100)) -le "$actual" ]; then
		echo "  PASS: $name within 1% (estimate $got actual $actual)"
	else
		echo "  FAIL: $name off by more than 1% (estimate $got actual $actual)"
		fail=$((fail + 1))
	fi
}
OCP_OPS="cincinnati-operator cli-manager cluster-kube-descheduler-operator devworkspace-operator kubernetes-nmstate-operator lightspeed-operator node-healthcheck-operator node-maintenance-operator redhat-oadp-operator web-terminal"
MESH_OPS="$OCP_OPS kiali-ossm servicemeshoperator3"
OPP_OPS="advanced-cluster-management cephcsi-operator cincinnati-operator cli-manager cluster-kube-descheduler-operator compliance-operator container-security-operator devworkspace-operator file-integrity-operator gatekeeper-operator-product kubernetes-nmstate-operator lightspeed-operator local-storage-operator lvms-operator mcg-operator multicluster-engine node-healthcheck-operator node-maintenance-operator ocs-client-operator ocs-operator ocs-tls-profiles odf-csi-addons-operator odf-dependencies odf-external-snapshotter-operator odf-operator odf-prometheus-operator odr-cluster-operator odr-hub-operator openshift-cert-manager-operator openshift-external-secrets-operator openshift-zero-trust-workload-identity-manager policy-controller-operator recipe redhat-oadp-operator rhacs-operator rhbk-operator rhtas-operator rhtpa-operator rook-ceph-operator secrets-store-csi-driver-operator security-profiles-operator submariner web-terminal"
# shellcheck disable=SC2086
bundle_isc "$tmp/bundle-ocp.yaml" $OCP_OPS
# shellcheck disable=SC2086
bundle_isc "$tmp/bundle-mesh.yaml" $MESH_OPS
# shellcheck disable=SC2086
bundle_isc "$tmp/bundle-opp.yaml" $OPP_OPS
eval "$(scripts/estimate-isc-size.sh --shell --isc "$tmp/bundle-ocp.yaml")"
within_one "ocp bundle" $((5326 * GIB / 100)) "$estimate_bytes"
eval "$(scripts/estimate-isc-size.sh --shell --isc "$tmp/bundle-mesh.yaml")"
within_one "mesh3 bundle" $((6708 * GIB / 100)) "$estimate_bytes"
eval "$(scripts/estimate-isc-size.sh --shell --isc "$tmp/bundle-opp.yaml")"
within_one "opp bundle" $((11360 * GIB / 100)) "$estimate_bytes"

# virt adds guest disk images on top of the same platform and operator union.
VIRT_OPS="cephcsi-operator cincinnati-operator cli-manager cluster-kube-descheduler-operator devworkspace-operator fence-agents-remediation kubernetes-nmstate-operator kubevirt-hyperconverged lightspeed-operator local-storage-operator lvms-operator mcg-operator metallb-operator mtv-operator node-healthcheck-operator node-maintenance-operator ocs-client-operator ocs-operator ocs-tls-profiles odf-csi-addons-operator odf-dependencies odf-external-snapshotter-operator odf-operator odf-prometheus-operator odr-cluster-operator odr-hub-operator recipe redhat-oadp-operator rook-ceph-operator self-node-remediation volsync-product web-terminal"
VIRT_IMAGES="registry.redhat.io/rhel9/rhel-guest-image:latest registry.redhat.io/rhel10/rhel-guest-image:latest quay.io/containerdisks/centos-stream:10 quay.io/containerdisks/centos-stream:9 quay.io/containerdisks/fedora:latest"
{
	echo "kind: ImageSetConfiguration"
	echo "apiVersion: mirror.openshift.io/v2alpha1"
	echo "mirror:"
	echo "  platform:"
	echo "    channels:"
	echo "    - name: stable-4.22"
	echo "  additionalImages:"
	for img in $VIRT_IMAGES; do
		echo "  - name: $img"
	done
	echo "  operators:"
	echo "  - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.22"
	echo "    packages:"
	for op in $VIRT_OPS; do
		echo "    - name: $op"
	done
} > "$tmp/bundle-virt.yaml"
eval "$(scripts/estimate-isc-size.sh --shell --isc "$tmp/bundle-virt.yaml")"
within_one "virt bundle" $((10320 * GIB / 100)) "$estimate_bytes"

echo
if [ "$fail" -eq 0 ]; then
	echo "ALL PASSED"
	exit 0
fi
echo "$fail FAILED"
exit 1
