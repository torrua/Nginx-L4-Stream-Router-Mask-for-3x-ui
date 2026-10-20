# @include "common/node-token.sh"

node_token_operation() {
    "$PYTHON_CMD" - "$@" <<'EOF_NODE_TOKEN_PY'
# @include "panel/node_token.py"
EOF_NODE_TOKEN_PY
}

ensure_node_token() {
    case "${ENABLE_NODE_TOKEN:-y}" in n|0|false) return 0 ;; esac
    NODE_TOKEN="${NODE_TOKEN:-}"
    if node_token_operation verify "$DB_PATH" "$NODE_TOKEN_NAME" "$NODE_TOKEN"; then
        ok "Действующий API-ключ ноды '$NODE_TOKEN_NAME' сохранён."
    else
        NODE_TOKEN=""
        local token_out="" attempt
        local -a arguments=()
        if [ -n "${XUI_BIN:-}" ]; then
            for attempt in 1 2; do
                case "$attempt" in
                    1) arguments=(-tokenName "$NODE_TOKEN_NAME" -tokenScope admin) ;;
                    2) arguments=(-tokenName "$NODE_TOKEN_NAME") ;;
                esac
                token_out=$("$XUI_BIN" setting -getApiToken "${arguments[@]}" 2>&1 || true)
                NODE_TOKEN=$(printf '%s\n' "$token_out" | awk '$1 == "apiToken:" {gsub(/\r/, "", $2); print $2; exit}')
                [ -z "$NODE_TOKEN" ] || break
            done
        fi
        # Also handles CLI versions without named-token flags, without renaming other tokens.
        if ! node_token_operation verify "$DB_PATH" "$NODE_TOKEN_NAME" "$NODE_TOKEN"; then
            NODE_TOKEN=$(node_token_operation create "$DB_PATH" "$NODE_TOKEN_NAME") || die "Не удалось создать API-ключ ноды 3X-UI."
        fi
        [ -n "$NODE_TOKEN" ] || die "3X-UI не вернул API-ключ ноды."
        ok "API-ключ ноды '$NODE_TOKEN_NAME' создан."
    fi
    local runtime_file
    runtime_file=$(node_token_runtime_file)
    node_token_operation persist "$runtime_file" "${CONFIG_FILE:-}" "$NODE_TOKEN_NAME" "$NODE_TOKEN" || die "Не удалось сохранить API-ключ ноды."
}
