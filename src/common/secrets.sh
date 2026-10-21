generate_secret_token() {
    # 16 bytes = 128 bits. Never replace a failed entropy read with $RANDOM.
    local token
    token=$(od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]') || return 1
    [[ "$token" =~ ^[0-9a-f]{32}$ ]] || { warn "Не удалось получить 128 бит случайности."; return 1; }
    printf '%s' "$token"
}

generate_urlsafe_token() {
    local nbytes="${1:-16}"
    local token=""
    if command -v python3 >/dev/null 2>&1; then
        token="$(python3 -c "import secrets, sys; print(secrets.token_urlsafe(int(sys.argv[1])))" "$nbytes" 2>/dev/null || true)"
    fi
    if [ -z "$token" ] && command -v openssl >/dev/null 2>&1; then
        token="$(openssl rand -base64 "$nbytes" 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$(( nbytes * 4 / 3 ))" || true)"
    fi
    if [ -z "$token" ] && [ -r /dev/urandom ]; then
        token="$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c "$nbytes" || true)"
    fi
    if [ -z "$token" ]; then
        token="$(generate_secret_token 2>/dev/null | head -c "$nbytes")"
    fi
    printf '%s' "$token"
}

generate_base64_token() {
    local nbytes="${1:-32}"
    local token=""
    if command -v openssl >/dev/null 2>&1; then
        token="$(openssl rand -base64 "$nbytes" 2>/dev/null || true)"
    fi
    if [ -z "$token" ] && command -v python3 >/dev/null 2>&1; then
        token="$(python3 -c "import secrets, base64, sys; print(base64.b64encode(secrets.token_bytes(int(sys.argv[1]))).decode())" "$nbytes" 2>/dev/null || true)"
    fi
    if [ -z "$token" ] && [ -r /dev/urandom ]; then
        token="$(head -c "$nbytes" /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -d '\n' || true)"
    fi
    printf '%s' "$token"
}

