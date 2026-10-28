# =============================================================
#  ШАГ 6: ПОЛНАЯ КОНФИГУРАЦИЯ NGINX И ПЕРЕЗАПУСК СЛУЖБ
# =============================================================
    if [ -z "${PANEL_PATH:-}" ]; then
        if command -v ensure_panel_path >/dev/null 2>&1; then
            ensure_panel_path || true
        fi
        [ -n "${PANEL_PATH:-}" ] || PANEL_PATH="/panel-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "p${RANDOM}")/"
    fi
    if [ -z "${DIAG_PATH:-}" ]; then
        if command -v ensure_diag_path >/dev/null 2>&1; then
            ensure_diag_path || true
        fi
        [ -n "${DIAG_PATH:-}" ] || DIAG_PATH="/diag-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "d${RANDOM}")/"
    fi
    if [ -z "${DIAG_TOKEN:-}" ]; then
        DIAG_TOKEN="$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 16 || echo "tok${RANDOM}")"
    fi
    if [ -z "${SUB_PATH:-}" ]; then
        SUB_PATH="/sub-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "sub${RANDOM}")/"
    fi
    if [ -z "${SUB_JSON_PATH:-}" ]; then
        SUB_JSON_PATH="${SUB_PATH}json/"
    fi
    if [ -z "${SUB_CLASH_PATH:-}" ]; then
        SUB_CLASH_PATH="${SUB_PATH}clash/"
    fi
    if [ -z "${XHTTP_STREAM_PATH:-}" ]; then
        XHTTP_STREAM_PATH="/$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xh${RANDOM}")/"
    fi
    DECOY_MODE="${DECOY_MODE:-1}"
    DEFAULT_FALLBACK="${DEFAULT_FALLBACK:-panel_3xui}"
    PANEL_PORT="${PANEL_PORT:-10443}"
    DEFAULT_PORT="${DEFAULT_PORT:-$PANEL_PORT}"
    SUB_PORT="${SUB_PORT:-55443}"
    XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
    REALITY_FALLBACK_PORT="${REALITY_FALLBACK_PORT:-9443}"
    SSL_BASE_DIR="${SSL_BASE_DIR:-/etc/letsencrypt/live}"
    WEBROOT="${WEBROOT:-/var/www/html}"
    NGINX_USER="${NGINX_USER:-nginx}"
    log "Сборка конфигурации Nginx Mainline (Stream L4 + HTTP/2 Upstream Engine)..."

    # Резервное копирование существующих конфигураций Nginx перед перезаписью
    backup_nginx_configs

    # Точечная очистка: удаляем только дефолтные заглушки и предыдущие конфиги маскирования
    rm -f /etc/nginx/sites-enabled/default \
          /etc/nginx/sites-available/default \
          /etc/nginx/conf.d/default.conf \
          /etc/nginx/http.d/default.conf \
          /etc/nginx/conf.d/stream.conf \
          /etc/nginx/conf.d/00-acme.conf \
          /etc/nginx/http.d/00-acme.conf \
          /etc/nginx/conf.d/01-main.conf \
          /etc/nginx/conf.d/02-external-*.conf \
          /etc/nginx/conf.d/03-adguard.conf \
          /etc/nginx/conf.d/vpn_mask.conf \
          /etc/nginx/stream.d/00-stream.conf \
          /etc/nginx/stream.d/vpn_mask_stream.conf 2>/dev/null || true

    mkdir -p /etc/nginx/modules-enabled 2>/dev/null || true
    find /etc/nginx/modules-enabled/ -xtype l -delete 2>/dev/null || true
    ensure_nginx_stream_module
    modules_load_block=""
    if compgen -G "/etc/nginx/modules-enabled/*.conf" >/dev/null 2>&1; then
        modules_load_block="include /etc/nginx/modules-enabled/*.conf;"
    else
        for cand in /etc/nginx/modules/ngx_stream_module.so \
                    /usr/lib/nginx/modules/ngx_stream_module.so \
                    /usr/share/nginx/modules/ngx_stream_module.so \
                    /usr/local/nginx/modules/ngx_stream_module.so; do
            if [ -f "$cand" ]; then
                modules_load_block="load_module $cand;"
                break
            fi
        done
    fi

    # Определение поддержки директив HTTP/2 в установленной версии Nginx
    determine_nginx_http2_mode

    wstunnel_badbot_bypass=""
    if is_true "${ENABLE_WSTUNNEL:-0}" && [ -n "${WSTUNNEL_PREFIX:-}" ]; then
        wstunnel_clean_prefix="${WSTUNNEL_PREFIX#/}"
        wstunnel_clean_prefix="${wstunnel_clean_prefix%/}"
        wstunnel_badbot_bypass="        ~^1:[01]:/${wstunnel_clean_prefix}/ 0;"$'\n'
    fi

    local nginx_pid_file="/run/nginx.pid"
    if is_openrc || [ -f /etc/alpine-release ]; then
        nginx_pid_file="/run/nginx/nginx.pid"
        mkdir -p /run/nginx 2>/dev/null || true
    fi

    # 1. Глобальный файл конфигурации /etc/nginx/nginx.conf
    cat << EOF > /etc/nginx/nginx.conf
