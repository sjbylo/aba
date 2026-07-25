FROM quay.io/centos/centos:stream9

# 1. Install sudo, git, and required tools
RUN dnf update -y && \
    dnf install -y sudo git curl tar gzip openssh-clients && \
    dnf clean all

# 2. Create non-root user (e.g., "dev")
RUN useradd -m -s /bin/bash dev

# 3. Grant passwordless sudo permissions to the user
RUN echo "dev ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/dev && \
    chmod 0440 /etc/sudoers.d/dev

# 4. Switch to the non-root user
USER dev
WORKDIR /workspace
