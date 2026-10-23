# Multi-stage Caddy build with naive forwardproxy and Cloudflare DNS plugin
FROM caddy:builder AS builder

RUN xcaddy build \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@c096d6a00cb28e019cc1995b04bdc6a9311d8024 \
    --with github.com/caddy-dns/cloudflare

FROM caddy:latest

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
