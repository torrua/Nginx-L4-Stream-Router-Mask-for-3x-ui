"""Tests for YABS benchmark integration and interactive prompt."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
BASH = Path(r"C:\Program Files\Git\bin\bash.exe") if os.name == "nt" else Path(shutil.which("bash") or "bash")


class BenchmarkTests(unittest.TestCase):
    def run_bash(self, script_code, env_extra=None):
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            prelude = """export PATH=/usr/bin:/bin:$PATH
set -euo pipefail
source src/common/colors.sh
source src/common/logger.sh
source src/common/config.sh
source src/system/benchmark.sh
"""
            script = work / "test.sh"
            script.write_text(prelude + script_code, encoding="utf-8", newline="\n")
            env = os.environ.copy()
            env["TEST_WORK"] = work.as_posix()
            if env_extra:
                env.update(env_extra)
            res = subprocess.run([str(BASH), script.as_posix()], cwd=ROOT, env=env,
                                 capture_output=True, text=True, encoding="utf-8", timeout=15)
            return res

    def test_run_yabs_benchmark_with_mock_runner(self):
        res = self.run_bash(r'''
log_file="$TEST_WORK/yabs.log"
mock_runner="$TEST_WORK/mock_yabs.sh"
cat << 'EOF' > "$mock_runner"
#!/usr/bin/env bash
echo "YABS Mock Runner Output: flags=[$*]"
EOF
chmod +x "$mock_runner"

export TEST_YABS_RUNNER="$mock_runner"
run_yabs_benchmark "-7 -r" "$log_file"

[ -f "$log_file" ] && echo "LOG_EXISTS"
cat "$log_file"
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("LOG_EXISTS", res.stdout)
        self.assertIn("YABS Mock Runner Output: flags=[-7 -r]", res.stdout)

    def test_offer_yabs_skips_when_skip_yabs_is_true(self):
        res = self.run_bash(r'''
export SKIP_YABS=1
offer_yabs_benchmark
echo "OFFER_FINISHED"
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("OFFER_FINISHED", res.stdout)
        self.assertNotIn("Проверка производительности сервера", res.stdout)

    def test_offer_yabs_non_interactive_skips_by_default(self):
        res = self.run_bash(r'''
export NON_INTERACTIVE=1
export RUN_YABS=0
offer_yabs_benchmark
echo "NON_INTERACTIVE_DONE"
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("NON_INTERACTIVE_DONE", res.stdout)
        self.assertNotIn("Проверка производительности сервера", res.stdout)

    def test_offer_yabs_non_interactive_runs_when_run_yabs_is_1(self):
        res = self.run_bash(r'''
log_file="$TEST_WORK/yabs.log"
mock_runner="$TEST_WORK/mock_yabs.sh"
cat << 'EOF' > "$mock_runner"
#!/usr/bin/env bash
echo "YABS_AUTO_TRIGGERED flags=[$*]"
EOF
chmod +x "$mock_runner"

export TEST_YABS_RUNNER="$mock_runner"
export NON_INTERACTIVE=1
export RUN_YABS=1
export YABS_ARGS="-g"

# Переопределяем log_file через временный аргумент run_yabs_benchmark
offer_yabs_benchmark
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("YABS_AUTO_TRIGGERED flags=[-g]", res.stdout)

    def test_offer_yabs_choice_4_triggers_geekbench_7(self):
        res = self.run_bash(r'''
mock_runner="$TEST_WORK/mock_yabs.sh"
cat << 'EOF' > "$mock_runner"
#!/usr/bin/env bash
echo "GB7_RAN flags=[$*]"
EOF
chmod +x "$mock_runner"

export TEST_YABS_RUNNER="$mock_runner"
export NON_INTERACTIVE=0
export YABS_TIMEOUT=5

# Симулируем ввод "4" (Geekbench 7)
offer_yabs_benchmark <<< "4"
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("GB7_RAN flags=[-7]", res.stdout)

    def test_offer_yabs_choice_2_triggers_express(self):
        res = self.run_bash(r'''
mock_runner="$TEST_WORK/mock_yabs.sh"
cat << 'EOF' > "$mock_runner"
#!/usr/bin/env bash
echo "EXPRESS_RAN flags=[$*]"
EOF
chmod +x "$mock_runner"

export TEST_YABS_RUNNER="$mock_runner"
export NON_INTERACTIVE=0
export YABS_TIMEOUT=5

# Симулируем ввод "2" (Express -g)
offer_yabs_benchmark <<< "2"
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("EXPRESS_RAN flags=[-g]", res.stdout)

    def test_offer_yabs_choice_5_triggers_network_only(self):
        res = self.run_bash(r'''
mock_runner="$TEST_WORK/mock_yabs.sh"
cat << 'EOF' > "$mock_runner"
#!/usr/bin/env bash
echo "NET_ONLY_RAN flags=[$*]"
EOF
chmod +x "$mock_runner"

export TEST_YABS_RUNNER="$mock_runner"
export NON_INTERACTIVE=0
export YABS_TIMEOUT=5

# Симулируем ввод "5" (Network only -f -g)
offer_yabs_benchmark <<< "5"
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("NET_ONLY_RAN flags=[-f -g]", res.stdout)

    def test_offer_yabs_choice_1_skips(self):
        res = self.run_bash(r'''
export NON_INTERACTIVE=0
export YABS_TIMEOUT=5

offer_yabs_benchmark <<< "1"
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("Тестирование производительности пропущено", res.stdout)

    def test_offer_yabs_idempotency_guard(self):
        res = self.run_bash(r'''
export SKIP_YABS=1
offer_yabs_benchmark
echo "FIRST_CALL"
offer_yabs_benchmark
echo "SECOND_CALL"
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("FIRST_CALL", res.stdout)
        self.assertIn("SECOND_CALL", res.stdout)

    def test_maintain_bench_with_explicit_flags(self):
        res = self.run_bash(r'''
mock_runner="$TEST_WORK/mock_yabs.sh"
cat << 'EOF' > "$mock_runner"
#!/usr/bin/env bash
echo "MAINTAIN_BENCH_FLAGS flags=[$*]"
EOF
chmod +x "$mock_runner"

export TEST_YABS_RUNNER="$mock_runner"

# Тестируем вызов maintain.sh с командой bench
bash maintain.sh bench -7 -r
''')
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("MAINTAIN_BENCH_FLAGS flags=[-7 -r]", res.stdout)



if __name__ == "__main__":
    unittest.main()
