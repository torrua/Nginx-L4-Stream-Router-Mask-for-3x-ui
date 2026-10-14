"""Read-only audit of source; reproductions use fixtures and mocked external calls.

No VPS, Docker daemon, package manager, network registration, or real keys used.
Run: python audit/2026-10-14/audit_checks.py
"""
import ast
import base64
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import tempfile
import types
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")
RESULTS = []

def record(name, status, **details):
    RESULTS.append(dict(check=name, status=status, **details))

def source(name, start=None, end=None):
    lines = (ROOT / name).read_text(encoding="utf-8").splitlines()
    return "\n".join(lines[(start or 1)-1:end]) + "\n"

def bash(code):
    return subprocess.run([str(BASH), "-s"], input="export PATH=/usr/bin:/bin:$PATH\n"+code, text=True, capture_output=True,
                          cwd=ROOT, timeout=15, encoding="utf-8")

def bash_file(name, *args):
    return subprocess.run([str(BASH), "-c", 'export PATH=/usr/bin:/bin:$PATH; exec bash "$@"', '--', name, *args],
                          cwd=ROOT, capture_output=True, text=True, timeout=15, encoding="utf-8")

def functions(name):
    tree = ast.parse(source(name))
    module = ast.Module(body=[n for n in tree.body if isinstance(n, ast.FunctionDef)], type_ignores=[])
    ns = dict(os=os, re=re, json=json, Path=Path, base64=base64,
              datetime=__import__('datetime').datetime, timezone=__import__('datetime').timezone)
    exec(compile(module, name, "exec"), ns)
    return ns

def fixture_db(path, modern=False):
    c = sqlite3.connect(path)
    c.executescript('''
        CREATE TABLE settings(id INTEGER PRIMARY KEY, key TEXT, value TEXT);
        CREATE TABLE users(id INTEGER PRIMARY KEY, username TEXT, password TEXT);
        INSERT INTO users VALUES(1, 'fixture-admin', 'fixture-password-hash');
        CREATE TABLE inbounds(id INTEGER PRIMARY KEY, user_id INTEGER, up INTEGER,
          down INTEGER, total INTEGER, remark TEXT, enable INTEGER, expiry_time INTEGER,
          listen TEXT, port INTEGER, protocol TEXT, settings TEXT, stream_settings TEXT,
          tag TEXT, sniffing TEXT);
    ''')
    if modern:
        c.executescript('''
          CREATE TABLE clients(id INTEGER PRIMARY KEY, email TEXT, enable INTEGER,
            created_at INTEGER, updated_at INTEGER, uuid TEXT, sub_id TEXT,
            password TEXT, wg_private_key TEXT, wg_public_key TEXT, wg_allowed_ips TEXT);
          CREATE TABLE client_traffics(id INTEGER PRIMARY KEY, email TEXT, inbound_id INTEGER,
            enable INTEGER, up INTEGER, down INTEGER, expiry_time INTEGER, total INTEGER, reset INTEGER);
          CREATE TABLE client_inbounds(client_id INTEGER, inbound_id INTEGER,
            flow_override TEXT, created_at INTEGER);
        ''')
    return c

def run_config(path, **env):
    raw = source("configure_3xui.sh").split("<< 'EOF_PYTHON_CONFIG'", 1)[1].split("\n", 1)[1]
    code = raw.split("conn.commit()", 1)[0] + "conn.commit()\n"
    env = dict(DB_PATH=str(path), PRIMARY_DOMAIN="audit.example", DRY_RUN="0",
               ENABLE_STEAL="n", ENABLE_CLASSIC="n", ENABLE_HY2="n",
               ENABLE_AWG_V3="n", ENABLE_AWG_V2="n", ENABLE_WARP="n") | env
    ns = {}
    with patch.dict(os.environ, env, clear=True), patch("subprocess.run", return_value=types.SimpleNamespace(returncode=1, stdout="")), contextlib.redirect_stdout(io.StringIO()):
        exec(compile(code, "configure_3xui.sh:480-1906", "exec"), ns)
    ns["conn"].close()
    return ns

