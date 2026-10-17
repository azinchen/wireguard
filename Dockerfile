ARG ALPINE_VERSION=3.24.2

############################
# 1) Fetch s6-overlay (arch-aware)
############################
FROM alpine:${ALPINE_VERSION} AS s6-fetch

ARG TARGETARCH
ARG TARGETVARIANT

ARG PACKAGE="just-containers/s6-overlay"
ARG PACKAGEVERSION="3.2.3.2"

RUN echo "**** install security fix packages ****" && \
    echo "**** install mandatory packages ****" && \
    apk --no-cache --no-progress add \
        tar=1.35-r5 \
        xz=5.8.4-r0 \
        wget=1.25.0-r3 \
        && \
    echo "**** create folders ****" && \
    mkdir -p /s6root && \
    echo "**** download ${PACKAGE} ****" && \
    echo "Target arch: ${TARGETARCH}${TARGETVARIANT}" && \
    # Map Docker TARGETARCH to s6-overlay architecture names
    case "${TARGETARCH}${TARGETVARIANT}" in \
        amd64)      s6_arch="x86_64" ;; \
        arm64)      s6_arch="aarch64" ;; \
        armv7)      s6_arch="arm" ;; \
        armv6)      s6_arch="armhf" ;; \
        386)        s6_arch="i686" ;; \
        ppc64)      s6_arch="powerpc64" ;; \
        ppc64le)    s6_arch="powerpc64le" ;; \
        riscv64)    s6_arch="riscv64" ;; \
        s390x)      s6_arch="s390x" ;; \
        *)          s6_arch="x86_64" ;; \
    esac && \
    echo "Package ${PACKAGE} version ${PACKAGEVERSION}" && \
    s6_url_base="https://github.com/${PACKAGE}/releases/download/v${PACKAGEVERSION}" && \
    wget -q "${s6_url_base}/s6-overlay-noarch.tar.xz" -qO /tmp/s6-overlay-noarch.tar.xz && \
    wget -q "${s6_url_base}/s6-overlay-${s6_arch}.tar.xz" -qO /tmp/s6-overlay-binaries.tar.xz && \
    wget -q "${s6_url_base}/s6-overlay-symlinks-noarch.tar.xz" -qO /tmp/s6-overlay-symlinks-noarch.tar.xz && \
    wget -q "${s6_url_base}/s6-overlay-symlinks-arch.tar.xz" -qO /tmp/s6-overlay-symlinks-arch.tar.xz && \
    tar -C /s6root/ -Jxpf /tmp/s6-overlay-noarch.tar.xz && \
    tar -C /s6root/ -Jxpf /tmp/s6-overlay-binaries.tar.xz && \
    tar -C /s6root/ -Jxpf /tmp/s6-overlay-symlinks-noarch.tar.xz && \
    tar -C /s6root/ -Jxpf /tmp/s6-overlay-symlinks-arch.tar.xz

############################
# 2) Assemble rootfs (apply perms here)
############################
FROM alpine:${ALPINE_VERSION} AS rootfs

ARG IMAGE_VERSION=N/A \
    BUILD_DATE=N/A

RUN mkdir -p /rootfs

ADD root/ /rootfs/

# Normalize permissions once (no chmods in final image)
RUN chmod +x /rootfs/usr/local/bin/* || true && \
    chmod +x /rootfs/etc/s6-overlay/s6-rc.d/*/run || true && \
    chmod +x /rootfs/etc/s6-overlay/s6-rc.d/*/finish || true

COPY --from=s6-fetch /s6root/ /rootfs/

# Stamp the image identity into backend-functions (every script sources it).
# LAST step of the stage on purpose: the ARG values change per build, so only
# this layer (and the final COPY --from=rootfs) miss the cache.
RUN safe_sed() { \
        pattern="$1"; \
        replacement="$2"; \
        file="$3"; \
        for delim in '/' '|' '#' '@' '%' '^' '&' '*' '+' '-' '_' '=' ':' ';' '<' '>' ',' '.' '?' '~'; do \
            if [ "${replacement%%*"$delim"*}" = "$replacement" ]; then \
                sed -i "s${delim}${pattern}${delim}${replacement}${delim}g" "$file"; \
                return; \
            fi; \
        done; \
        echo "No safe delimiter found for $pattern in $file" >&2; \
        return 1; \
    } && \
    safe_sed "__IMAGE_VERSION__" "${IMAGE_VERSION}" /rootfs/usr/local/bin/backend-functions && \
    safe_sed "__BUILD_DATE__" "${BUILD_DATE}" /rootfs/usr/local/bin/backend-functions

############################
# 3) Final runtime (minimal layers)
############################
FROM alpine:${ALPINE_VERSION}

ARG IMAGE_VERSION=N/A \
    BUILD_DATE=N/A

LABEL org.opencontainers.image.title="WireGuard VPN Docker container" \
      org.opencontainers.image.description="WireGuard VPN node in a Docker container: inbound peers with zero-config provisioning, per-peer exits (direct, upstream VPN containers, other WireGuard peers), fail-closed kill switch, hot reload" \
      org.opencontainers.image.authors="Alexander Zinchenko <alexander@zinchenko.com>" \
      org.opencontainers.image.url="https://github.com/azinchen/wireguard" \
      org.opencontainers.image.source="https://github.com/azinchen/wireguard" \
      org.opencontainers.image.vendor="Alexander Zinchenko <alexander@zinchenko.com>" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      com.wireguard.url="https://www.wireguard.com/" \
      com.wireguard.documentation="https://www.wireguard.com/quickstart/"

# wireguard-tools-wg is the bare `wg` binary: the image builds interfaces
# with ip + wg setconf/syncconf and never uses wg-quick (nor its bash
# dependency). wireguard-go is the userspace fallback for hosts without the
# kernel module; libqrencode-tools renders peer configs as QR codes.
RUN apk --no-cache --no-progress add \
    wireguard-tools-wg=1.0.20260223-r0 \
    wireguard-go=0.0.20250522-r11 \
    iproute2-minimal=7.0.0-r0 \
    nftables=1.1.6-r1 \
    libqrencode-tools=4.1.1-r3 \
    bind-tools=9.20.29-r0 \
    curl=8.22.0-r0 \
    ca-certificates=20260909-r0 \
    tzdata=2026e-r0

# One COPY to bring everything in
COPY --from=rootfs /rootfs/ /

# Runtime knobs: never wait on longruns at boot; abort container start if an
# init oneshot (env validation, firewall, routing) fails -> fail-closed
ENV S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2

# Report container health from the WireGuard state. start-period covers
# interface bring-up including gateway initialization. Opt-in: the probe
# reports healthy unless HEALTH_CHECK_ENABLED=true is set.
HEALTHCHECK --interval=60s --timeout=15s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/healthcheck"]

VOLUME ["/etc/wireguard"]
EXPOSE 51820/udp

ENTRYPOINT ["/init"]