user $NGINX_USER;
worker_processes auto;
pid ${nginx_pid_file};
worker_rlimit_nofile 524288;
${modules_load_block}

error_log /var/log/nginx/error.log warn;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    server_tokens off;
    etag off;
    charset utf-8;
    resolver 1.1.1.1 8.8.8.8 ipv6=off valid=300s;
    resolver_timeout 5s;

    # Оптимизация окна и стриминга HTTP/2 для устранения просадок больших потоков
${HTTP2_HTTP_PARAMS}

    map \$proxy_protocol_addr \$ak_real_ip {
        ""      \$remote_addr;
        default \$proxy_protocol_addr;
    }

    upstream panel_3xui {
        server 127.0.0.1:$PANEL_PORT;
        keepalive 30;
    }

    upstream sub_backend {
        server 127.0.0.1:$SUB_PORT;
        keepalive 30;
    }

    upstream xray_xhttp_stream {
        server 127.0.0.1:$XHTTP_STREAM_PORT;
        keepalive 64;
    }

    proxy_cache_path /var/cache/nginx/img_cache levels=1:2 keys_zone=img_zone:10m max_size=1g inactive=7d use_temp_path=off;
    proxy_cache_path /var/cache/nginx/html_cache levels=1:2 keys_zone=html_zone:20m max_size=500m inactive=30d use_temp_path=off;

    access_log off;

    keepalive_timeout 300s;
    keepalive_requests 100000;
    client_body_timeout 300s;
    client_header_timeout 30s;
    send_timeout 300s;
    reset_timedout_connection on;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    set_real_ip_from unix:;

    client_max_body_size 64m;
    client_body_buffer_size 128k;
    large_client_header_buffers 4 16k;
    client_header_buffer_size 1k;

    open_file_cache max=2000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;

    gzip on;
    gzip_vary on;
    gzip_comp_level 2;
    gzip_min_length 512;
    gzip_proxied any;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        "" close;
    }

    map \$http_user_agent \$badbot_raw {
        default 0;
        "" 1;
        ~*(?:httpclient|lwp-request|axios|fetch|insomnia|postman|libwww-perl|java|php|ruby|nuclei|httpx|ffuf|dirsearch|gobuster) 1;
        ~*(?:sqlmap|nikto|masscan|zgrab|zmap|acunetix|dirbuster|wpscan|nmap|hydra|bfexam|censys|shodan|dirb|feroxbuster|katana) 1;
        ~*(?:ahrefs|semrush|mj12bot|dotbot|rogerbot|exabot|sogou|bytespider|yandexbot|pinterest|baidu|duckduckgo|bingbot|googlebot) 1;
        ~*(?:gptbot|claudebot|chatgpt|cohere|omgili|anthropic|google-extended|applebot-extended|meta-externalagent|ccbot|perplexity|openai|perplexities|gemini|bard|anthropic-ai|commoncrawl|diffbot|weborama|bytespider-ai) 1;
        ~*(?:facebookexternalhit|twitterbot|linkedinbot|slackbot|discordbot) 1;
    }

    map \$request_uri \$is_scan_attempt {
        default 0;
        ~^/(?:pages|public)/(pages|catalog|schedule|random|public|donate|team|login|cp)\.php\$ 0;
        ~*\.(?:php|php5|phtml|asp|aspx|jsp|do|action|cgi|pl|py|rb)\$ 1;
        ~*(\.env|\.git|\.config|\.htaccess|\.sql|\.bak|\.old|\.swp|\.ini|config\.php|web\.config|settings\.py)\$ 1;
        ~*^/(?:admin|administrator|wp-admin|wp-login|phpmyadmin|sqladmin|setup|install|dashboard|manager|controlpanel|config|auth|backend|logs)/ 1;
        ~*(\.\./|\.\.\\|/etc/passwd|/boot/|/windows/|/proc/) 1;
        ~*^/(?:graphql|swagger-ui|api-docs|redoc)/ 1;
        ~*\.(?:zip|tar\.gz|rar|7z)\$ 1;
        ~*(?:\.git/|wp-json|xmlrpc|/\.env|config\.bak|debug\.log|test\.php) 1;
    }

    map "\$badbot_raw:\$is_scan_attempt:\$request_uri" \$badbot {
        ~^.*:/robots\.txt(\?|\$) 0;
        ~^.*:/.well-known/security\.txt(\?|\$) 0;
        ~^1:[01]:${PANEL_PATH} 0;
        ~^1:[01]:${DIAG_PATH} 0;
        ~^1:[01]:${SUB_PATH} 0;
        ~^1:[01]:${SUB_JSON_PATH} 0;
        ~^1:[01]:${SUB_CLASH_PATH} 0;
        ~^1:[01]:/sub/ 0;
        ~^1:[01]:/json/ 0;
        ~^1:[01]:/clash/ 0;
        ~^1:[01]:${XHTTP_STREAM_PATH} 0;
${wstunnel_badbot_bypass}        ~^1:[01]:/dns-query 0;
        ~^1:[01]:/agh/ 0;
        ~(^1:|:1) 1;
        default 0;
    }

    map "\$cookie_diag_key:\$arg_token" \$diag_auth {
        default 0;
        "~^${DIAG_TOKEN}:" 1;
        "~:${DIAG_TOKEN}\$" 1;
    }

    limit_req_zone \$binary_remote_addr zone=bot:1m rate=4r/s;
    limit_req_zone \$binary_remote_addr zone=panel:10m rate=30r/s;
    limit_req_zone \$binary_remote_addr zone=subs:1m rate=10r/s;
    limit_req_zone \$binary_remote_addr zone=scan:1m rate=1r/s;
    limit_conn_zone \$binary_remote_addr zone=addr:1m;
    limit_req_zone \$binary_remote_addr zone=assets:1m rate=150r/s;
    limit_req_zone \$binary_remote_addr zone=doh:10m rate=300r/s;
    limit_req_status 429;

    proxy_hide_header X-Proxy-Engine;
    proxy_hide_header X-Original-URL;
    proxy_hide_header X-RateLimit-Remaining;
    proxy_hide_header Server;
    proxy_hide_header X-Powered-By;
    proxy_hide_header Via;
    proxy_hide_header X-Varnish;
    proxy_hide_header X-Varnish-Cache;
    proxy_hide_header Age;
    proxy_hide_header CF-Ray;
    proxy_hide_header CF-Cache-Status;
    proxy_hide_header Alt-Svc;
    proxy_hide_header X-Cache-Status;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF

