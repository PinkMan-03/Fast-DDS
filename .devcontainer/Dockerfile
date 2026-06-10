# =============================================================================
# Fast DDS Learning Dev Container
# -----------------------------------------------------------------------------
# Base : Ubuntu 24.04 LTS (Tier 1 supported)
# Tools: gcc-13.2 (default in 24.04), cmake, ninja, ccache, colcon, vcstool
# Deps : asio, tinyxml2, openssl, libp11 (DDS Security)
# =============================================================================

ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

LABEL maintainer="fastdds-learner"
LABEL description="Fast DDS development environment (Tier 1)"

# -----------------------------------------------------------------------------
# 1) Avoid interactive prompts during apt-get
# -----------------------------------------------------------------------------
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# -----------------------------------------------------------------------------
# 2) Install system dependencies in a single layer to keep image small
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install --no-install-recommends -y \
    # ---- Build toolchain (gcc-13.2 is default on 24.04) -----------------
    build-essential \
    cmake \
    ninja-build \
    ccache \
    pkg-config \
    # ---- Source control --------------------------------------------------
    git \
    git-lfs \
    ca-certificates \
    openssh-client \
    # ---- Python (for colcon / vcstool) -----------------------------------
    python3 \
    python3-pip \
    python3-venv \
    python3-setuptools \
    # ---- Fast DDS core dependencies --------------------------------------
    libasio-dev \
    libtinyxml2-dev \
    libssl-dev \
    # ---- Fast DDS Security (optional but useful) -------------------------
    libp11-dev \
    libengine-pkcs11-openssl \
    softhsm2 \
    # ---- Network tools (for DDS debugging) -------------------------------
    iproute2 \
    iputils-ping \
    net-tools \
    tcpdump \
    # ---- Editors & shell utilities --------------------------------------
    vim \
    nano \
    less \
    tree \
    htop \
    tmux \
    curl \
    wget \
    unzip \
    # ---- Debug tools ----------------------------------------------------
    gdb \
    valgrind \
    strace \
    # ---- Documentation tools --------------------------------------------
    doxygen \
    graphviz \
    # ---- Misc -----------------------------------------------------------
    sudo \
    locales \
    bash-completion \
    zsh \
 && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 3) Configure locale (UTF-8)
# -----------------------------------------------------------------------------
RUN locale-gen en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# -----------------------------------------------------------------------------
# 4) Install colcon + vcstool (Python tools for workspace management)
# -----------------------------------------------------------------------------
RUN pip3 install --no-cache-dir --break-system-packages \
    colcon-common-extensions \
    vcstool

# -----------------------------------------------------------------------------
# 5) Create a non-root dev user (UID/GID overridable via build args)
# -----------------------------------------------------------------------------
ARG USER_NAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

RUN if getent group ${USER_GID} >/dev/null; then \
        groupmod -n ${USER_NAME} $(getent group ${USER_GID} | cut -d: -f1); \
    else \
        groupadd --gid ${USER_GID} ${USER_NAME}; \
    fi \
 && if getent passwd ${USER_UID} >/dev/null; then \
        usermod -l ${USER_NAME} -d /home/${USER_NAME} -m -s /bin/bash $(getent passwd ${USER_UID} | cut -d: -f1); \
    else \
        useradd --uid ${USER_UID} --gid ${USER_GID} -m -s /bin/bash ${USER_NAME}; \
    fi \
 && echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER_NAME} \
 && chmod 0440 /etc/sudoers.d/${USER_NAME}

# -----------------------------------------------------------------------------
# 6) Configure ccache for faster rebuilds (cache persisted via volume)
# -----------------------------------------------------------------------------
ENV PATH=/usr/lib/ccache:${PATH}
ENV CCACHE_DIR=/home/${USER_NAME}/.ccache

# -----------------------------------------------------------------------------
# 7) Pre-create workspace directories owned by the dev user
#    (NOTE: these get shadowed at runtime by docker-compose named volumes;
#    entrypoint.sh re-chowns them on every container start.)
# -----------------------------------------------------------------------------
RUN mkdir -p /workspace /home/${USER_NAME}/.ccache /home/${USER_NAME}/.history \
 && chown -R ${USER_UID}:${USER_GID} /workspace /home/${USER_NAME}

# -----------------------------------------------------------------------------
# 8) Copy the entrypoint that fixes volume ownership at every container start
# -----------------------------------------------------------------------------
COPY --chown=root:root --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# -----------------------------------------------------------------------------
# 9) Switch to non-root user and set sensible defaults
# -----------------------------------------------------------------------------
USER ${USER_NAME}
WORKDIR /workspace

# -----------------------------------------------------------------------------
# 10) Friendly bash prompt + history persistence
# -----------------------------------------------------------------------------
RUN echo '\n# Fast DDS dev container customizations'                  >> ~/.bashrc \
 && echo 'export HISTFILE=/home/${USER}/.history/.bash_history'        >> ~/.bashrc \
 && echo 'export HISTSIZE=10000'                                       >> ~/.bashrc \
 && echo 'export HISTFILESIZE=10000'                                   >> ~/.bashrc \
 && echo 'export PS1="\[\033[1;32m\][\u@fastdds-dev]\[\033[0m\] \[\033[1;34m\]\w\[\033[0m\] $ "' >> ~/.bashrc \
 && echo 'alias ll="ls -alF"'                                          >> ~/.bashrc \
 && echo 'alias la="ls -A"'                                            >> ~/.bashrc \
 && echo '[ -f /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion' >> ~/.bashrc

# -----------------------------------------------------------------------------
# 11) Entrypoint chains: entrypoint.sh fixes ownership, then exec the CMD
# -----------------------------------------------------------------------------
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
