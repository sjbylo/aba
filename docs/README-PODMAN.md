# Running ABA from a Container Image

An alternative to the standard `aba bundle` tarball workflow.
Instead of unpacking ABA + installing RPMs on the disconnected bastion,
you build a container image on the connected side and transfer it as a
single file.  The disconnected bastion only needs **podman** installed.

## How it works

```
 CONNECTED HOST                       DISCONNECTED HOST
 ──────────────                       ─────────────────
 ABA repo + internet                  podman only

  1. aba -d mirror save                 4. podman load -i aba-image.tar
  2. podman build → aba:latest         5. place mirror tars in mirror/data/
  3. podman save  → aba-image.tar      6. edit mirror/mirror.conf
     transfer aba-image.tar ──────►    7. build/aba-run.sh
     transfer mirror_*.tar  ──────►         └─ aba -d mirror install  (Quay on host via SSH)
     transfer aba-transfer.tar ───►         └─ aba -d mirror load     (push images)
                                            └─ aba <cluster> install
```

The mirror registry runs on the **host**, not inside the container.
ABA inside the container SSHes back to the host to install and manage it.

## Step 1 — Save images (connected host)

```bash
cd ~/aba          # or wherever your ABA repo lives

# Edit aba.conf with your OCP version, operators, etc.
vim aba.conf

# Save images — downloads release + operator images into mirror/data/
aba -d mirror save
```

This produces:
- `mirror/data/mirror_*.tar` — image-set archives (the bulk of the data)
- `mirror/data/aba-transfer.tar` — metadata for incremental updates

## Step 2 — Build the container image (connected host)

```bash
cd ~/aba

# Match your host UID so bind-mounts work on the disconnected side
podman build --build-arg ABA_UID=$(id -u) \
       -t aba:latest -f build/Containerfile .

# Export to a portable tar
podman save aba:latest -o /tmp/aba-image.tar
```

The image (~4–5 GB) includes:
- UBI9 base + all required RPMs (make, jq, nmstate, skopeo, coreos-installer, ...)
- ABA repo with all scripts, Makefiles, and templates
- CLI tools (oc, oc-mirror, openshift-install, etc.)
- Mirror-registry installer tarball

It does **not** include the image-set archives — those are mounted at runtime.

## Step 3 — Transfer to the disconnected host

Move these files to the disconnected bastion (USB drive, SCP, sneakernet):

| File | From | Typical size |
|------|------|-------------|
| `aba-image.tar` | `/tmp/aba-image.tar` | ~4–5 GB |
| `mirror_*.tar` | `mirror/data/mirror_*.tar` | 2–50+ GB |
| `aba-transfer.tar` | `mirror/data/aba-transfer.tar` | small |

## Step 4 — Set up the disconnected host

### Load the container image

```bash
podman load -i /tmp/aba-image.tar
```

### Place the mirror tars

Create an ABA directory structure anywhere on the host and drop the tars in:

```bash
mkdir -p /opt/aba/mirror/data          # example — can be anywhere
cp mirror_000001.tar aba-transfer.tar /opt/aba/mirror/data/
```

### Configure mirror.conf

```bash
cat > /opt/aba/mirror/mirror.conf << 'EOF'
reg_host=bastion.example.com       # FQDN of THIS host
reg_port=8443
reg_path=/ocp4/openshift4
reg_user=init
reg_pw='yourpassword'
reg_vendor=auto
data_dir=

# ABA inside the container SSHes back to this host to install the registry
reg_ssh_key=~/.ssh/id_rsa
reg_ssh_user=steve
EOF
```

Replace `bastion.example.com` with your actual hostname,
and `steve` with your actual username.

### Ensure SSH access to yourself

ABA installs the registry on the host via SSH.  The container needs to
be able to SSH back to the host:

```bash
# Generate a key if you don't have one
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa

# Authorize it for localhost access
ssh-copy-id $(hostname)

# Verify
ssh $(hostname) echo ok
```

## Step 5 — Run ABA from the container

### Using the helper script

