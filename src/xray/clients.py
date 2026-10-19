def sync_inbound_clients(inbound_id, protocol, remark, target_settings, target_stream=None):
    clients = target_settings.get("clients", [])
    if not clients:
        return
    
    import time
    now_ms = int(time.time() * 1000)
    for idx, client in enumerate(clients):
        # 1. Email (уникальный ключ клиента в 3X-UI)
        email = client.get("email") or client.get("Email") or ""
        if not email:
            safe_remark = remark.lower().replace(" ", "-").replace("_", "-")
            email = f"client-{safe_remark}" if idx == 0 else f"client-{safe_remark}-{idx+1}"
            client["email"] = email
        
        # 2. subId для персональной подписки
        sub_id = client.get("subId") or client.get("sub_id") or ""
        if not sub_id:
            sub_id = secrets.token_hex(8)
            client["subId"] = sub_id
            
        # 3. Статус активности
        if "enable" not in client:
            client["enable"] = True
            
        client_flow = client.get("flow", "")
        client_secret = client.get("secret", "")
        client_adtag = client.get("adTag") or client.get("ad_tag") or ""
        if protocol in ("vless", "vmess"):
            client_uuid = client.get("id", "") or client.get("uuid", "")
            client_pass = client.get("password", "")
        elif protocol == "hysteria":
            client_uuid = client.get("uuid", "")
            client_pass = client.get("auth") or client.get("password") or client.get("id", "")
        elif protocol == "tuic":
            client_uuid = client.get("uuid", "") or client.get("id", "")
            client_pass = client.get("password", "")
        elif protocol == "shadowsocks":
            client_uuid = client.get("uuid", "") or client.get("id", "")
            client_pass = client.get("password", "")
        elif protocol == "mtproto":
            client_uuid = client.get("uuid", "")
            client_pass = client.get("password", "")
            if not client_pass and "secret" not in clients_cols and client_secret:
                client_pass = client_secret
        else:
            client_uuid = client.get("uuid", "")
            client_pass = client.get("password", "")
        
        if dry_run:
            continue
            
        # A. Таблица client_traffics (статистика, статус и отображение в панели 3X-UI)
        if "client_traffics" in all_tables and "email" in client_traffics_cols:
            cur.execute("SELECT id FROM client_traffics WHERE email = ?", (email,))
            ct_row = cur.fetchone()
            if not ct_row:
                ct_data = {
                    "inbound_id": inbound_id,
                    "enable": 1 if client.get("enable", True) else 0,
                    "email": email,
                    "up": 0, "down": 0, "expiry_time": 0, "total": 0, "reset": 0
                }
                for opt_col in ["uuid", "sub_id", "subId"]:
                    if opt_col in client_traffics_cols:
                        ct_data[opt_col] = client_uuid if opt_col == "uuid" else sub_id
                valid_ct = {k: v for k, v in ct_data.items() if k in client_traffics_cols}
                if valid_ct:
                    cols = ", ".join(valid_ct.keys())
                    placeholders = ", ".join(["?"] * len(valid_ct))
                    cur.execute(f"INSERT INTO client_traffics ({cols}) VALUES ({placeholders})", list(valid_ct.values()))
            else:
                ct_updates = {}
                if "enable" in client and "enable" in client_traffics_cols:
                    ct_updates["enable"] = 1 if client["enable"] else 0
                for opt_col in ["uuid", "sub_id", "subId"]:
                    if opt_col in client_traffics_cols:
                        val = client_uuid if opt_col == "uuid" else sub_id
                        if val: ct_updates[opt_col] = val
                valid_ct_up = {k: v for k, v in ct_updates.items() if k in client_traffics_cols}
                if valid_ct_up:
                    set_ct = ", ".join(f"{k} = ?" for k in valid_ct_up.keys())
                    cur.execute(f"UPDATE client_traffics SET {set_ct} WHERE email = ?", list(valid_ct_up.values()) + [email])
                
        # B. Таблица clients (единый реестр клиентов в 3X-UI v2.5+)
        client_db_id = None
        if "clients" in all_tables and "email" in clients_cols:
            cur.execute("SELECT id FROM clients WHERE email = ?", (email,))
            c_row = cur.fetchone()
            if not c_row:
                c_data = {
                    "email": email,
                    "enable": 1 if client.get("enable", True) else 0,
                    "created_at": now_ms,
                    "updated_at": now_ms
                }
                if "sub_id" in clients_cols and sub_id: c_data["sub_id"] = sub_id
                if "subId" in clients_cols and sub_id: c_data["subId"] = sub_id
                if "uuid" in clients_cols and client_uuid: c_data["uuid"] = client_uuid
                if "password" in clients_cols and client_pass and protocol != "hysteria": c_data["password"] = client_pass
                if "auth" in clients_cols and client_pass and protocol == "hysteria": c_data["auth"] = client_pass
                if "flow" in clients_cols and client_flow: c_data["flow"] = client_flow
                if "secret" in clients_cols and client_secret: c_data["secret"] = client_secret
                if "ad_tag" in clients_cols and client_adtag: c_data["ad_tag"] = client_adtag
                if "adTag" in clients_cols and client_adtag: c_data["adTag"] = client_adtag
                if protocol == "amneziawg":
                    if "wg_private_key" in clients_cols and client.get("privateKey"):
                        c_data["wg_private_key"] = client.get("privateKey")
                    if "wg_public_key" in clients_cols and client.get("publicKey"):
                        c_data["wg_public_key"] = client.get("publicKey")
                    if "wg_allowed_ips" in clients_cols and client.get("allowedIPs"):
                        ips = client.get("allowedIPs")
                        c_data["wg_allowed_ips"] = ", ".join(ips) if isinstance(ips, list) else str(ips).strip("[]'\"")
                valid_c = {k: v for k, v in c_data.items() if k in clients_cols}
                if valid_c:
                    cols = ", ".join(valid_c.keys())
                    placeholders = ", ".join(["?"] * len(valid_c))
                    cur.execute(f"INSERT INTO clients ({cols}) VALUES ({placeholders})", list(valid_c.values()))
                    client_db_id = cur.lastrowid
            else:
                client_db_id = c_row[0]
                c_updates = {}
                if "updated_at" in clients_cols:
                    c_updates["updated_at"] = now_ms
                if "enable" in client and "enable" in clients_cols:
                    c_updates["enable"] = 1 if client["enable"] else 0
                if "sub_id" in clients_cols and sub_id: c_updates["sub_id"] = sub_id
                if "uuid" in clients_cols and client_uuid: c_updates["uuid"] = client_uuid
                if "password" in clients_cols and client_pass and protocol != "hysteria": c_updates["password"] = client_pass
                if "auth" in clients_cols and client_pass and protocol == "hysteria": c_updates["auth"] = client_pass
                if "flow" in clients_cols and client_flow: c_updates["flow"] = client_flow
                if "secret" in clients_cols and client_secret: c_updates["secret"] = client_secret
                if "ad_tag" in clients_cols and client_adtag: c_updates["ad_tag"] = client_adtag
                if "adTag" in clients_cols and client_adtag: c_updates["adTag"] = client_adtag
                if protocol == "amneziawg":
                    if "wg_private_key" in clients_cols and client.get("privateKey"):
                        c_updates["wg_private_key"] = client.get("privateKey")
                    if "wg_public_key" in clients_cols and client.get("publicKey"):
                        c_updates["wg_public_key"] = client.get("publicKey")
                    if "wg_allowed_ips" in clients_cols and client.get("allowedIPs"):
                        ips = client.get("allowedIPs")
                        clean_ip = ", ".join(ips) if isinstance(ips, list) else str(ips).strip("[]'\"")
                        is_legacy_v2 = "v2" in remark.lower() or "legacy" in remark.lower()
                        cur.execute("SELECT wg_allowed_ips FROM clients WHERE id = ?", (client_db_id,))
                        curr_wg_ip_row = cur.fetchone()
                        curr_wg_ip = curr_wg_ip_row[0] if curr_wg_ip_row and curr_wg_ip_row[0] else ""
                        if not is_legacy_v2 or not curr_wg_ip or curr_wg_ip.startswith("["):
                            c_updates["wg_allowed_ips"] = clean_ip
                valid_c_up = {k: v for k, v in c_updates.items() if k in clients_cols}
                if valid_c_up:
                    set_clause = ", ".join(f"{k} = ?" for k in valid_c_up.keys())
                    cur.execute(f"UPDATE clients SET {set_clause} WHERE id = ?", list(valid_c_up.values()) + [client_db_id])
                
        # C. Таблица client_inbounds (связь клиент <-> инбаунд в 3X-UI v2.5+)
        if "client_inbounds" in all_tables and client_db_id is not None:
            cur.execute("SELECT 1 FROM client_inbounds WHERE client_id = ? AND inbound_id = ?", (client_db_id, inbound_id))
            if not cur.fetchone():
                ci_data = {
                    "client_id": client_db_id,
                    "inbound_id": inbound_id,
                    "flow_override": client_flow,
                    "created_at": now_ms
                }
                valid_ci = {k: v for k, v in ci_data.items() if k in client_inbounds_cols}
                cols = ", ".join(valid_ci.keys())
                placeholders = ", ".join(["?"] * len(valid_ci))
                cur.execute(f"INSERT INTO client_inbounds ({cols}) VALUES ({placeholders})", list(valid_ci.values()))
            else:
                if "flow_override" in client_inbounds_cols:
                    cur.execute("UPDATE client_inbounds SET flow_override = ? WHERE client_id = ? AND inbound_id = ?", (client_flow, client_db_id, inbound_id))
