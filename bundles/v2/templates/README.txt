╔══════════════════════════════════════════════════════════════════════╗
   ABA Install Bundle for OpenShift v<VERSION>                        
   Created: <DATETIME>                                                
   Size:     <SIZE>
   ABA:      v<ABA_VERSION>
   Platform: x86_64
   http://github.com/sjbylo/aba                                       
╚══════════════════════════════════════════════════════════════════════╝

─── CONTENTS ──────────────────────────────────────────────────────────

  - OpenShift binaries:
    - <PRIMARY_CLIS>
  - Mirror registry installers:
      mirror/mirror-registry.tar.gz  (Quay)
      mirror/docker-reg-image.tgz   (Docker)
  - Supporting tools:
    - <SECONDARY_CLIS>
  - Operators included in this bundle (see list below)
  - Image set config: imageset-config.yaml (see below)

─── TEST RESULTS ──────────────────────────────────────────────────────

This install bundle has been tested.

<TEST_RESULTS>

See the build folder for full test logs and the test script used.

─── QUICK START ───────────────────────────────────────────────────────

  DISK SPACE: The bastion host needs approximately 3-4x the bundle
  size (~<SIZE> x 3) for unpacked content, oc-mirror cache, and
  mirror registry images.

  1. Transfer the bundle files to the disconnected environment.

  2. Verify integrity:

       ./VERIFY.sh

  3. Unpack:

       ./UNPACK.sh [destination-dir]

  4. Install and configure ABA:

       cd <destination-dir>/aba
       ./install
       aba                                          # CLI workflow
       abatui                                       # Or use the interactive TUI

  5. Load images into a mirror registry:

       aba -d mirror load -H registry.example.com   # Install Quay & load images
       aba load -h                                  # Read under "Examples ..."

  6. Install OpenShift:

       aba cluster --name sno --type sno            # Create cluster config
       cd sno
       aba                                          # Install the cluster

       aba cluster -h                               # See all cluster options

  See ABA's full documentation:
  https://github.com/sjbylo/aba/blob/main/README.md

════════════════════════════════════════════════════════════════════════
