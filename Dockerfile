# ==============================================================================
# VIRGOZKI PANEL + SSH-WS (OpenResty Alpine + OpenSSH + BadVPN + Python + Xray)
# ==============================================================================

FROM openresty/openresty:alpine

# ------------------------------------------------------------------------------
# SYSTEM PACKAGES
# ------------------------------------------------------------------------------
RUN apk add --no-cache \
    ca-certificates \
    wget \
    unzip \
    tini \
    curl \
    iptables \
    ipset \
    openssh \
    python3 \
    bash \
    build-base \
    cmake \
    git \
    libressl-dev

# ------------------------------------------------------------------------------
# INSTALL XRAY CORE
# ------------------------------------------------------------------------------
RUN mkdir -p /tmp/xray /etc/xray \
    && wget -O /tmp/xray/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip /tmp/xray/xray.zip -d /tmp/xray \
    && mv /tmp/xray/xray /usr/local/bin/xray \
    && chmod +x /usr/local/bin/xray \
    && rm -rf /tmp/xray

# ------------------------------------------------------------------------------
# BADVPN UDPGW INSTALLATION
# ------------------------------------------------------------------------------
RUN git clone --depth 1 https://github.com/ambrop72/badvpn.git /tmp/badvpn \
    && mkdir -p /tmp/badvpn/build \
    && cd /tmp/badvpn/build \
    && cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    && make install \
    && rm -rf /tmp/badvpn

# ------------------------------------------------------------------------------
# SSH CONFIGURATION & USER
# ------------------------------------------------------------------------------
RUN mkdir -p /run/sshd /var/run/sshd /etc/ssh \
    && adduser -D -s /bin/bash virgozki \
    && echo 'virgozki:virgozki' | chpasswd

RUN printf '%s\n' \
    'PermitRootLogin yes' \
    'PasswordAuthentication yes' \
    'PubkeyAuthentication yes' \
    'UseDNS no' \
    'TCPKeepAlive yes' \
    'ClientAliveInterval 30' \
    'ClientAliveCountMax 3' \
    'MaxSessions 50' \
    'Compression no' \
    'X11Forwarding no' \
    'AllowTcpForwarding yes' \
    'AllowTcpForwarding remote' \
    'PermitOpen any' \
    'Banner /etc/ssh/banner.txt' \
    >> /etc/ssh/sshd_config

# ------------------------------------------------------------------------------
# COPY APPLICATION FILES
# ------------------------------------------------------------------------------
COPY banner.txt /etc/ssh/banner.txt
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY index.html /usr/local/openresty/nginx/html/index.html
COPY config.json /etc/xray.json
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/entrypoint.sh"]
