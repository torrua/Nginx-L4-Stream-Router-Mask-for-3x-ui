"""Exercise the real selector with terminal byte sequences, including SSH delays."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")


class MultiselectTests(unittest.TestCase):
    def menu(self, keys, *, enabled=None, capable=True, back=False, initial=None, producer=None, columns=80, locale=None):
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            # Use a pipe instead of the host's controlling terminal. Capability alone
            # is substituted; routing, parsing, rendering and state updates are real.
            source = (ROOT / "src/tui/prompts.sh").read_text(encoding="utf-8")
            source = source.split("# ----------------- Обработка аргументов командной строки", 1)[0]
            source = source.replace("/dev/tty", (work / "no-controlling-terminal").as_posix())
            script = work / "menu.sh"
            flags = initial or ["n"] * 13
            prelude = f"""export PATH=/usr/bin:/bin:$PATH
set -euo pipefail
source src/common/colors.sh
is_true() {{ [[ "${{1:-}}" == y || "${{1:-}}" == 1 || "${{1:-}}" == true ]]; }}
ok() {{ :; }}
log() {{ :; }}
warn() {{ printf '%s\\n' "$*" >&2; }}
NON_INTERACTIVE=0
WIZARD_ALLOW_BACK={int(back)}
COLUMNS={columns}
"""
            settings = "unset ENABLE_TUI_MULTISELECT\n" if enabled is None else f"ENABLE_TUI_MULTISELECT={enabled}\n"
            setup = "\ncan_use_interactive_tui() { return " + ("0" if capable else "1") + "; }\n" + settings
            setup += "protocol_keys=(" + " ".join(f"PROTO_{i}" for i in range(13)) + ")\n"
            setup += "protocol_labels=(" + " ".join(shlex.quote(f"Protocol {i + 1}: " + "a long protocol description " * 4) for i in range(13)) + ")\n"
            setup += "\n".join(f"PROTO_{i}={flag}" for i, flag in enumerate(flags)) + "\n"
            setup += "trap ':' INT\ntrap ':' TERM\nbefore_traps=$(trap -p INT TERM)\n"
            redirect = ""
            if producer:
                setup += "produce_keys() { " + producer + "; }\n"
                redirect = " < <(produce_keys)"
            setup += "status=0\nprompt_multiselect 'Choose protocols' protocol_keys protocol_labels" + redirect + " || status=$?\n"
            setup += """if [[ "$(trap -p INT TERM)" == "$before_traps" ]]; then echo TRAPS=preserved; else echo TRAPS=changed; fi
printf '\\nRESULT=%s:' "$status"
for name in "${protocol_keys[@]}"; do printf '%s' "${!name}"; done
printf '\\n'
"""
            script.write_text(prelude + source + setup, encoding="utf-8", newline="\n")
            env = os.environ.copy()
            env["TERM"] = "xterm-256color"
            if locale:
                env["LC_ALL"] = locale
            result = subprocess.run([str(BASH), script.as_posix()], input=keys.encode("utf-8"), cwd=ROOT, env=env,
                                    capture_output=True, timeout=15)
            try:
                result.stdout = result.stdout.decode("utf-8")
                result.stderr = result.stderr.decode("utf-8")
            except UnicodeDecodeError as error:
                self.fail(f"Selector emitted malformed UTF-8: {error}")
            return result

    def assert_selection(self, result, selected, status=0):
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout[-400:])
        flags = "".join("y" if i in selected else "n" for i in range(13))
        self.assertIn(f"RESULT={status}:{flags}", result.stdout[-100:])

    def test_arrows_are_enabled_by_default(self):
        self.assert_selection(self.menu("\x1b[B \n"), {1})

    def test_up_wraps_to_last_of_thirteen_protocols(self):
        self.assert_selection(self.menu("\x1b[A \n", enabled=1), {12})

    def test_application_cursor_keys(self):
        self.assert_selection(self.menu("\x1bOB \n", enabled=1), {1})

    def test_modified_cursor_sequence_is_consumed_whole(self):
        self.assert_selection(self.menu("\x1b[1;5B \n", enabled=1, back=True), {1})

    def test_fragmented_ssh_arrow_does_not_trigger_back(self):
        self.assert_selection(self.menu("", enabled=1, back=True,
                                       producer="printf '\\033'; sleep 0.05; printf '['; sleep 0.05; printf 'B \\n'"), {1})

    def test_cr_accepts_pending_selection(self):
        self.assert_selection(self.menu(" \r", enabled=1), {0})

    def test_back_discards_unconfirmed_changes(self):
        initial = ["y"] + ["n"] * 12
        self.assert_selection(self.menu("\x1b[B b", enabled=1, back=True, initial=initial), {0}, status=10)

    def test_numeric_fallback_when_terminal_is_not_capable(self):
        self.assert_selection(self.menu("1,10,13\n", capable=False), {0, 9, 12})

    def test_explicit_numeric_mode(self):
        self.assert_selection(self.menu("2,12\n", enabled=0), {1, 11})

    def test_question_mark_switches_to_numeric_input(self):
        self.assert_selection(self.menu("?1,10,13\n", enabled=1), {0, 9, 12})

    def test_all_and_clear_shortcuts(self):
        self.assert_selection(self.menu("a\n", enabled=1), set(range(13)))
        self.assert_selection(self.menu("a0\x1b[B \n", enabled=1), {1})

    def test_rendered_rows_do_not_wrap_in_a_narrow_terminal(self):
        result = self.menu("\n", enabled=1, columns=40)
        self.assert_selection(result, set())
        import re
        rows = [row for row in result.stdout.splitlines() if row.startswith("\x1b[2K  ")]
        self.assertTrue(rows)
        for row in rows:
            plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", row)
            self.assertLessEqual(len(plain), 39, plain)

    def test_selector_restores_callers_signal_handlers(self):
        result = self.menu("\n", enabled=1)
        self.assert_selection(result, set())
        self.assertIn("TRAPS=preserved", result.stdout[-150:])

    def test_utf8_menu_is_not_cut_between_bytes_under_c_locale(self):
        self.assert_selection(self.menu("\n", enabled=1, columns=44, locale="C"), set())

    def single_menu(self, keys, *, default="firefox", capable=True, initial="firefox"):
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            source = (ROOT / "src/tui/prompts.sh").read_text(encoding="utf-8")
            source = source.split("# ----------------- Обработка аргументов командной строки", 1)[0]
            source = source.replace("/dev/tty", (work / "no-controlling-terminal").as_posix())
            script = work / "single_menu.sh"
            prelude = """export PATH=/usr/bin:/bin:$PATH
