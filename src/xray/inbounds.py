def smart_reconcile_inbound(port, protocol, tag, remark, default_settings, default_stream, listen="127.0.0.1"):
    cur.execute("SELECT id, settings, stream_settings, protocol, tag, remark, listen, enable FROM inbounds WHERE port = ? OR tag = ?", (port, tag))
    row = cur.fetchone()
    
    if not row:
        # Инбаунд отсутствует -> создаем под ключ
        settings_json = json.dumps(default_settings, ensure_ascii=False)
        stream_json = json.dumps(default_stream, ensure_ascii=False)
        sniffing_json = json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"]})
        if not dry_run:
            cur.execute("""
                INSERT INTO inbounds (
                    user_id, up, down, total, remark, enable, expiry_time,
                    listen, port, protocol, settings, stream_settings, tag, sniffing
                ) VALUES (?, 0, 0, 0, ?, 1, 0, ?, ?, ?, ?, ?, ?, ?)
            """, (admin_id, remark, listen, port, protocol, settings_json, stream_json, tag, sniffing_json))
            new_inbound_id = cur.lastrowid
            if "sync_inbound_clients" in globals():
                sync_inbound_clients(new_inbound_id, protocol, remark, default_settings, default_stream)
                settings_json = json.dumps(default_settings, ensure_ascii=False)
                cur.execute("UPDATE inbounds SET settings = ? WHERE id = ?", (settings_json, new_inbound_id))
        print(f"  [СОЗДАНО] Отсутствующий инбаунд: {remark} ({protocol.upper()} на порту {port}) добавлен и зарегистрирован в реестре клиентов.")
        return

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

    # Сохранение пользовательского названия инбаунда (remark), если оно было изменено
    final_remark = remark
    force_remarks_flag = globals().get("force_remarks", False)
    if not force_remarks_flag and cur_remark and str(cur_remark).strip():
        final_remark = str(cur_remark).strip()
        if final_remark != remark:
            preserved.append(f"пользовательское название '{final_remark}'")

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
                    for limit_field in ["totalGB", "expiryTime", "limitIp", "tgId", "reset", "resetDay", "resetMax", "enable"]:
                        if limit_field in ec:
                            merged_c[limit_field] = ec[limit_field]
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
            target_settings["clients"] = existing_clients
            preserved.append(f"клиенты ({len(existing_clients)} польз.)")
        else:
            repairs.append("добавлен клиент по умолчанию")

    # Б. Проверка и ремонт VLESS REALITY
    if protocol == "vless" and "realitySettings" in target_stream:
        cur_reality = cur_stream.get("realitySettings", {})
        
        # Сохранение privateKey
        priv = cur_reality.get("privateKey")
        if priv:
            target_stream["realitySettings"]["privateKey"] = priv
            preserved.append("privateKey Reality")
        
        # Сохранение shortIds
        sids = cur_reality.get("shortIds")
        if sids:
            target_stream["realitySettings"]["shortIds"] = sids
            preserved.append("shortIds")

        # Ремонт / сохранение settings.publicKey
        pub = cur_reality.get("settings", {}).get("publicKey") or cur_reality.get("publicKey")
        if pub:
            target_stream["realitySettings"]["settings"]["publicKey"] = pub
            if not cur_reality.get("settings", {}).get("publicKey"):
                repairs.append("исправлен отсутствующий settings.publicKey (устранена ошибка empty password)")
            else:
                preserved.append("publicKey")
        else:
            derived_pub = curve25519_reality_pubkey(target_stream["realitySettings"]["privateKey"])
            if derived_pub:
                target_stream["realitySettings"]["settings"]["publicKey"] = derived_pub
                repairs.append("восстановлен settings.publicKey по x25519")

        # Ремонт мертвого swdist.microsoft.com SNI или пустых значений
        old_snis = cur_reality.get("serverNames", [])
        old_dest = str(cur_reality.get("dest", "")).strip()
        if any("swdist.microsoft.com" in s for s in old_snis) or "swdist.microsoft.com" in old_dest:
            repairs.append(f"заменен мертвый SNI swdist.microsoft.com -> {classic_sni}")
            target_stream["realitySettings"]["serverNames"] = [classic_sni]
            target_stream["realitySettings"]["dest"] = f"{classic_sni}:443"
            target_stream["realitySettings"]["xver"] = 0
        elif old_snis:
            target_stream["realitySettings"]["serverNames"] = old_snis
            target_stream["realitySettings"]["dest"] = old_dest or target_stream["realitySettings"]["dest"]
            preserved.append(f"SNI ({','.join(old_snis)})")

        # Строгая гарантия параметров VLESS REALITY (маскировка под свой сайт: Nginx Fallback + Xver=1 + target)
        if port == steal_port or tag == "in-steal-reality" or cur_tag == "in-steal-reality":
            fallback_dest = f"127.0.0.1:{reality_fallback_port}"
            if not target_stream["realitySettings"].get("dest") or target_stream["realitySettings"]["dest"] != fallback_dest:
                target_stream["realitySettings"]["dest"] = fallback_dest
                repairs.append(f"установлен dest: {fallback_dest} (Nginx SSL Fallback, защита от сброса)")
            else:
                preserved.append(f"anti-loop dest {reality_fallback_port}")
            target_stream["realitySettings"]["target"] = fallback_dest
            if target_stream["realitySettings"].get("xver") != 1:
                target_stream["realitySettings"]["xver"] = 1
                repairs.append("установлен xver: 1 (Proxy Protocol для Nginx Anti-Loop)")

        # Строгая гарантия параметров VLESS REALITY (маскировка под внешние сервисы: xver=0, dest: 443, target: 443)
        if port == classic_port or tag == "in-classic-reality" or cur_tag == "in-classic-reality":
            if not target_stream["realitySettings"].get("dest"):
                target_stream["realitySettings"]["dest"] = f"{classic_sni}:443"
                repairs.append(f"восстановлен пустой dest -> {classic_sni}:443")
            target_stream["realitySettings"]["target"] = target_stream["realitySettings"]["dest"]
            target_stream["realitySettings"]["xver"] = 0

    # В. Проверка и ремонт xHTTP
    if protocol == "vless" and "xhttpSettings" in target_stream:
        cur_xh = cur_stream.get("xhttpSettings", {})
        if cur_xh.get("path"):
            target_stream["xhttpSettings"]["path"] = cur_xh["path"]
            preserved.append(f"path ({cur_xh['path']})")
        target_stream["xhttpSettings"]["mode"] = "stream-one"
        if cur_settings.get("decryption"):
            target_settings["decryption"] = cur_settings["decryption"]
            preserved.append("decryption xHTTP")
        if cur_settings.get("encryption"):
            target_settings["encryption"] = cur_settings["encryption"]
            preserved.append("encryption xHTTP")

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

    # Е. Проверка и сохранение externalProxy (:443 и кастомных хостов узлов)
    cur_ext = cur_stream.get("externalProxy", [])
    expected_ext_port = 443 if protocol in ("vless", "hysteria") and port != hy2_port else (hy2_port if protocol == "hysteria" else port)

    # Сохраняем кастомный хост узла (dest), если он был настроен и не равен localhost
    target_dest = domain
    if cur_ext and len(cur_ext) > 0 and cur_ext[0].get("dest"):
        ext_dest = str(cur_ext[0]["dest"]).strip()
        if ext_dest and ext_dest not in ("127.0.0.1", "localhost", "0.0.0.0"):
            target_dest = ext_dest
            if ext_dest != domain:
                preserved.append(f"кастомный хост узла ({ext_dest})")

    if not cur_ext or cur_ext[0].get("port") != expected_ext_port or cur_ext[0].get("dest") != target_dest or cur_ext[0].get("remark") != final_remark:
        force_tls_val = "same" if protocol == "vless" and "realitySettings" in target_stream else "tls"
        target_stream["externalProxy"] = [{
            "dest": target_dest,
            "port": expected_ext_port,
            "forceTls": force_tls_val,
            "remark": final_remark
        }]
        repairs.append(f"исправлен externalProxy -> {target_dest}:{expected_ext_port}")
    else:
        target_stream["externalProxy"] = cur_ext
        preserved.append(f"externalProxy :{expected_ext_port}")

    # Синхронизация клиентов в реестре (client_traffics, clients, client_inbounds)
    if "sync_inbound_clients" in globals():
        sync_inbound_clients(inbound_id, protocol, final_remark, target_settings, target_stream)

    # Запись в SQLite
    settings_json = json.dumps(target_settings, ensure_ascii=False)
    stream_json = json.dumps(target_stream, ensure_ascii=False)
    sniffing_json = json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"]})

    if not dry_run:
        cur.execute("""
            UPDATE inbounds
            SET protocol = ?, tag = ?, remark = ?, settings = ?, stream_settings = ?, listen = ?, sniffing = ?, enable = ?
            WHERE id = ?
        """, (protocol, tag, final_remark, settings_json, stream_json, listen, sniffing_json, cur_enable, inbound_id))

    status_str = f"  [ОБНОВЛЕН] {final_remark} (порт {port}):"
    if repairs:
        status_str += f"\n    -> Исправлено: {', '.join(repairs)}"
    if preserved:
        status_str += f"\n    -> Сохранено: {', '.join(preserved)}"
    print(status_str)
