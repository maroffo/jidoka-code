"""Run bundled Semgrep CE rules against disposable copies of review source."""

import json
import os
import re
import selectors
import shutil
import signal
import subprocess
from collections import Counter
from pathlib import Path
from tempfile import TemporaryDirectory
from time import monotonic

from .contracts import Scan, Signal, Snapshot
from .source import _safe_path

_RULES = Path(__file__).resolve().parent.parent / "rules" / "python.yml"
_MAX_TARGETS = 28
_MAX_TARGET_BYTES = 24_000
_MAX_INPUT = 96_000
_MAX_OUTPUT = 1_000_000
_MAX_SIGNALS = 100
_SCAN_SECONDS = 20
_VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
_DOCS = {".md", ".rst", ".txt"}
_PYTHON = {".py", ".pyi"}


def _targets(snapshot, limits):
    paths = Counter(file["path"] for file in snapshot["files"])
    targets = {}
    unsupported = False
    remaining = _MAX_INPUT
    for file in snapshot["files"]:
        path, text = file["path"], file["after"]
        if not text:
            continue
        if not _safe_path(path) or paths[path] != 1:
            limits.append("Skipped source with an invalid or duplicate scan path.")
            continue
        suffix = Path(path).suffix
        if suffix in _DOCS or Path(path).name == "LICENSE":
            continue
        if suffix not in _PYTHON:
            unsupported = True
            continue
        try:
            raw = text.encode("utf-8")
        except UnicodeError:
            limits.append(f"Unsupported source encoding for {path}.")
            continue
        if b"\0" in raw or len(raw) > min(remaining, _MAX_TARGET_BYTES) or len(targets) >= _MAX_TARGETS:
            limits.append(f"Semgrep input budget or file type excluded {path}.")
            continue
        remaining -= len(raw)
        targets[f"target_{len(targets)}.py"] = path, raw
    if unsupported:
        limits.append("The bundled Semgrep rules cover Python only. Other source types were skipped.")
    return targets


def _run(command, directory, env):
    """Keep the JSON pipe bounded and stop child processes on an interrupted scan."""
    deadline = monotonic() + _SCAN_SECONDS
    with subprocess.Popen(
        command, cwd=directory, env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True,
    ) as process:
        try:
            if process.stdout is None:
                raise OSError("Semgrep output pipe was unavailable.")
            output_fd = process.stdout.fileno()
            output = bytearray()
            with selectors.DefaultSelector() as selector:
                selector.register(output_fd, selectors.EVENT_READ)
                while len(output) <= _MAX_OUTPUT:
                    remaining = deadline - monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        raise subprocess.TimeoutExpired(command, _SCAN_SECONDS)
                    chunk = os.read(output_fd, min(65_536, _MAX_OUTPUT + 1 - len(output)))
                    if not chunk:
                        return process.wait(timeout=max(0, deadline - monotonic())), output
                    output.extend(chunk)
            raise ValueError("Semgrep output exceeded the size budget.")
        finally:
            if process.returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()


def _result(result, targets, report):
    paths = result.get("paths")
    scanned = paths.get("scanned") if isinstance(paths, dict) else None
    errors = result.get("errors")
    results = result.get("results")
    if (
        not isinstance(scanned, list) or not all(isinstance(path, str) and path in targets for path in scanned)
        or not isinstance(errors, list) or not isinstance(results, list)
    ):
        raise ValueError("Invalid Semgrep response.")

    version = result.get("version")
    if isinstance(version, str) and _VERSION.fullmatch(version):
        report["version"] = version
    else:
        report["limits"].append("Semgrep did not report its version.")

    error_paths = {
        error["path"] for error in errors
        if isinstance(error, dict) and isinstance(error.get("path"), str)
    }
    scanned_paths = set(scanned)
    covered = scanned_paths - error_paths
    report["covered"] = [path for name, (path, _) in targets.items() if name in covered]
    if errors:
        report["limits"].append("Semgrep reported scan errors. Coverage may be incomplete.")
    if len(covered) != len(targets):
        report["limits"].append("Semgrep did not cover every prepared Python file.")

    invalid = False
    seen = set()
    for item in results:
        if not isinstance(item, dict):
            invalid = True
            continue
        name, rule = item.get("path"), item.get("check_id")
        start, extra = item.get("start"), item.get("extra")
        line = start.get("line") if isinstance(start, dict) else None
        message = extra.get("message") if isinstance(extra, dict) else None
        if (
            not isinstance(name, str) or name not in scanned_paths
            or not isinstance(rule, str) or not 0 < len(rule) <= 120 or not rule.isprintable()
            or type(line) is not int or not isinstance(message, str)
            or not 0 < len(message) <= 400 or not message.isprintable()
        ):
            invalid = True
            continue
        path, raw = targets[name]
        line_count = raw.count(b"\n") + (not raw.endswith(b"\n"))
        if not 1 <= line <= line_count:
            invalid = True
            continue
        identity = rule, path, line, message
        if identity in seen:
            continue
        if len(seen) == _MAX_SIGNALS:
            report["limits"].append("Semgrep signals exceeded the reporting budget.")
            break
        seen.add(identity)
        report["signals"].append(Signal(rule=rule, path=path, line=line, message=message))
    if invalid:
        report["limits"].append("Some Semgrep output had invalid source positions or fields.")


def scan(snapshot: Snapshot) -> Scan:
    """Run local Python rules on head text and return only source-grounded leads."""
    report = Scan(signals=[], limits=[], version="", covered=[])
    targets = _targets(snapshot, report["limits"])
    if not targets:
        return report
    executable = shutil.which("semgrep")
    if executable is None:
        report["limits"].append("Semgrep CE is unavailable.")
        return report
    try:
        with TemporaryDirectory(prefix="jidoka-scan-") as temp:
            root = Path(temp)
            work = root / "source"
            work.mkdir()
            for name, (_, raw) in targets.items():
                (work / name).write_bytes(raw)
            env = {
                "PATH": os.environ.get("PATH", os.defpath),
                "HOME": temp,
                "XDG_CONFIG_HOME": temp,
                "XDG_CACHE_HOME": temp,
                "TMPDIR": temp,
                "SEMGREP_SEND_METRICS": "off",
                "SEMGREP_ENABLE_VERSION_CHECK": "0",
            }
            command = [
                os.path.abspath(executable), "scan", "--oss-only", "--json", "--quiet",
                "--metrics=off", "--disable-version-check", "--no-git-ignore",
                "--disable-nosem", "--no-rewrite-rule-ids", "--jobs=1", "--timeout=5",
                "--max-memory=256", f"--max-target-bytes={_MAX_TARGET_BYTES}",
                f"--config={_RULES}", "--", *targets,
            ]
            status, output = _run(command, work, env)
            if status != 0:
                report["limits"].append("Semgrep exited unsuccessfully.")
            result = json.loads(output)
            if not isinstance(result, dict):
                raise TypeError("Expected a Semgrep response object.")
            _result(result, targets, report)
    except subprocess.TimeoutExpired:
        report["limits"].append("Semgrep exceeded the scan deadline.")
    except (OSError, ValueError, TypeError, RecursionError):
        report["limits"].append("Semgrep could not complete a bounded local scan.")
    report["limits"] = list(dict.fromkeys(report["limits"]))
    return report
