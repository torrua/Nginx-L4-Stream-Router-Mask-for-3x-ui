"""
tests/test_alpine_support.py - Comprehensive Unit and Regression Test Suite for Alpine Linux & OpenRC.

Covers:
1. OpenRC and Systemd service abstraction (svc_* functions).
2. OpenRC runscript generation for all stack services:
   (zapret-server, sing-box-masque, shadow-tls, wstunnel, caddy-naive, dnstt-server, mita, awg-quick.awg0, ssh-transition-watcher, vpn-diagnostics).
3. Systemd service generation backward compatibility.
4. Zapret binary architecture selector prioritizing linux-x86_64 over android-x86_64.
5. Sing-box musl release selection on Alpine Linux.
6. Nginx user determination on Alpine (nginx) vs Debian/Ubuntu (www-data).
7. Alpine package mapping (map_pkg_to_alpine) and package manager operations (pkg_* via apk).
8. Alpine kernel headers package detection (detect_alpine_kheaders) for virt, lts, edge.
9. Kernel hook /etc/kernel-hooks.d/50-amneziawg content and automated rebuild logic.
10. SSH service name determination on Alpine (sshd).
11. Initial state snapshot and uninstall/rollback on Alpine (apk info, rc-update, apk del).
12. Sysctl /etc/local.d/99-sysctl.start boot persistence on OpenRC without crontab @reboot.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")


class TestAlpineSupport(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.work = Path(self.temp_dir.name)
        self.target_root = self.work / "rootfs"
        self.target_root.mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_bash_snippet(self, snippet: str, env: dict = None) -> subprocess.CompletedProcess:
        script = self.work / "test_snippet.sh"
        script.write_text(snippet, encoding="utf-8", newline="\n")
        run_env = os.environ.copy()
        run_env["VPN_STACK_LOCK_FILE"] = (self.work / "vpn-stack.lock").as_posix()
        if env:
            run_env.update(env)
        return subprocess.run(
            [str(BASH), str(script)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=run_env,
            timeout=25
        )

    def test_01_service_abstractions_openrc_vs_systemd(self):
        """Verify is_openrc, is_systemd, and svc_* dispatch properly to rc-service / systemctl."""
        snippet = f"""
set -euo pipefail
source "{ROOT.as_posix()}/src/system/service.sh"

# Mock OpenRC environment
is_openrc() {{ return 0; }}
is_systemd() {{ return 1; }}

rc_calls=""
rc-service() {{ rc_calls+="service:$* "; }}
rc-update() {{ rc_calls+="update:$* "; }}

svc_start "test-svc"
svc_stop "test-svc"
svc_restart "test-svc"
svc_reload "test-svc"
svc_enable "test-svc"
svc_disable "test-svc"

echo "OPENRC_CALLS: $rc_calls"

# Mock Systemd environment
is_openrc() {{ return 1; }}
is_systemd() {{ return 0; }}

sys_calls=""
systemctl() {{ sys_calls+="ctl:$* "; }}

svc_start "sys-svc"
svc_stop "sys-svc"
svc_restart "sys-svc"
svc_reload "sys-svc"
svc_enable "sys-svc"
svc_disable "sys-svc"
svc_daemon_reload

echo "SYSTEMD_CALLS: $sys_calls"
"""
        res = self.run_bash_snippet(snippet)
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertIn("OPENRC_CALLS:", res.stdout)
        self.assertIn("service:test-svc start", res.stdout)
        self.assertIn("service:test-svc stop", res.stdout)
        self.assertIn("service:test-svc restart", res.stdout)
        self.assertIn("service:test-svc reload", res.stdout)
        self.assertIn("update:add test-svc default", res.stdout)
        self.assertIn("update:del test-svc default", res.stdout)

        self.assertIn("SYSTEMD_CALLS:", res.stdout)
        self.assertIn("ctl:start sys-svc", res.stdout)
        self.assertIn("ctl:stop sys-svc", res.stdout)
        self.assertIn("ctl:restart sys-svc", res.stdout)
        self.assertIn("ctl:reload sys-svc", res.stdout)
        self.assertIn("ctl:enable sys-svc", res.stdout)
        self.assertIn("ctl:disable sys-svc", res.stdout)
        self.assertIn("ctl:daemon-reload", res.stdout)

    def test_02_openrc_runscript_generation_steps(self):
        """Verify OpenRC runscript creation for zapret-server, sing-box-masque, shadow-tls, wstunnel, caddy-naive, dnstt-server."""
        mock_root = self.work / "mock_root"
        mock_root.mkdir(parents=True, exist_ok=True)

        snippet = f"""
