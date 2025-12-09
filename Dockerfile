ARG TARGETPLATFORM
ARG BUILDPLATFORM

FROM alpine:latest

# For access via VNC
EXPOSE 5900

# Expose Most Port of RouterOS
# EXPOSE 1194 1701 1723 1812/udp 1813/udp 21 22 23 443 4500/udp 50 500/udp 51 2021 2022 2023 2027 5900 80 8080 8291 8728 8729 8900

# Expose Just API and Winbox Port of RouterOS
EXPOSE 8291 8728 8729

# USER root

# Change work dir (it will also create this folder if is not exist)
WORKDIR /routeros

# Add Persistent Folder
RUN mkdir -p  /routeros_source

# Install dependencies
RUN set -xe \
 && apk add --no-cache --update \
	netcat-openbsd \
	# if your node x86_64
    qemu-x86_64 qemu-system-x86_64 \
	# if your node arm64
	# qemu-img qemu-system-aarch64 \
    busybox-extras iproute2 iputils \
    bridge-utils iptables jq bash python3 zip unzip

# Environments which may be change
ARG ROUTEROS_VERSION="7.20.4"
ENV ROUTEROS_VERSION=${ROUTEROS_VERSION}
ENV ROUTEROS_IMAGE="chr-${ROUTEROS_VERSION}.vdi"
ENV ROUTEROS_PATH="https://download.mikrotik.com/routeros/${ROUTEROS_VERSION}/${ROUTEROS_IMAGE}.zip"

# Download VDI image from remote site
RUN wget "$ROUTEROS_PATH" -O "/routeros_source/${ROUTEROS_IMAGE}.zip" && \
	unzip "/routeros_source/${ROUTEROS_IMAGE}.zip" -d "/routeros_source" && \
    rm -f "/routeros_source/${ROUTEROS_IMAGE}.zip"

# Remove unused packet
RUN apk del zip unzip

# Copy script to routeros folder
ADD ["./scripts", "/routeros_source"]

# Set execute permissions on scripts
# RUN chmod +x /routeros_source/*.*

ENTRYPOINT ["/routeros_source/entrypoint.sh"]