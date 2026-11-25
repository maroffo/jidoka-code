"""One offline test per container lifetime. No repository or credential volumes."""
import json
import os
import signal
import socket
import subprocess
import tempfile
import time

CONTROL = "/test-control/run.sock"
USER = 65534
# A regular file bounds memory even if the child floods stdout.
MAX_OUTPUT = 8192


def run(conn, argv):
    os.chdir("/work")
    child = dict(user=USER, group=USER, extra_groups=[],
                 env={"HOME": "/work", "PATH": os.environ["PATH"], "TMPDIR": "/tmp",
                      "GOTOOLCHAIN": "local", "GOPROXY": "off", "CARGO_NET_OFFLINE": "true"})
    # The trusted gateway sends the pinned export only after receiving this byte.
    conn.sendall(b"+")
    unpack = subprocess.run(["tar", "--extract", "--no-same-owner", "--no-same-permissions"],
                            stdin=conn, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            timeout=45, **child)
    if unpack.returncode:
        return {"status": "unavailable", "output": "Could not prepare the pinned source."}
    started = time.monotonic()
    with tempfile.TemporaryFile() as log:
        try:
            proc = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                  timeout=120, **child)
        except subprocess.TimeoutExpired:
            return {"status": "timeout", "output": "Test exceeded 120 seconds."}
        except OSError:
            return {"status": "unavailable", "output": "Test executable unavailable in the sandbox."}
        log.seek(0)
        data = log.read(MAX_OUTPUT + 1)
        return {"status": "passed" if proc.returncode == 0 else "failed",
                "exit_code": proc.returncode, "seconds": int(time.monotonic() - started),
                "output": data[:MAX_OUTPUT].decode(errors="replace") + ("\n[truncated]" if len(data) > MAX_OUTPUT else "")}


def main():
    os.umask(0o077)
    os.makedirs("/test-control", exist_ok=True)
    os.chmod("/test-control", 0o700)
    with socket.socket(socket.AF_UNIX) as listener:
        staging = CONTROL + ".starting"
        if os.path.exists(staging):
            os.unlink(staging)
        listener.bind(staging)
        listener.listen(1)
        os.replace(staging, CONTROL)
        conn, _ = listener.accept()
    # Exiting PID 1 destroys all descendants, including detached tests, before reuse.
    signal.alarm(180)
    with conn, conn.makefile("rb") as header:
        argv = json.loads(header.readline(4097))
        if not isinstance(argv, list) or not argv or not all(isinstance(arg, str) for arg in argv):
            return
        result = run(conn, argv)
        conn.sendall(json.dumps(result).encode())


if __name__ == "__main__":
    main()
