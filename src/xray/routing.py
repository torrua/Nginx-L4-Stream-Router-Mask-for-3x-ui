# ----------------- Шаблон ядра Xray и правила маршрутизации -----------------

DEFAULT_XRAY_TEMPLATE = {
    "api": {
        "services": ["HandlerService", "LoggerService", "StatsService", "RoutingService"],
        "tag": "api"
    },
    "inbounds": [{
        "listen": "127.0.0.1", "port": 62789, "protocol": "tunnel",
        "settings": {"rewriteAddress": "127.0.0.1"}, "tag": "api"
    }],
    "log": {"access": "none", "dnsLog": False, "error": "", "loglevel": "warning", "maskAddress": ""},
    "metrics": {"listen": "127.0.0.1:11111", "tag": "metrics_out"},
    "outbounds": [
        {"protocol": "freedom", "settings": {"domainStrategy": "AsIs"}, "tag": "direct"},
        {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
    ],
    "policy": {
        "levels": {"0": {"statsUserDownlink": True, "statsUserUplink": True}},
        "system": {"statsInboundDownlink": True, "statsInboundUplink": True, "statsOutboundDownlink": False, "statsOutboundUplink": False}
    },
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {"inboundTag": ["api"], "outboundTag": "api", "type": "field"},
            {"ip": ["geoip:private"], "outboundTag": "blocked", "type": "field"}
        ]
    },
    "stats": {}
}

BAD_GEOSITES = {
    "geosite:ru", "geosite:yandex", "geosite:vk", "geosite:youtube",
    "geosite:openai", "geosite:google-gemini", "geosite:anthropic", "geosite:cloudflare"
}

YT_DOMAINS = [
    "domain:youtube.com",
    "domain:googlevideo.com",
    "domain:ytimg.com",
    "domain:youtu.be",
    "domain:youtubei.googleapis.com",
    "domain:yt.be"
]

RU_DOMAINS = [
    "domain:ru",
    "domain:su",
    "domain:рф",
    "domain:xn--p1ai",
    "domain:yandex.ru",
    "domain:yandex.net",
    "domain:ya.ru",
    "domain:vk.com",
    "domain:vk.ru",
    "domain:vkvideo.ru",
    "domain:gosuslugi.ru",
    "domain:sberbank.ru",
    "domain:tbank.ru",
    "domain:tinkoff.ru",
    "domain:dzen.ru",
    "domain:mail.ru",
    "domain:rutube.ru",
    "domain:ozon.ru",
    "domain:wildberries.ru",
    "domain:avito.ru"
]

WARP_DOMAINS = [
    "domain:openai.com",
    "domain:chatgpt.com",
    "domain:oaistatic.com",
    "domain:oaiusercontent.com",
    "domain:anthropic.com",
    "domain:claude.ai",
    "domain:gemini.google.com",
    "domain:aistudio.google.com",
    "domain:deepmind.google",
    "domain:makersuite.google.com",
    "domain:generativelanguage.googleapis.com",
    "domain:ai.google.dev",
    "domain:google.com",
    "domain:cloudflare.com",
    "domain:challenges.cloudflare.com"
]
