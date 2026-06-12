# Session State

## Current goal
Preparing for s390x (LinuxONE) testing run.

## Done this session
- Reviewed existing s390x test documentation (`ai/s390x-test-report.md` from May 6, 2026)
- Summarized the test procedure and known quirks for the user

## Next steps
- User to provision a LinuxONE Community Cloud instance
- Run s390x test sequence following the documented procedure
- Update test report with new results

## Decisions / notes
- Last s390x test: May 6, 2026 -- all 9 tests passed
- Key quirks: polkit needed for Quay, network interface has space in name, dig not available
- README has LinuxONE FAQ at line ~1533