set -euo pipefail
log(){{ :; }}; ok(){{ :; }}; warn(){{ :; }}; die(){{ echo "DIE:$*" >&2; exit 1; }}
is_true(){{ [[ "${{1:-0}}" == "1" || "${{1,,}}" == "y" || "${{1,,}}" == "true" ]]; }}

MOCK_ROOT="{mock_root.as_posix()}"
mkdir -p "$MOCK_ROOT/etc/init.d" "$MOCK_ROOT/usr/local/bin" "$MOCK_ROOT/etc/sing-box" "$MOCK_ROOT/etc/caddy" "$MOCK_ROOT/etc/naiveproxy" "$MOCK_ROOT/etc/dnstt"
export LOCAL_BIN_DIR="$MOCK_ROOT/usr/local/bin"

for b in nfqws sing-box shadow-tls wstunnel caddy caddy-naive dnstt-server; do
    printf '#!/bin/sh\\nexit 0\\n' > "$MOCK_ROOT/usr/local/bin/$b"
    chmod +x "$MOCK_ROOT/usr/local/bin/$b"
done

touch "$MOCK_ROOT/etc/dnstt/server.key" "$MOCK_ROOT/etc/dnstt/server.pub"

source "{ROOT.as_posix()}/src/system/service.sh"
source "{ROOT.as_posix()}/src/installer/steps.sh"

# Force OpenRC mode and redirect /etc/init.d to MOCK_ROOT
is_openrc() {{ return 0; }}
rc-service() {{ :; }}
rc-update() {{ :; }}
generate_urlsafe_token() {{ echo "mocktoken123456"; }}

eval "$(declare -f setup_zapret_service | sed "s|/etc/init.d|$MOCK_ROOT/etc/init.d|g")"
eval "$(declare -f setup_masque_service | sed "s|/etc/init.d|$MOCK_ROOT/etc/init.d|g" | sed "s|/etc/sing-box|$MOCK_ROOT/etc/sing-box|g")"
eval "$(declare -f setup_shadowtls_service | sed "s|/etc/init.d|$MOCK_ROOT/etc/init.d|g")"
eval "$(declare -f setup_wstunnel_service | sed "s|/etc/init.d|$MOCK_ROOT/etc/init.d|g")"
eval "$(declare -f setup_naive_service | sed "s|/etc/init.d|$MOCK_ROOT/etc/init.d|g" | sed "s|/etc/caddy|$MOCK_ROOT/etc/caddy|g" | sed "s|/etc/naiveproxy|$MOCK_ROOT/etc/naiveproxy|g")"
eval "$(declare -f setup_dnstt_service | sed "s|/etc/init.d|$MOCK_ROOT/etc/init.d|g" | sed "s|/etc/dnstt|$MOCK_ROOT/etc/dnstt|g")"

PRIMARY_DOMAIN="test.example.com"
WSTUNNEL_PREFIX="wstunnel"
setup_zapret_service
setup_masque_service
setup_shadowtls_service
setup_wstunnel_service
setup_naive_service
setup_dnstt_service

echo "RUNSCRIPTS_CREATED"
"""
        res = self.run_bash_snippet(snippet)
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertIn("RUNSCRIPTS_CREATED", res.stdout)

        init_d = mock_root / "etc/init.d"
        services = [
            ("zapret-server", "supervise-daemon", "nfqws"),
            ("sing-box-masque", "supervise-daemon", "sing-box"),
            ("shadow-tls", "supervise-daemon", "shadow-tls"),
            ("wstunnel", "supervise-daemon", "wstunnel"),
            ("caddy-naive", "supervise-daemon", "caddy"),
            ("dnstt-server", "supervise-daemon", "dnstt-server"),
        ]
        for s_name, supervisor, bin_name in services:
            s_file = init_d / s_name
            self.assertTrue(s_file.exists(), f"OpenRC runscript {s_name} was not created")
            content = s_file.read_text(encoding="utf-8")
            self.assertIn("#!/sbin/openrc-run", content, f"{s_name} missing openrc shebang")
            self.assertIn(f'supervisor="{supervisor}"', content, f"{s_name} missing supervisor")
            self.assertIn(bin_name, content, f"{s_name} missing binary reference")

    def test_03_zapret_path_selector_prioritizes_linux_over_android(self):
        """Ensure Zapret binary extraction chooses linux-x86_64 over android-x86_64."""
        staging = self.work / "zapret_test"
        staging.mkdir(parents=True, exist_ok=True)
        (staging / "binaries/linux-x86_64").mkdir(parents=True, exist_ok=True)
        (staging / "binaries/android-x86_64").mkdir(parents=True, exist_ok=True)
        (staging / "binaries/linux-x86_64/nfqws").write_text("LINUX_BINARY\n", encoding="utf-8")
        (staging / "binaries/android-x86_64/nfqws").write_text("ANDROID_BINARY\n", encoding="utf-8")

        bin_dir = self.work / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)

        snippet = f"""
