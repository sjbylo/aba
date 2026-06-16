# Quay Pasta Hairpin: Default Route Required

**Date**: March 2026

## Problem

After installing the Quay mirror registry on a host that has been taken
offline (no default route), the ansible health check fails:

```
curl: (35) OpenSSL SSL_connect: Connection reset by peer
  in connection to bastion.example.com:8443
```

The registry is healthy — external machines (e.g. a laptop) can reach
`https://bastion.example.com:8443/health/instance` and get a 200 response.
`localhost:8443` also works from the host itself.  Only the **host connecting
to its own external IP/hostname** fails.

## Root Cause

Quay runs as a rootless podman pod using **pasta** networking.  Pasta maps
host ports into the pod's network namespace.  When the host connects to its
own external IP (a "hairpin" connection), pasta needs a valid default route
in the host's routing table to set up the return path.  Without one, the
TCP handshake completes but the TLS negotiation is reset.

In the bundle-creation pipeline, `05-go-offline.sh` disconnects the internet
interface (`ens4`) via `int_down`, which removes the only default route.
The lab/internal interface (`ens3`, e.g. 10.0.1.5) remains up but has no
default route — only a connected route for the 10.0.0.0/20 subnet.  When
`06b-install-registry.sh` installs Quay, the pod is created in this
no-default-route state.  Pasta initialises its routing when the pod starts,
and without a default route it cannot handle hairpin connections.

**What works and what doesn't in this state:**

| Path                          | Result  | Why                                        |
|-------------------------------|---------|--------------------------------------------|
| `curl localhost:8443`         | OK      | Loopback, no pasta involved                |
| `curl 10.0.1.5:8443`         | FAIL    | Hairpin through pasta, no default route     |
| `curl bastion.example.com:8443` | FAIL  | Same — hostname resolves to 10.0.1.5       |
| From external machine         | OK      | Incoming traffic, pasta forwards normally  |

## Fix

Add a temporary default route via the internal gateway **before** Quay is
installed, then remove it afterwards.  The gateway does not need to reach the
internet — pasta only needs a default route to exist when the pod is created.

In `bundles/v2/phases/06b-install-registry.sh`:

```bash
sudo ip route add default via $GATEWAY_IP dev ens3

aba -d mirror install -H $TEST_HOST

sudo ip route del default via $GATEWAY_IP dev ens3
```

`GATEWAY_IP` (e.g. `10.0.1.1`) is defined in `bundle.conf`.

After the route is removed, the pod continues to work because pasta's
internal state was initialised while the route was present.

## How to Diagnose

If a Quay install fails with "Connection reset by peer" from the host itself:

1. Check for a default route: `ip route show default`
   - If empty, this is the problem.
2. Verify external access works: from another machine, `curl -k https://HOST:8443/v2/`
3. Verify localhost works: `curl -k https://localhost:8443/v2/`
4. If external and localhost work but host-to-own-IP fails, add a temp route:
   ```bash
   sudo ip route add default via <gateway> dev <interface>
   ```
5. Restart the pod so pasta re-initialises with the route:
   ```bash
   systemctl --user restart quay-pod.service
   sleep 30
   curl -k https://HOST:8443/health/instance
   ```

## Key Takeaway

Pasta requires a default route at pod-creation time to handle hairpin
(host-to-self) connections.  In offline/disconnected environments, always
ensure a default route exists before starting rootless podman pods that
need to be accessed via the host's own IP.
