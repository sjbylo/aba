# Release Highlights — 1.2.2

- Non-root users no longer blocked by sudo gate; password-based sudo works throughout (thanks @msalmanmasood, [#36](https://github.com/sjbylo/aba/issues/36))
- Docker registry containers now survive host reboot (podman-restart.service enabled)
- Upgrade path validation now checks that a complete path exists from your current version to the target, catching unreachable targets early
- TUI login no longer contaminates kubeconfig with expiring tokens
- CLI download retries improved (3 attempts with backoff) for flaky networks
- New `aba ssh --all` flag for running commands across all cluster nodes
- KVM VM creation now verifies boot success and warns on host resource overcommit
- KVM: Open vSwitch bridge support via new `KVM_NETWORK_OPTS` config option (thanks @msalmanmasood, [#37](https://github.com/sjbylo/aba/discussions/37))
- TUI "Prepare Upgrade" offers a "set target only" option (skip immediate download)
