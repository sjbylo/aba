#!/bin/bash -e
set -o pipefail
# Standalone summary of an AgentConfig file.
#
# A cluster directory may contain agent-config-summary*.sh. Those are examples
# of the shape only. This script does not call them.
# The file is read with yaml2json from include_all.sh and summarized with jq,
# the same split as scripts/cluster-config.sh.
#
# Usage: scripts/agent-config-summary.sh [-s|-v] [agent-config.yaml]
#   default   Compact: cluster, gateway, DNS/NTP, IPs, MACs, NICs
#   -s        Short, and disk hints
#   -v        One block per node
#
# Run it from anywhere. The default file is ./agent-config.yaml.

LEVEL=very
FILE=agent-config.yaml

usage() {
	printf 'Usage: %s [-s|-v] [agent-config.yaml]\n' "$(basename "$0")"
	printf '  default  Compact summary\n'
	printf '  -s       Short summary, including disk hints\n'
	printf '  -v       Per-node summary\n'
}

while [ $# -gt 0 ]; do
	case "$1" in
		-s|--short) LEVEL=short ;;
		-v|--verbose|-l|--long) LEVEL=long ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*)
			printf 'ERROR: Unknown option: %s\n' "$1" >&2
			exit 1
			;;
		*) FILE=$1 ;;
	esac
	shift
done

if [ ! -f "$FILE" ]; then
	printf 'ERROR: AgentConfig file not found: %s\n' "$FILE" >&2
	exit 1
fi

_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$_dir/include_all.sh"

if ! command -v jq >/dev/null 2>&1; then
	printf 'ERROR: jq is required.\n' >&2
	exit 1
fi

