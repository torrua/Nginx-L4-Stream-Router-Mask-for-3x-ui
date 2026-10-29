def smart_reconcile_inbound(port, protocol, tag, remark, default_settings, default_stream, listen="127.0.0.1", enabled=True):
    inb_cols = globals().get("inbounds_cols")
    if inb_cols is None:
        try:
            cur.execute("PRAGMA table_info(inbounds)")
            inb_cols = set(r[1] for r in cur.fetchall())
        except Exception:
            inb_cols = set()

    tr_col = "traffic_reset" if "traffic_reset" in inb_cols else ("trafficReset" if "trafficReset" in inb_cols else None)
    trd_col = "traffic_reset_day" if "traffic_reset_day" in inb_cols else ("trafficResetDay" if "trafficResetDay" in inb_cols else None)
    ltrt_col = "last_traffic_reset_time" if "last_traffic_reset_time" in inb_cols else ("lastTrafficResetTime" if "lastTrafficResetTime" in inb_cols else None)

    target_tr = globals().get("inbound_traffic_reset", "monthly")
    target_tr_day = globals().get("inbound_traffic_reset_day", 1)

    cur.execute("SELECT id, settings, stream_settings, protocol, tag, remark, listen, enable FROM inbounds WHERE port = ? OR tag = ?", (port, tag))
    row = cur.fetchone()
    
    if not row:
        # Инбаунд отсутствует -> создаем под ключ
        target_settings = json.loads(json.dumps(default_settings))
        target_stream = json.loads(json.dumps(default_stream))
        if protocol == "mtproto" and "preferIp" not in target_settings:
            target_settings["preferIp"] = "prefer-ipv4"
        if "externalProxy" in target_stream and isinstance(target_stream["externalProxy"], list) and len(target_stream["externalProxy"]) > 0:
            for ep in target_stream["externalProxy"]:
                if protocol in ("shadowsocks", "mtproto", "amneziawg"):
                    ep["forceTls"] = "none"
                elif protocol == "vless" and "realitySettings" in target_stream:
                    ep["forceTls"] = "same"
                elif "forceTls" not in ep:
                    ep["forceTls"] = "tls"
                if "alpn" in ep and isinstance(ep["alpn"], str):
                    ep["alpn"] = [ep["alpn"]] if ep["alpn"] else []

        settings_json = json.dumps(target_settings, ensure_ascii=False)
        stream_json = json.dumps(target_stream, ensure_ascii=False)
        sniffing_json = json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"]})
        new_inbound_id = None
        if not dry_run:
            ib_data = {
                "user_id": admin_id,
                "up": 0,
                "down": 0,
                "total": 0,
                "remark": remark,
                "enable": 1 if enabled else 0,
                "expiry_time": 0,
                "listen": listen,
                "port": port,
                "protocol": protocol,
                "settings": settings_json,
                "stream_settings": stream_json,
                "tag": tag,
                "sniffing": sniffing_json,
            }
            if tr_col:
                ib_data[tr_col] = target_tr
            if trd_col:
                ib_data[trd_col] = target_tr_day
            if ltrt_col:
                ib_data[ltrt_col] = 0

            if inb_cols:
                valid_ib = {k: v for k, v in ib_data.items() if k in inb_cols}
            else:
                valid_ib = {k: v for k, v in ib_data.items() if not k.startswith("traffic") and not k.startswith("last_traffic")}

            cols_str = ", ".join(valid_ib.keys())
            placeholders = ", ".join(["?"] * len(valid_ib))
            cur.execute(f"INSERT INTO inbounds ({cols_str}) VALUES ({placeholders})", list(valid_ib.values()))
            new_inbound_id = cur.lastrowid
            if "sync_inbound_clients" in globals():
                sync_inbound_clients(new_inbound_id, protocol, remark, target_settings, target_stream)
                settings_json = json.dumps(target_settings, ensure_ascii=False)
                cur.execute("UPDATE inbounds SET settings = ? WHERE id = ?", (settings_json, new_inbound_id))
        print(f"  [СОЗДАНО] Отсутствующий инбаунд: {remark} ({protocol.upper()} на порту {port}) добавлен и зарегистрирован в реестре клиентов.")
        return new_inbound_id

    inbound_id, raw_s, raw_st, proto, cur_tag, cur_remark, cur_listen, cur_enable = row
    cur_enable = 1 if cur_enable is None else cur_enable
    try:
        cur_settings = json.loads(raw_s) if raw_s else {}
    except Exception:
        cur_settings = {}
    try:
        cur_stream = json.loads(raw_st) if raw_st else {}
    except Exception:
        cur_stream = {}

    target_settings = json.loads(json.dumps(default_settings))
    target_stream = json.loads(json.dumps(default_stream))
    repairs = []
    preserved = []
    target_snis = []
    old_snis = []

    # Сохранение пользовательского названия инбаунда (remark), если оно было изменено
    final_remark = remark
    force_remarks_flag = globals().get("force_remarks", False)
    if not force_remarks_flag and cur_remark and str(cur_remark).strip():
        final_remark = str(cur_remark).strip()
        if final_remark != remark:
            preserved.append(f"пользовательское название '{final_remark}'")

    # Расписание сброса трафика инбаунда
    final_tr = target_tr
    final_tr_day = target_tr_day
    if tr_col:
        cur_tr = None
        cur_tr_day = 1
        try:
            sel_cols = f"{tr_col}, {trd_col}" if trd_col else tr_col
            cur.execute(f"SELECT {sel_cols} FROM inbounds WHERE id = ?", (inbound_id,))
            tr_row = cur.fetchone()
            if tr_row:
                cur_tr = tr_row[0]
                if trd_col and len(tr_row) > 1 and tr_row[1] is not None:
                    cur_tr_day = tr_row[1]
        except Exception:
            pass

        if cur_tr and cur_tr not in ("never", ""):
            final_tr = cur_tr
            final_tr_day = cur_tr_day
            preserved.append(f"расписание сброса трафика '{cur_tr}' (день {cur_tr_day})")
        else:
            final_tr = target_tr
            final_tr_day = target_tr_day
            repairs.append(f"настроен ежемесячный сброс трафика (1-го числа в 00:00)")

    # А. Сохранение и консолидация клиентов (единый реестр)
    existing_clients = cur_settings.get("clients", [])
    if "unified_email" in globals() and globals().get("unified_email"):
        u_email = globals()["unified_email"]
        consolidated_clients = []
        has_unified = False
        default_client = default_settings.get("clients", [])[0] if default_settings.get("clients") else None
        
        for ec in existing_clients:
            ec_email = ec.get("email") or ec.get("Email") or ""
            if ec_email == u_email:
                if not has_unified and default_client:
                    merged_c = json.loads(json.dumps(default_client))
                    for limit_field in ["totalGB", "expiryTime", "limitIp", "tgId", "reset", "resetDay", "resetMax", "trafficReset", "trafficResetDay", "enable"]:
                        if limit_field in ec:
                            merged_c[limit_field] = ec[limit_field]
                    if "trafficReset" not in merged_c or merged_c.get("trafficReset") in ("", "never", None):
                        merged_c["trafficReset"] = target_tr
                    if "trafficResetDay" not in merged_c or not merged_c.get("trafficResetDay"):
                        merged_c["trafficResetDay"] = target_tr_day
                    if "resetDay" not in merged_c or not merged_c.get("resetDay"):
                        merged_c["resetDay"] = target_tr_day
                    if protocol == "shadowsocks" and ec.get("password"):
                        if not globals().get("regen_server_keys", False) and "validate_ss2022_key" in globals() and validate_ss2022_key(ec["password"], target_settings.get("method", "2022-blake3-aes-256-gcm")):
                            merged_c["password"] = ec["password"]
                        else:
                            merged_c["password"] = globals().get("unified_ss_client_pass") or (generate_ss2022_key(target_settings.get("method", "2022-blake3-aes-256-gcm")) if "generate_ss2022_key" in globals() else ec.get("password"))
                            if globals().get("regen_server_keys", False):
                                repairs.append("обновлен ключ единого клиента SS-2022")
                            else:
                                repairs.append("исправлен невалидный ключ единого клиента SS-2022")
                    elif protocol == "tuic":
                        if ec.get("uuid"): merged_c["uuid"] = ec["uuid"]
                        if ec.get("password"): merged_c["password"] = ec["password"]
                    elif protocol == "mtproto":
                        if ec.get("secret") and not globals().get("regen_server_keys", False):
                            if "validate_mtproto_secret" not in globals() or validate_mtproto_secret(ec["secret"]):
                                merged_c["secret"] = ec["secret"]
                            else:
                                merged_c["secret"] = globals().get("unified_mtp_secret") or (generate_mtproto_secret(globals().get("mtproto_faketls_domain", "gateway.icloud.com")) if "generate_mtproto_secret" in globals() else ec.get("secret"))
                                repairs.append("исправлен невалидный FakeTLS секрет MTProto единого клиента")
                        else:
                            merged_c["secret"] = globals().get("unified_mtp_secret") or (generate_mtproto_secret(globals().get("mtproto_faketls_domain", "gateway.icloud.com")) if "generate_mtproto_secret" in globals() else ec.get("secret"))
                            if globals().get("regen_server_keys", False):
                                repairs.append("обновлен FakeTLS секрет MTProto единого клиента")
                        if ec.get("adTag") or ec.get("ad_tag"):
                            ad_cand = ec.get("adTag") or ec.get("ad_tag")
                            if "validate_mtproto_adtag" in globals() and not validate_mtproto_adtag(ad_cand):
                                merged_c["adTag"] = ""
                                repairs.append("очищен невалидный adTag MTProto")
                            else:
                                merged_c["adTag"] = ad_cand
                    elif protocol == "vless" and "xhttpSettings" in target_stream:
                        enc_cand = ec.get("encryption") or cur_settings.get("encryption") or target_settings.get("encryption")
                        if enc_cand:
                            merged_c["encryption"] = enc_cand
                    consolidated_clients.append(merged_c)
                    has_unified = True
                    preserved.append(f"единый клиент '{u_email}'")
            else:
                consolidated_clients.append(ec)
                preserved.append(f"клиент '{ec_email}'")
                
        if not has_unified and default_client:
            consolidated_clients.insert(0, json.loads(json.dumps(default_client)))
            repairs.append(f"добавлен единый клиент '{u_email}'")
            
        target_settings["clients"] = consolidated_clients
    else:
        if existing_clients and len(existing_clients) > 0:
            for ec in existing_clients:
                if "trafficReset" not in ec or ec.get("trafficReset") in ("", "never", None):
                    ec["trafficReset"] = target_tr
                if "trafficResetDay" not in ec or not ec.get("trafficResetDay"):
                    ec["trafficResetDay"] = target_tr_day
                if "resetDay" not in ec or not ec.get("resetDay"):
                    ec["resetDay"] = target_tr_day
            target_settings["clients"] = existing_clients
            preserved.append(f"клиенты ({len(existing_clients)} польз.)")
        else:
            repairs.append("добавлен клиент по умолчанию")

    # Б. Проверка и ремонт VLESS REALITY
    if protocol == "vless" and "realitySettings" in target_stream:
        cur_reality = cur_stream.get("realitySettings", {})
        
        # Сохранение privateKey
        priv = cur_reality.get("privateKey")
        if priv and not globals().get("regen_server_keys", False):
            target_stream["realitySettings"]["privateKey"] = priv
            preserved.append("privateKey Reality")
        elif priv and globals().get("regen_server_keys", False):
            repairs.append("обновлен серверный privateKey Reality")
        
        # Сохранение shortIds
        sids = cur_reality.get("shortIds")
        if sids and not globals().get("regen_server_keys", False):
            target_stream["realitySettings"]["shortIds"] = sids
            preserved.append("shortIds")
        elif sids and globals().get("regen_server_keys", False):
            repairs.append("обновлен пул shortIds Reality")

        # Ремонт / сохранение settings.publicKey
        pub = cur_reality.get("settings", {}).get("publicKey") or cur_reality.get("publicKey")
        if pub and not globals().get("regen_server_keys", False):
            target_stream["realitySettings"]["settings"]["publicKey"] = pub
            if not cur_reality.get("settings", {}).get("publicKey"):
                repairs.append("исправлен отсутствующий settings.publicKey (устранена ошибка empty password)")
            else:
                preserved.append("publicKey")
        else:
            derived_pub = curve25519_reality_pubkey(target_stream["realitySettings"]["privateKey"])
            if derived_pub:
                target_stream["realitySettings"]["settings"]["publicKey"] = derived_pub
                if globals().get("regen_server_keys", False):
                    repairs.append("обновлен серверный publicKey Reality")
                else:
                    repairs.append("восстановлен settings.publicKey по x25519")

        # settings.fingerprint
        tgt_fp = target_stream.get("realitySettings", {}).get("settings", {}).get("fingerprint")
        cur_fp = cur_reality.get("settings", {}).get("fingerprint")
        if tgt_fp and cur_fp and tgt_fp != cur_fp:
            target_stream["realitySettings"]["settings"]["fingerprint"] = tgt_fp
            repairs.append(f"обновлен fingerprint Reality ({cur_fp} -> {tgt_fp})")
        elif cur_fp and not tgt_fp:
            if "settings" in target_stream["realitySettings"] and isinstance(target_stream["realitySettings"]["settings"], dict):
                target_stream["realitySettings"]["settings"]["fingerprint"] = cur_fp

        # Ремонт мертвого swdist.microsoft.com SNI или пустых значений, либо обновление пула SNI
        old_snis = cur_reality.get("serverNames", [])
        old_dest = str(cur_reality.get("dest", "")).strip()
        target_snis = target_stream["realitySettings"].get("serverNames", [])
        c_sni_fallback = globals().get("classic_sni", "dl.google.com")
        c_port = globals().get("classic_port", 46443)

        if any("swdist.microsoft.com" in s for s in old_snis) or "swdist.microsoft.com" in old_dest:
            chosen_snis = target_snis if (target_snis and not any("swdist.microsoft.com" in s for s in target_snis)) else [c_sni_fallback]
            target_stream["realitySettings"]["serverNames"] = chosen_snis
            target_stream["realitySettings"]["dest"] = f"{chosen_snis[0]}:443"
            target_stream["realitySettings"]["xver"] = 0
            repairs.append(f"заменен мертвый SNI swdist.microsoft.com -> {','.join(chosen_snis)}")
        elif target_snis and target_snis != old_snis:
            target_stream["realitySettings"]["serverNames"] = target_snis
            if port == c_port or tag == "in-classic-reality" or cur_tag == "in-classic-reality":
                target_stream["realitySettings"]["dest"] = f"{target_snis[0]}:443"
                target_stream["realitySettings"]["target"] = f"{target_snis[0]}:443"
                if "settings" in target_stream["realitySettings"] and isinstance(target_stream["realitySettings"]["settings"], dict):
                    target_stream["realitySettings"]["settings"]["serverName"] = target_snis[0]
            repairs.append(f"обновлен пул SNI Reality ({','.join(target_snis)})")
        elif old_snis:
            target_stream["realitySettings"]["serverNames"] = old_snis
            target_stream["realitySettings"]["dest"] = old_dest or target_stream["realitySettings"]["dest"]
            preserved.append(f"SNI ({','.join(old_snis)})")
        elif target_snis:
            target_stream["realitySettings"]["serverNames"] = target_snis

        # Строгая гарантия параметров VLESS REALITY (маскировка под свой сайт: Nginx Fallback + Xver=1 + target)
        s_port = globals().get("steal_port", 45443)
        sc_port = globals().get("steal_compat_port", 47443)
        rf_port = globals().get("reality_fallback_port", 9443)
        if port in (s_port, sc_port) or tag in ("in-steal-reality", "in-steal-backup", "in-steal-compat") or cur_tag in ("in-steal-reality", "in-steal-backup", "in-steal-compat"):
            fallback_dest = f"127.0.0.1:{rf_port}"
            if not target_stream["realitySettings"].get("dest") or target_stream["realitySettings"]["dest"] != fallback_dest:
                target_stream["realitySettings"]["dest"] = fallback_dest
                repairs.append(f"установлен dest: {fallback_dest} (Nginx SSL Fallback, защита от сброса)")
            else:
                preserved.append(f"anti-loop dest {rf_port}")
            target_stream["realitySettings"]["target"] = fallback_dest
            if target_stream["realitySettings"].get("xver") != 1:
                target_stream["realitySettings"]["xver"] = 1
                repairs.append("установлен xver: 1 (Proxy Protocol для Nginx Anti-Loop)")

        # Строгая гарантия параметров VLESS REALITY (маскировка под внешние сервисы: xver=0, dest: 443, target: 443)
        c_port = globals().get("classic_port", 46443)
        c_sni = globals().get("classic_sni", "dl.google.com")
        if port == c_port or tag == "in-classic-reality" or cur_tag == "in-classic-reality":
            if not target_stream["realitySettings"].get("dest"):
                target_stream["realitySettings"]["dest"] = f"{c_sni}:443"
                repairs.append(f"восстановлен пустой dest -> {c_sni}:443")
            target_stream["realitySettings"]["target"] = target_stream["realitySettings"]["dest"]
            target_stream["realitySettings"]["xver"] = 0

    # В. Проверка и ремонт xHTTP
    if protocol == "vless" and "xhttpSettings" in target_stream:
        cur_xh = cur_stream.get("xhttpSettings", {})
        tgt_p = (target_stream["xhttpSettings"].get("path") or "").strip("/")
        cur_p = (cur_xh.get("path") or "").strip("/")
        if (not tgt_p or tgt_p == "Stream-One-Path" or tgt_p.startswith("vless-")) and cur_p:
            target_stream["xhttpSettings"]["path"] = f"/{cur_p}/"
            preserved.append(f"path (/{cur_p}/)")
        elif cur_p and tgt_p == cur_p:
            preserved.append(f"path (/{cur_p}/)")
        elif cur_p and tgt_p != cur_p:
            repairs.append(f"синхронизирован path xHTTP: /{cur_p}/ -> /{tgt_p}/")
        target_stream["xhttpSettings"]["mode"] = cur_xh.get("mode") or target_stream["xhttpSettings"].get("mode") or "auto"
        if cur_settings.get("decryption") and cur_settings["decryption"] != "none":
            target_settings["decryption"] = cur_settings["decryption"]
            preserved.append("decryption xHTTP")
        if cur_settings.get("encryption"):
            target_settings["encryption"] = cur_settings["encryption"]
            preserved.append("encryption xHTTP")
        elif not target_settings.get("encryption"):
            for c in cur_settings.get("clients", []):
                if c.get("encryption"):
                    target_settings["encryption"] = c["encryption"]
                    preserved.append("encryption xHTTP (из клиентов)")
                    break
        if cur_xh.get("xmux") and isinstance(cur_xh["xmux"], dict):
            target_stream["xhttpSettings"]["xmux"] = cur_xh["xmux"]
            preserved.append("xmux xHTTP")
        if cur_xh.get("noSSEHeader") is not None:
            target_stream["xhttpSettings"]["noSSEHeader"] = cur_xh["noSSEHeader"]
            preserved.append("noSSEHeader xHTTP")
        if cur_xh.get("xPaddingBytes"):
            target_stream["xhttpSettings"]["xPaddingBytes"] = cur_xh["xPaddingBytes"]
            preserved.append(f"xPaddingBytes ({cur_xh['xPaddingBytes']})")
        if target_settings.get("encryption"):
            for c in target_settings.get("clients", []):
                c["encryption"] = target_settings["encryption"]

    # Г. Проверка и ремонт Hysteria 2
    if protocol == "hysteria":
        if cur_settings.get("clients"):
            target_settings["clients"] = cur_settings["clients"]
            preserved.append("пароль Hysteria 2")
        
        cur_certs = cur_stream.get("tlsSettings", {}).get("certificates", [])
        if cur_certs and cur_certs[0].get("certificateFile") and os.path.exists(cur_certs[0]["certificateFile"]):
            target_stream["tlsSettings"]["certificates"] = cur_certs
            preserved.append("действующие SSL-сертификаты Hy2")

    # Д. Проверка и ремонт AmneziaWG
    if protocol == "amneziawg":
        cur_srv = cur_settings.get("server", {})
        if cur_srv.get("privateKey"):
            target_settings["server"]["privateKey"] = cur_srv["privateKey"]
            preserved.append("серверный privateKey AWG")
            
            # Валидация Curve25519
            expected_pub = curve25519_pubkey(cur_srv["privateKey"])
            actual_pub = cur_srv.get("publicKey")
            if actual_pub and expected_pub and actual_pub == expected_pub:
                target_settings["server"]["publicKey"] = actual_pub
                preserved.append("валидный publicKey AWG (Handshake OK)")
            elif expected_pub:
                target_settings["server"]["publicKey"] = expected_pub
                repairs.append("исправлен поврежденный publicKey сервера Curve25519")
        
        # Сохранение параметров обфускации
        for param in [
            "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4",
            "headerProtectionKey", "randomTrailers", "disableCookies", "mtu", "subnetIp", "subnetCidr",
            "keepaliveTimeout", "rekeyAfterTime", "rekeyTimeout", "rejectAfterTime", "maxHandshakeAttempts",
            "i1", "i2", "i3", "i4", "i5", "contentPaddingAddition", "cpa"
        ]:
            if param in cur_srv:
                target_settings["server"][param] = cur_srv[param]
        if cur_srv.get("headerProtectionKey"):
            preserved.append("HeaderProtectionKey AWG")
        if cur_srv.get("contentPaddingAddition") or cur_srv.get("cpa"):
            preserved.append("ContentPaddingAddition (CPA)")

        # Аудит и оптимизация AmneziaWG (v3.1 и v2.0):
        # 1. RandomTrailers:
        # Для новых профилей по умолчанию отключен (off/False).
        # На существующем инбаунде сохраняем действующее значение сервера, чтобы не нарушать wire-формат клиентов.
        # Принудительно отключается только при явном указании AWG_DISABLE_RANDOM_TRAILERS=1.
        disable_rt = os.environ.get("AWG_DISABLE_RANDOM_TRAILERS", "").strip().lower() in ("1", "y", "true")
        if disable_rt and target_settings["server"].get("randomTrailers"):
            target_settings["server"]["randomTrailers"] = False
            repairs.append("отключен randomTrailers по флагу AWG_DISABLE_RANDOM_TRAILERS")

        # 1.1 Коррекция граничного условия таймингов в 3X-UI: строго max(rekey) < min(reject)
        rekey_val = str(target_settings["server"].get("rekeyAfterTime", ""))
        reject_val = str(target_settings["server"].get("rejectAfterTime", ""))
        if "-" in rekey_val and "-" in reject_val:
            try:
                r_parts = [int(x.strip()) for x in rekey_val.split("-", 1)]
                rej_parts = [int(x.strip()) for x in reject_val.split("-", 1)]
                if r_parts[1] >= rej_parts[0]:
                    new_r_max = max(r_parts[0], rej_parts[0] - 10)
                    target_settings["server"]["rekeyAfterTime"] = f"{r_parts[0]}-{new_r_max}"
                    repairs.append(f"исправлен rekeyAfterTime='{r_parts[0]}-{new_r_max}' (обеспечение max(rekey) < min(reject) для валидатора 3X-UI)")
            except (ValueError, IndexError):
                pass

        # 2. Фиксация базового MTU 1280 (уменьшение риска фрагментации)
        cur_mtu = target_settings["server"].get("mtu")
        try:
            cur_mtu_int = int(cur_mtu) if cur_mtu is not None else 1280
        except (TypeError, ValueError):
            cur_mtu_int = 1280
        if cur_mtu_int > 1280:
            target_settings["server"]["mtu"] = 1280
            repairs.append(f"исправлен MTU={cur_mtu_int} -> 1280 (базовый MTU)")

        # 3. Аудит смещений S1-S4: должны быть >= 12 при активном HeaderProtectionKey
        has_hpk = bool(target_settings["server"].get("headerProtectionKey"))
        if has_hpk:
            s_defaults = {"s1": 16, "s2": 16, "s3": 16, "s4": 16}
            for s_param, min_val in [("s1", 12), ("s2", 12), ("s3", 12), ("s4", 12)]:
                val = target_settings["server"].get(s_param)
                try:
                    val_int = int(val)
                except (TypeError, ValueError):
                    val_int = 0
                if val_int < min_val:
                    target_settings["server"][s_param] = s_defaults[s_param]
                    repairs.append(f"исправлен {s_param}={val} -> {s_defaults[s_param]} (требование HPK: S >= 12)")

        # 4. Валидация мусорных пакетов Jc / Jmin / Jmax (допустимый диапазон Jc: 0-128, J: 0-1280)
        cur_jc = target_settings["server"].get("jc")
        if cur_jc is not None:
            try:
                jc_int = int(cur_jc)
                if jc_int < 0 or jc_int > 128:
                    target_settings["server"]["jc"] = 4
                    repairs.append(f"исправлен Jc={cur_jc} -> 4 (выход за пределы протокола 0-128)")
            except (TypeError, ValueError):
                target_settings["server"]["jc"] = 4
                repairs.append(f"исправлен Jc={cur_jc} -> 4 (некорректное значение)")

        cur_jmin = target_settings["server"].get("jmin")
        cur_jmax = target_settings["server"].get("jmax")
        if cur_jmin is not None and cur_jmax is not None:
            try:
                jmin_int = int(cur_jmin)
                jmax_int = int(cur_jmax)
                if jmin_int < 0 or jmax_int < 0 or jmin_int > jmax_int or jmax_int > 1280:
                    target_settings["server"]["jmin"] = 40
                    target_settings["server"]["jmax"] = 70
                    repairs.append("исправлены некорректные Jmin/Jmax -> Jmin=40, Jmax=70")
            except (TypeError, ValueError):
                target_settings["server"]["jmin"] = 40
                target_settings["server"]["jmax"] = 70
                repairs.append("исправлены нечисловые Jmin/Jmax -> Jmin=40, Jmax=70")

    # Е. Проверка и ремонт Shadowsocks 2022
    if protocol == "shadowsocks":
        ss_method = cur_settings.get("method") or target_settings.get("method", "2022-blake3-aes-256-gcm")
        target_settings["method"] = ss_method
        target_settings["network"] = "tcp,udp"
        target_settings["udpOverTcp"] = True
        target_settings["udp_over_tcp"] = True
        if target_stream.get("network") in ("tcp,udp", "udp"):
            target_stream["network"] = "tcp"
            repairs.append("исправлен network в stream_settings -> 'tcp'")

        # Валидация / сохранение серверного пароля (PSK)
        cur_srv_pwd = cur_settings.get("password")
        if cur_srv_pwd and not globals().get("regen_server_keys", False) and "validate_ss2022_key" in globals() and validate_ss2022_key(cur_srv_pwd, ss_method):
            target_settings["password"] = cur_srv_pwd
            preserved.append("серверный ключ SS-2022")
        elif "generate_ss2022_key" in globals():
            target_settings["password"] = target_settings.get("password") or generate_ss2022_key(ss_method)
            if globals().get("regen_server_keys", False):
                repairs.append("обновлен серверный мастер-ключ SS-2022")
            else:
                repairs.append("сгенерирован валидный серверный ключ SS-2022 (исправлена ошибка длины)")

        # Аудит клиентов: валидация ключей и очистка устаревшего поля 'method'
        c_repaired = False
        method_removed = False
        for c in target_settings.get("clients", []):
            if "method" in c:
                c.pop("method", None)
                method_removed = True
            c_pwd = c.get("password")
            if not c_pwd or ("validate_ss2022_key" in globals() and not validate_ss2022_key(c_pwd, ss_method)):
                if "generate_ss2022_key" in globals():
                    c["password"] = generate_ss2022_key(ss_method)
                    c_repaired = True
        if method_removed:
            repairs.append("удалено устаревшее поле client.method")
        if c_repaired:
            repairs.append("исправлен невалидный ключ клиента SS-2022")
        elif not any("невалидный ключ" in r for r in repairs):
            preserved.append("ключи клиентов SS-2022")

    # Ж. Проверка и ремонт TUIC v5
    if protocol == "tuic":
        tuic_cert = cur_settings.get("certificate") or target_settings.get("certificate") or globals().get("ssl_cert") or ""
        tuic_key = cur_settings.get("private_key") or target_settings.get("private_key") or globals().get("ssl_key") or ""
        if cur_settings.get("certificate") and cur_settings.get("private_key"):
            target_settings["certificate"] = tuic_cert
            target_settings["private_key"] = tuic_key
            preserved.append("SSL-сертификаты TUIC")
        else:
            target_settings["certificate"] = tuic_cert
            target_settings["private_key"] = tuic_key
            repairs.append("добавлены пути сертификатов в settings TUIC")

        target_settings["congestion_control"] = cur_settings.get("congestion_control") or target_settings.get("congestion_control", "bbr")
        target_settings["alpn"] = cur_settings.get("alpn") or target_settings.get("alpn", ["h3", "spdy/3.1"])
        for tuic_opt in ["udp_relay_mode", "zero_rtt_handshake", "max_idle_time", "authentication_timeout", "max_udp_relay_packet_size", "sni"]:
            if tuic_opt in cur_settings:
                target_settings[tuic_opt] = cur_settings[tuic_opt]
        if cur_settings.get("congestion_control"):
            preserved.append(f"congestion_control ({target_settings['congestion_control']})")
        if cur_settings.get("alpn"):
            preserved.append(f"alpn ({target_settings['alpn']})")

        target_stream["network"] = "quic"
        target_stream["security"] = "tls"

    # З. Проверка и ремонт Telegram MTProxy (FakeTLS)
    if protocol == "mtproto":
        root_cleaned = False
        for obsolete_field in ["secret", "adTag", "ad_tag"]:
            if obsolete_field in cur_settings or obsolete_field in target_settings:
                target_settings.pop(obsolete_field, None)
                root_cleaned = True
        if root_cleaned:
            repairs.append("очищены устаревшие корневые поля secret/adTag в settings MTProto")

        if cur_settings.get("domainFronting"):
            target_settings["domainFronting"] = cur_settings["domainFronting"]
            preserved.append("domainFronting MTProto")

        target_settings["preferIp"] = cur_settings.get("preferIp") or target_settings.get("preferIp") or "prefer-ipv4"
        if target_settings.get("preferIp") == "prefer-ipv4":
            preserved.append("preferIp (prefer-ipv4)")

        mtp_faketls = globals().get("mtproto_faketls_domain") or target_settings.get("domainFronting", {}).get("ip") or "gateway.icloud.com"
        for c in target_settings.get("clients", []):
            c_sec = c.get("secret")
            if not c_sec or ("validate_mtproto_secret" in globals() and not validate_mtproto_secret(c_sec)):
                if "generate_mtproto_secret" in globals():
                    c["secret"] = generate_mtproto_secret(mtp_faketls)
                    repairs.append("исправлен/сгенерирован FakeTLS секрет MTProto")
            else:
                preserved.append("секрет FakeTLS MTProto")
            c_ad = c.get("adTag") or c.get("ad_tag")
            if c_ad:
                if "validate_mtproto_adtag" in globals() and not validate_mtproto_adtag(c_ad):
                    c["adTag"] = ""
                    c.pop("ad_tag", None)
                    repairs.append("очищен невалидный adTag MTProto")
                else:
                    c["adTag"] = c_ad
                    c.pop("ad_tag", None)
                    preserved.append("промо-тег adTag MTProto")

    # И. Проверка и сохранение externalProxy (:443, SNI и кастомных хостов узлов)
    cur_ext = cur_stream.get("externalProxy", [])
    h_port = globals().get("hy2_port", 443)
    expected_ext_port = 443 if protocol in ("vless", "hysteria") and port != h_port else (h_port if protocol == "hysteria" else port)

    cur_domain = globals().get("domain", "")
    def_ext = default_stream.get("externalProxy", [])
    def_dest = def_ext[0].get("dest") if (def_ext and isinstance(def_ext, list) and def_ext[0].get("dest")) else cur_domain
    def_sni = def_ext[0].get("sni", "") if (def_ext and isinstance(def_ext, list) and def_ext[0].get("sni")) else ""

    force_sub_flag = globals().get("force_sub", False)
    # Сохраняем кастомный хост узла (dest), если он был настроен и не равен localhost
    target_dest = def_dest
    if not force_sub_flag and cur_ext and len(cur_ext) > 0 and cur_ext[0].get("dest"):
        ext_dest = str(cur_ext[0]["dest"]).strip()
        if ext_dest and ext_dest not in ("127.0.0.1", "localhost", "0.0.0.0"):
            if ext_dest == cur_domain and def_dest != cur_domain:
                target_dest = def_dest
            else:
                target_dest = ext_dest
                if ext_dest != cur_domain and ext_dest != def_dest:
                    preserved.append(f"кастомный хост узла ({ext_dest})")

    if protocol in ("shadowsocks", "mtproto", "amneziawg"):
        force_tls_val = "none"
    elif protocol == "vless" and "realitySettings" in target_stream:
        force_tls_val = "same"
    else:
        force_tls_val = "tls"

    cur_fps = [ce.get("fingerprint") for ce in cur_ext] if (cur_ext and isinstance(cur_ext, list)) else []
    def_fps = [de.get("fingerprint") for de in def_ext] if (def_ext and isinstance(def_ext, list)) else []
    fp_changed = bool(def_fps and cur_fps != def_fps)
    sni_pool_changed = bool(target_snis and target_snis != old_snis)
    if len(def_ext) > 1 or sni_pool_changed or fp_changed:
        updated_ext = []
        for de in def_ext:
            entry = dict(de)
            if target_dest:
                entry["dest"] = target_dest
            entry["port"] = expected_ext_port
            entry["forceTls"] = force_tls_val
            if "alpn" in entry and isinstance(entry["alpn"], str):
                entry["alpn"] = [entry["alpn"]] if entry["alpn"] else []
            updated_ext.append(entry)
        target_stream["externalProxy"] = updated_ext
        if cur_ext != updated_ext:
            repairs.append(f"обновлен externalProxy ({len(updated_ext)} узлов)")
        else:
            preserved.append(f"externalProxy ({len(updated_ext)} узлов)")
    else:
        # Сохраняем SNI для externalProxy (критично для VLESS REALITY и маршрутизации Nginx Stream L4)
        target_sni = def_sni
        if not force_sub_flag and cur_ext and len(cur_ext) > 0 and cur_ext[0].get("sni"):
            ext_sni = str(cur_ext[0]["sni"]).strip()
            if ext_sni:
                if ext_sni == cur_domain and def_sni != cur_domain:
                    target_sni = def_sni
                else:
                    target_sni = ext_sni
                    if target_sni != def_sni:
                        preserved.append(f"кастомный externalProxy SNI ({ext_sni})")

        ext_entry = {
            "dest": target_dest,
            "port": expected_ext_port,
            "forceTls": force_tls_val,
            "remark": final_remark
        }
        if target_sni:
            ext_entry["sni"] = target_sni
        if def_ext and isinstance(def_ext, list):
            if def_ext[0].get("fingerprint"):
                ext_entry["fingerprint"] = def_ext[0]["fingerprint"]
            if def_ext[0].get("alpn"):
                ext_alpn = def_ext[0]["alpn"]
                if isinstance(ext_alpn, str):
                    ext_alpn = [ext_alpn] if ext_alpn else []
                ext_entry["alpn"] = ext_alpn

        def_fp = def_ext[0].get("fingerprint") if (def_ext and isinstance(def_ext, list) and len(def_ext) > 0) else None
        cur_fp_single = cur_ext[0].get("fingerprint") if (cur_ext and isinstance(cur_ext, list) and len(cur_ext) > 0) else None

        def_alpn = def_ext[0].get("alpn") if (def_ext and isinstance(def_ext, list) and len(def_ext) > 0) else None
        if isinstance(def_alpn, str):
            def_alpn = [def_alpn] if def_alpn else []
        cur_alpn = cur_ext[0].get("alpn") if (cur_ext and isinstance(cur_ext, list) and len(cur_ext) > 0) else None

        alpn_needs_repair = False
        if isinstance(cur_alpn, str):
            alpn_needs_repair = True
        elif def_alpn is not None and cur_alpn != def_alpn:
            alpn_needs_repair = True

        needs_ext_repair = (
            not cur_ext
            or cur_ext[0].get("port") != expected_ext_port
            or cur_ext[0].get("dest") != target_dest
            or cur_ext[0].get("remark") != final_remark
            or cur_ext[0].get("forceTls") != force_tls_val
            or (target_sni and cur_ext[0].get("sni") != target_sni)
            or (def_fp and cur_fp_single != def_fp)
            or alpn_needs_repair
        )

        if needs_ext_repair:
            target_stream["externalProxy"] = [ext_entry]
            sni_desc = f", sni: {target_sni}" if target_sni else ""
            repairs.append(f"исправлен externalProxy -> {target_dest}:{expected_ext_port}{sni_desc}")
        else:
            for ep in cur_ext:
                if isinstance(ep, dict) and "alpn" in ep and isinstance(ep["alpn"], str):
                    ep["alpn"] = [ep["alpn"]] if ep["alpn"] else []
                    repairs.append("исправлен тип alpn в externalProxy (string -> array)")
            target_stream["externalProxy"] = cur_ext
            preserved.append(f"externalProxy :{expected_ext_port}")

    # В 3X-UI externalProxy[].alpn обязан быть массивом (array), строка вызывает ошибку валидации формы
    if "externalProxy" in target_stream and isinstance(target_stream["externalProxy"], list):
        for ep in target_stream["externalProxy"]:
            if isinstance(ep, dict) and "alpn" in ep and isinstance(ep["alpn"], str):
                ep["alpn"] = [ep["alpn"]] if ep["alpn"] else []

    # Синхронизация клиентов в реестре (client_traffics, clients, client_inbounds)
    if "sync_inbound_clients" in globals():
        sync_inbound_clients(inbound_id, protocol, final_remark, target_settings, target_stream)

    # Запись в SQLite
    settings_json = json.dumps(target_settings, ensure_ascii=False)
    stream_json = json.dumps(target_stream, ensure_ascii=False)
    sniffing_json = json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"]})

    if not dry_run:
        update_fields = [
            "protocol = ?", "tag = ?", "remark = ?", "settings = ?",
            "stream_settings = ?", "listen = ?", "sniffing = ?", "enable = ?"
        ]
        effective_enable = (0 if not enabled else cur_enable)
        update_vals = [protocol, tag, final_remark, settings_json, stream_json, listen, sniffing_json, effective_enable]
        if tr_col and tr_col in inb_cols:
            update_fields.append(f"{tr_col} = ?")
            update_vals.append(final_tr)
        if trd_col and trd_col in inb_cols:
            update_fields.append(f"{trd_col} = ?")
            update_vals.append(final_tr_day)
        update_vals.append(inbound_id)
        cur.execute(f"UPDATE inbounds SET {', '.join(update_fields)} WHERE id = ?", tuple(update_vals))

    status_str = f"  [ОБНОВЛЕН] {final_remark} (порт {port}):"
    if repairs:
        status_str += f"\n    -> Исправлено: {', '.join(repairs)}"
    if preserved:
        status_str += f"\n    -> Сохранено: {', '.join(preserved)}"
    print(status_str)
    return inbound_id
