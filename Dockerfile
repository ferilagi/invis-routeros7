# syntax=docker/dockerfile:1.4
ARG ROUTEROS_VERSION="7.21.3"
ARG TARGETPLATFORM
ARG BUILDPLATFORM

# Set build stage
FROM alpine:latest AS base

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
    qemu-x86_64 \
    qemu-system-x86_64

# Buat device node untuk /dev/net/tun
RUN mkdir -p /dev/net && \
    mknod /dev/net/tun c 10 200 && \
    chmod 666 /dev/net/tun

# EXPOSE VNC (optional)
EXPOSE 5900

# FTP
# EXPOSE 21 

# SSH, Telnet, HTTP, HTTPS, Winbox,
EXPOSE 22 23 80 443 8291         

# API, API SSL, OpenVP(2 Port), L2TP, PPTP, RADIUS(2Udp Port)
EXPOSE 8728 8729 1194 1701 1723 1812/udp 1813/udp

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