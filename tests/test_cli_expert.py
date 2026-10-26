"""Automated CLI integration tests for expert and interactive installation flows."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")
sys.path.insert(0, str(ROOT))
from scripts.build import bundle_file, SRC_DIR

_CACHE: dict[str, str] = {}


def _get_bundled(entrypoint: str) -> str:
    if entrypoint not in _CACHE:
        _CACHE[entrypoint] = bundle_file(SRC_DIR / f"entrypoints/{entrypoint}.main.sh", SRC_DIR)
    return _CACHE[entrypoint]


def run_cli_fixture(entrypoint: str, mode: str, web: bool) -> subprocess.CompletedProcess:
    packages = bundle_file(SRC_DIR / "system/packages.sh", SRC_DIR)
    system_checks = packages[:packages.index("install_prerequisites()")]
    wizard = bundle_file(SRC_DIR / "tui/wizard.sh", SRC_DIR)
    raw_source = _get_bundled(entrypoint)

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
    interview_stubs = ""
    if mode == "interactive":
        interview_stubs = r'''
print_mask_banner() { :; }
prompt_yes_no() { if [ "$3" = ENABLE_WEB_STACK ]; then printf -v "$3" 0; else printf -v "$3" 1; fi; }
prompt_default() { printf -v "$3" '%s' "$2"; }
'''
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        source = raw_source.replace(system_checks, "")
        source = source.replace("/etc/server-setup.env", (work / "system.env").as_posix())
        source = source.replace(wizard, stubs + "\n" + interview_stubs + "\n" + wizard)
        source = source.rsplit("\nrun_installation\n", 1)[0] + "\n" + operations + "\nrun_installation\n"
        script = work / "fixture.sh"
        script.write_text(source, encoding="utf-8", newline="\n")
        args = [str(BASH), script.as_posix(), "--expert" if mode == "interactive" else mode, "--force",
                "--no-www", "--no-hy2", "--awg-standalone", "--awg-host", "vpn.example.com"]
        if web:
            args += ["--domain", "example.com", "--email", "admin@example.com"]
        else:
            args.append("--no-web-stack")
        if mode != "interactive":
            args.append("--non-interactive")
        env = os.environ.copy()
        env["VPN_STACK_LOCK_FILE"] = (work / "vpn-stack.lock").as_posix()
        return subprocess.run(args, cwd=work, input="\n\n\n", text=True, encoding="utf-8", capture_output=True, env=env, timeout=30)


class TestCliExpertFlow(unittest.TestCase):
    def _assert_plan(self, result: subprocess.CompletedProcess, web: bool):
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout[-700:])
        lines = result.stdout.splitlines()
        self.assertEqual(lines.count("APPLY:awg"), 1)
        self.assertEqual(lines.count("APPLY:panel"), int(web))
        self.assertEqual(lines[-2:], ["SAVE", "REPORT"])
        self.assertLess(lines.index("INSPECT"), lines.index("SAVE"))
        self.assertLess(lines.index("APPLY:awg"), lines.index("APPLY:verify"))

    def test_install_expert_no_web(self):
        res = run_cli_fixture("install", "--expert", web=False)
        self._assert_plan(res, web=False)

    def test_install_expert_with_web(self):
        res = run_cli_fixture("install", "--expert", web=True)
        self._assert_plan(res, web=True)

    def test_install_interactive_no_web(self):
        res = run_cli_fixture("install", "interactive", web=False)
        self._assert_plan(res, web=False)


if __name__ == "__main__":
    unittest.main()
