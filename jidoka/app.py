"""Entrypoint for the single-user Jidoka review service."""

import logging
import os
import sqlite3
from pathlib import Path
from threading import Event, Thread
from urllib.parse import urlsplit
from wsgiref.simple_server import make_server

from jidoka import engine, scanner, source, web
from jidoka.contracts import PublishedReport
from jidoka.provider import Provider


def make_process(allowed_repos, ask):
    def process(url: str) -> PublishedReport:
        snapshot = source.collect(url, allowed_repos)
        scan = scanner.scan(snapshot)
        report = engine.review(snapshot, scan, ask)
        return {
            "scan": scan,
            "focus": report["focus"],
            "findings": report["findings"],
            "repo": snapshot["repo"],
            "base": snapshot["base"],
            "head": snapshot["head"],
            "limits": list(
                dict.fromkeys(snapshot["limits"] + scan["limits"] + report["limits"])
            ),
        }

    return process


def local_app(app):
    """The pilot accepts browser requests addressed to loopback only."""

    def serve(environ, start_response):
        try:
            host = urlsplit("//" + environ.get("HTTP_HOST", ""))
            valid = (
                host.hostname in {"localhost", "127.0.0.1", "::1"}
                and host.username is None
                and not (host.path or host.query or host.fragment)
                and (host.port is None or host.port > 0)
            )
        except ValueError:
            valid = False
        if not valid:
            start_response(
                "403 Forbidden", [("Content-Type", "text/plain; charset=utf-8")]
            )
            return [b"Apri Jidoka usando localhost."]
        return app(environ, start_response)

    return serve


def work(stop, database, process):
    while not stop.is_set():
        try:
            web.run_one(database, process)
        except sqlite3.OperationalError:
            # The next poll can recover from temporary database contention.
            logging.getLogger(__name__).error("Review queue poll failed")
        stop.wait(0.5)


def main():
    provider = Provider(
        os.environ["JIDOKA_PROVIDER_URL"],
        os.environ["JIDOKA_MODEL"],
        os.environ.get("JIDOKA_API_KEY", ""),
    )
    allowed = {
        repo.strip().lower()
        for repo in os.environ["JIDOKA_REPOS"].split(",")
        if repo.strip()
    }
    if not allowed:
        raise SystemExit("Set JIDOKA_REPOS to at least one approved public owner/repo")
    database = Path(os.environ.get("JIDOKA_DB", "data/reviews.sqlite3"))
    database.parent.mkdir(parents=True, exist_ok=True)
    app = local_app(web.create_app(str(database), provider.label))
    host = os.environ.get("JIDOKA_BIND", "127.0.0.1")
    port = int(os.environ.get("JIDOKA_PORT", "8080"))
    stop = Event()
    with make_server(host, port, app) as server:
        web.recover(str(database), provider.label)
        worker = Thread(
            target=work,
            args=(stop, str(database), make_process(allowed, provider.ask)),
            daemon=True,
        )
        worker.start()
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            stop.set()


if __name__ == "__main__":
    main()
