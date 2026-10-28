# @include "common/node-token.sh"

node_token_operation() {
    "$PYTHON_CMD" - "$@" <<'EOF_NODE_TOKEN_PY'
# @include "panel/node_token.py"
EOF_NODE_TOKEN_PY
}

ensure_node_token() {
    case "${ENABLE_NODE_TOKEN:-y}" in n|0|false) return 0 ;; esac
    NODE_TOKEN="${NODE_TOKEN:-}"
    local target_scope="${NODE_TOKEN_SCOPE:-node-sync}"
    case "${target_scope,,}" in
        admin) target_scope="admin" ;;
        node-admin) target_scope="node-admin" ;;
        *) target_scope="node-sync" ;;
    esac

    if node_token_operation verify "$DB_PATH" "$NODE_TOKEN_NAME" "$NODE_TOKEN"; then
        ok "Действующий API-ключ ноды '$NODE_TOKEN_NAME' сохранён."
    else
        NODE_TOKEN=""
        local token_out="" attempt
        local -a arguments=()
        if [ -n "${XUI_BIN:-}" ]; then
            for attempt in 1 2 3; do
                case "$attempt" in
                    1) arguments=(-tokenName "$NODE_TOKEN_NAME" -tokenScope "$target_scope") ;;
                    2)
                        # Fallback if 3X-UI version does not support node-sync for -tokenScope
                        if [ "$target_scope" != "admin" ]; then
                            arguments=(-tokenName "$NODE_TOKEN_NAME" -tokenScope admin)
                        else
                            arguments=(-tokenName "$NODE_TOKEN_NAME")
                        fi
                        ;;
                    3) arguments=(-tokenName "$NODE_TOKEN_NAME") ;;
                esac
                token_out=$("$XUI_BIN" setting -getApiToken "${arguments[@]}" 2>&1 || true)
                NODE_TOKEN=$(printf '%s\n' "$token_out" | awk '$1 == "apiToken:" {gsub(/\r/, "", $2); print $2; exit}')
                [ -z "$NODE_TOKEN" ] || break
            done
        fi
        # Also handles CLI versions without named-token flags, without renaming other tokens.
        if ! node_token_operation verify "$DB_PATH" "$NODE_TOKEN_NAME" "$NODE_TOKEN"; then
            NODE_TOKEN=$(node_token_operation create "$DB_PATH" "$NODE_TOKEN_NAME" "$target_scope") || die "Не удалось создать API-ключ ноды 3X-UI."
        fi
        [ -n "$NODE_TOKEN" ] || die "3X-UI не вернул API-ключ ноды."
        local scope_title="Синхронизация узла"
        [ "$target_scope" = "admin" ] && scope_title="Администратор"
        ok "API-ключ ноды '$NODE_TOKEN_NAME' создан (область доступа: $scope_title)."
    fi
    local runtime_file
    runtime_file=$(node_token_runtime_file)
    node_token_operation persist "$runtime_file" "${CONFIG_FILE:-}" "$NODE_TOKEN_NAME" "$NODE_TOKEN" "$target_scope" || die "Не удалось сохранить API-ключ ноды."
}
