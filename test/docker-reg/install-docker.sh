# Install docker 

rpm -q dnf-plugins-core 		|| sudo dnf install -y dnf-plugins-core
[ -s /etc/yum.repos.d/docker-ce.repo ]	|| sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
rpm -q docker-ce			|| sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Make docker run as non-root
grep ^docker /etc/group || sudo groupadd docker || true
sudo usermod -aG docker $USER
newgrp docker || true

sudo systemctl start docker
sudo systemctl enable docker

