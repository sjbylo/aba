#!/usr/bin/env bash
# Test: Comprehensive input validation for ALL ABA config value types
# Covers accept + reject for: cluster/mirror names, domains, FQDNs, usernames,
# passwords, IPv4, CIDR, IP lists, NTP lists, MACs, ports, paths, vendors,
# image_source, operator names. Complements test-normalize-ipv4.sh (canonicalization)
# and test-reserved-name-validation.sh (reserved dirs).
# Tier: unit (no network)

cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=/dev/null
source scripts/include_all.sh noerr

pass=0
fail=0
_pass() { pass=$(( pass + 1 )); printf "  \033[32mPASS\033[0m  %s\n" "$*"; }
_fail() { fail=$(( fail + 1 )); printf "  \033[31mFAIL\033[0m  %s\n" "$*"; }

# Expect validator to succeed (rc=0). Output ignored unless want_out set.
_ok() {
	local desc="$1" fn="$2" input="$3"
	local rc=0
	"$fn" "$input" >/dev/null 2>&1 || rc=$?
	if [ "$rc" -eq 0 ]; then
		_pass "$desc"
	else
		_fail "$desc (input='$input' expected accept, rc=$rc)"
	fi
}

# Expect validator to fail (rc!=0).
_bad() {
	local desc="$1" fn="$2" input="$3"
	local rc=0
	"$fn" "$input" >/dev/null 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		_pass "$desc"
	else
		_fail "$desc (input='$input' expected reject)"
	fi
}

echo "=== cluster / mirror names ==="
_ok  "cluster: sno" _valid_cluster_name "sno"
_ok  "cluster: e2e-compact4" _valid_cluster_name "e2e-compact4"
_ok  "cluster: a" _valid_cluster_name "a"
_ok  "cluster: a1b2" _valid_cluster_name "a1b2"
_bad "cluster: empty" _valid_cluster_name ""
_bad "cluster: Upper" _valid_cluster_name "SNO"
_bad "cluster: leading digit" _valid_cluster_name "1sno"
_bad "cluster: underscore" _valid_cluster_name "my_cluster"
_bad "cluster: trailing hyphen" _valid_cluster_name "sno-"
_bad "cluster: reserved mirror" _valid_cluster_name "mirror"
_bad "cluster: reserved scripts" _valid_cluster_name "scripts"
_ok  "mirror: mirror (allowed)" _valid_mirror_name "mirror"
_ok  "mirror: myreg" _valid_mirror_name "myreg"
_bad "mirror: reserved cli" _valid_mirror_name "cli"
_bad "mirror: Upper" _valid_mirror_name "Mirror"

echo
echo "=== domain (_valid_domain) ==="
_ok  "domain: example.com" _valid_domain "example.com"
_ok  "domain: lab" _valid_domain "lab"
_ok  "domain: p4.example.com" _valid_domain "p4.example.com"
_ok  "domain: my_lab" _valid_domain "my_lab"
_ok  "domain: lab.internal" _valid_domain "lab.internal"
_bad "domain: empty" _valid_domain ""
_bad "domain: leading hyphen" _valid_domain "-lab.com"
_bad "domain: trailing hyphen label" _valid_domain "lab-.com"
_bad "domain: spaces" _valid_domain "ex ample.com"

echo
echo "=== domain (validate_domain TUI) ==="
_ok  "validate_domain: example.com" validate_domain "example.com"
_ok  "validate_domain: single label" validate_domain "lab"
_bad "validate_domain: empty" validate_domain ""
_bad "validate_domain: .." validate_domain "a..b"
_bad "validate_domain: leading dot" validate_domain ".example.com"
_bad "validate_domain: underscore (TUI stricter)" validate_domain "my_lab"

echo
echo "=== FQDN (_valid_fqdn — reg_host) ==="
_ok  "fqdn: registry.example.com" _valid_fqdn "registry.example.com"
_ok  "fqdn: con4.example.com" _valid_fqdn "con4.example.com"
_ok  "fqdn: a.b" _valid_fqdn "a.b"
_bad "fqdn: single label" _valid_fqdn "registry"
_bad "fqdn: empty" _valid_fqdn ""
_bad "fqdn: trailing dot" _valid_fqdn "registry.example.com."
_bad "fqdn: IP address" _valid_fqdn "10.0.2.40"

echo
echo "=== username ==="
_ok  "user: steve" _valid_username "steve"
_ok  "user: _svc" _valid_username "_svc"
_ok  "user: reg.user-1" _valid_username "reg.user-1"
_bad "user: empty" _valid_username ""
_bad "user: leading digit" _valid_username "1admin"
_bad "user: space" _valid_username "ste ve"
_bad "user: slash" _valid_username "ste/ve"

