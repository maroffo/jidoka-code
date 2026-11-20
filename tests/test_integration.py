"""Exercise the service from the HTML form through storage and review to its permalink."""

import io
import re
import tempfile
import unittest
from http.cookies import SimpleCookie
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.parse import urlencode
from wsgiref.util import setup_testing_defaults

from jidoka import app, web


class ServiceTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.database = str(Path(tmp.name, "reviews.db"))
        self.provider = "test provider"
        self.wsgi = app.local_app(web.create_app(self.database, self.provider))
        self.repo = "example/calculator"
        self.url = f"https://github.com/{self.repo}/pull/3"
        self.snapshot = {
            "url": self.url,
            "repo": self.repo,
            "number": 3,
            "base": "a" * 40,
            "head": "b" * 40,
            "intent": ["Document units"],
            "limits": [],
            "files": [
                {
                    "path": "units.py",
                    "before": "",
                    "after": "# seconds\n",
                    "patch": "+# seconds",
                }
            ],
        }

    def request(self, path, fields=None, cookie=""):
        env = {}
        setup_testing_defaults(env)
        env.update(PATH_INFO=path, HTTP_HOST="localhost", HTTP_COOKIE=cookie)
        if fields is not None:
            data = urlencode(fields).encode()
            env.update(
                REQUEST_METHOD="POST",
                HTTP_ORIGIN="http://localhost",
                CONTENT_TYPE="application/x-www-form-urlencoded",
                CONTENT_LENGTH=str(len(data)),
            )
            env["wsgi.input"] = io.BytesIO(data)
        result = Mock()
        body = b"".join(self.wsgi(env, result)).decode()
        status, headers = result.call_args.args[:2]
        return int(status.split()[0]), dict(headers), body

    def queue(self):
        status, headers, body = self.request("/")
        self.assertEqual(status, 200)
        match = re.search(r'name="csrf_token" value="([^"]+)"', body)
        if match is None:
            self.fail("Missing CSRF token in the form")
        token = match[1]
        cookie = SimpleCookie(headers["Set-Cookie"])
        status, headers, _ = self.request(
            "/",
            {"csrf_token": token, "consent": "yes", "url": self.url},
            cookie.output(header="", attrs=[]).strip(),
        )
        self.assertEqual(status, 303)
        return headers["Location"]

    def test_foreign_host_cannot_access_loopback_service(self):
        wrapped = Mock()
        start = Mock()
        app.local_app(wrapped)({"HTTP_HOST": "public.example:8080"}, start)
        self.assertEqual(start.call_args.args[0], "403 Forbidden")
        wrapped.assert_not_called()

    def test_report_persists_with_coverage_limit(self):
        location = self.queue()
        ask = Mock(
            side_effect=[
                {"complete": True, "hypotheses": []},
                {"complete": True, "assessments": []},
            ]
        )
        scan = {
            "signals": [],
            "covered": [],
            "version": "test",
            "limits": ["Synthetic coverage limit"],
        }
        process = app.make_process({self.repo}, ask)
        with (
            patch.object(app.source, "collect", return_value=self.snapshot) as collect,
            patch.object(app.scanner, "scan", return_value=scan),
        ):
            self.assertTrue(web.run_one(self.database, process))
        collect.assert_called_once_with(self.url, {self.repo})
        self.assertEqual(ask.call_count, 2)
        self.wsgi = app.local_app(web.create_app(self.database, self.provider))
        web.recover(self.database)
        status, _, body = self.request(location)
        self.assertEqual(status, 200)
        self.assertIn("Synthetic coverage limit", body)
        self.assertIn("Scansione Semgrep", body)
        self.assertIn("Versione: test", body)
        self.assertIn(self.snapshot["head"], body)
        self.assertIn(location, self.request("/")[2])

    def test_failed_provider_is_visible_without_secret(self):
        location = self.queue()
        ask = Mock(side_effect=RuntimeError("PRIVATE_TEST_VALUE"))
        scan = {"signals": [], "covered": [], "version": "test", "limits": []}
        with (
            patch.object(app.source, "collect", return_value=self.snapshot),
            patch.object(app.scanner, "scan", return_value=scan),
        ):
            web.run_one(self.database, app.make_process({self.repo}, ask))
        status, _, body = self.request(location)
        self.assertEqual(status, 200)
        self.assertIn("fallita", body.lower())
        self.assertNotIn("PRIVATE_TEST_VALUE", body)
