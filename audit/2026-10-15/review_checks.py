"""Focused review reproductions for 955ac28..92d39e7. No production changes."""
import ast
import contextlib
import importlib.util
import io
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import sqlite3
import subprocess
import tempfile
import types
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent
BASH = r'C:\Program Files\Git\bin\bash.exe' if os.name == 'nt' else 'bash'

def read(name):
    return (ROOT / name).read_text(encoding='utf-8')

def shell(code):
    return subprocess.run([BASH,'-s'],input='export PATH=/usr/bin:/bin:$PATH\n'+code,
                          cwd=ROOT,text=True,encoding='utf-8',capture_output=True,timeout=20)

def load_audit():
    spec=importlib.util.spec_from_file_location('previous_audit',ROOT/'audit/2026-10-14/audit_checks.py')
    mod=importlib.util.module_from_spec(spec)
    with patch('sys.dont_write_bytecode',True): spec.loader.exec_module(mod)
    return mod

def awg_functions():
    nodes=[n for n in ast.parse(read('manage_amneziawg.py')).body if isinstance(n,ast.FunctionDef)]
    ns=dict(Path=Path,os=os,re=re,json=json,ipaddress=ipaddress)
    exec(compile(ast.Module(body=nodes,type_ignores=[]),'manage_amneziawg.py','exec'),ns)
    return ns