# 2. Карта SNI для Stream L4
STREAM_MAP_RULES=""
REALITY_UPSTREAMS=""

for dom in "${ALL_DOMAINS[@]}"; do
    if is_true "${STEAL_ENABLED:-0}" && [ -n "${DOMAIN_TO_PORT[$dom]:-}" ]; then
        port="${DOMAIN_TO_PORT[$dom]}"
        STREAM_MAP_RULES+="        ${dom}     reality_backend_${port};"$'\n'
    elif is_true "${ENABLE_NAIVE:-0}" && [ -n "${NAIVE_DOMAIN:-}" ] && [ "$dom" = "$NAIVE_DOMAIN" ] && [ "$dom" != "${PRIMARY_DOMAIN:-}" ]; then
        STREAM_MAP_RULES+="        ${dom}     naive_backend;"$'\n'
    else
        STREAM_MAP_RULES+="        ${dom}     nginx_http_backend;"$'\n'
    fi
done

if is_true "${CLASSIC_ENABLED:-0}"; then
    for ext_sni in "${!EXT_SNI_TO_PORT[@]}"; do
        port="${EXT_SNI_TO_PORT[$ext_sni]}"
        if is_true "${ENABLE_SHADOWTLS:-0}" && [ "$ext_sni" = "${SHADOWTLS_SNI:-gateway.icloud.com}" ]; then
            continue
        fi
        STREAM_MAP_RULES+="        ${ext_sni}     reality_backend_${port};"$'\n'
    done
fi

if is_true "${ENABLE_SHADOWTLS:-0}"; then
    STREAM_MAP_RULES+="        ${SHADOWTLS_SNI:-gateway.icloud.com}     shadowtls_backend;"$'\n'
fi

if is_true "${ENABLE_NAIVE:-0}" && [ -n "${NAIVE_DOMAIN:-}" ] && [ "$NAIVE_DOMAIN" != "${PRIMARY_DOMAIN:-}" ]; then
    if [[ ! "$STREAM_MAP_RULES" =~ "$NAIVE_DOMAIN" ]]; then
        STREAM_MAP_RULES+="        ${NAIVE_DOMAIN}     naive_backend;"$'\n'
    fi
fi

SHADOWTLS_STREAM_BLOCKS=""
if is_true "${ENABLE_SHADOWTLS:-0}"; then
    SHADOWTLS_STREAM_BLOCKS="
upstream shadowtls_backend {
    server 127.0.0.1:8542;
}

server {
    listen 127.0.0.1:8542 proxy_protocol;
    proxy_pass 127.0.0.1:${SHADOWTLS_PORT:-8543};
}
"
fi