_filter=$(cat <<'JQ'
def parts:
  if type != "string" then null
  else
    ((try capture("^(?<p>.*?)(?<n>\\d+)$") catch null) // null) as $m
    | if $m == null then null else [$m.p, ($m.n | tonumber)] end
  end;

# Order kept. jq's unique sorts, which would reshuffle DNS and NIC names.
def uniq:
  reduce .[] as $x ([]; if index($x) != null then . else . + [$x] end);

def compress_names:
  . as $all
  | def go($i; $acc):
      if $i >= ($all | length) then ($acc | join(", "))
      else
        ($all[$i] | parts) as $m
        | if $m == null then go($i + 1; $acc + [$all[$i]])
          else
            (
              reduce range($i + 1; $all | length) as $j ({last: $m[1], j: $i};
                if .j != ($j - 1) then .
                else
                  ($all[$j] | parts) as $n
                  | if $n == null or $n[0] != $m[0] or $n[1] != (.last + 1) then .
                    else .last = $n[1] | .j = $j
                    end
                end
              )
            ) as $run
            | if $run.j == $i then go($i + 1; $acc + [$all[$i]])
              else go($run.j + 1; $acc + [$m[0] + ($m[1] | tostring) + "-" + ($run.last | tostring)])
              end
          end
      end;
  if length == 0 then "-" else go(0; []) end;

def compress_pairs:
  . as $all
  | def go($i; $acc):
      if $i >= ($all | length) then ($acc | join("; "))
      else
        $all[$i] as $cur
        | ($cur[0] | parts) as $am
        | ($cur[1] | parts) as $vm
        | if $am == null or $vm == null then go($i + 1; $acc + [$cur[0] + "=" + $cur[1]])
          else
            (
              reduce range($i + 1; $all | length) as $j ({lastn: $am[1], lastv: $vm[1], j: $i};
                if .j != ($j - 1) then .
                else
                  ($all[$j][0] | parts) as $an
                  | ($all[$j][1] | parts) as $vn
                  | if $an == null or $vn == null
                      or $an[0] != $am[0] or $vn[0] != $vm[0]
                      or $an[1] != (.lastn + 1) or $vn[1] != (.lastv + 1)
                    then .
                    else .lastn = $an[1] | .lastv = $vn[1] | .j = $j
                    end
                end
              )
            ) as $run
            | if $run.j == $i then go($i + 1; $acc + [$cur[0] + "=" + $cur[1]])
              else
                go($run.j + 1; $acc + [
                  $am[0] + ($am[1] | tostring) + "-" + ($run.lastn | tostring)
                  + " "
                  + $vm[0] + ($vm[1] | tostring) + "-" + ($run.lastv | tostring)
                ])
              end
          end
      end;
  if length == 0 then "" else go(0; []) end;

def show($xs):
  ($xs | map(select(. != null and . != "")) | uniq) as $u
  | if ($u | length) == 0 then "-" else $u | join(", ") end;

def findkey($k):
  recurse(if type == "object" or type == "array" then .[]? else empty end)
  | objects
  | select(has($k))
  | .[$k];

def strings_of($k):
  [findkey($k) | if type == "array" then .[] else . end | select(type == "string")]
  | uniq;

def addr:
  if type == "object" then
    if .ip != null and .["prefix-length"] != null then "\(.ip)/\(.["prefix-length"])"
    elif .ip != null then "\(.ip)"
    else empty
    end
  elif type == "string" then .
  else empty
  end;

def nodes:
  . as $root
  | reduce range(0; ($root.hosts // []) | length) as $i
      ({M: 0, W: 0, N: 0, list: []};
        ($root.hosts[$i]) as $h
        | ($h.role // "unknown") as $role
        | (if $role == "master" then "M" elif $role == "worker" then "W" else ($role[0:1] | ascii_upcase) end) as $p
        | (if $p == "M" then .M += 1 elif $p == "W" then .W += 1 else .N += 1 end) as $st
        | ($st[$p]) as $n
        | $st
        | .list += [(
            $h
            | . as $host
            | {
                hostname: ($host.hostname // "?"),
                role: $role,
                alias: ($p + ($n | tostring)),
                macs: (
                  reduce (
                    (
                      (($host.interfaces // [])[]? | select(type == "object") | {name: (.name // "?"), mac: (.macAddress // .["mac-address"] // "")}),
                      (($host.networkConfig.interfaces // [])[]? | select(type == "object") | {name: (.name // "?"), mac: (.["mac-address"] // .macAddress // "")})
                    )
                    | select(.mac != "")
                  ) as $m ({}; .[$m.name] = $m.mac)
                ),
                ifaces: [($host.networkConfig.interfaces // [])[]? | .name // "?"],
                ips: [($host.networkConfig.interfaces // [])[]? | (.ipv4.address // [])[]?, (.ipv6.address // [])[]? | addr],
                bonds: [
                  ($host.networkConfig.interfaces // [])[]?
                  | select(.type == "bond")
                  | . as $nic
                  | ($nic["link-aggregation"].mode // null) as $mode
                  | ($nic["link-aggregation"].port // []) as $ports
                  | ($nic.name // "bond")
                    + (if $mode != null then "(\($mode))" else "" end)
                    + (if ($ports | length) > 0 then ":" + ($ports | map(tostring) | join(",")) else "" end)
                ],
                dhcp: [
                  ($host.networkConfig.interfaces // [])[]?
                  | . as $nic
                  | if ($nic.ipv4.enabled == true and $nic.ipv4.dhcp == true) then "\($nic.name):v4" else empty end,
                  if ($nic.ipv6.enabled == true and $nic.ipv6.dhcp == true) then "\($nic.name):v6" else empty end
                ],
                gateways: ($host.networkConfig | strings_of("next-hop-address")),
                dns: ($host.networkConfig | strings_of("server")),
                disks: ($host.rootDeviceHints // null)
              }
          )]
      )
  | .list;

def per_node($nodes; $key):
  [ $nodes[] | .alias as $a | (.[$key] // [])[] | [$a, .] ] as $pairs
  | ([$pairs[][1]] | uniq) as $distinct
  | if ($distinct | length) <= 1 then show($distinct)
    else ($pairs | compress_pairs)
    end;

def ip_line($nodes):
  reduce $nodes[] as $n ({order: [], g: {}, meta: {}};
    reduce ($n.ips // [])[] as $ip (.;
      ((try ($ip | capture("^(?<a>[0-9]+)\\.(?<b>[0-9]+)\\.(?<c>[0-9]+)\\.(?<d>[0-9]+)/(?<p>[0-9]+)$")) catch null) // null) as $c
      | if $c == null then
          (if (.g.other | type) != "array" then .order += ["other"] | .g.other = [] else . end)
          | .g.other += [[$n.alias, $ip]]
        else
          ($c.a + "." + $c.b + "." + $c.c + "/" + $c.p) as $key
          | (if (.g[$key] | type) != "array" then .order += [$key] | .g[$key] = [] else . end)
          | .g[$key] += [[$n.alias, "." + $c.d]]
          | .meta[$key] = ($c.a + "." + $c.b + "." + $c.c + ".x/" + $c.p)
        end
    )
  )
  | . as $s
  | if ($s.order | length) == 0 then "-"
    else
      [ $s.order[] |
          if . == "other" then ($s.g[.] | compress_pairs)
          else ($s.meta[.] + ": " + ($s.g[.] | compress_pairs))
          end
      ] | join(" | ")
    end;

def mac_line($nodes):
  reduce $nodes[] as $n ({order: [], g: {}, other: []};
    reduce ($n.macs | to_entries[]) as $e (.;
      ($e.value | ascii_downcase) as $mac
      | ($mac | split(":")) as $p
      | if ($p | length) == 6 and all($p[]; test("^[0-9a-f]{2}$")) then
          ($e.key + " " + ($p[0:5] | join(":")) + ":xx") as $key
          | (if (.g[$key] | type) != "array" then .order += [$key] | .g[$key] = [] else . end)
          | .g[$key] += [[$n.alias, $p[5]]]
        else
          .other += [$n.alias + ":" + $e.key + "=" + $e.value]
        end
    )
  )
  | . as $s
  | ([$s.order[] | . + " " + ($s.g[.] | compress_pairs)] + $s.other) as $bits
  | if ($bits | length) == 0 then "-" else $bits | join(" | ") end;

def role_line($nodes):
  ([$nodes[] | select(.role == "master") | .hostname]) as $m
  | ([$nodes[] | select(.role == "worker") | .hostname]) as $w
  | ([
      (if ($m | length) > 0 then "\($m | length) masters (\($m | compress_names))" else empty end),
      (if ($w | length) > 0 then "\($w | length) workers (\($w | compress_names))" else empty end)
    ] | join(", "));

def summary:
  . as $root
  | nodes as $nodes
  | ($root.metadata.name // "-") as $cluster
  | ($root.rendezvousIP // "-") as $rv
  | role_line($nodes) as $roles
  | per_node($nodes; "gateways") as $gw
  | per_node($nodes; "dns") as $dns
  | show($root.additionalNTPSources // []) as $ntp
  | (if $dns == $ntp then "DNS/NTP: " + $dns else "DNS: " + $dns + " | NTP: " + $ntp end) as $dnsntp
  | ip_line($nodes) as $ips
  | mac_line($nodes) as $macs
  | show([$nodes[].ifaces[]]) as $nics
  | show([$nodes[].bonds[]]) as $bonds
  | show([ $nodes[] | .alias as $a | .dhcp[]? | $a + ":" + . ]) as $dhcp
  | (
      [
        (if $root.apiVIPs then "api=" + ($root.apiVIPs | tojson) else empty end),
        (if $root.ingressVIPs then "ingress=" + ($root.ingressVIPs | tojson) else empty end)
      ] | show(.)
    ) as $vip
  | if $level == "short" then
      [
        ($cluster + " | " + $roles + " | RV: " + $rv),
        ("IP:  " + $ips),
        ("MAC: " + $macs),
        ("GW: " + $gw + " | " + $dnsntp),
        ("NIC: " + $nics + " | Bond: " + $bonds + " | DHCP: " + $dhcp + " | VIP: " + $vip),
        ("CPU: " + show([$root | findkey("cpuArchitecture") | if type == "array" then .[] else . end | select(type == "string")]) + " | Disks: " + (
          [ $nodes[] | select(.disks != null) | .alias + "=" + (.disks | tojson) ] | show(.)
        ))
      ] | join("\n")
    elif $level == "long" then
      (
        [
          "",
          ("AGENT CONFIGURATION: " + $file),
          ("=" * 75),
          ($cluster + " | " + $roles + " | RV: " + $rv),
          ""
        ]
        + [
            $nodes[] |
            [
              (.hostname + " [" + .role + "] (" + .alias + ")"),
              ("  IP:          " + show(.ips)),
              ("  MAC:         " + show([.macs | to_entries[] | .key + "=" + .value])),
              ("  Interfaces:  " + show(.ifaces)),
              ("  Gateway:     " + show(.gateways)),
              ("  DNS:         " + show(.dns)),
              ("  DHCP:        " + show(.dhcp)),
              ("  Bonds:       " + show(.bonds)),
              (if .disks != null then "  Root disk:   " + (.disks | tojson) else empty end),
              ""
            ][]
          ]
        + [
            "CLUSTER SETTINGS",
            ("-" * 75),
            ("NTP:           " + $ntp),
            ("API VIPs:      " + show($root.apiVIPs // [])),
            ("Ingress VIPs:  " + show($root.ingressVIPs // [])),
            ("CPU:           " + show([$root | findkey("cpuArchitecture") | if type == "array" then .[] else . end | select(type == "string")])),
            ("Disks:         " + show([$nodes[] | select(.disks != null) | .alias + "=" + (.disks | tojson)])),
            ("=" * 75)
          ]
      ) | join("\n")
    else
      [
        ($cluster + " | " + $roles + " | RV: " + $rv + " | GW: " + $gw + " | " + $dnsntp),
        ("IP:  " + $ips),
        ("MAC: " + $macs),
        ("NET: " + $nics + " | Bond: " + $bonds + " | DHCP: " + $dhcp + " | VIP: " + $vip)
      ] | join("\n")
    end;

summary

JQ
)
yaml2json < "$FILE" | jq -r --arg level "$LEVEL" --arg file "$FILE" "$_filter"