def main():
    results=[]
    audit=load_audit()
    with tempfile.TemporaryDirectory(prefix='review-fixtures-',dir=OUT) as folder:
        tmp=Path(folder)

        # Same CI entrypoint; route output to temporary directory, preserve checks.json.
        audit.OUT=tmp
        captured=io.StringIO()
        try:
            with contextlib.redirect_stdout(captured): audit.main()
            results.append(dict(check='committed_audit_suite',completed=True,
                                defects_reported=[r['check'] for r in audit.RESULTS if r['status'] in ('DEFECT_REPRODUCED','FAIL')]))
        except Exception as exc:
            results.append(dict(check='committed_audit_suite',completed=False,
                                exception=type(exc).__name__,message=str(exc)))

        # Inject an ordinary failing CLI check, without altering files or commands.
        gate=load_audit(); gate.OUT=tmp
        original_bash_file=gate.bash_file
        def failing_version(name,*args):
            if name=='install.sh' and args==('--version',):
                return types.SimpleNamespace(returncode=9,stdout='',stderr='fixture CLI failure')
            return original_bash_file(name,*args)
        gate.bash_file=failing_version
        completed=False
        try:
            with contextlib.redirect_stdout(io.StringIO()): gate.main()
            completed=True
        except Exception:
            pass
        results.append(dict(check='ci_gate_ignores_failed_cli_check',completed=completed,
                            failure_was_recorded=any(r['status']=='FAIL' for r in gate.RESULTS)))

        # Exporting only the main task loses ordinary shell variables and helpers.
        r=shell('set -euo pipefail\nsource src/tui/base.sh\nDEBUG_MODE=1; NON_INTERACTIVE=1;\n'
                'PRIMARY_DOMAIN=audit.example\nhelper(){ :; }; task(){ printf "%s" "$PRIMARY_DOMAIN"; helper; };\n'
                'run_with_spinner fixture task || exit 10\n')
        results.append(dict(check='debug_spinner_loses_context',exit_code=r.returncode,
                            stderr=r.stderr.strip(),context_failure='unbound variable' in r.stderr))

        # Backup API and sqlite3 CLI failure must not silently downgrade to cp.
        wal=tmp/'wal.db'; copied=tmp/'fallback.db'
        c=sqlite3.connect(wal); c.execute('PRAGMA journal_mode=WAL'); c.execute('PRAGMA wal_autocheckpoint=0')
        c.execute('CREATE TABLE sample(value TEXT)'); c.commit(); c.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        c.execute("INSERT INTO sample VALUES('committed-in-wal')"); c.commit()
        r=shell('source src/common/backup.sh\npython3(){ return 1; }; sqlite3(){ return 1; };\n'+
                'backup_sqlite_db '+shlex.quote(wal.as_posix())+' '+shlex.quote(copied.as_posix())+'\n')
        backup=sqlite3.connect(copied)
        rows=backup.execute('SELECT count(*) FROM sample').fetchone()[0]
        results.append(dict(check='backup_fallback_loses_wal',exit_code=r.returncode,committed_rows=1,backup_rows=rows))
        backup.close(); c.close()

        # New preflight treats running AGH as a foreign conflict and never aborts on 443.
        r=shell('set -euo pipefail\nCHECK_MODE=0; NON_INTERACTIVE=0; DEBUG_MODE=0; CYAN=; BOLD=; NC=; DIM=; WHITE=; warn(){ :; }; ok(){ :; };\n'
                'source src/common/preflight.sh\nENABLE_AGH=1; PORT_AGH_WEB=3000\n'
                'is_port_in_use(){ [[ "$2" == 3000 || "$2" == 443 ]]; };\n'
                'get_port_listener_info(){ if [[ "$2" == 3000 ]]; then echo AdGuardHome; else echo docker-proxy; fi; };\n'
                'inspect_port_conflicts\nprintf "SELECTED_PORT=%s\\n" "$PORT_AGH_WEB"\n')
        results.append(dict(check='preflight_own_agh_and_foreign_https',exit_code=r.returncode,
                            own_service_was_moved='SELECTED_PORT=3001' in r.stdout,stderr=r.stderr.strip()))

        # Sanitization was added to add only; remove still traverses export directory.
        ns=awg_functions(); exports=tmp/'exports'; exports.mkdir()
        victim=tmp/'victim.conf'; victim.write_text('fixture-only',encoding='utf-8')
        ns.update(AWG_DIR=exports,CONTAINER='fixture',load_clients_table=lambda:[],
                  save_clients_table=lambda _:None,read_container_file=lambda _:'')
        result=ns['remove_client']('../victim')
        results.append(dict(check='awg_remove_path_traversal',reported_ok=result['ok'],outside_fixture_deleted=not victim.exists()))

        # Block flag exists only in clientsTable; native config still contains peer.
        config='[Interface]\nAddress=10.8.0.1/24\n[Peer]\nPublicKey = fixture-key\nAllowedIPs = 10.8.0.2/32\n'
        table=[dict(clientId='fixture-key',userData=dict(clientName='alice',allowed_ips='10.8.0.2/32'))]
        writes=[]
        ns.update(load_clients_table=lambda:table,save_clients_table=lambda t:writes.append(json.loads(json.dumps(t))),
                  read_container_file=lambda _:config,write_container_file=lambda *a:None,
                  run_cmd=lambda *a,**kw:('','',0))
        result=ns['block_client']('alice')
        results.append(dict(check='awg_block_restart_configuration',reported_ok=result['ok'],
                            blocked_flag=table[0]['userData'].get('blocked'),persisted_peer='PublicKey = fixture-key' in config))

        # Both container and host write failures are swallowed by the new fallback.
        ns=awg_functions(); ns.update(CONTAINER='fixture',run_cmd=lambda *a,**kw:('','fixture failure',1))
        try:
            ns['write_container_file'](str(tmp/'nonexistent'/'clientsTable'),'fixture')
            swallowed=True
        except Exception:
            swallowed=False
        results.append(dict(check='awg_persistent_write_failure_swallowed',swallowed=swallowed))

        # Release routing normalization must preserve constraints/custom IP entries.
        db=tmp/'routes.db'; c=audit.fixture_db(db)
        tpl=dict(outbounds=[dict(tag='direct',protocol='freedom'),dict(tag='blocked',protocol='blackhole'),
                            dict(tag='warp',protocol='wireguard',settings=dict(secretKey='fixture'))],
                 routing=dict(domainStrategy='AsIs',rules=[dict(type='field',outboundTag='direct',
                                domain=['domain:ru'],ip=['geoip:ru','203.0.113.0/24'],user=['alice'])]))
        c.execute('INSERT INTO settings(key,value) VALUES(?,?)',('xrayTemplateConfig',json.dumps(tpl)))
        c.execute('INSERT INTO settings(key,value) VALUES(?,?)',('warpData',json.dumps(dict(private_key='fixture',device_id='fixture'))))
        c.commit(); c.close()
        audit.run_config(db,ENABLE_WARP='y')
        c=sqlite3.connect(db); current=json.loads(c.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()[0]); c.close()
        results.append(dict(check='routing_custom_constraints_lost',
            user_constraint_present=any(r.get('user')==['alice'] for r in current['routing']['rules']),
            custom_network_present=any('203.0.113.0/24' in r.get('ip',[]) for r in current['routing']['rules'])))

        # Current pure-data fixes: confirm clients/status/encryption preservation.
        db=tmp/'preserve.db'; c=audit.fixture_db(db,modern=True)
        client=dict(id='uuid-existing',email='Client',subId='sub-existing',enable=False)
        c.execute("INSERT INTO clients VALUES(1,'Client',0,0,0,'uuid-existing','sub-existing','pwd','','','')")
        c.execute("INSERT INTO client_traffics VALUES(1,'Client',1,0,100,200,0,1000,0)")
        c.execute("INSERT INTO inbounds VALUES(1,1,0,0,0,'custom',0,0,'127.0.0.1',50443,'vless',?,?,'in-xhttp-stream','{}')",
            (json.dumps(dict(clients=[client],decryption='old-key',encryption='old-public')),
             json.dumps(dict(network='xhttp',xhttpSettings=dict(path='/existing/')))))
        c.commit(); c.close(); audit.run_config(db)
        c=sqlite3.connect(db); enabled,settings=c.execute('SELECT enable,settings FROM inbounds WHERE id=1').fetchone()
        results.append(dict(check='disabled_and_xhttp_keys_preserved',inbound_enable=enabled,
                            client_enable=c.execute("SELECT enable FROM clients WHERE email='Client'").fetchone()[0],
                            decryption=json.loads(settings)['decryption']))
        c.close()

    (OUT/'review_checks.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(results,ensure_ascii=False,indent=2))

if __name__=='__main__':
    main()