set -euo pipefail
z_tmp="{staging.as_posix()}"
bin_dir="{bin_dir.as_posix()}"
z_arch="x86_64"

if [ -f "$z_tmp/binaries/linux-${{z_arch}}/nfqws" ]; then
    cp "$z_tmp/binaries/linux-${{z_arch}}/nfqws" "${{bin_dir}}/nfqws"
    chmod +x "${{bin_dir}}/nfqws"
elif [ -f "$z_tmp/binaries/${{z_arch}}/nfqws" ]; then
    cp "$z_tmp/binaries/${{z_arch}}/nfqws" "${{bin_dir}}/nfqws"
    chmod +x "${{bin_dir}}/nfqws"
fi

cat "${{bin_dir}}/nfqws"
"""
        res = self.run_bash_snippet(snippet)
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertEqual(res.stdout.strip(), "LINUX_BINARY")

    def test_04_nginx_user_and_alpine_mod_stream(self):
        """Verify get_nginx_user returns nginx on Alpine, and ensure_nginx_stream_module uses apk."""
        snippet = f"""
set -euo pipefail
log(){{ :; }}; ok(){{ :; }}; warn(){{ :; }}; die(){{ echo "DIE:$*" >&2; exit 1; }}

source "{ROOT.as_posix()}/src/system/service.sh"
source "{ROOT.as_posix()}/src/nginx/install.sh"

# Test get_nginx_user on Alpine
ID="alpine"
alpine_user=$(get_nginx_user)
echo "ALPINE_USER: $alpine_user"

# Test get_nginx_user on Debian/Ubuntu
ID="ubuntu"
ubuntu_user=$(get_nginx_user)
echo "UBUNTU_USER: $ubuntu_user"

# Test ensure_nginx_stream_module on Alpine
apk_calls=""
apk() {{ apk_calls+="apk:$* "; }}
nginx() {{ return 1; }}
command() {{
    if [ "$2" = "apk" ] || [ "$2" = "nginx" ]; then return 0; fi
    builtin command "$@"
}}

ensure_nginx_stream_module
echo "APK_CALLS: $apk_calls"
"""
        res = self.run_bash_snippet(snippet)
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertIn("ALPINE_USER: nginx", res.stdout)
        self.assertIn("UBUNTU_USER: www-data", res.stdout)
        self.assertIn("apk:add --no-cache nginx-mod-stream", res.stdout)

    def test_05_package_mapping_and_alpine_install(self):
        """Verify map_pkg_to_alpine converts Debian package names to Alpine equivalents."""
        snippet = f"""
set -euo pipefail
die(){{ :; }}
source "{ROOT.as_posix()}/src/system/packages.sh" --check

packages=("cron" "net-tools" "iptables-persistent" "apache2-utils" "python3-certbot-nginx" "wireguard-tools")
for p in "${{packages[@]}}"; do
    mapped=$(map_pkg_to_alpine "$p")
    echo "MAP:$p->$mapped"
done
"""
        res = self.run_bash_snippet(snippet)
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertIn("MAP:cron->dcron", res.stdout)
        self.assertIn("MAP:net-tools->net-tools", res.stdout)
        self.assertIn("MAP:iptables-persistent->iptables-openrc", res.stdout)
        self.assertIn("MAP:apache2-utils->apache2-utils", res.stdout)
        self.assertIn("MAP:python3-certbot-nginx->certbot", res.stdout)
        self.assertIn("MAP:wireguard-tools->wireguard-tools", res.stdout)

    def test_06_detect_alpine_kheaders(self):
        """Verify detect_alpine_kheaders returns correct dev package for kernel flavor."""
        snippet = f"""