NAIVE_STREAM_BLOCKS=""
if is_true "${ENABLE_NAIVE:-0}"; then
    NAIVE_STREAM_BLOCKS="
upstream naive_backend {
    server 127.0.0.1:8447;
}

server {
    listen 127.0.0.1:8447 proxy_protocol;
    proxy_pass 127.0.0.1:${NAIVE_PORT:-8446};
}
"
fi

for port in "${ALL_REALITY_PORTS[@]:-}"; do
    if [ -n "$port" ]; then
        REALITY_UPSTREAMS+="
    upstream reality_backend_${port} {
        server 127.0.0.1:${port};
        server unix:/dev/shm/nginx-http.sock backup;
    }
"
    fi
done

if is_true "${CLASSIC_ENABLED:-0}"; then
    DEFAULT_PORT="${CLASSIC_PORTS_LIST[0]:-46443}"
    DEFAULT_FALLBACK="reality_backend_${DEFAULT_PORT}"
else
    DEFAULT_FALLBACK="nginx_http_backend"
fi

# 2.1. Адаптация сторонних HTTPS-сайтов для бесконфликтной работы со Stream L4 роутером
for vf in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [ -f "$vf" ] || continue
    b_name=$(basename "$vf")
    case "$b_name" in
        default|default.conf|01-main.conf|02-*.conf|03-adguard.conf|vpn_mask.conf)
            continue
            ;;
    esac
    if grep -Eq 'listen[[:space:]]+([^;]*:)?443' "$vf" 2>/dev/null; then
        if ! grep -q 'listen[[:space:]]+unix:' "$vf" 2>/dev/null; then
            log "Адаптация vhost $b_name: перенос listen 443 на сокет unix:/dev/shm/nginx-http.sock..."
            sed -i -E 's/listen[[:space:]]+([^;]*:)?443[[:space:]]*ssl[[:space:]]*([^;]*);/listen unix:\/dev\/shm\/nginx-http.sock ssl \2 proxy_protocol;/g' "$vf" 2>/dev/null || true
            sed -i -E 's/listen[[:space:]]+([^;]*:)?443[[:space:]]*([^;]*);/listen unix:\/dev\/shm\/nginx-http.sock ssl \2 proxy_protocol;/g' "$vf" 2>/dev/null || true
            sn_list=$(grep -E '^[[:space:]]*server_name[[:space:]]+' "$vf" 2>/dev/null | sed -E 's/^[[:space:]]*server_name[[:space:]]+([^;]+);/\1/' || true)
            for s_dom in $sn_list; do
                if [ "$s_dom" != "_" ] && [[ ! "$STREAM_MAP_RULES" =~ "$s_dom" ]]; then
                    STREAM_MAP_RULES+="        ${s_dom}     nginx_http_backend;"$'\n'
                fi
            done
        fi
    fi
done

cat << EOF > "/etc/nginx/stream.d/00-stream.conf"
map \$ssl_preread_server_name \$backend_gate {
    hostnames;
    ""                     nginx_http_backend;
${STREAM_MAP_RULES}    default                ${DEFAULT_FALLBACK};
}

upstream nginx_http_backend {
    server unix:/dev/shm/nginx-http.sock;
}

${REALITY_UPSTREAMS}
${SHADOWTLS_STREAM_BLOCKS}
${NAIVE_STREAM_BLOCKS}

server {
    listen 443 backlog=65535 reuseport;
    proxy_protocol on;
    proxy_pass \$backend_gate;
    ssl_preread on;
}
EOF

# 2.5 Конфигурация локаций AdGuard Home (Режим 1: на основном домене)
AGH_MAIN_LOCATION_BLOCKS=""
if is_true "${ENABLE_AGH:-0}" && [ "${AGH_MODE:-1}" = "1" ]; then
    AGH_MAIN_LOCATION_BLOCKS="
    # --- ЛОКАЦИЯ: ADGUARD HOME DOH (ENDPOINT С CLIENTID) ---
    location = /dns-query {
        return 404;
    }

    location = /dns-query/${AGH_CLIENT_ID} {
        limit_req zone=doh burst=500 nodelay;
        proxy_pass http://127.0.0.1:${PORT_AGH_WEB:-3000};
        proxy_http_version 1.1;
        proxy_set_header Connection \"\";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_set_header X-Forwarded-For \$ak_real_ip;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
    }

    location /dns-query/ {
        return 403;
    }
"
fi

# 3. Конфигурация локаций маскировки (Автономные чистые профили)
DECOY_LOCATION_BLOCKS=""