def main():
    for name in ["install.sh", "secure-vps.sh", "setup_mask.sh", "configure_3xui.sh", "update_repair.sh", "manage_amneziawg.sh"]:
        r = subprocess.run([str(BASH), "-n", name], cwd=ROOT, capture_output=True, text=True)
        record("bash_syntax:"+name, "PASS" if r.returncode == 0 else "FAIL", exit_code=r.returncode)
    ast.parse(source("manage_amneziawg.py"))
    record("python_syntax:manage_amneziawg.py", "PASS")
    for name, marker in [("configure_3xui.sh", "EOF_PYTHON_CONFIG"), ("update_repair.sh", "EOF_PYTHON_RECONCILE")]:
        code = source(name).split("<< '"+marker+"'", 1)[1].split("\n", 1)[1].split("\n"+marker, 1)[0]
        ast.parse(code)
        record("embedded_python_syntax:"+name, "PASS")
    for name in ["setup_mask.sh", "configure_3xui.sh", "update_repair.sh"]:
        r = bash_file(name, "--help")
        record("cli_help:"+name, "PASS" if r.returncode == 0 else "FAIL", exit_code=r.returncode)
    for name in ["setup_mask.sh", "install.sh"]:
        r = bash_file(name, "--version")
        record("cli_version:"+name, "PASS" if r.returncode == 0 and "v7.3.4" in r.stdout else "FAIL", exit_code=r.returncode)

    with tempfile.TemporaryDirectory(prefix="audit-fixture-", dir=OUT) as d:
        tmp = Path(d)
        cfg = tmp / "generated.env"
        r = bash_file("setup_mask.sh", "--gen-config", cfg.as_posix())
        record("cli_config_generation", "PASS" if r.returncode == 0 and cfg.exists() else "FAIL", exit_code=r.returncode)

        # Random-generation pipeline used by interactive Express, with set -e.
        r = bash("set -euo pipefail\nunset ADMIN_PASSWORD\n" + source("setup_mask.sh", 2283, 2283) + "echo REACHED_AFTER_GENERATION\n")
        record("express_random_pipeline", "DEFECT_REPRODUCED" if r.returncode != 0 else "NOT_REPRODUCED",
               exit_code=r.returncode, reached_next_statement="REACHED_AFTER_GENERATION" in r.stdout)

        # Only in-memory initialization and selected noninteractive branch.
        r = bash("set -euo pipefail\nwarn(){ :; }; ok(){ :; };\n" + source("setup_mask.sh", 68, 71) + source("setup_mask.sh", 704, 835) +
                 "PRIMARY_DOMAIN=audit.example; ENABLE_HY2=y; PANEL_PATH=paneltest; SUB_PATH=subtest; XHTTP_STREAM_PATH=xhtest;\n" +
                 "reconstruct_arrays_from_vars\n" +
                 "for k in HY2_PORT_HOPPING AUTO_SETUP_3XUI CF_AUTH_METHOD; do if [[ -v $k ]]; then echo $k=defined; else echo $k=UNDEFINED; fi; done\n" +
                 "echo AWG=$ENABLE_AWG_V3 AGH=$ENABLE_AGH WARP=$ENABLE_WARP\n" + source("setup_mask.sh", 5337, 5339) + "echo NAT_BRANCH; fi\n")
        record("noninteractive_missing_defaults", "DEFECT_REPRODUCED" if r.returncode != 0 else "NOT_REPRODUCED", exit_code=r.returncode,
               output=r.stdout.strip(), error=r.stderr.strip())
        r = bash("set -euo pipefail\nwarn(){ :; };\n" + source("setup_mask.sh", 68, 71) + source("setup_mask.sh", 704, 835) +
                 "PRIMARY_DOMAIN=audit.example; ENABLE_HY2=y; HY2_DOMAIN=hy.audit.example; ENABLE_AGH=y; AGH_MODE=2; AGH_DOMAIN=dns.audit.example; PANEL_PATH=ptest; SUB_PATH=stest; XHTTP_STREAM_PATH=xtest;\nreconstruct_arrays_from_vars\nprintf '%s\\n' \"${ALL_DOMAINS[@]}\"\n")
        record("noninteractive_certificate_domains", "DEFECT_REPRODUCED" if "hy.audit.example" not in r.stdout and "dns.audit.example" not in r.stdout else "NOT_REPRODUCED", domains=r.stdout.splitlines())

        r = bash("set -euo pipefail\nDEBUG_MODE=1; NON_INTERACTIVE=1; CYAN=; WHITE=; NC=; DIM=; GREEN=; CHECK=; RED=; CROSS=; BOLD=; YELLOW=; ARROW=;\n" + source("setup_mask.sh", 232, 334) +
                 "failing_step(){ false; echo CONTINUED_AFTER_FAILURE; };\nrun_with_spinner fixture failing_step || exit 10\n")
        record("spinner_function_masks_internal_failure", "DEFECT_REPRODUCED" if r.returncode==0 and 'CONTINUED_AFTER_FAILURE' in r.stdout else "NOT_REPRODUCED", exit_code=r.returncode)

        # Main configurator on a synthetic legacy schema, then modern-schema fixtures.
        db = tmp / "legacy.db"
        c = fixture_db(db); c.commit(); c.close()
        run_config(db)
        record("configurator_legacy_fixture", "PASS")

        db = tmp / "clients.db"; c = fixture_db(db, modern=True)
        c.execute("INSERT INTO clients VALUES(1,'alice-classic',0,0,0,'uuid-a','sub-a','pwd-a','','','')")
        c.execute("INSERT INTO clients VALUES(2,'bob',0,0,0,'uuid-b','sub-b','pwd-b','','','')")
        c.execute("INSERT INTO client_traffics VALUES(1,'alice-classic',10,0,100,200,0,1000,0)")
        c.execute("INSERT INTO client_inbounds VALUES(1,10,'',0)"); c.commit(); c.close()
        run_config(db)
        c=sqlite3.connect(db)
        removed = c.execute("SELECT count(*) FROM clients WHERE email='alice-classic'").fetchone()[0] == 0
        copied = c.execute("SELECT uuid,sub_id FROM clients WHERE email='Client'").fetchone() == ('uuid-a','sub-a')
        record("client_suffix_deletion_and_identity_copy", "DEFECT_REPRODUCED" if removed and copied else "NOT_REPRODUCED", deleted_existing_client=removed, copied_another_identity=copied)
        c.close()

        db = tmp / "disabled.db"; c = fixture_db(db, modern=True)
        client = dict(id="uuid-existing", email="Client", subId="sub-existing", enable=False)
        c.execute("INSERT INTO clients VALUES(1,'Client',0,0,0,'uuid-existing','sub-existing','pwd','','','')")
        c.execute("INSERT INTO client_traffics VALUES(1,'Client',1,0,100,200,0,1000,0)")
        c.execute("INSERT INTO inbounds VALUES(1,1,0,0,0,'custom',0,0,'127.0.0.1',50443,'vless',?,?,'in-xhttp-stream','{}')",
                  (json.dumps(dict(clients=[client],decryption="old-decryption",encryption="old-encryption")),json.dumps(dict(network="xhttp",xhttpSettings=dict(path="/existing/")))))
        c.commit(); c.close(); run_config(db)
        c=sqlite3.connect(db); ib=c.execute("SELECT enable,settings FROM inbounds WHERE id=1").fetchone()
        flags=[ib[0], c.execute("SELECT enable FROM clients WHERE email='Client'").fetchone()[0], c.execute("SELECT enable FROM client_traffics WHERE email='Client'").fetchone()[0]]
        record("disabled_client_and_inbound_reenabled", "DEFECT_REPRODUCED" if flags == [1,1,1] else "NOT_REPRODUCED", flags=flags, json_client_enable=json.loads(ib[1])["clients"][0]["enable"])
        record("xhttp_encryption_not_preserved", "DEFECT_REPRODUCED" if json.loads(ib[1]).get("decryption") != "old-decryption" else "NOT_REPRODUCED", resulting_decryption=json.loads(ib[1]).get("decryption"))
        c.close()

        # WAL copy failure: main file alone misses committed changes in WAL.
        wal=tmp/'wal.db'; c=sqlite3.connect(wal)
        c.execute('PRAGMA journal_mode=WAL'); c.execute('PRAGMA wal_autocheckpoint=0')
        c.execute('CREATE TABLE sample(value TEXT)'); c.commit(); c.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        c.execute("INSERT INTO sample VALUES('committed-in-wal')"); c.commit()
        shutil.copyfile(wal,tmp/'copied.db'); copied=sqlite3.connect(tmp/'copied.db')
        count=copied.execute('SELECT count(*) FROM sample').fetchone()[0]
        record("sqlite_live_file_copy_loses_wal", "DEFECT_REPRODUCED" if count==0 else "NOT_REPRODUCED", copied_rows=count, original_rows=1)
        copied.close(); c.close()

        db = tmp/'schema.db'; c=fixture_db(db)
        c.execute('CREATE TABLE clients(id INTEGER PRIMARY KEY,email TEXT)'); c.commit(); c.close()
        try:
            run_config(db)
            record('configurator_unknown_clients_schema', 'NOT_REPRODUCED')
        except sqlite3.OperationalError as e:
            record('configurator_unknown_clients_schema', 'DEFECT_REPRODUCED', error=str(e))

        # --dry-run still attempts Cloudflare registration; network fully mocked.
        db=tmp/'dryrun-warp.db'; c=fixture_db(db); c.commit(); c.close()
        class Response:
            def __enter__(self): return self
            def __exit__(self,*a): pass
            def read(self): return b'{"id":"fixture-device","token":"fixture-token","config":{}}'
        digest=hashlib.sha256(db.read_bytes()).hexdigest()
        with patch('urllib.request.urlopen',return_value=Response()) as urlopen:
            run_config(db,DRY_RUN='1',ENABLE_WARP='y')
        record('dryrun_warp_registration_side_effect', 'DEFECT_REPRODUCED' if urlopen.call_count>0 else 'NOT_REPRODUCED',
               external_post_attempts=urlopen.call_count, database_unchanged=digest==hashlib.sha256(db.read_bytes()).hexdigest())

        # Existing WARP route priority is kept before existing YouTube exception.
        db=tmp/'routes.db'; c=fixture_db(db)
        tpl=dict(outbounds=[dict(tag='direct',protocol='freedom'),dict(tag='blocked',protocol='blackhole'),dict(tag='warp',protocol='wireguard',settings=dict(secretKey='fixture'))],
                 routing=dict(domainStrategy='AsIs',rules=[dict(type='field',outboundTag='warp',domain=['domain:googlevideo.com']),dict(type='field',outboundTag='direct',domain=['domain:youtube.com'])]))
        c.execute('INSERT INTO settings(key,value) VALUES(?,?)',('xrayTemplateConfig',json.dumps(tpl)))
        c.execute('INSERT INTO settings(key,value) VALUES(?,?)',('warpData',json.dumps(dict(private_key='fixture',device_id='fixture'))))
        c.commit(); c.close(); run_config(db,ENABLE_WARP='y')
        c=sqlite3.connect(db); tpl=json.loads(c.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()[0]); c.close()
        rules=tpl['routing']['rules']; wi=next(i for i,r in enumerate(rules) if r['outboundTag']=='warp'); yi=next(i for i,r in enumerate(rules) if r['outboundTag']=='direct' and 'domain:googlevideo.com' in r.get('domain',[]))
        record('existing_warp_rule_precedes_youtube_exception','DEFECT_REPRODUCED' if wi<yi else 'NOT_REPRODUCED', warp_index=wi,youtube_index=yi,
               ru_rule_combines_domain_and_ip=any(r.get('outboundTag')=='direct' and 'domain:ru' in r.get('domain',[]) and 'geoip:ru' in r.get('ip',[]) for r in rules))

        # Literal IP-mask test combines curl's 000 stdout and appended fallback.
        r=bash("curl(){ printf 000; return 35; };\n"+source('setup_mask.sh',1670,1670)+"printf '%s' \"$ip_resp\"\n")
        record('doctor_drop_status_concatenation','DEFECT_REPRODUCED' if r.stdout=='000DROP' else 'NOT_REPRODUCED', actual_output=r.stdout)

        # AWG functions only; importing module would have side effects.
        n=functions("manage_amneziawg.py")
        commands=[]; table=[]; saved=[]
        def cmd(text, **kwargs):
            commands.append(text)
            if 'genkey' in text: return ('fixture-private-key','',0)
            if 'pubkey' in text: return ('fixture-public-key','',0)
            return ('','',1)
        n.update(CONTAINER='fixture-container', AWG_DIR=tmp/'nested'/'exports', SERVER_HOST='audit.example', SERVER_PORT='8443', CLIENT_MTU='1280',
                 run_cmd=cmd, ensure_container_networking=lambda:None, load_clients_table=lambda:table,
                 save_clients_table=lambda t:saved.append(t), read_container_file=lambda _: '[Interface]\nAddress=10.66.0.1/24\n',
                 append_container_file=lambda *a:None, get_server_pubkey=lambda:'fixture-server-public',get_server_psk=lambda:'fixture-psk',
                 encode_amnezia_vpnuri_31=lambda *a,**kw:'fixture-uri')
        for key in ['JC','JMIN','JMAX','S1','S2','S3','S4','H1','H2','H3','H4','I1','HEADER_PROTECTION_KEY']: n[key]='fixture'
        n['AWG_DIR'].mkdir(parents=True)
        r=n['add_client']('../escaped')
        record("awg_client_name_path_traversal", "DEFECT_REPRODUCED" if (tmp/'nested'/'escaped.conf').exists() else "NOT_REPRODUCED", reported_ok=r['ok'])
        record("awg_custom_subnet_ignored", "DEFECT_REPRODUCED" if n['find_next_ip']().startswith('10.8.') else "NOT_REPRODUCED", allocated_ip=n['find_next_ip'](), configured_subnet='10.66.0.0/24')
        r=n['block_client']('missing')
        record("awg_missing_client_block_false_success", "DEFECT_REPRODUCED" if r['ok'] else "NOT_REPRODUCED")
        persistent='[Peer]\nPublicKey=fixture-public\nAllowedIPs=10.8.1.3/32\n'
        n.update(load_clients_table=lambda:[dict(clientId='fixture-public',userData=dict(clientName='fixture',allowed_ips='10.8.1.3/32'))],
                 read_container_file=lambda _:persistent)
        before=len(saved); n['block_client']('fixture')
        record("awg_block_not_persistent", "DEFECT_REPRODUCED" if len(saved)==before else "NOT_REPRODUCED", persistent_registry_updated=len(saved)!=before)

        # Bind-mounted path: host append and docker tee -a target same file.
        bound=tmp/'bind-mounted.conf'; bound.write_text('[Interface]\n',encoding='utf-8')
        def tee_same_file(text, **kwargs):
            with bound.open('a',encoding='utf-8') as handle: handle.write(kwargs['input_data'])
            return ('','',0)
        bind_ns=functions('manage_amneziawg.py')
        bind_ns.update(CONTAINER='fixture-container', run_cmd=tee_same_file)
        bind_ns['append_container_file'](str(bound),'[Peer]\nPublicKey=fixture\n')
        occurrences=bound.read_text(encoding='utf-8').count('[Peer]')
        record('awg_bind_mount_duplicate_append','DEFECT_REPRODUCED' if occurrences==2 else 'NOT_REPRODUCED', peer_blocks=occurrences)

    # Secret scan reports only locations/categories. Do not print source values.
    signals=[]
    for p in (ROOT/'scratch').glob('*.py'):
        for i,line in enumerate(p.read_text(encoding='utf-8',errors='replace').splitlines(),1):
            if re.search(r'password\s*=\s*[\"\'](?![\"\'])',line,re.I):
                signals.append(dict(file=p.relative_to(ROOT).as_posix(),line=i,category='literal_password_argument'))
    record("ignored_operations_secret_signals", "REVIEW_REQUIRED", locations=signals, note="Heuristic only; values redacted and credentials not tested")
    manifest={p.name:dict(lines=len(p.read_text(encoding='utf-8').splitlines()),sha256=hashlib.sha256(p.read_bytes()).hexdigest())
              for p in ROOT.glob('*') if p.suffix in ('.sh','.py')}
    output=dict(scope="local source and synthetic fixtures only", platform="Windows; Git Bash 5.2.37; Python 3.13", results=RESULTS, manifest=manifest)
    (OUT/'checks.json').write_text(json.dumps(output,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    for r in RESULTS:
        print(r['status']+': '+r['check'])
    print('Evidence: '+str(OUT/'checks.json'))

if __name__ == '__main__':
    main()
