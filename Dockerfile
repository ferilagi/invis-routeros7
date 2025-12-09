# syntax=docker/dockerfile:1.4
ARG ROUTEROS_VERSION="7.20.4"
ARG TARGETPLATFORM
ARG BUILDPLATFORM

# Set build stage
FROM --platform=$BUILDPLATFORM alpine:latest AS base

# Set shell options globally (RECOMMENDED)
SHELL ["/bin/sh", "-xe", "-o", "pipefail", "-c"]

# Change work dir (it will also create this folder if is not exist)
WORKDIR /routeros

# Add Persistent Folder
RUN mkdir -p  /routeros_source

# Install dependencies
RUN set -xe \
 && apk add --no-cache --update \
    wget \
    unzip \
    bash \
    python3 \
    iproute2 \
    iputils \
    bridge-utils \
    iptables \
    jq \
    busybox-extras \
    netcat-openbsd \
    tunctl \
    udhcpd

# Install QEMU x86_64 EMULATOR untuk semua platform
# RouterOS hanya jalan di x86_64, jadi kita perlu qemu-system-x86_64
RUN apk add --no-cache \
    qemu-system-x86_64 \
    qemu-img \
    qemu-modules

# Untuk ARM host, kita juga perlu beberapa dependencies tambahan
RUN if [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
        echo "Installing ARM emulation dependencies..." && \
        apk add --no-cache qemu-x86_64; \
    fi

# Buat device node untuk /dev/net/tun
RUN mkdir -p /dev/net && \
    mknod /dev/net/tun c 10 200 && \
    chmod 666 /dev/net/tun

# EXPOSE ROUTEROS PORTS
#EXPOSE 5900        # VNC (optional)
EXPOSE 21           # FTP
EXPOSE 22           # SSH
EXPOSE 23           # Telnet
EXPOSE 80           # HTTP
EXPOSE 443          # HTTPS
EXPOSE 8291         # Winbox
EXPOSE 8728         # API
EXPOSE 8729         # API SSL
EXPOSE 1194         # OpenVPN 1194/tcp, 1194/udp
EXPOSE 1701         # L2TP
EXPOSE 1723         # PPTP
EXPOSE 1812/udp     # RADIUS Authentication
EXPOSE 1813/udp     # RADIUS Accounting

FROM base AS downloader

# Environments which may be change
ARG ROUTEROS_VERSION
ENV ROUTEROS_VERSION=${ROUTEROS_VERSION}
ENV ROUTEROS_IMAGE="chr-${ROUTEROS_VERSION}.vdi"
ENV ROUTEROS_URL="https://download.mikrotik.com/routeros/${ROUTEROS_VERSION}/${ROUTEROS_IMAGE}.zip"

# Download RouterOS VDI ke /routeros_source (persistent folder)
WORKDIR /routeros_source

# Download VDI image from remote site
RUN wget -q "${ROUTEROS_URL}" -O "${ROUTEROS_IMAGE}.zip" && \
    unzip -q "${ROUTEROS_IMAGE}.zip" && \
    rm -f "${ROUTEROS_IMAGE}.zip" && \
    mv "${ROUTEROS_IMAGE}" chr.vdi && \
    echo "Downloaded RouterOS ${ROUTEROS_VERSION}" && \
    ls -lh chr.vdi

FROM base AS final

# Copy extracted VDI dari downloader stage
COPY --from=downloader /routeros_source/chr.vdi /routeros_source/chr.vdi

# Copy scripts ke /routeros_source
COPY ./scripts /routeros_source

RUN echo "Setting permissions for scripts..." && \
    find /routeros_source -type f \( -name "*.sh" -o -name "*.py" -o -name "qemu-*" \) \
    -exec chmod +x {} \; 2>/dev/null || true

# Verify everything is in place
RUN echo "=== Container Structure ===" && \
    echo "Working directory: $(pwd)" && \
    echo "RouterOS VDI: /routeros_source/chr.vdi" && \
    ls -la /routeros_source/chr.vdi && \
    echo -e "\n=== All scripts ===" && \
    ls -la /routeros_source/

# Health check untuk RouterOS API port
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD nc -z localhost 8728 || exit 1


# Metadata labels
LABEL org.opencontainers.image.title="Mikrotik RouterOS Container"
LABEL org.opencontainers.image.version="${ROUTEROS_VERSION}"
LABEL org.opencontainers.image.description="Mikrotik RouterOS ${ROUTEROS_VERSION} in Docker container"
LABEL org.opencontainers.image.source="https://github.com/ferilagi/invis-routeros7"
LABEL org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["/routeros_source/entrypoint.sh"]