The easiest way — run from the ABA directory:

```bash
cd /opt/aba

# Interactive shell inside the container
build/aba-run.sh

# Or run a specific command directly
build/aba-run.sh aba -d mirror install
build/aba-run.sh aba -d mirror load
```

The script auto-detects the ABA repo root from its own location and
mounts `mirror/data/` and `mirror/mirror.conf` from the host.

### Manual podman run

If you prefer to run `podman` directly:

```bash
ABA_ROOT=/opt/aba   # wherever your ABA directory is
C_HOME=/home/aba    # must match ABA_USER in Containerfile (default: aba)

podman run --rm -it \
    --name aba \
    --network host \
    --privileged \
    --userns keep-id \
    -v "$HOME/.aba:$C_HOME/.aba:Z" \
    -v "$HOME/.ssh:$C_HOME/.ssh:ro" \
    -v "$ABA_ROOT/mirror/data:$C_HOME/aba/mirror/data:Z" \
    -v "$ABA_ROOT/mirror/mirror.conf:$C_HOME/aba/mirror/mirror.conf:ro" \
    -e "HOST_USER=$USER" \
    -e "HOST_HOME=$HOME" \
    aba:latest
```

### Inside the container

```bash
# Install the mirror registry (on the host, via SSH)
aba -d mirror install

# Load images into the registry
aba -d mirror load

# Create and install a cluster
aba sno --name mycluster
cd mycluster
vim cluster.conf    # set domain, IPs, etc.
aba install
```

## Podman flags explained

| Flag | Why |
|------|-----|
| `--network host` | ABA SSHes to the host; the registry listens on host ports |
| `--privileged` | Required for ISO generation (coreos-installer) and nmstate |
| `--userns keep-id` | Maps your host UID into the container so bind-mounts work |
| `-v ~/.aba:...` | Persistent ABA state (logs, runner) survives container restarts |
| `-v ~/.ssh:...:ro` | SSH keys for registry installation (read-only) |
| `-v mirror/data:...` | Image-set archives — kept outside the image to avoid huge layers |
| `-v mirror.conf:...:ro` | Your registry configuration |

## Environment variables

The helper script (`build/aba-run.sh`) and manual `podman run` accept
these overrides:

| Variable | Default | Description |
|----------|---------|-------------|
| `ABA_IMAGE` | `aba:latest` | Container image name |
| `ABA_DATA` | `<repo>/mirror/data` | Host path to image-set archives |
| `ABA_CONF` | `<repo>/mirror/mirror.conf` | Host path to mirror.conf |
| `ABA_STATE` | `~/.aba` | Host path to persistent ABA state |
| `ABA_CONTAINER_USER` | `aba` | Container username (must match `ABA_USER` build arg) |

## Incremental updates (day 2)

To add operators or upgrade OCP later:

1. **Connected host**: update `aba.conf`, run `aba -d mirror save` again
2. **Transfer** the new `mirror_*.tar` + `aba-transfer.tar`
3. **Disconnected host** (from the container):
   ```bash
   aba -d mirror load
   aba day2
   ```

## Troubleshooting

### "Permission denied" on SSH

Ensure your SSH key is authorized:
```bash
ssh-copy-id $(hostname)
```

If the Quay installer's internal key is stale, remove it and let
the installer regenerate:
```bash
rm -f ~/.ssh/quay_installer ~/.ssh/quay_installer.pub
```

### "manifest unknown" during load

The `aba-transfer.tar` and `mirror_*.tar` files must come from the
**same** `aba save` run.  A version mismatch between the metadata
and the image archives causes this error.

### Registry health-check retries

After `aba -d mirror install`, the Quay health check retries for up to
3 minutes.  A few "FAILED - RETRYING" messages are normal — Quay
needs time to start.

### UID mismatch on bind-mounts

If files inside the container show as owned by `nobody`, rebuild
the image with your UID:
```bash
podman build --build-arg ABA_UID=$(id -u) \
       -t aba:latest -f build/Containerfile .
```
