#!/bin/bash
# CatalogSource naming when a bundle carries operator catalogs of two OCP minors
# (upgrade mode). Catalogs of one family must get distinct names, the catalog of
# the cluster's minor keeps the standard name. Unit test, no network (skopeo is stubbed).

set -eo pipefail

cd "$(dirname "$0")/../.."

source scripts/include_all.sh

fail=0
check() {
	local name=$1 want=$2 got=$3
	if [ "$got" = "$want" ]; then
		echo "PASS: $name"
	else
		echo "FAIL: $name (want '$want', got '$got')"
		fail=1
	fi
}

echo "=== catalog_source_name ==="
check "single catalog keeps standard name" "redhat-operators" \
	"$(catalog_source_name redhat-operators 4.21 4.20 1 sha256-69ac9)"
check "single catalog, unknown minor" "redhat-operators" \
	"$(catalog_source_name redhat-operators "" 4.20 1 sha256-69ac9)"
check "two minors, cluster minor keeps standard name" "redhat-operators" \
	"$(catalog_source_name redhat-operators 4.20 4.20 2 sha256-cbb01)"
check "two minors, other minor suffixed" "redhat-operators-v4-21" \
	"$(catalog_source_name redhat-operators 4.21 4.20 2 sha256-69ac9)"
check "two minors, certified family" "certified-operators-v4-21" \
	"$(catalog_source_name certified-operators 4.21 4.20 2 sha256-b29f9)"
check "two minors, unknown minor falls back to file id" "redhat-operators-sha256-69ac9" \
	"$(catalog_source_name redhat-operators "" 4.20 2 sha256-69ac9)"
check "major 5" "redhat-operators-v5-0" \
	"$(catalog_source_name redhat-operators 5.0 4.23 2 sha256-12345)"

echo "=== catalog_source_preferred_minor ==="
check "cluster minor present" "4.20" "$(catalog_source_preferred_minor 4.20 4.21 4.20)"
check "cluster upgraded" "4.21" "$(catalog_source_preferred_minor 4.21 4.20 4.21)"
check "cluster minor absent, lowest wins" "4.20" "$(catalog_source_preferred_minor 4.19 4.21 4.20)"
check "version sort, not string sort" "4.9" "$(catalog_source_preferred_minor 4.8 4.10 4.9)"
check "unknown minors ignored" "4.20" "$(catalog_source_preferred_minor 4.19 "" 4.21 4.20)"
check "no cluster minor" "4.20" "$(catalog_source_preferred_minor "" 4.21 4.20)"

echo "=== catalog_image_minor ==="
check "tag ref" "4.21" "$(catalog_image_minor registry.example.com:8443/redhat/redhat-operator-index:v4.21)"
check "tag ref major 5" "5.0" "$(catalog_image_minor registry.example.com:8443/redhat/redhat-operator-index:v5.0)"

# Stub skopeo: print the catalog label for digest refs, fail for anything else
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT
cat > "$stub_dir/skopeo" <<'EOF'
#!/bin/bash
for a in "$@"; do last=$a; done
echo "$*" >> "$(dirname "$0")/calls"
case "$last" in
	*@sha256:4200*) echo "v4.20" ;;
	*@sha256:nolabel*) echo "<no value>" ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$stub_dir/skopeo"
_old_path=$PATH
PATH="$stub_dir:$PATH"

check "digest ref, label read" "4.20" "$(catalog_image_minor registry.example.com:8443/redhat/redhat-operator-index@sha256:4200aa)"
check "digest ref, no label" "" "$(catalog_image_minor registry.example.com:8443/redhat/redhat-operator-index@sha256:nolabel)"
check "digest ref, inspect fails" "" "$(catalog_image_minor registry.example.com:8443/redhat/redhat-operator-index@sha256:dead)"

echo "{}" > "$stub_dir/auth.json"
echo "dummy" > "$stub_dir/rootCA.pem"
catalog_image_minor registry.example.com:8443/redhat/redhat-operator-index@sha256:4200aa "$stub_dir/auth.json" "$stub_dir/rootCA.pem" >/dev/null
grep -q -- "--authfile $stub_dir/auth.json" "$stub_dir/calls" && echo "PASS: authfile passed to skopeo" || { echo "FAIL: authfile not passed to skopeo"; fail=1; }
grep -q -- "--cert-dir" "$stub_dir/calls" && echo "PASS: CA passed to skopeo" || { echo "FAIL: CA not passed to skopeo"; fail=1; }
PATH=$_old_path

echo "=== day2.sh wiring ==="
grep -q 'catalog_source_name ' scripts/day2.sh && echo "PASS: day2 uses catalog_source_name" || { echo "FAIL: day2 does not use catalog_source_name"; fail=1; }
grep -q 'catalog_image_minor ' scripts/day2.sh && echo "PASS: day2 uses catalog_image_minor" || { echo "FAIL: day2 does not use catalog_image_minor"; fail=1; }

exit "$fail"
