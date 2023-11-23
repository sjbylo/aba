# Installing j2cli onto RHEL 8

This is the only way i could find to install j2 onto RHEL 8.  Install this before running aba.
- From: https://snapcraft.io/install/j2/rhel

Set up EPEL:

```
sudo dnf install https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
sudo dnf upgrade
```

```
sudo yum install snapd

sudo systemctl enable --now snapd.socket

sudo ln -s /var/lib/snapd/snap /snap

sudo snap install j2
```

Then run these to put j2 into your $PATH

```
mkdir -p ~/bin
ln -s /snap/bin/j2 ~/bin
```

