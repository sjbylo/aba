# Folder containing Aba install bundles for OpenShift

Use these install bundles to install OpenShift into a fully disconnected (air-gapped) environment.

Content:

  "base"  - all files needed to install just OpenShift, no Operators included.
  "ocp"   - all files needed to install OpenShift and some useful Operators.
  "ocpv"  - OpenShift and Operators for OpenShift Virtualization.
  "ai"    - OpenShift and Operators for OpenShift AI.
  "opp"   - OpenShift and Operators for ACM, ACS and ODF.
  "mesh3" - OpenShift and Operators for Service Mesh v3.
  "sec"   - OpenShift and Operators for Security.

For all details, including bundle build log and test results, see the README.txt file in each bundle folder.

Should these bundles be missing important images and/or operators, please let us know at:
  https://github.com/sjbylo/aba/issues/new 
and we'll consider adding them to the bundle.

Read how to create your own custom install bundle here:
  https://github.com/sjbylo/aba/blob/main/README.md#creating-a-custom-install-bundle

