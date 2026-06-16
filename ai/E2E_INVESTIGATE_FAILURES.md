# Investigating E2E Suite Failures

When a suite fails (shown as FAIL in `./run.sh status` or in the Done list):

1. **Identify pool and suite**  
   From status: which conN ran the suite and the suite name.

2. **Fetch logs from that conN**  
   ```bash
   ssh steve@conN.example.com 'tail -200 ~/aba/test/e2e/logs/<suite>-latest.log'
   ssh steve@conN.example.com 'tail -80 ~/aba/test/e2e/logs/<suite>-summary.log'
   ```
   Replace `<suite>` with e.g. create-bundle-to-disk, airgapped-local-reg.

3. **Find the failing step**  
   Look for the last FAIL, "Attempt ... FAILED", or the command that exited non-zero in the log.

4. **Fix**  
   Prefer fixing ABA core or test/suite logic under test/e2e/ (suites, lib, run.sh, runner.sh).  
   Avoid band-aids: fix root cause (e.g. wait for resources, correct command, or add retries with appropriate backoff).

5. **Redeploy and re-run**  
   ```bash
   cd test/e2e
   ./run.sh deploy --pools N
   ./run.sh reschedule --suite NAME
   ```
   Or after `./run.sh stop`, run again with `./run.sh run --suite NAME --pools N -y`.

## Log locations on conN

- `~/aba/test/e2e/logs/<suite>-latest.log` — full suite log
- `~/aba/test/e2e/logs/<suite>-summary.log` — progress table
- `~/aba/test/e2e/logs/summary.log` — symlink to current suite summary
