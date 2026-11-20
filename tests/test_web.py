import io
import re
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
from unittest.mock import Mock
from urllib.parse import urlencode
from wsgiref.util import setup_testing_defaults
from wsgiref.validate import validator

from jidoka.web import create_app, recover, run_one

_ORIGIN = "http://127.0.0.1:8080"
_URL = "https://github.com/example/demo/pull/1"
_PROVIDER = "provider sintetico <modello>"
_BASE, _HEAD = "a" * 40, "b" * 40


def report(**overrides):
    return {
        "repo": "example/demo", "base": _BASE, "head": _HEAD,
        "focus": [], "findings": [], "limits": [],
        **overrides,
    }


class WebTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.db_path = Path(directory.name) / "reviews.sqlite3"
        self.app = validator(create_app(self.db_path, _PROVIDER))

    def request(self, path="/", method="GET", form=None, **overrides):
        body = urlencode(form or {}).encode()
        environ = {}
        setup_testing_defaults(environ)
        environ.update({
            "REQUEST_METHOD": method,
            "PATH_INFO": path,
            "QUERY_STRING": "",
            "HTTP_HOST": "127.0.0.1:8080",
            "CONTENT_TYPE": "application/x-www-form-urlencoded",
            "CONTENT_LENGTH": str(len(body)),
            "wsgi.input": io.BytesIO(body),
            **overrides,
        })
        response = Mock()
        chunks = self.app(environ, response)
        try:
            html = b"".join(chunks).decode()
        finally:
            chunks.close()
        status, headers = response.call_args.args
        headers = dict(headers)
        self.assertEqual(int(headers["Content-Length"]), len(html.encode()))
        return int(status.split()[0]), headers, html

    def open_form(self):
        status, headers, html = self.request()
        self.assertEqual(status, 200)
        cookie = headers["Set-Cookie"].split(";", 1)[0]
        token = re.search(r'name="csrf_token" value="([^"]+)"', html)[1]
        return cookie, {"url": _URL, "consent": "yes", "csrf_token": token}

    def submit(self, url=_URL):
        cookie, form = self.open_form()
        form["url"] = url
        status, headers, _ = self.request(method="POST", form=form, HTTP_COOKIE=cookie, HTTP_ORIGIN=_ORIGIN)
        self.assertEqual(status, 303)
        return headers["Location"]

    def test_form_displays_provider_and_keeps_it_escaped(self):
        status, headers, html = self.request()
        self.assertEqual(status, 200)
        self.assertIn('lang="it"', html)
        self.assertIn('method="post"', html)
        self.assertIn('name="consent" type="checkbox" value="yes" required', html)
        self.assertIn("provider sintetico &lt;modello&gt;", html)
        self.assertNotIn("<modello>", html)
        self.assertIn("SameSite=Strict", headers["Set-Cookie"])
        self.assertIn("HttpOnly", headers["Set-Cookie"])
        self.assertEqual(headers["Cache-Control"], "no-store")

    def test_cross_origin_submission_cannot_enqueue_with_valid_token(self):
        cookie, form = self.open_form()
        for headers in (
            {"HTTP_ORIGIN": "http://localhost:8080"},
            {"HTTP_ORIGIN": "http://127.0.0.1:9999"},
            {"HTTP_ORIGIN": "https://127.0.0.1:8080"},
            {"HTTP_ORIGIN": "null"},
            {"HTTP_REFERER": "https://other.example/page"},
            {"HTTP_SEC_FETCH_SITE": "cross-site"},
        ):
            with self.subTest(headers=headers):
                status, _, html = self.request(method="POST", form=form, HTTP_COOKIE=cookie, **headers)
                self.assertEqual(status, 403)
                self.assertIn("Invio del modulo non autorizzato", html)
        process = Mock()
        self.assertFalse(run_one(self.db_path, process))
        process.assert_not_called()

    def test_token_must_match_browser_cookie(self):
        cookie, form = self.open_form()
        other_cookie, _ = self.open_form()
        for fields, sent_cookie in (
            (form, ""),
            (form, other_cookie),
            ({**form, "csrf_token": ""}, cookie),
        ):
            with self.subTest(fields=fields, cookie=sent_cookie):
                status, _, _ = self.request(method="POST", form=fields, HTTP_COOKIE=sent_cookie)
                self.assertEqual(status, 403)
        self.assertFalse(run_one(self.db_path, Mock()))
        status, headers, html = self.request(HTTP_COOKIE=cookie)
        self.assertEqual(status, 200)
        self.assertNotIn("Set-Cookie", headers)
        self.assertIn(form["csrf_token"], html)
        self.assertEqual(self.request(method="POST", form=form, HTTP_COOKIE=cookie)[0], 303)

    def test_invalid_url_or_missing_consent_does_not_enqueue(self):
        cookie, form = self.open_form()
        without_consent = {name: value for name, value in form.items() if name != "consent"}
        status, _, html = self.request(method="POST", form=without_consent, HTTP_COOKIE=cookie)
        self.assertEqual(status, 400)
        self.assertIn("Conferma l’invio", html)
        for url in (
            "http://github.com/example/demo/pull/1",
            "https://github.com.example/example/demo/pull/1",
            "https://github.com@example.test/example/demo/pull/1",
            "https://github.com/example/../pull/1",
            "https://github.com/example/demo/issues/1",
            "https://github.com/example/demo/pull/0",
            f"https://github.com/example/{'a' * 101}/pull/1",
            '"><script>alert(1)</script>',
        ):
            with self.subTest(url=url):
                status, _, html = self.request(method="POST", form={**form, "url": url}, HTTP_COOKIE=cookie)
                self.assertEqual(status, 400)
                self.assertIn("Inserisci l’URL HTTPS", html)
                self.assertNotIn("<script>", html)
        self.assertFalse(run_one(self.db_path, Mock()))

    def test_invalid_request_body_does_not_enqueue(self):
        cookie, form = self.open_form()
        for code, overrides in (
            (400, {"CONTENT_LENGTH": ""}),
            (400, {"CONTENT_LENGTH": "12", "wsgi.input": io.BytesIO(b"url=x")}),
            (400, {"CONTENT_LENGTH": "5", "wsgi.input": io.BytesIO(b"url=\xff")}),
            (413, {"CONTENT_LENGTH": "8193"}),
            (415, {"CONTENT_TYPE": "text/plain"}),
        ):
            with self.subTest(overrides=overrides):
                status, _, _ = self.request(method="POST", form=form, HTTP_COOKIE=cookie, **overrides)
                self.assertEqual(status, code)
        self.assertFalse(run_one(self.db_path, Mock()))

    def test_queue_is_fifo_and_history_survives_restart(self):
        first = self.submit(f"{_URL}?notification=fixture#discussion")
        second_url = "https://github.com/example/demo/pull/2"
        second = self.submit(second_url)
        self.assertIn("In coda", self.request(first)[2])
        self.app = validator(create_app(self.db_path, _PROVIDER))
        self.assertEqual(recover(self.db_path, provider_label=_PROVIDER), 0)

        def process(url):
            self.assertEqual(url, _URL)
            self.assertIn("In corso", self.request(first)[2])
            self.assertIn("In coda", self.request(second)[2])
            return report()

        first_process = Mock(side_effect=process)
        self.assertTrue(run_one(self.db_path, first_process))
        first_process.assert_called_once_with(_URL)
        status, _, html = self.request(first)
        self.assertEqual(status, 200)
        self.assertIn("Completata", html)
        self.assertIn("Nessun problema verificato.", html)
        self.assertIn(_BASE, html)
        self.assertIn(_HEAD, html)
        self.assertIn("In coda", self.request(second)[2])

        second_process = Mock(return_value=report(limits=["Scanner assente"]))
        self.assertTrue(run_one(self.db_path, second_process))
        second_process.assert_called_once_with(second_url)
        self.assertFalse(run_one(self.db_path, second_process))
        second_process.assert_called_once()
        self.assertEqual(recover(self.db_path), 0)
        self.app = validator(create_app(self.db_path, _PROVIDER))

        html = self.request()[2]
        self.assertIn(f'<a href="{first}">{_URL}</a> · Completata', html)
        self.assertIn(f'<a href="{second}">{second_url}</a> · Parziale', html)
        html = self.request(second)[2]
        self.assertIn("Scanner assente", html)
        self.assertIn("Nessun problema verificato nel materiale esaminato.", html)

    def test_report_shows_ordered_focus_findings_and_links_at_reviewed_commit(self):
        location = self.submit()
        path = 'src/prova #"<.py'
        focus = {
            "path": path, "line": 12, "checked": "Controllo sintetico",
            "outcome": "<em>Esito</em>", "action": "Verifica che l’importazione sia completa.",
        }
        finding = {
            "path": path, "line": 28, "title": "<script>Titolo</script>",
            "impact": "Risultato incompleto", "evidence": "Riga 28\n<script>prova</script>",
            "attribution": "introduced",
        }
        process = Mock(return_value=report(
            focus=[focus, {**focus, "line": 13}, {**focus, "line": 14}, {**focus, "line": 15}],
            findings=[finding, {**finding, "path": "../altro", "line": 2, "attribution": "preexisting"}],
            limits=["Scanner <non disponibile>"],
        ))
        self.assertTrue(run_one(self.db_path, process))
        status, _, html = self.request(location)
        self.assertEqual(status, 200)
        self.assertIn("Parziale", html)
        self.assertLess(html.index("Dove concentrarti"), html.index("Problemi verificati"))
        self.assertLess(html.index("Problemi verificati"), html.index("Limiti di copertura"))
        revision = f"https://github.com/example/demo/blob/{_HEAD}"
        file_url = revision + "/src/prova%20%23%22%3C.py"
        for line in (12, 13, 14, 28):
            self.assertIn(f'href="{file_url}#L{line}"', html)
        self.assertNotIn("#L15", html)
        self.assertNotIn(f'href="{revision}/../altro', html)
        self.assertNotIn("<script>", html)
        self.assertIn("&lt;em&gt;Esito&lt;/em&gt;", html)
        self.assertIn("Riga 28\n&lt;script&gt;prova&lt;/script&gt;", html)
        self.assertIn("Verifica che l’importazione sia completa.", html)
        self.assertIn("Introdotto dalla PR", html)
        self.assertIn("Preesistente", html)
        self.assertIn("Scanner &lt;non disponibile&gt;", html)

    def test_only_one_worker_can_claim_a_queued_review(self):
        location = self.submit()
        ready = Barrier(2, timeout=5)
        process = Mock(return_value=report())

        def claim():
            ready.wait()
            return run_one(self.db_path, process)

        with ThreadPoolExecutor(max_workers=2) as workers:
            claims = [workers.submit(claim) for _ in range(2)]
        self.assertEqual(sorted(claim.result() for claim in claims), [False, True])
        process.assert_called_once_with(_URL)
        self.assertIn("Completata", self.request(location)[2])

    def test_process_failure_and_malformed_result_show_generic_error(self):
        for process in (
            Mock(side_effect=RuntimeError("test-segreto DA NON MOSTRARE")),
            Mock(return_value={"limits": []}),
            Mock(return_value=report(findings=[{}])),
        ):
            with self.subTest(process=process):
                location = self.submit()
                self.assertTrue(run_one(self.db_path, process))
                html = self.request(location)[2]
                self.assertIn("Fallita", html)
                self.assertIn("L’analisi non è riuscita", html)
                self.assertNotIn("test-segreto", html)
                self.assertNotIn("Nessun problema verificato", html)

    def test_recovery_marks_only_interrupted_jobs_as_failed(self):
        first = self.submit()
        second = self.submit()
        with self.assertRaises(KeyboardInterrupt):
            run_one(self.db_path, Mock(side_effect=KeyboardInterrupt))
        self.assertIn("In corso", self.request(first)[2])
        self.assertEqual(recover(self.db_path), 1)
        self.assertEqual(recover(self.db_path), 0)
        self.app = validator(create_app(self.db_path, _PROVIDER))
        html = self.request(first)[2]
        self.assertIn("Fallita", html)
        self.assertIn("L’analisi è stata interrotta", html)
        self.assertIn("In coda", self.request(second)[2])
        self.assertTrue(run_one(self.db_path, Mock(return_value=report())))
        self.assertIn("Completata", self.request(second)[2])

    def test_pending_consent_cannot_carry_over_to_another_provider(self):
        interrupted = self.submit()
        location = self.submit()
        with self.assertRaises(KeyboardInterrupt):
            run_one(self.db_path, Mock(side_effect=KeyboardInterrupt))

        old_cookie, old_form = self.open_form()
        provider = "nuovo provider sintetico"
        self.app = validator(create_app(self.db_path, provider))
        self.assertEqual(recover(self.db_path, provider_label=provider), 2)
        self.assertIn("L’analisi è stata interrotta", self.request(interrupted)[2])
        status, _, html = self.request(location)
        self.assertEqual(status, 200)
        self.assertIn("Fallita", html)
        self.assertIn("Il provider è cambiato", html)
        self.assertEqual(
            self.request(method="POST", form=old_form, HTTP_COOKIE=old_cookie, HTTP_ORIGIN=_ORIGIN)[0],
            403,
        )

        process = Mock(return_value=report())
        self.assertFalse(run_one(self.db_path, process))
        process.assert_not_called()
        new_url = "https://github.com/example/demo/pull/2"
        new_location = self.submit(new_url)
        self.assertTrue(run_one(self.db_path, process))
        self.assertFalse(run_one(self.db_path, process))
        process.assert_called_once_with(new_url)
        self.assertIn(provider, self.request(new_location)[2])

    def test_unknown_review_and_unsupported_method(self):
        self.assertEqual(self.request("/reviews/99")[0], 404)
        self.assertEqual(self.request("/reviews/9223372036854775808")[0], 404)
        status, headers, _ = self.request(method="DELETE")
        self.assertEqual(status, 405)
        self.assertEqual(headers["Allow"], "GET, POST")