if [ "$DECOY_MODE" = "1" ]; then
    # Режим 1: DataSphere Analytics
    DECOY_LOCATION_BLOCKS="
        add_header Content-Security-Policy \"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none';\" always;
        add_header X-DataSphere-Engine \"v4.0.2\" always;

        location ~ ^/(api/v1/datasphere/status|status)\$ {
            default_type application/json;
            return 200 '{\"status\":\"online\",\"cluster\":\"datasphere-edge-ultra\",\"nodes_active\":148,\"telemetry_rate\":\"99.998%\",\"version\":\"4.0.2\"}';
        }

        location = /api/v1/datasphere/auth {
            if (\$request_method = POST) {
                add_header Content-Type \"application/json; charset=utf-8\" always;
                return 401 '{\"status\":\"error\",\"code\":401,\"error\":\"Недействительный токен кластера или ключ авторизации узла. Доступ запрещен.\"}';
            }
            return 405;
        }

        location = / {
            default_type text/html;
            root $WEBROOT;
            try_files /index.html =404;
        }

        location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|webp)\$ {
            root $WEBROOT;
            expires 7d;
            access_log off;
            add_header Cache-Control \"public, max-age=604800, immutable\" always;
            try_files \$uri =404;
        }

        location / {
            return 404;
        }
"
elif [ "$DECOY_MODE" = "2" ]; then
    # Режим 2: CosmosCloud
    DECOY_LOCATION_BLOCKS="
        add_header X-Cosmoscloud-Version \"0.22.18\" always;

        location ~ ^/(api/v1/status|status)\$ {
            default_type application/json;
            return 200 '{\"installed\":true,\"maintenance\":false,\"version\":\"0.22.18\",\"productname\":\"CosmosCloud\"}';
        }

        location = /api/v1/auth/login {
            if (\$request_method = POST) {
                add_header Content-Type \"application/json\" always;
                return 401 '{\"error\":\"Wrong nickname or password. Try again or try resetting your password\",\"code\":401}';
            }
            return 405;
        }

        location = / {
            default_type text/html;
            root $WEBROOT;
            try_files /index.html =404;
        }

        location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|webp)\$ {
            root $WEBROOT;
            expires 7d;
            access_log off;
            try_files \$uri =404;
        }

        location / {
            return 404;
        }
"
else
    # Режим 3: Welcome to nginx
    DECOY_LOCATION_BLOCKS="
        location = / {
            default_type text/html;
            root $WEBROOT;
            try_files /index.html =404;
        }

        location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|webp)\$ {
            root $WEBROOT;
            expires 7d;
            access_log off;
            try_files \$uri =404;
        }

        location / {
            return 404;
        }
"
fi

WSTUNNEL_LOCATION_BLOCK=""
if is_true "${ENABLE_WSTUNNEL:-0}" && [ -n "${WSTUNNEL_PREFIX:-}" ]; then
    wstunnel_clean_prefix="${WSTUNNEL_PREFIX#/}"
    wstunnel_clean_prefix="${wstunnel_clean_prefix%/}"
    WSTUNNEL_LOCATION_BLOCK="
    # --- ЛОКАЦИЯ: WSTUNNEL (L7 WebSocket Tunnel) ---
    location ^~ /${wstunnel_clean_prefix}/ {
        proxy_pass http://127.0.0.1:${WSTUNNEL_PORT:-8080};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_set_header X-Forwarded-For \$ak_real_ip;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }
"
fi

# 4. Основной виртуальный хост в /etc/nginx/conf.d/01-main.conf
cat << EOF > "/etc/nginx/conf.d/01-main.conf"
# HTTP Порт 80 (Проверка ACME и редирект на HTTPS)
server {
    listen 80 default_server;
    server_name _;
    access_log off;

    if (\$badbot) { return 444; }

    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
    }

    location ~* ^/(wp-admin|wp-login|xmlrpc|vendor|cgi-bin) { return 444; }
    location ~ /\.(git|env|htaccess|svn) { return 444; }

    # Немедленный сброс прямых сканеров по IP (IPv4 и IPv6)
    if (\$host ~* "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$") { return 444; }
    if (\$host ~* "^\[?[0-9a-fA-F:]+\]?$") { return 444; }
    if (\$host = "") { return 444; }

    location / {
        return 301 https://\$host\$request_uri;
    }

    error_page 400 403 404 405 =404 /dev/null;
}

# HTTPS SSL-Reject сервер для перехвата невалидных SNI и сканеров по IP
server {
    listen unix:/dev/shm/nginx-http.sock ssl ${HTTP2_LISTEN_PARAM}default_server proxy_protocol;
    listen 127.0.0.1:$REALITY_FALLBACK_PORT ssl ${HTTP2_LISTEN_PARAM}default_server proxy_protocol;
    ${HTTP2_DIRECTIVE}
    server_name _;

    ssl_reject_handshake on;
    ssl_session_tickets off;

    ssl_certificate ${SSL_BASE_DIR}/$PRIMARY_DOMAIN/fullchain.pem;
    ssl_certificate_key ${SSL_BASE_DIR}/$PRIMARY_DOMAIN/privkey.pem;
}

