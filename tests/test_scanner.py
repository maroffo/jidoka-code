import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from jidoka import scanner


def file(path, after, before="", patch_text=""):
    return {"path": path, "patch": patch_text, "before": before, "after": after}


def snapshot(*files):
    return {
        "url": "https://github.com/owner/project/pull/1", "repo": "owner/project", "number": 1,
        "base": "a" * 40, "head": "b" * 40, "intent": [], "files": list(files), "limits": [],
    }


def signal(path="target_0.py", line=1):
    return {"path": path, "check_id": "fixture-rule", "start": {"line": line}, "extra": {"message": "Review this."}}


def reply(*, results=(), scanned=("target_0.py",), errors=(), status=0):
    return status, json.dumps({
        "results": list(results), "paths": {"scanned": list(scanned)},
        "errors": list(errors), "version": "1.146.0",
    }).encode()


class ScannerTests(unittest.TestCase):
    def test_stages_only_head_in_a_clean_directory_with_local_rules(self):
        workdirs = []

        def run(command, work, env):
            workdirs.append(work)
            self.assertEqual(command[:2], ["/local/semgrep", "scan"])
            for option in ("--metrics=off", "--disable-version-check", "--oss-only", "--no-git-ignore", "--disable-nosem"):
                self.assertIn(option, command)
            self.assertIn(f"--config={scanner._RULES}", command)
            self.assertEqual(command[-2:], ["--", "target_0.py"])
            self.assertEqual(list(work.iterdir()), [work / "target_0.py"])
            self.assertEqual((work / "target_0.py").read_bytes(), b"present = True\r\n")
            self.assertEqual(env["HOME"], str(work.parent))
            self.assertEqual(env["SEMGREP_SEND_METRICS"], "off")
            self.assertEqual(env["SEMGREP_ENABLE_VERSION_CHECK"], "0")
            for key in ("SEMGREP_APP_TOKEN", "JIDOKA_API_KEY", "HTTPS_PROXY", "PYTHONPATH"):
                self.assertNotIn(key, env)
            return reply(results=[signal(), signal()])

        with (
            patch.object(scanner.shutil, "which", return_value="/local/semgrep"),
            patch.object(scanner, "_run", side_effect=run),
            patch.dict(os.environ, {"SEMGREP_APP_TOKEN": "synthetic", "JIDOKA_API_KEY": "synthetic"}),
        ):
            result = scanner.scan(snapshot(
                file("pkg/a file.py", "present = True\r\n", before="old()", patch_text="+patch"),
                file("README.md", "Docs"), file("removed.py", "", before="old()"),
            ))
        self.assertFalse(workdirs[0].exists())
        self.assertEqual(result["version"], "1.146.0")
        self.assertEqual(result["covered"], ["pkg/a file.py"])
        self.assertEqual(result["signals"], [
            {"rule": "fixture-rule", "path": "pkg/a file.py", "line": 1, "message": "Review this."},
        ])
        self.assertEqual(result["limits"], [])

    def test_unsupported_duplicate_and_unsafe_paths_are_reported(self):
        with patch.object(scanner, "_run") as run:
            result = scanner.scan(snapshot(
                file("../outside.py", "x = 1"), file("dup.py", "x = 1"), file("dup.py", "x = 2"),
                file("code.js", "let x = 1;"), file("large.py", "x" * (scanner._MAX_TARGET_BYTES + 1)),
            ))
        run.assert_not_called()
        self.assertEqual(result["covered"], [])
        self.assertTrue(any("Python only" in limit for limit in result["limits"]))
        self.assertTrue(any("invalid or duplicate" in limit for limit in result["limits"]))
        self.assertTrue(any("large.py" in limit for limit in result["limits"]))

    def test_missing_executable_is_partial(self):
        with patch.object(scanner.shutil, "which", return_value=None):
            result = scanner.scan(snapshot(file("task.py", "pass\n")))
        self.assertEqual(result["signals"], [])
        self.assertEqual(result["covered"], [])
        self.assertTrue(any("unavailable" in limit for limit in result["limits"]))

    def test_skipped_files_and_invalid_locations_are_partial(self):
        response = reply(
            results=[signal(), signal("../outside.py"), signal(line=True), signal(line=2)],
            errors=[{"path": "target_1.py", "message": "Synthetic parse failure"}],
            scanned=["target_0.py", "target_1.py"], status=2,
        )
        with patch.object(scanner.shutil, "which", return_value="/local/semgrep"), patch.object(scanner, "_run", return_value=response):
            result = scanner.scan(snapshot(file("good.py", "pass\n"), file("broken.py", "fixture")))
        self.assertEqual(result["covered"], ["good.py"])
        self.assertEqual([(hit["path"], hit["line"]) for hit in result["signals"]], [("good.py", 1)])
        self.assertTrue(any("scan errors" in limit for limit in result["limits"]))
        self.assertTrue(any("invalid source positions" in limit for limit in result["limits"]))

    def test_malformed_output_or_timeout_returns_a_limit(self):
        for error in (subprocess.TimeoutExpired("semgrep", 1), None):
            with (
                self.subTest(error=error),
                patch.object(scanner.shutil, "which", return_value="/local/semgrep"),
                patch.object(scanner, "_run", return_value=(0, b"bad json"), side_effect=error),
            ):
                result = scanner.scan(snapshot(file("task.py", "pass\n")))
            self.assertTrue(result["limits"])
            self.assertEqual(result["covered"], [])

    def test_command_runner_enforces_output_and_time_budgets(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(scanner, "_MAX_OUTPUT", 16), self.assertRaisesRegex(ValueError, "output"):
                scanner._run([sys.executable, "-c", "print('x' * 100)"], directory, {})
            with patch.object(scanner, "_SCAN_SECONDS", 0.1), self.assertRaises(subprocess.TimeoutExpired):
                scanner._run([sys.executable, "-c", "from time import sleep; sleep(10)"], directory, {})

    @unittest.skipUnless(shutil.which("semgrep"), "Semgrep CE is unavailable")
    def test_real_rule_matches_positive_and_ignores_negative_fixture(self):
        result = scanner.scan(snapshot(
            file("test_positive.py", 'import subprocess\nsubprocess.run("fixture", shell=True)  # nosemgrep\n'),
            file("negative.py", 'import subprocess\nsubprocess.run(["fixture"], shell=False)\n'),
        ))
        self.assertEqual(result["limits"], [])
        self.assertTrue(result["version"])
        self.assertEqual(result["covered"], ["test_positive.py", "negative.py"])
        self.assertEqual(
            [(hit["rule"], hit["path"], hit["line"]) for hit in result["signals"]],
            [("python-subprocess-shell", "test_positive.py", 2)],
        )
