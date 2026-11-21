#!/usr/bin/env bash
# Unit: e2e code-update coverage ("all suites passed since last code update")
# Tier: unit (no network, no pools)
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
exec test/e2e/scripts/test-code-coverage.sh
