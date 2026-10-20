generate_secret_token() {
    # 16 bytes = 128 bits. Never replace a failed entropy read with $RANDOM.
    local token
    token=$(od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]') || return 1
    [[ "$token" =~ ^[0-9a-f]{32}$ ]] || { warn "Не удалось получить 128 бит случайности."; return 1; }
    printf '%s' "$token"
}