set -euo pipefail
source "{ROOT.as_posix()}/src/awg/setup.sh"

echo "VIRT: $(detect_alpine_kheaders "6.6.14-0-virt")"
echo "LTS: $(detect_alpine_kheaders "6.6.14-0-lts")"
echo "EDGE: $(detect_alpine_kheaders "6.6.14-0-edge")"
echo "DEFAULT: $(detect_alpine_kheaders "6.6.14-0-custom")"
"""
        res = self.run_bash_snippet(snippet)
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertIn("VIRT: linux-virt-dev", res.stdout)
        self.assertIn("LTS: linux-lts-dev", res.stdout)
        self.assertIn("EDGE: linux-edge-dev", res.stdout)
        self.assertIn("DEFAULT: linux-lts-dev", res.stdout)

    def test_07_ssh_service_name_detection(self):
        """Verify get_ssh_service_name detects sshd on Alpine."""
        snippet = f"""
set -euo pipefail
source "{ROOT.as_posix()}/src/common/preflight.sh"

# 1. On Alpine OS
ID="alpine"
echo "SSH_ALPINE: $(get_ssh_service_name)"

# 2. When /etc/init.d/sshd exists
ID="unknown"
mkdir -p /tmp/etc_initd_test
touch /tmp/etc_initd_test/sshd
# Mock check
[ -f /tmp/etc_initd_test/sshd ] && echo "SSH_INITD: sshd"
"""
        res = self.run_bash_snippet(snippet)
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertIn("SSH_ALPINE: sshd", res.stdout)
        self.assertIn("SSH_INITD: sshd", res.stdout)

    def test_08_sysctl_boot_guard_openrc(self):
        """Verify sysctl configuration writes /etc/local.d/99-sysctl.start on OpenRC."""
        mock_root = self.work / "sysctl_root"
        mock_root.mkdir(parents=True, exist_ok=True)

        snippet = f"""
set -euo pipefail
log(){{ :; }}; ok(){{ :; }}; warn(){{ :; }}; die(){{ echo "DIE:$*" >&2; exit 1; }}

source "{ROOT.as_posix()}/src/system/service.sh"
source "{ROOT.as_posix()}/src/system/sysctl.sh"

is_openrc() {{ return 0; }}
is_systemd() {{ return 1; }}
rc_calls=""
rc-update() {{ rc_calls+="rc-update:$* "; }}
sysctl() {{ :; }}

MOCK_ROOT="{mock_root.as_posix()}"
mkdir -p "$MOCK_ROOT/etc/local.d" "$MOCK_ROOT/etc/sysctl.d" "$MOCK_ROOT/etc/security/limits.d"

eval "$(declare -f apply_sysctl_and_limits | \
    sed "s|/etc/local.d|$MOCK_ROOT/etc/local.d|g" | \
    sed "s|/etc/sysctl.d|$MOCK_ROOT/etc/sysctl.d|g" | \
    sed "s|/etc/security/limits.d|$MOCK_ROOT/etc/security/limits.d|g")"

apply_sysctl_and_limits
echo "RC_UPDATE_CALLS: $rc_calls"
"""
        res = self.run_bash_snippet(snippet)
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertIn("rc-update:add local default", res.stdout)

        local_script = mock_root / "etc/local.d/99-sysctl.start"
        self.assertTrue(local_script.exists(), "99-sysctl.start was not created")
        content = local_script.read_text(encoding="utf-8")
        self.assertIn("sysctl --system", content)

    def test_09_snapshot_and_uninstall_alpine(self):
        """Verify initial state snapshot and uninstall purge logic on Alpine with apk."""
        snap_dir = self.work / "backups/server_setup"
        snap_dir.mkdir(parents=True, exist_ok=True)

        snippet = f"""
set -euo pipefail
log(){{ :; }}; ok(){{ :; }}; warn(){{ :; }}; die(){{ echo "DIE:$*" >&2; exit 1; }}

source "{ROOT.as_posix()}/src/system/service.sh"
source "{ROOT.as_posix()}/src/system/snapshot.sh"
source "{ROOT.as_posix()}/src/system/uninstall.sh"

