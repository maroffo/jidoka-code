"""Trusted AGY-side relay. The reviewer selects argv, the controller pins the source."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time


def dispatch(source, argv):
    deadline = time.monotonic() + 65
    with socket.socket(socket.AF_UNIX) as backend:
        backend.settimeout(185)
        while True:
            try:
                backend.connect("/test-control/run.sock")
                break
            except FileNotFoundError:
                if not Path("/test-control").is_dir():
                    raise
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.2)
            except ConnectionRefusedError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.2)
        backend.sendall(json.dumps(argv).encode() + b"\n")
        if backend.recv(1) != b"+":
            raise ValueError("Invalid handshake")
        backend.setblocking(True)
        subprocess.run(["/bin/tar", "-cf", "-", "-C", source, "."], stdout=backend,
                       stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, check=True, timeout=50)
        backend.settimeout(185)
        backend.shutdown(socket.SHUT_WR)
        with backend.makefile("rb") as response:
            result = json.loads(response.read(65537))
        if result["status"] not in ("passed", "failed", "timeout", "unavailable"):
            raise ValueError("Invalid sandbox response")
        return result


def serve(source, directory):
    with socket.socket(socket.AF_UNIX) as server:
        path = directory / "test.sock"
        server.bind(str(path))
        os.chmod(path, 0o666)
        server.listen(1)
        for _ in range(32):
            client, _ = server.accept()
            with client:
                try:
                    client.settimeout(5)
                    with client.makefile("rb") as stream:
                        raw = stream.readline(4097)
                    if len(raw) > 4096 or not raw.endswith(b"\n"):
                        raise ValueError("Invalid command")
                    argv = json.loads(raw)
                    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) and "\0" not in a for a in argv):
                        raise ValueError("Invalid arguments")
                except (ValueError, OSError):
                    continue
                try:
                    result = dispatch(source, argv)
                except (OSError, subprocess.SubprocessError, ValueError, KeyError):
                    result = {"status": "unavailable", "output": "The offline test sandbox did not complete the request."}
                # Persist only execution metadata. Raw test output is for the current review.
                receipt = {k: v for k, v in result.items() if k != "output"}
                receipt["argv"] = argv
                with (directory / "tests.jsonl").open("a") as log:
                    log.write(json.dumps(receipt) + "\n")
                try:
                    client.sendall(json.dumps(result).encode())
                except OSError:
                    pass


if __name__ == "__main__":
    serve(sys.argv[1], Path(sys.argv[2]))
