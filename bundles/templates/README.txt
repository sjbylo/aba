# Aba install bundle for OpenShift v<VERSION>

This Aba install bundle was created on: <DATETIME>

Content of this OpenShift install bundle:

- List of Operators in this install bundle (see below):
- The imageset-config.yaml file shows the image sets contained in this bundle (see below).
- CLI Install files:
  - <CLIS>
- Installation file for Quay Mirror Registry: mirror/mirror-registry.tar.gz
- Installation file for Docker Registry: mirror/docker-reg-image.tgz
- Scripts to install/configure mirror reg. and install OpenShift.


This install bundle has been tested. 
See the files in the build folder for all test results, full log
of the bundle build/test and this install bundle's test script.


# How to use this install bundle

Download and transfer all bundle files to a RHEL 8 or 9 bastion host in the *disconnected environment*.

## Verify integrity of all archive files:

./VERIFY.sh

## Unpack with:

./UNPACK.sh [destination directory]

or run:

cat ocp_<VERSION>* | tar -C <destination-dir> -xvf -


## If unpacking is successful, install and run aba:

cd <destination-dir>/aba
./install 
aba                                                               # Follow the instructions.
                                                                  # Verify all parameters aba.conf are set correctly.


## Install & load Quay with the images (either local or remote):

aba load --retry 8 -H registry.example.com                        # Replace with your registry's FQDN which
                                                                  # normally points to the default local IP address.
aba load --retry 8 -H registry.example.com -k ~/.ssh/id_rsa       # Install Quay on a *remote* host using your ssh key.

aba load -h                                                       # See more options.


## Example of installing OpenShift:

aba cluster --name sno --type sno                                 # Init sno/cluster.conf file, then follow instructions.
cd sno
aba                                                               # Install OpenShift, follow instructions.

aba cluster -h                                                    # See help on how to install a cluster.

## See Aba's README.md for help:
https://github.com/sjbylo/aba/blob/main/README.md