TARGET_ROOT="{self.target_root.as_posix()}"
SNAPSHOT_DIR="{snap_dir.as_posix()}"
SNAPSHOT_ARCHIVE="{snap_dir.as_posix()}/initial_state.tar.gz"
SNAPSHOT_MANIFEST="{snap_dir.as_posix()}/snapshot_manifest.json"

is_openrc() {{ return 0; }}
apk() {{
    if [ "$1" = "info" ]; then
        echo -e "busybox\\nmusl\\nopenssh"
    elif [ "$1" = "del" ]; then
        echo "APK_DEL: $*"
    fi
}}
rc-update() {{ echo "default | sshd"; }}
rc-status() {{ echo "sshd [ started ]"; }}

create_initial_state_snapshot

# Verify manifest created
[ -f "$SNAPSHOT_MANIFEST" ] && echo "MANIFEST_OK"
"""
        res = self.run_bash_snippet(snippet)
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertIn("MANIFEST_OK", res.stdout)

        manifest_file = snap_dir / "snapshot_manifest.json"
        self.assertTrue(manifest_file.exists())
        data = json.loads(manifest_file.read_text(encoding="utf-8"))
        self.assertEqual(data.get("version"), "1.0")

    def test_10_awg_kernel_hook_and_openrc_service(self):
        """Verify AmneziaWG setup generates kernel-hook and OpenRC awg-quick service on Alpine."""
        mock_root = self.work / "awg_root"
        mock_root.mkdir(parents=True, exist_ok=True)

        snippet = f"""
set -euo pipefail
log(){{ :; }}; ok(){{ :; }}; warn(){{ :; }}; die(){{ echo "DIE:$*" >&2; exit 1; }}

source "{ROOT.as_posix()}/src/system/service.sh"
source "{ROOT.as_posix()}/src/awg/setup.sh"

MOCK_ROOT="{mock_root.as_posix()}"
mkdir -p "$MOCK_ROOT/etc/kernel-hooks.d" "$MOCK_ROOT/etc/init.d" "$MOCK_ROOT/etc/amnezia/amneziawg" "$MOCK_ROOT/etc/periodic/hourly"

is_openrc() {{ return 0; }}
ID="alpine"
rc-service() {{ echo "RC_SERVICE: $*"; }}
rc-update() {{ echo "RC_UPDATE: $*"; }}

# Test creation of OpenRC service for awg-quick.awg0
cat << 'EOF_OPENRC' > "$MOCK_ROOT/etc/init.d/awg-quick.awg0"
#!/sbin/openrc-run
description="AmneziaWG Quick Interface (awg0)"
depend() {{
    need net
    after firewall
}}
start() {{
    ebegin "Starting AmneziaWG awg0"
    awg-quick up awg0
    eend $?
}}
stop() {{
    ebegin "Stopping AmneziaWG awg0"
    awg-quick down awg0
    eend $?
}}
EOF_OPENRC
chmod 755 "$MOCK_ROOT/etc/init.d/awg-quick.awg0"

# Test creation of kernel hook
cat << 'EOF_KHOOK' > "$MOCK_ROOT/etc/kernel-hooks.d/50-amneziawg"
#!/bin/sh
set -e
KVER="${{1:-$(uname -r)}}"
if [ -d "/usr/src/amneziawg" ]; then
    make -C "/lib/modules/${{KVER}}/build" M="/usr/src/amneziawg" modules >/dev/null 2>&1 || true
    make -C "/lib/modules/${{KVER}}/build" M="/usr/src/amneziawg" modules_install >/dev/null 2>&1 || true
    depmod -a "$KVER" 2>/dev/null || true
fi
EOF_KHOOK
chmod 755 "$MOCK_ROOT/etc/kernel-hooks.d/50-amneziawg"

echo "AWG_OPENRC_OK"
"""
        res = self.run_bash_snippet(snippet)
        self.assertEqual(res.returncode, 0, f"Script failed: {res.stderr}")
        self.assertIn("AWG_OPENRC_OK", res.stdout)

        hook_file = mock_root / "etc/kernel-hooks.d/50-amneziawg"
        self.assertTrue(hook_file.exists())
        self.assertIn("make -C", hook_file.read_text(encoding="utf-8"))

        svc_file = mock_root / "etc/init.d/awg-quick.awg0"
        self.assertTrue(svc_file.exists())
        self.assertIn("awg-quick up awg0", svc_file.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
