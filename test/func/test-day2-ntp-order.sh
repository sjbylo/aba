#!/bin/bash
# Day-2 NTP checks the API before it writes chrony files.
# Does not run day2-config-ntp.sh.

set -eo pipefail

cd "$(dirname "$0")/../.."

api=$(grep -n 'cluster_api_reachable' scripts/day2-config-ntp.sh | head -1 | cut -d: -f1)
who=$(grep -n 'oc whoami' scripts/day2-config-ntp.sh | head -1 | cut -d: -f1)
write=$(grep -n 'cat > .99-master-chrony-conf-override.bu' scripts/day2-config-ntp.sh | head -1 | cut -d: -f1)

fail=0
if [ -n "$api" ] && [ -n "$who" ] && [ -n "$write" ] \
	&& [ "$api" -lt "$write" ] && [ "$who" -lt "$write" ]; then
	echo "PASS: API check is before the chrony files are written"
else
	echo "FAIL: API check is not before the chrony write (api=$api who=$who write=$write)"
	fail=1
fi

exit "$fail"
