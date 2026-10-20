"""Installation orchestration exercised without touching the host system."""
import itertools
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")
sys.path.insert(0, str(ROOT))
from scripts.build import bundle_file, SRC_DIR


class InstallationFlowTests(unittest.TestCase):
    def shell(self, code, module="installer/plan.sh"):
        source = ROOT / "src" / module
        self.assertTrue(source.is_file(), f"Missing shared installation module: {module}")
        with tempfile.TemporaryDirectory(prefix="installation flow ") as temp:
            prelude = r'''
export PATH=/usr/bin:/bin:$PATH
set -euo pipefail
is_true() { [[ "${1:-}" == 1 || "${1:-}" == y || "${1:-}" == true ]]; }
log() { :; }; ok() { :; }; warn() { echo "WARN:$*"; }
die() { echo "DIE:$*" >&2; exit 1; }
print_step_bar() { :; }
record_step_completed() { :; }
source src/common/colors.sh
SCRIPT_VERSION=test
NON_INTERACTIVE=1
CHECK_MODE=0
DEBUG_MODE=0
'''
            env = dict(os.environ, TEST_WORK=Path(temp).as_posix())
            return subprocess.run([str(BASH), "-s"], input=prelude + bundle_file(source, SRC_DIR) + "\n" + code,
                                  cwd=ROOT, env=env, text=True, encoding="utf-8", capture_output=True, timeout=20)

    def test_required_task_failure_is_not_masked_by_following_command(self):
        for debug, conditional in itertools.product((0, 1), (False, True)):
            with self.subTest(debug=debug, conditional=conditional):
                invoke = ('if run_with_spinner fixture broken; then echo BAD_SUCCESS; else echo "RC=$?"; fi'
                          if conditional else 'set +e; run_with_spinner fixture broken; echo "RC=$?"')
                result = self.shell(f'''
DEBUG_MODE={debug}
SPINNER_LOG_FILE="$TEST_WORK/task.log"
PRIVATE_VALUE="available"
helper() {{ echo "CONTEXT:$PRIVATE_VALUE"; }}
broken() {{ helper; false; echo BAD_CONTINUATION; }}
{invoke}
''', "common/spinner.sh")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("RC=1", result.stdout)
                self.assertIn("CONTEXT:available", result.stdout)
                self.assertNotIn("BAD_CONTINUATION", result.stdout)
                self.assertNotIn("BAD_SUCCESS", result.stdout)

    def test_command_substitution_keeps_failure_semantics(self):
        result = self.shell(r'''
SPINNER_LOG_FILE="$TEST_WORK/task.log"
broken() { local generated; generated=$(false; echo BAD_CONTINUATION); }
if run_with_spinner fixture broken; then echo BAD_SUCCESS; else echo "RC=$?"; fi
''', "common/spinner.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RC=1", result.stdout)
        self.assertNotIn("BAD_SUCCESS", result.stdout)

    def test_plan_contains_only_selected_components_in_dependency_order(self):
        for web, agh, awg in itertools.product((0, 1), repeat=3):
            if not web and not awg:
                continue
            with self.subTest(web=web, agh=agh, awg=awg):
                result = self.shell(f'''
ENABLE_WEB_STACK={web}; ENABLE_AGH={agh}; ENABLE_AWG_STANDALONE={awg}
build_installation_plan
printf '%s\\n' "${{INSTALLATION_PLAN[@]}}"
''')
                self.assertEqual(result.returncode, 0, result.stderr)
                ids = result.stdout.splitlines()
                self.assertEqual(ids[-1], "verify")
                self.assertEqual(len(ids), len(set(ids)))
                self.assertEqual("nginx" in ids, bool(web))
                self.assertEqual("panel" in ids, bool(web))
                self.assertEqual("adguard" in ids, bool(web and agh))
                self.assertEqual("awg" in ids, bool(awg))
                if web:
                    self.assertLess(ids.index("nginx"), ids.index("certificates"))
                    self.assertLess(ids.index("certificates"), ids.index("nginx_config"))
                    self.assertLess(ids.index("nginx_config"), ids.index("panel"))

    def test_failed_preflight_prevents_all_mutations(self):
        result = self.shell(r'''
ENABLE_WEB_STACK=1; ENABLE_AGH=0; ENABLE_AWG_STANDALONE=0
validate_installation_config() { :; }
inspect_port_conflicts() { echo PREFLIGHT; return 19; }
confirm_installation_plan() { echo BAD_CONFIRM; }
save_session_state() { echo BAD_SAVE; }
install_step_packages() { echo BAD_APPLY; }
run_installation
echo BAD_SUCCESS
''')
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertIn("PREFLIGHT", result.stdout)
        self.assertNotIn("BAD_", result.stdout)

    def test_cancelled_plan_prevents_all_mutations(self):
        result = self.shell(r'''
ENABLE_WEB_STACK=0; ENABLE_AGH=0; ENABLE_AWG_STANDALONE=1
validate_installation_config() { :; }
inspect_port_conflicts() { :; }
confirm_installation_plan() { return 20; }
save_session_state() { echo BAD_SAVE; }
install_step_packages() { echo BAD_APPLY; }
run_installation
echo BAD_SUCCESS
''')
        self.assertEqual(result.returncode, 20, result.stderr)
        self.assertNotIn("BAD_", result.stdout)

    def test_failed_stage_blocks_dependents_and_report(self):
        result = self.shell(r'''
ENABLE_WEB_STACK=0; ENABLE_AGH=0; ENABLE_AWG_STANDALONE=1
validate_installation_config() { :; }; inspect_port_conflicts() { :; }
confirm_installation_plan() { :; }; save_session_state() { :; }
should_skip_step() { return 1; }; step_begin() { :; }; step_finish() { echo "DONE:$1"; }
install_step_packages() { echo PACKAGES; return 21; }
install_step_kernel() { echo BAD_KERNEL; }
report_installation() { echo BAD_REPORT; }
run_installation
''')
        self.assertEqual(result.returncode, 21, result.stderr)
        self.assertIn("PACKAGES", result.stdout)
        self.assertNotIn("BAD_", result.stdout)
        self.assertNotIn("DONE:packages", result.stdout)

    def test_service_verification_precedes_report_for_every_profile(self):
        result = self.shell(r'''
ENABLE_WEB_STACK=1; ENABLE_AGH=1; ENABLE_AWG_STANDALONE=1
validate_installation_config() { :; }; inspect_port_conflicts() { :; }
confirm_installation_plan() { :; }; save_session_state() { :; }
should_skip_step() { return 1; }; step_begin() { :; }; step_finish() { :; }
build_installation_plan
for id in "${INSTALLATION_PLAN[@]}"; do
    eval "install_step_$id() { echo APPLY:$id; }"
done
report_installation() { echo REPORT; }
run_installation
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        applied = [line for line in result.stdout.splitlines() if line.startswith(("APPLY:", "REPORT"))]
        self.assertEqual(applied[-2:], ["APPLY:verify", "REPORT"])
        self.assertEqual(applied.count("APPLY:panel"), 1)
        self.assertEqual(applied.count("APPLY:awg"), 1)

    def test_entrypoints_share_the_same_installer(self):
        install = bundle_file(SRC_DIR / "entrypoints/install.main.sh", SRC_DIR)
        setup = bundle_file(SRC_DIR / "entrypoints/setup.main.sh", SRC_DIR)
        self.assertTrue("run_installation" in install, "Main entrypoint must use the shared engine")
        self.assertEqual(install.count("run_installation\n"), 1)
        self.assertTrue(setup.strip() in install, "Entrypoints must share the complete source body")

    def test_wizard_never_starts_background_installation(self):
        wizard = (SRC_DIR / "tui/wizard.sh").read_text(encoding="utf-8")
        self.assertFalse("start_background_preinstall" in wizard, "Wizard must not install system packages")
        self.assertFalse("start_amneziawg_preinstall_bg" in wizard, "Wizard must not launch DKMS")

    def test_checkpoint_is_bound_to_step_identity_and_configuration(self):
        result = self.shell(r'''
source src/common/checkpoint.sh
SAVED_CONFIG_FILE="$TEST_WORK/config.env"
ENABLE_WEB_STACK=1; ENABLE_AWG_STANDALONE=0; ENABLE_AGH=0
PRIMARY_DOMAIN=one.example
build_installation_plan
checkpoint_artifact_valid() { return 0; }
record_step_completed nginx_config
RESUME_STEP=99
should_skip_step nginx_config && echo MATCH
PRIMARY_DOMAIN=two.example
if should_skip_step nginx_config; then echo BAD_STALE; else echo INVALIDATED; fi
ENABLE_WEB_STACK=0; ENABLE_AWG_STANDALONE=1
build_installation_plan
if should_skip_step awg; then echo BAD_IDENTITY; else echo DIFFERENT_STEP; fi
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MATCH", result.stdout)
        self.assertIn("INVALIDATED", result.stdout)
        self.assertIn("DIFFERENT_STEP", result.stdout)
        self.assertNotIn("BAD_", result.stdout)

    def test_checkpoint_missing_artifact_reexecutes_step_and_never_skips_verification(self):
        result = self.shell(r'''
source src/common/checkpoint.sh
SAVED_CONFIG_FILE="$TEST_WORK/config.env"
ENABLE_WEB_STACK=0; ENABLE_AWG_STANDALONE=1
build_installation_plan
record_step_completed awg
RESUME_STEP=99
checkpoint_artifact_valid() { return 1; }
if should_skip_step awg; then echo BAD_MISSING; fi
record_step_completed verify
checkpoint_artifact_valid() { return 0; }
if should_skip_step verify; then echo BAD_VERIFY; fi
echo CHECKED
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("BAD_", result.stdout)
        self.assertIn("CHECKED", result.stdout)

    def test_express_preserves_explicit_parameters_and_secrets(self):
        result = self.shell(r'''
source src/installer/express.sh
PRIMARY_DOMAIN=example.com
PANEL_PATH=/keep-panel/; SUB_PATH=/keep-sub/; XHTTP_STREAM_PATH=/keep-stream/
ADMIN_USERNAME=existing; ADMIN_PASSWORD=existing-password
ENABLE_HY2=n; CLI_ENABLE_HY2=n
ENABLE_AWG_V3=n; CONFIG_EXPLICIT_KEYS[ENABLE_AWG_V3]=1
apply_express_defaults
printf '%s|%s|%s|%s|%s|%s|%s' "$PANEL_PATH" "$SUB_PATH" "$XHTTP_STREAM_PATH" "$ADMIN_USERNAME" "$ADMIN_PASSWORD" "$ENABLE_HY2" "$ENABLE_AWG_V3"
''', "system/env.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("/keep-panel/|/keep-sub/|/keep-stream/|existing|existing-password|0|0", result.stdout)

    def test_failed_health_check_returns_error(self):
        result = self.shell(r'''
ENABLE_WEB_STACK=1
ENABLE_STEAL=n; ENABLE_CLASSIC=n; ENABLE_HY2=n; ENABLE_AWG_V3=n; ENABLE_AWG_V2=n; ENABLE_AGH=n
PRIMARY_DOMAIN=example.com; SSL_ENGINE_CHOICE=1
systemctl() { return 1; }; timeout() { return 0; }
curl() { echo 200; }
post_install_sanity_check
echo BAD_SUCCESS
''', "common/preflight.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("BAD_SUCCESS", result.stdout)

    def test_certificate_failure_never_becomes_a_self_signed_success(self):
        for ssl_engine in (1, 2):
            with self.subTest(ssl_engine=ssl_engine):
                result = self.shell(f'''
SSL_ENGINE_CHOICE={ssl_engine}
run_with_spinner() {{ shift; "$@"; }}
obtain_cert() {{ return 27; }}
obtain_cf_cert() {{ return 27; }}
issue_required_certificate example.com
echo BAD_SUCCESS
''', "installer/web.sh")
                self.assertEqual(result.returncode, 27, result.stderr)
                self.assertNotIn("BAD_SUCCESS", result.stdout)

    def test_selected_protocols_cannot_claim_the_same_udp_port(self):
        result = self.shell(r'''
ENABLE_WEB_STACK=1; PRIMARY_DOMAIN=example.com; LE_EMAIL=admin@example.com
ENABLE_AWG_STANDALONE=1; AWG_STANDALONE_PORT=8445
ENABLE_MASQUE=1; MASQUE_PORT=8445
validate_installation_config
echo BAD_SUCCESS
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("BAD_SUCCESS", result.stdout)

    def test_default_ports_for_standalone_and_masque_do_not_conflict(self):
        result = self.shell(r'''
ENABLE_WEB_STACK=1; PRIMARY_DOMAIN=example.com; LE_EMAIL=admin@example.com
ENABLE_AWG_STANDALONE=1
ENABLE_MASQUE=1
validate_installation_config
echo VALID
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("VALID", result.stdout)

    def test_tcp_and_udp_can_share_a_number(self):
        result = self.shell(r'''
ENABLE_WEB_STACK=1; PRIMARY_DOMAIN=example.com; LE_EMAIL=admin@example.com
ENABLE_HY2=1; HY2_PORT=443
validate_installation_config
echo VALID
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("VALID", result.stdout)

    def test_security_step_adds_a_key_without_unrelated_security_options(self):
        result = self.shell(r'''
SSH_PUBLIC_KEY="ssh-ed25519 fixture"; SSH_PORT=22; SSH_ACTIVE_PORT=22
add_authorized_key() { echo ADDED; }
install_step_security
''', "installer/engine.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ADDED", result.stdout)

    def test_explicit_rotation_does_not_resume_an_old_checkpoint(self):
        result = self.shell(r'''
source src/common/checkpoint.sh
SAVED_CONFIG_FILE="$TEST_WORK/config.env"
ENABLE_WEB_STACK=0; ENABLE_AWG_STANDALONE=1
build_installation_plan
record_step_completed kernel
ROTATE_PATHS=1
restore_installation_checkpoint
printf '%s|%s' "$LAST_COMPLETED_STEP" "$RESUME_STEP"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "0|1")

    def test_finalization_generates_missing_credentials_once(self):
        result = self.shell(r'''
PRIMARY_DOMAIN=example.com; ENABLE_WEB_STACK=1; ENABLE_AGH=1
finalize_installation_config
first="$ADMIN_PASSWORD|$AGH_PASS|$PANEL_PATH"
finalize_installation_config
[[ "$first" == "$ADMIN_PASSWORD|$AGH_PASS|$PANEL_PATH" ]]
[[ "$ADMIN_PASSWORD" =~ ^[0-9a-f]{32}$ && "$AGH_PASS" =~ ^[0-9a-f]{32}$ ]]
echo STABLE
''', "system/env.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("STABLE", result.stdout)

    def test_firewall_applies_public_ports_and_keeps_tunnels_internal(self):
        result = self.shell(r'''
source src/common/protocols.sh
SSH_ACTIVE_PORT=2222; SSH_PORT=2222
ENABLE_WEB_STACK=1; ENABLE_HY2=1; HY2_PORT=443
HY2_PORT_HOPPING=n; HY2_PORT_HOPPING_RANGE=""
ENABLE_WSTUNNEL=1; WSTUNNEL_PORT=8080
ENABLE_AWG_STANDALONE=0
ENABLE_AWG_V3=0; ENABLE_AWG_V2=0; ENABLE_SS2022=0; ENABLE_TUIC=0
ENABLE_MTPROTO=0; ENABLE_MASQUE=0; ENABLE_DNSTT=0
ufw() { echo "UFW:$*"; }
install_step_firewall
''', "installer/engine.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("UFW:allow 443/udp", result.stdout)
        self.assertIn("UFW:allow 2222/tcp", result.stdout)
        self.assertIn("UFW:deny 8080/tcp", result.stdout)
        self.assertNotIn("UFW:allow 8080/tcp", result.stdout)

    def test_standalone_health_check_never_requires_web_services(self):
        result = self.shell(r'''
ENABLE_WEB_STACK=0; ENABLE_AWG_STANDALONE=1; AWG_STANDALONE_PORT=8445
systemctl() { [[ "$*" == *awg-quick@awg0* ]]; }
ss() { echo 'UNCONN 0 0 0.0.0.0:8445 0.0.0.0:*'; }
check_required_file() { :; }
post_install_sanity_check
echo VERIFIED
''', "common/preflight.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("VERIFIED", result.stdout)

    def test_real_cli_runs_both_entrypoints_through_the_same_safe_plan(self):
        # Keep the parser, configuration loader and complete wizard; replace host operations.
        packages = bundle_file(SRC_DIR / "system/packages.sh", SRC_DIR)
        system_checks = packages[:packages.index("install_prerequisites()")]
        wizard = bundle_file(SRC_DIR / "tui/wizard.sh", SRC_DIR)
        stubs = r'''
get_wan_ip() { printf ''; }
detect_active_ssh_port() { echo 22; }
inspect_port_conflicts() { printf '\nINSPECT\n'; }
eval "$(declare -f save_session_state | sed '1s/save_session_state/persist_fixture_config/')"
save_session_state() { persist_fixture_config "$@" >/dev/null; echo SAVE; }
'''
        operations = r'''
build_installation_plan
for fixture_id in "${INSTALLATION_PLAN[@]}"; do
    eval "install_step_$fixture_id() { echo APPLY:$fixture_id; }"
done
report_installation() { echo REPORT; }
'''
        for entrypoint, mode, web in itertools.product(("install", "setup"), ("--auto", "--expert", "interactive"), (False, True)):
            if mode == "interactive" and web:
                continue
            with self.subTest(entrypoint=entrypoint, mode=mode, web=web), tempfile.TemporaryDirectory() as temp:
                work = Path(temp)
                source = bundle_file(SRC_DIR / f"entrypoints/{entrypoint}.main.sh", SRC_DIR)
                source = source.replace(system_checks, "")
                source = source.replace("/etc/server-setup.env", (work / "system.env").as_posix())
                interview_stubs = ""
                if mode == "interactive":
                    interview_stubs = r'''
print_mask_banner() { :; }
prompt_yes_no() { if [ "$3" = ENABLE_WEB_STACK ]; then printf -v "$3" 0; else printf -v "$3" 1; fi; }
prompt_default() { printf -v "$3" '%s' "$2"; }
'''
                source = source.replace(wizard, stubs + "\n" + interview_stubs + "\n" + wizard)
                source = source.rsplit("\nrun_installation\n", 1)[0] + "\n" + operations + "\nrun_installation\n"
                script = work / "fixture.sh"
                script.write_text(source, encoding="utf-8", newline="\n")
                args = [str(BASH), script.as_posix(), "--expert" if mode == "interactive" else mode, "--force",
                        "--no-www",
                        "--no-hy2", "--awg-standalone", "--awg-host", "vpn.example.com"]
                if web:
                    args += ["--domain", "example.com", "--email", "admin@example.com"]
                else:
                    args.append("--no-web-stack")
                if mode != "interactive":
                    args.append("--non-interactive")
                result = subprocess.run(args, cwd=work, input="\n\n\n", text=True, encoding="utf-8", capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout[-700:])
                lines = result.stdout.splitlines()
                self.assertEqual(lines.count("APPLY:awg"), 1)
                self.assertEqual(lines.count("APPLY:panel"), int(web))
                self.assertEqual(lines[-2:], ["SAVE", "REPORT"])
                self.assertLess(lines.index("INSPECT"), lines.index("SAVE"))
                self.assertLess(lines.index("APPLY:awg"), lines.index("APPLY:verify"))

    def test_step_started_records_failed_step_and_restore_detects_it(self):
        result = self.shell(r'''
source src/common/checkpoint.sh
SAVED_CONFIG_FILE="$TEST_WORK/config.env"
ENABLE_WEB_STACK=1; ENABLE_AWG_STANDALONE=0; ENABLE_AGH=0
PRIMARY_DOMAIN=test.example
build_installation_plan
record_step_started packages
restore_installation_checkpoint
printf 'STARTED:%s|%s\n' "$CHECKPOINT_FAILED" "$FAILED_STEP_NUM"
record_step_completed packages
restore_installation_checkpoint
printf 'COMPLETED:%s|%s|%s\n' "$CHECKPOINT_FAILED" "$FAILED_STEP_NUM" "$LAST_COMPLETED_STEP"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("STARTED:packages|1", result.stdout)
        self.assertIn("COMPLETED:|0|1", result.stdout)

    def test_validate_installation_config_fallback_email(self):
        result = self.shell(r'''
ENABLE_WEB_STACK=1; PRIMARY_DOMAIN=example.com; LE_EMAIL=""
validate_installation_config
printf 'EMAIL:%s\n' "$LE_EMAIL"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("EMAIL:admin@example.com", result.stdout)

    def test_save_session_state_persists_ports_mode_and_extras(self):
        result = self.shell(r'''
PRIMARY_DOMAIN=example.com; ENABLE_WEB_STACK=1
PORTS_SETUP_MODE=2
REALITY_FALLBACK_PORT=9443
EXTRA_DOMAINS_USER=("extra1.example.com" "extra2.example.com")
save_session_state "$TEST_WORK/config.env"
grep -q '^PORTS_SETUP_MODE="2"' "$TEST_WORK/config.env" && echo PORTS_OK
grep -q '^REALITY_FALLBACK_PORT="9443"' "$TEST_WORK/config.env" && echo FALLBACK_OK
grep -q 'extra1.example.com' "$TEST_WORK/config.env" && echo EXTRA_OK
''', "system/env.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PORTS_OK", result.stdout)
        self.assertIn("FALLBACK_OK", result.stdout)
        self.assertIn("EXTRA_OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
