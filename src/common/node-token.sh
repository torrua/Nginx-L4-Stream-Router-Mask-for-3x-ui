normalize_node_token_config() {
    local enabled="${CLI_ENABLE_NODE_TOKEN:-${ENABLE_NODE_TOKEN:-y}}"
    NODE_TOKEN="${NODE_TOKEN:-}"
    NODE_TOKEN_NAME="${CLI_NODE_TOKEN_NAME:-${NODE_TOKEN_NAME:-}}"
    case "${enabled,,}" in y|1|true) ENABLE_NODE_TOKEN=y ;; *) ENABLE_NODE_TOKEN=n; return 0 ;; esac
    case "${AUTO_SETUP_3XUI:-y}" in n|0|false) ENABLE_NODE_TOKEN=n; return 0 ;; esac
    if [ -z "$NODE_TOKEN_NAME" ]; then
        local prefix="${SERVER_PREFIX-Server}"
        case "${prefix,,}" in ''|-|none|off|no) NODE_TOKEN_NAME=Master-Node-Cluster ;; *) NODE_TOKEN_NAME="${prefix}-Node" ;; esac
    fi
}

node_token_runtime_file() {
    if [ -n "${NODE_ENV_FILE:-}" ]; then printf '%s' "$NODE_ENV_FILE";
    elif [ -d /run ]; then printf '/run/3xui_node_token.env';
    else printf '/tmp/3xui_node_token.env'; fi
}

load_node_token_result() {
    local file="$1" line key value
    NODE_TOKEN=""
    [ -f "$file" ] || return 1
    local double_quote='^"(.*)"$' single_quote="^'(.*)'\$"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^(NODE_TOKEN_NAME|NODE_TOKEN)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        if [[ "$value" =~ $double_quote ]] || [[ "$value" =~ $single_quote ]]; then value="${BASH_REMATCH[1]}"; fi
        printf -v "$key" '%s' "$value"
    done < "$file"
    [ -n "${NODE_TOKEN:-}" ]
}
