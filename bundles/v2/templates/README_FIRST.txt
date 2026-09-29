╔══════════════════════════════════════════════════════════════════════╗
   ABA Install Bundles for OpenShift (x86_64)
   http://github.com/sjbylo/aba
╚══════════════════════════════════════════════════════════════════════╝

Select one of the install bundles below to install OpenShift into a
fully disconnected (air-gapped) environment.

  IMPORTANT: Only ONE bundle can be used at a time. They cannot be
  combined. To include different operators or images, create your own
  custom install bundle (see link below).

─── AVAILABLE BUNDLES ─────────────────────────────────────────────────

  "release"  - OpenShift only, no Operators.               (~26 GB)
  "ocp"      - OpenShift + useful day-2 Operators.         (~38 GB)
  "mesh3"    - OpenShift + Service Mesh v3 Operators.      (~51 GB)
  "virt"     - OpenShift + OCP Virtualization + ODF.       (~98 GB)
  "opp"      - OpenShift + ACM, ACS, and ODF Operators.   (~120 GB)
  "ai"       - OpenShift + OpenShift AI + GPU Operators.  (~608 GB)

  For full details, including build logs and test results, see the
  README.txt file inside each bundle folder.

─── CUSTOM BUNDLES ────────────────────────────────────────────────────

  Should these bundles be missing important images or operators,
  please let us know:
    https://github.com/sjbylo/aba/issues/new

  Create your own custom install bundle:
    https://github.com/sjbylo/aba/blob/main/README.md#custom-bundles

════════════════════════════════════════════════════════════════════════
