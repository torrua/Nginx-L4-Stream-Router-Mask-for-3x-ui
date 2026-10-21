# Express provides defaults for the common installation engine.
express_default() {
    local name="$1" value="$2" cli_name="CLI_$1"
    if [ -z "${CONFIG_EXPLICIT_KEYS[$name]:-}" ] && [ -z "${!cli_name:-}" ]; then
        printf -v "$name" '%s' "$value"
    fi
}

apply_express_defaults() {
    express_default ADD_WWW n
    express_default ENABLE_STEAL y
    express_default STEAL_PORT 45443
    express_default STEAL_DOMAINS_STR "cdn.$PRIMARY_DOMAIN"
    express_default ENABLE_CLASSIC y
    express_default CLASSIC_PORT 46443
    express_default CLASSIC_SNI avito.ru
    express_default ENABLE_HY2 y
    express_default HY2_PORT 443
    express_default HY2_DOMAIN "$PRIMARY_DOMAIN"
    express_default ENABLE_AWG_V3 y
    express_default AWG_V3_PORT 8443
    express_default ENABLE_AWG_V2 n
    express_default ENABLE_TUIC y
    express_default ENABLE_SS2022 y
    express_default ENABLE_MTPROTO y
    express_default DECOY_MODE 1
    express_default PORTS_SETUP_MODE 0
    express_default PATHS_SETUP_MODE 0
    express_default SSL_ENGINE_CHOICE 1
    express_default AUTO_SETUP_3XUI y
    express_default ENABLE_WARP y
    express_default ENABLE_AGH y
    express_default AGH_MODE 1
    express_default AGH_XRAY_DNS n
    reconstruct_arrays_from_vars
    finalize_installation_config
}
