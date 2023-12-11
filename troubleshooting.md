# Troubleshooting 

Try these commands to discover any problems with the installation of OCP using the Agent-based method.

Ssh to the rendezvous server:

```
make ssh
# This will run `ssh core@<ip of rendezvous server>`

[core@master1 ~]$ journalctl -u assisted-service.service -f 
Nov 19 02:14:31 master1 systemd[1]: Starting Assisted Service container...
Nov 19 02:14:31 master1 podman[2600]: Trying to pull quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:042248d2950dab0cb12163bfa021ce5c980b828feeb33080eec24accd5fb8adc...
Nov 19 02:14:31 master1 podman[2600]: Getting image source signatures
Nov 19 02:14:31 master1 podman[2600]: Copying blob sha256:516e4391bf00c004b3f333b2f8649982ce9dbb7f0e30405b5c10bf67b7c573bc
Nov 19 02:14:31 master1 podman[2600]: Copying blob sha256:97da74cc6d8fa5d1634eb1760fd1da5c6048619c264c23e62d75f3bf6b8ef5c4
Nov 19 02:14:31 master1 podman[2600]: Copying blob sha256:225bb0746beb8f28f6f4fadfba9a75debd4628e3c9c95956eca922f82f956d9b
Nov 19 02:14:31 master1 podman[2600]: Copying blob sha256:d8190195889efb5333eeec18af9b6c82313edd4db62989bd3a357caca4f13f0e
Nov 19 02:14:31 master1 podman[2600]: Copying blob sha256:43e3075e6dc816f272ecb9a69965e9e05b2938bfada8eec974e6ab4ab9de65f3
...

Started Assisted Service container
```

- Be sure the Assisted Service image can be pulled and started.

If it fails the log will show:

```
Nov 23 09:31:53 master1 systemd[1]: Starting Assisted Service container...
Nov 23 09:31:53 master1 podman[2424]: Trying to pull quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:d28c9adc6863eb1d3983d15f5da41a91d39bc7c5493092006f95d7acd2463fe6...
Nov 23 09:31:56 master1 podman[2424]: Error: initializing source docker://quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:d28c9adc6863eb1d3983d15f5da41a91d39bc7c5493092006f95d7acd2463fe6: reading manifest sha256:d28c9adc6863eb1d3983d15f5da41a91d39bc7c5493092006f95d7acd2463fe6 in quay.io/openshift-release-dev/ocp-v4.0-art-dev: unauthorized: access to the requested resource is not authorized
Nov 23 09:31:56 master1 systemd[1]: assisted-service.service: Main process exited, code=exited, status=125/n/a
Nov 23 09:31:56 master1 systemd[1]: Dependency failed for Assisted Service container.
Nov 23 09:31:56 master1 systemd[1]: assisted-service.service: Job assisted-service.service/start failed with result 'dependency'.
Nov 23 09:31:56 master1 systemd[1]: assisted-service.service: Failed with result 'exit-code'.
Nov 23 09:31:56 master1 systemd[1]: assisted-service.service: Scheduled restart job, restart counter is at 1.
Nov 23 09:31:56 master1 systemd[1]: Stopped Assisted Service container.
```


If the image cannot be pulled from the registry:

```
unauthorized: access to the requested resource is not authorized
```

Be sure the InfraEnv is properly set:

```
Successfully registered InfraEnv ocp1 with id
```

Be sure the release image can be pulled:

```
[core@master1 ~]$   journalctl -b -u release-image.service -f
Nov 19 02:18:18 master1 systemd[1]: Starting Download the OpenShift Release Image...
Nov 19 02:18:18 master1 release-image-download.sh[5747]: Pulling quay.io/openshift-release-dev/ocp-release@sha256:f8ba6f54eae419aba17926417d950ae18e06021beae9d7947a8b8243ad48353a...
Nov 19 02:18:18 master1 release-image-download.sh[5853]: 0adedea0b5eac1a9f85b61c904bd73060cea4718dae98ee1fb8a3af444067a0d
Nov 19 02:18:19 master1 systemd[1]: Finished Download the OpenShift Release Image.
```

During bootkube installation:

```
[core@master1 ~]$   journalctl -b -u bootkube.service -f
```

It is normal to see warnings, errors and failure messages.  

Typical errors:
- "unable to get REST mapping for ..."
- "no matches for kind ..." 
- "Failed to create ..."

But, after 5-10 mins you should see more positive messages:

```
Nov 19 02:27:06 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-scheduler/openshift-kube-scheduler        DoesNotExist
Nov 19 02:27:06 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-controller-manager/kube-controller-manager        DoesNotExist
Nov 19 02:27:06 master1 bootkube.sh[10004]:         Pod Status:openshift-cluster-version/cluster-version-operator        Pending
Nov 19 02:27:06 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-apiserver/kube-apiserver        DoesNotExist
```

Installation progressing:

```
Nov 19 02:38:46 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-apiserver/kube-apiserver        Pending
Nov 19 02:38:46 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-scheduler/openshift-kube-scheduler        RunningNotReady
Nov 19 02:38:46 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-controller-manager/kube-controller-manager        DoesNotExist
Nov 19 02:38:46 master1 bootkube.sh[10004]:         Pod Status:openshift-cluster-version/cluster-version-operator        Ready
```

Installation of bookkube complete:
```
Nov 19 02:39:21 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-apiserver/kube-apiserver        Ready
Nov 19 02:39:21 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-scheduler/openshift-kube-scheduler        Ready
Nov 19 02:39:21 master1 bootkube.sh[10004]:         Pod Status:openshift-kube-controller-manager/kube-controller-manager        Ready
Nov 19 02:39:21 master1 bootkube.sh[10004]:         Pod Status:openshift-cluster-version/cluster-version-operator        Ready
```

... successs!

Then, the log will show the following: 

```
Nov 19 02:39:21 master1 bootkube.sh[10004]: All self-hosted control plane components successfully started
Nov 19 02:39:21 master1 bootkube.sh[10004]: Waiting for 2 masters to join        0 masters joined the cluster
Nov 19 02:39:26 master1 bootkube.sh[10004]:         Master master2 joined the cluster                                                                                    
Nov 19 02:39:26 master1 bootkube.sh[10004]:         Master master3 joined the cluster                                                                                    
Nov 19 02:39:26 master1 bootkube.sh[10004]:         2 masters joined the cluster
Nov 19 02:39:26 master1 bootkube.sh[10004]: All self-hosted control plane components successfully started
Nov 19 02:39:26 master1 bootkube.sh[10004]: Sending bootstrap-success event. Waiting for remaining assets to be created.
```

## Other problems that might happen during mirroring: 

oc mirror fails with error "invalid mirror sequence order"
https://access.redhat.com/solutions/7026766

