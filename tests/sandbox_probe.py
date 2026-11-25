"""Run inside the AGY image with an isolated test-control volume and a sandbox peer."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        root.chmod(0o711)
        src, relay = root / "source", root / "relay"
        src.mkdir()
        relay.mkdir(mode=0o711)
        relay.chmod(0o711)
        (src / "go.mod").write_text("module example.test/probe\n\ngo 1.23\n")
        (src / "sum_test.go").write_text('package probe\nimport "testing"\nfunc TestSum(t *testing.T) { if 2+2 != 4 { t.Fatal("sum") } }\n')
        (src / "check.py").write_text("""
import os
from pathlib import Path
assert os.getuid() == 65534
import errno, socket
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
    assert probe.connect_ex(('192.0.2.1', 9)) == errno.ENETUNREACH
assert all(not Path(p).exists() for p in ('/jobs', '/control/agy.sock', '/authority/session/token.json', '/var/run/docker.sock'))
assert not os.access('/test-control', os.X_OK)
assert not any(k.startswith(('JIDOKA', 'GOOGLE', 'GITHUB')) for k in os.environ)
assert not Path('prior-test').exists()
Path('prior-test').touch()
""")
        sock = relay / 'test.sock'
        gateway = subprocess.Popen(["python3", "-I", "/usr/local/lib/jidoka/test_gateway.py", src, relay])
        try:
            for _ in range(100):
                if sock.exists():
                    break
                time.sleep(.05)
            def check(args, expected):
                p = subprocess.run(["jidoka-test", *args], cwd="/tmp",
                                   env={"PATH": os.environ["PATH"], "JIDOKA_TEST_SOCKET": str(sock)},
                                   user=10002, group=10002, extra_groups=[], timeout=260, capture_output=True, text=True)
                assert (p.returncode == 0) == (expected == "passed"), (p.stderr, p.stdout)
                row = json.loads((relay / "tests.jsonl").read_text().splitlines()[-1])
                assert row["argv"] == args and row["status"] == expected, row
                print(expected, args[0], flush=True)
            check(["python3", "check.py"], "passed")
            check(["python3", "check.py"], "passed")
            check(["go", "test", "-run", "^TestSum$", "."], "passed")
            check(["python3", "-c", "raise SystemExit(3)"], "failed")
            check(["jidoka-uninstalled-test-executable"], "unavailable")
            assert not (src / "prior-test").exists()
        finally:
            gateway.terminate()
            gateway.wait(timeout=5)


if __name__ == "__main__":
    main()
