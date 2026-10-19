FROM ghcr.io/sagernet/sing-box:latest

# Sing-box 1.14+ with native MASQUE (RFC 9484 / RFC 9298) support
ENTRYPOINT ["sing-box"]
CMD ["run", "-c", "/etc/sing-box/config.json"]