# HTTPS Основной рабочий сервер (Главный домен)
server {
    listen unix:/dev/shm/nginx-http.sock ssl ${HTTP2_LISTEN_PARAM}proxy_protocol;
    listen 127.0.0.1:$REALITY_FALLBACK_PORT ssl ${HTTP2_LISTEN_PARAM}proxy_protocol;
    ${HTTP2_DIRECTIVE}
    server_name $PRIMARY_DOMAIN;

    ssl_certificate ${SSL_BASE_DIR}/$PRIMARY_DOMAIN/fullchain.pem;
    ssl_certificate_key ${SSL_BASE_DIR}/$PRIMARY_DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    ssl_buffer_size 4k;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 4h;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    if (\$is_scan_attempt) { return 404; }
    if (\$badbot) { return 404; }
    if (\$request_method !~ ^(GET|HEAD|POST)\$) { return 405; }

    error_page 400 403 404 405 @notfound;

    # --- ЛОКАЦИЯ 1: ПАНЕЛЬ 3X-UI ---
    location = ${PANEL_PATH%/} {
        return 301 ${PANEL_PATH};
    }

    location ^~ ${PANEL_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=panel burst=40 delay=20;
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_intercept_errors off;
    }

    # --- ЛОКАЦИЯ 1.1: SSO-МОСТ ДЛЯ ВЕБ-ДИАГНОСТИКИ ИЗ ПАНЕЛИ 3X-UI ---
    location = ${PANEL_PATH}diag {
        auth_request /__diag_auth;
        error_page 401 403 = @diag_login;
        try_files /__nonexistent @diag_sso_ok;
    }
    location = ${PANEL_PATH}diag/ {
        return 302 ${PANEL_PATH}diag;
    }
    location @diag_login {
        return 302 ${PANEL_PATH};
    }
    location @diag_sso_ok {
        add_header Set-Cookie "diag_key=${DIAG_TOKEN}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=86400" always;
        return 302 ${DIAG_PATH};
    }
    location = /__diag_auth {
        internal;
        proxy_pass http://127.0.0.1:$PANEL_PORT${PANEL_PATH}panel/;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Requested-With XMLHttpRequest;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_intercept_errors on;
        error_page 300 301 302 303 304 305 307 308 400 401 402 403 404 405 500 501 502 503 504 =401 @diag_denied;
    }
    location @diag_denied { return 401; }

    # --- ЛОКАЦИЯ 1.2: ПОРТАЛ ВЕБ-ДИАГНОСТИКИ (СТРОГОЕ СОКРЫТИЕ 404 БЕЗ УТЕЧКИ ПУТИ) ---
    location = ${DIAG_PATH%/} {
        return 302 ${DIAG_PATH}\$is_args\$args;
    }
    location ^~ ${DIAG_PATH} {
        if (\$diag_auth = 0) { return 404; }
        alias /var/www/diagnostics/;
        index index.html;
        add_header Set-Cookie "diag_key=${DIAG_TOKEN}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=86400" always;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
    }
    location = ${DIAG_PATH}api/st/ping {
        if (\$diag_auth = 0) { return 404; }
        default_type text/plain;
        return 200 "OK";
    }
    location = ${DIAG_PATH}api/st/getIP {
        if (\$diag_auth = 0) { return 404; }
        default_type text/plain;
        return 200 "\$ak_real_ip";
    }
    location = ${DIAG_PATH}api/st/getip {
        if (\$diag_auth = 0) { return 404; }
        default_type text/plain;
        return 200 "\$ak_real_ip";
    }
    location = ${DIAG_PATH}api/st/download {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/download;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_buffering off;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/st/down {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/down;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_buffering off;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/st/upload {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/upload;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_request_buffering off;
        client_max_body_size 128m;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/st/up {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/up;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_request_buffering off;
        client_max_body_size 128m;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/mtr {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/mtr;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_read_timeout 90s;
    }

    # --- ЛОКАЦИЯ 2: ПОДПИСКИ КЛИЕНТОВ ---
    location ^~ /sub/ {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ^~ ${SUB_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ^~ ${SUB_JSON_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ^~ ${SUB_CLASH_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ~* ^/(sub|json|clash)/ {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    # --- ЛОКАЦИЯ 3: VLESS xHTTP (Native gRPC / H2 Stream-One) ---
    location ^~ ${XHTTP_STREAM_PATH} {
        client_max_body_size 0;
        client_body_timeout 1h;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_socket_keepalive on;

        grpc_set_header Host \$http_host;
        grpc_set_header X-Real-IP \$ak_real_ip;
        grpc_set_header X-Forwarded-For \$ak_real_ip;
        grpc_set_header X-Forwarded-Proto \$scheme;

        grpc_pass grpc://xray_xhttp_stream;
    }

    $WSTUNNEL_LOCATION_BLOCK
    $AGH_MAIN_LOCATION_BLOCKS

    # --- ЛОКАЦИЯ 4: ДЕКОЙ САЙТ / МАСКИРОВКА ---
    $DECOY_LOCATION_BLOCKS

    # --- СЛУЖЕБНЫЕ ЛОКАЦИИ ---
    location ~ ^/debug-[a-z0-9]+\.log\$ {
        root $WEBROOT;
        default_type text/plain;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        try_files \$uri =404;
    }

    location = /robots.txt {
        root $WEBROOT;
        access_log off;
    }

    location ~ ^/(favicon\.ico|favicon\.svg)\$ {
        root $WEBROOT;
        access_log off;
        expires 30d;
    }

    location = /.well-known/security.txt {
        default_type text/plain;
        access_log off;
        return 200 "Contact: mailto:admin@$PRIMARY_DOMAIN\nPreferred-Languages: ru,en\n";
    }

    location @notfound {
        limit_req zone=scan burst=3 nodelay;
        root $WEBROOT;
        rewrite ^ /404.html break;
    }
}
EOF

    # 4.1. Очистка устаревшего stub-сервера 11443 (Anti-Loop Fallback теперь обслуживается напрямую через 9443 с полным SNI)
    rm -f "/etc/nginx/conf.d/02-steal-stub.conf" 2>/dev/null || true

# 5. Генерация виртуальных хостов для дополнительных доменов
for ((i=1; i<${#ALL_DOMAINS[@]}; i++)); do
    ext_dom="${ALL_DOMAINS[$i]}"
    if [ "$ext_dom" != "$PRIMARY_DOMAIN" ] && [ "$ext_dom" != "${AGH_DOMAIN:-}" ] && [ -f "${SSL_BASE_DIR}/$ext_dom/fullchain.pem" ]; then
        cat << EOF > "/etc/nginx/conf.d/02-${ext_dom}.conf"
server {
    listen unix:/dev/shm/nginx-http.sock ssl ${HTTP2_LISTEN_PARAM}proxy_protocol;
    listen 127.0.0.1:$REALITY_FALLBACK_PORT ssl ${HTTP2_LISTEN_PARAM}proxy_protocol;
    ${HTTP2_DIRECTIVE}
    server_name $ext_dom;

    ssl_certificate ${SSL_BASE_DIR}/$ext_dom/fullchain.pem;
    ssl_certificate_key ${SSL_BASE_DIR}/$ext_dom/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    ssl_buffer_size 4k;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 4h;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    if (\$is_scan_attempt) { return 404; }
    if (\$badbot) { return 404; }
    if (\$request_method !~ ^(GET|HEAD|POST)\$) { return 405; }

    error_page 400 403 404 405 @notfound;

    $DECOY_LOCATION_BLOCKS
    $WSTUNNEL_LOCATION_BLOCK

    location ^~ ${PANEL_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_intercept_errors off;
    }

    # --- ЛОКАЦИЯ 1.1: SSO-МОСТ ДЛЯ ВЕБ-ДИАГНОСТИКИ ИЗ ПАНЕЛИ 3X-UI ---
    location = ${PANEL_PATH}diag {
        auth_request /__diag_auth;
        error_page 401 403 = @diag_login;
        try_files /__nonexistent @diag_sso_ok;
    }
    location = ${PANEL_PATH}diag/ {
        return 302 ${PANEL_PATH}diag;
    }
    location @diag_login {
        return 302 ${PANEL_PATH};
    }
    location @diag_sso_ok {
        add_header Set-Cookie "diag_key=${DIAG_TOKEN}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=86400" always;
        return 302 ${DIAG_PATH};
    }
    location = /__diag_auth {
        internal;
        proxy_pass http://127.0.0.1:$PANEL_PORT${PANEL_PATH}panel/;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Requested-With XMLHttpRequest;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_intercept_errors on;
        error_page 300 301 302 303 304 305 307 308 400 401 402 403 404 405 500 501 502 503 504 =401 @diag_denied;
    }
    location @diag_denied { return 401; }

    # --- ЛОКАЦИЯ 1.2: ПОРТАЛ ВЕБ-ДИАГНОСТИКИ (СТРОГОЕ СОКРЫТИЕ 404 БЕЗ УТЕЧКИ ПУТИ) ---
    location = ${DIAG_PATH%/} {
        return 302 ${DIAG_PATH}\$is_args\$args;
    }
    location ^~ ${DIAG_PATH} {
        if (\$diag_auth = 0) { return 404; }
        alias /var/www/diagnostics/;
        index index.html;
        add_header Set-Cookie "diag_key=${DIAG_TOKEN}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=86400" always;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
    }
    location = ${DIAG_PATH}api/st/ping {
        if (\$diag_auth = 0) { return 404; }
        default_type text/plain;
        return 200 "OK";
    }
    location = ${DIAG_PATH}api/st/getIP {
        if (\$diag_auth = 0) { return 404; }
        default_type text/plain;
        return 200 "\$ak_real_ip";
    }
    location = ${DIAG_PATH}api/st/getip {
        if (\$diag_auth = 0) { return 404; }
        default_type text/plain;
        return 200 "\$ak_real_ip";
    }
    location = ${DIAG_PATH}api/st/download {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/download;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_buffering off;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/st/down {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/down;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_buffering off;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/st/upload {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/upload;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_request_buffering off;
        client_max_body_size 128m;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/st/up {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/up;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_request_buffering off;
        client_max_body_size 128m;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/mtr {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/mtr;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_read_timeout 90s;
    }

    location ^~ /sub/ {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ^~ ${SUB_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ^~ ${SUB_JSON_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ^~ ${SUB_CLASH_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ~* ^/(sub|json|clash)/ {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    # --- ЛОКАЦИЯ: VLESS xHTTP (Native gRPC / H2 Stream-One) ---
    location ^~ ${XHTTP_STREAM_PATH} {
        client_max_body_size 0;
        client_body_timeout 1h;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_socket_keepalive on;

        grpc_set_header Host \$http_host;
        grpc_set_header X-Real-IP \$ak_real_ip;
        grpc_set_header X-Forwarded-For \$ak_real_ip;
        grpc_set_header X-Forwarded-Proto \$scheme;

        grpc_pass grpc://xray_xhttp_stream;
    }

    location ~ ^/debug-[a-z0-9]+\.log\$ {
        root $WEBROOT;
        default_type text/plain;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        try_files \$uri =404;
    }

    location = /robots.txt {
        root $WEBROOT;
        access_log off;
    }

    location ~ ^/(favicon\.ico|favicon\.svg)\$ {
        root $WEBROOT;
        access_log off;
        expires 30d;
    }

    location = /.well-known/security.txt {
        default_type text/plain;
        access_log off;
        return 200 "Contact: mailto:admin@$ext_dom\nPreferred-Languages: ru,en\n";
    }

    location @notfound {
        limit_req zone=scan burst=3 nodelay;
        root $WEBROOT;
        rewrite ^ /404.html break;
    }
}
EOF
    fi
done

    # 6. Виртуальный хост для AdGuard Home (Режим 2: отдельный поддомен)
    if is_true "${ENABLE_AGH:-0}" && [ "${AGH_MODE:-1}" = "2" ] && [ -n "${AGH_DOMAIN:-}" ] && [ -f "${SSL_BASE_DIR:-/etc/letsencrypt/live}/$AGH_DOMAIN/fullchain.pem" ]; then
        cat << EOF > "/etc/nginx/conf.d/03-adguard.conf"
upstream adguard_backend { server 127.0.0.1:${PORT_AGH_WEB:-3000}; keepalive 32; }

server {
    listen unix:/dev/shm/nginx-http.sock ssl ${HTTP2_LISTEN_PARAM}proxy_protocol;
    listen 127.0.0.1:$REALITY_FALLBACK_PORT ssl ${HTTP2_LISTEN_PARAM}proxy_protocol;
    ${HTTP2_DIRECTIVE}
    server_name $AGH_DOMAIN;

    ssl_certificate ${SSL_BASE_DIR}/$AGH_DOMAIN/fullchain.pem;
    ssl_certificate_key ${SSL_BASE_DIR}/$AGH_DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    ssl_buffer_size 4k;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 4h;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    # Защита от ботов: пустой /dns-query без токена
    location = /dns-query {
        return 404;
    }

    location /dns-query/ {
        limit_req zone=doh burst=500 nodelay;
        proxy_pass http://adguard_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_set_header X-Forwarded-For \$ak_real_ip;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
    }

    location / {
        limit_req zone=panel burst=60 delay=30;
        proxy_pass http://adguard_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
    else
        rm -f "/etc/nginx/conf.d/03-adguard.conf" 2>/dev/null || true
    fi

    # Развертывание демона веб-диагностики и статических файлов перед запуском Nginx
    setup_vpn_diagnostics || true

    run_with_spinner "Тестирование конфигурации и перезапуск Nginx Mainline" nginx_reload_task || {
        restore_nginx_configs
        die "Ошибка запуска Nginx. Конфигурация автоматически возвращена в исходное состояние."
    }

    local nginx_ver="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || echo "")"
    local nginx_arch="$(uname -s 2>/dev/null || echo "Linux") $(uname -m 2>/dev/null || echo "x86_64")"
    if [ -n "$nginx_ver" ]; then
        ok " Активирован веб-сервер Nginx v${nginx_ver} (${nginx_arch})"
    else
        ok " Активирован веб-сервер Nginx (${nginx_arch})"
    fi
