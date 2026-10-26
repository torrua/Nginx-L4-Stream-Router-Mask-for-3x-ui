FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    iptables \
    libnetfilter-queue1 \
    curl \
    ca-certificates \
    tar && \
    rm -rf /var/lib/apt/lists/*

# Установка nfqws из официального релиза bol-van/zapret
ARG ZAPRET_VERSION=v72.13
RUN mkdir -p /tmp/zapret && \
    curl -fsSL "https://github.com/bol-van/zapret/releases/download/${ZAPRET_VERSION}/zapret-${ZAPRET_VERSION}.tar.gz" -o /tmp/zapret.tar.gz && \
    tar -zxf /tmp/zapret.tar.gz -C /tmp/zapret --strip-components=1 && \
    (cp /tmp/zapret/binaries/linux-x86_64/nfqws /usr/local/bin/nfqws 2>/dev/null || cp /tmp/zapret/binaries/x86_64/nfqws /usr/local/bin/nfqws) && \
    chmod +x /usr/local/bin/nfqws && \
    rm -rf /tmp/zapret*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