echo
echo "=== password ==="
_ok  "pw: long enough" _valid_password "abcdefgh"
_ok  "pw: mixed" _valid_password "S3cure!Pass"
_bad "pw: short" _valid_password "abcdefg"
_bad "pw: space" _valid_password "abcd efgh"
_bad "pw: single quote" _valid_password "abcd'efgh"
_bad "pw: double quote" _valid_password 'abcd"efgh'
_bad "pw: backtick" _valid_password 'abcd`efgh'
_bad "pw: dollar" _valid_password 'abcd$efgh'

echo
echo "=== IPv4 / CIDR / lists ==="
_ok  "ipv4: 10.0.2.43" _valid_ipv4 "10.0.2.43"
_ok  "ipv4: leading zeros accepted" _valid_ipv4 "10.0.0.08"
_ok  "validate_ip: 192.168.1.1" validate_ip "192.168.1.1"
_bad "ipv4: 256" _valid_ipv4 "10.0.0.256"
_bad "ipv4: empty" _valid_ipv4 ""
_ok  "cidr: 10.0.0.0/20" validate_cidr "10.0.0.0/20"
_ok  "cidr: leading-zero form" validate_cidr "010.0.0.0/08"
_bad "cidr: /33" validate_cidr "10.0.0.0/33"
_ok  "ip list: two" validate_ip_list "10.0.2.40,8.8.4.4"
_bad "ip list: one bad" validate_ip_list "10.0.2.40,999.1.1.1"
_bad "ip list: empty" validate_ip_list ""

echo
echo "=== NTP servers ==="
_ok  "ntp: pool + IP" validate_ntp_servers "pool.ntp.org,10.0.1.8"
_ok  "ntp: single label" validate_ntp_servers "ntp"
_ok  "ntp: chrony host" validate_ntp_servers "time.google.com"
_bad "ntp: empty" validate_ntp_servers ""
_bad "ntp: bad token" validate_ntp_servers "10.0.1.8,bad_host!"

echo
echo "=== MAC / port / path ==="
_ok  "mac: colon hex" _valid_mac "00:50:56:ab:cd:ef"
_ok  "mac: uppercase" _valid_mac "AA:BB:CC:DD:EE:FF"
_bad "mac: placeholder" _valid_mac "xx:xx:xx:xx:xx:xx"
_bad "mac: hyphen form" _valid_mac "00-50-56-ab-cd-ef"
_bad "mac: short" _valid_mac "00:50:56:ab:cd"
_ok  "port: ens160" _valid_port_name "ens160"
_ok  "port: eth0.10" _valid_port_name "eth0.10"
_bad "port: slash" _valid_port_name "ens/160"
_bad "port: empty" _valid_port_name ""
_ok  "path: /var/lib/aba" _valid_abs_path "/var/lib/aba"
_ok  "path: ~/data" _valid_abs_path "~/data"
_ok  "path: /" _valid_abs_path "/"
_bad "path: relative" _valid_abs_path "var/lib"
_bad "path: spaces" _valid_abs_path "/var/my dir"

echo
echo "=== vendors / image_source / operators ==="
_ok  "reg_vendor: quay" _valid_reg_vendor "quay"
_ok  "reg_vendor: existing" _valid_reg_vendor "existing"
_ok  "reg_vendor: omr" _valid_reg_vendor "$_OMR_VENDOR"
_bad "reg_vendor: bogus" _valid_reg_vendor "podman"
_ok  "cli_vendor: docker" _valid_cli_vendor "docker"
_bad "cli_vendor: existing (internal)" _valid_cli_vendor "existing"
_ok  "image_source: direct" _valid_image_source "direct"
_ok  "image_source: proxy" _valid_image_source "proxy"
_ok  "image_source: mirror dir" _valid_image_source "mirror"
_ok  "image_source: custom dir" _valid_image_source "my-mirror.1"
_bad "image_source: slash" _valid_image_source "a/b"
# Format-only for operators (index lookup may warn but format still returns 0/1)
_ok  "operator: acm style" _valid_operator_name "advanced-cluster-management"
_ok  "operator: leading digit" _valid_operator_name "3scale-operator"
_bad "operator: Upper" _valid_operator_name "ACM"
_bad "operator: underscore" _valid_operator_name "my_op"

echo
echo "=== normalize round-trip (spot) ==="
got=$(normalize_ipv4 "10.0.0.08") || got=FAIL
[ "$got" = "10.0.0.8" ] && _pass "normalize_ipv4 spot" || _fail "normalize_ipv4 spot got=$got"
got=$(normalize_cidr "010.0.0.0/08") || got=FAIL
[ "$got" = "10.0.0.0/8" ] && _pass "normalize_cidr spot" || _fail "normalize_cidr spot got=$got"
got=$(normalize_uint "08") || got=FAIL
[ "$got" = "8" ] && _pass "normalize_uint spot" || _fail "normalize_uint spot got=$got"

echo
echo "Results: $pass passed, $fail failed"
exit "$fail"