set -euo pipefail
source src/common/colors.sh
ok() { :; }
log() { :; }
warn() { printf '%s\n' "$*" >&2; }
NON_INTERACTIVE=0
WIZARD_ALLOW_BACK=0
COLUMNS=80
"""
            setup = "\ncan_use_interactive_tui() { return " + ("0" if capable else "1") + "; }\n"
            setup += "fp_keys=(firefox chrome safari ios android edge randomized)\n"
            setup += "fp_labels=(Firefox Chrome Safari iOS Android Edge Random)\n"
            setup += f'REALITY_FINGERPRINT="{initial}"\n'
            setup += f'status=0\nprompt_select "Select Fingerprint" REALITY_FINGERPRINT "{default}" fp_keys fp_labels || status=$?\n'
            setup += 'printf "\nRESULT=%s:%s\n" "$status" "$REALITY_FINGERPRINT"\n'
            script.write_text(prelude + source + setup, encoding="utf-8", newline="\n")
            env = os.environ.copy()
            env["TERM"] = "xterm-256color"
            result = subprocess.run([str(BASH), script.as_posix()], input=keys.encode("utf-8"), cwd=ROOT, env=env,
                                    capture_output=True, timeout=15)
            try:
                result.stdout = result.stdout.decode("utf-8")
            except UnicodeDecodeError:
                result.stdout = result.stdout.decode("utf-8", "replace")
            return result

    def test_single_select_tui_enter_default(self):
        res = self.single_menu("\n", default="firefox", capable=True)
        self.assertIn("RESULT=0:firefox", res.stdout)

    def test_single_select_tui_arrow_down(self):
        res = self.single_menu("\x1b[B\n", default="firefox", capable=True)
        self.assertIn("RESULT=0:chrome", res.stdout)

    def test_single_select_tui_space_and_enter(self):
        res = self.single_menu("\x1b[B \n", default="firefox", capable=True)
        self.assertIn("RESULT=0:chrome", res.stdout)

    def test_single_select_tui_digit_select(self):
        res = self.single_menu("3\n", default="firefox", capable=True)
        self.assertIn("RESULT=0:safari", res.stdout)

    def test_single_select_numeric_fallback(self):
        res = self.single_menu("?3\n", default="firefox", capable=True)
        self.assertIn("RESULT=0:safari", res.stdout)

    def test_single_select_non_tui_numeric(self):
        res = self.single_menu("2\n", default="firefox", capable=False)
        self.assertIn("RESULT=0:chrome", res.stdout)

    def test_single_select_sni_preset_keys(self):
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            source = (ROOT / "src" / "tui" / "prompts.sh").read_text(encoding="utf-8")
            source = source.replace("/dev/tty", (work / "no-controlling-terminal").as_posix())
            script = work / "sni_menu.sh"
            prelude = """export PATH=/usr/bin:/bin:$PATH
set -euo pipefail
source src/common/colors.sh
ok() { :; }
log() { :; }
warn() { printf '%s\n' "$*" >&2; }
NON_INTERACTIVE=0
WIZARD_ALLOW_BACK=0
COLUMNS=80
"""
            setup = """
can_use_interactive_tui() { return 0; }
sni_preset_keys=(google microsoft apple samsung custom)
sni_preset_labels=("Google пул (по умолчанию)" "Microsoft пул" "Apple пул" "Samsung" "Свой SNI")
chosen_sni_preset=""
status=0
prompt_select "Select SNI" chosen_sni_preset "google" sni_preset_keys sni_preset_labels || status=$?
printf "\nRESULT=%s:%s\n" "$status" "$chosen_sni_preset"
"""
            script.write_text(prelude + source + setup, encoding="utf-8", newline="\n")
            env = os.environ.copy()
            env["TERM"] = "xterm-256color"
            result = subprocess.run([str(BASH), script.as_posix()], input="\x1b[B\n".encode("utf-8"), cwd=ROOT, env=env,
                                    capture_output=True, timeout=15)
            out = result.stdout.decode("utf-8", "replace")
            self.assertIn("RESULT=0:microsoft", out)
            # Ensure menu line doesn't leak raw domain contents into preset keys
            self.assertNotIn("staticview.microsoft.com", out)


if __name__ == "__main__":
    unittest.main()
