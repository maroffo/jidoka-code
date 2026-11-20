"""Italian WSGI interface and persistent queue for Jidoka reviews."""

import hmac
import json
import re
import secrets
import sqlite3
from collections.abc import Callable
from contextlib import closing, contextmanager
from html import escape
from http import HTTPStatus
from http.cookies import CookieError, SimpleCookie
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit
from wsgiref.util import application_uri

from jidoka.contracts import Finding, Focus, PublishedReport

_STATUSES = {
    "queued": "In coda",
    "running": "In corso",
    "completed": "Completata",
    "partial": "Parziale",
    "failed": "Fallita",
}
_ATTRIBUTION = {
    "introduced": "Introdotto dalla PR",
    "preexisting": "Preesistente",
    "unknown": "Attribuzione incerta",
}
_FAILED = "L’analisi non è riuscita. Puoi inviare di nuovo la PR dalla pagina iniziale."
_INTERRUPTED = "L’analisi è stata interrotta prima della fine. Invia di nuovo la PR per riprovare."
_PROVIDER_CHANGED = "Il provider è cambiato. Invia di nuovo la PR per confermare il destinatario."
_REPO = r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/(?!\.{1,2}(?:/|$))[A-Za-z0-9_.-]{1,100}"
_PULL_URL = re.compile(
    rf"https://github\.com/({_REPO})/pull/([1-9][0-9]{{0,9}})/?(?:[?#][^\s]*)?",
    re.IGNORECASE | re.ASCII,
)
_REVIEW_PATH = re.compile(r"/reviews/([1-9][0-9]{0,18})")
_FORM_LIMIT = 8192
_CSRF_COOKIE = "jidoka_csrf"


@contextmanager
def _connect(db_path):
    with closing(sqlite3.connect(db_path)) as db, db:
        db.row_factory = sqlite3.Row
        yield db


def _init_db(db):
    db.execute("""
        CREATE TABLE IF NOT EXISTS reviews (
            id INTEGER PRIMARY KEY,
            url TEXT NOT NULL,
            provider TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            report TEXT,
            error TEXT
        )
        """)


def recover(db_path: str | Path, provider_label: str | None = None) -> int:
    """Fail interrupted reviews and stale provider consents before the worker starts."""
    with _connect(db_path) as db:
        _init_db(db)
        failed = db.execute(
            "UPDATE reviews SET status = 'failed', error = ? WHERE status = 'running'",
            (_INTERRUPTED,),
        ).rowcount
        if provider_label is not None:
            failed += db.execute(
                "UPDATE reviews SET status = 'failed', error = ? WHERE status = 'queued' AND provider <> ?",
                (_PROVIDER_CHANGED, provider_label),
            ).rowcount
        return failed


def _encode_report(report):
    if not isinstance(report, dict) or not all(
        isinstance(report.get(key), expected)
        for key, expected in (
            ("repo", str), ("base", str), ("head", str),
            ("focus", list), ("findings", list), ("limits", list),
        )
    ):
        raise ValueError("Invalid report")
    for name, record in (("focus", Focus), ("findings", Finding)):
        if not all(
            isinstance(item, dict) and record.__required_keys__ <= item.keys()
            for item in report[name]
        ):
            raise ValueError("Invalid report entry")
    return json.dumps(report, ensure_ascii=True, allow_nan=False)


def run_one(db_path: str | Path, process: Callable[[str], PublishedReport]) -> bool:
    """Claim the oldest queued review and save its result. Return whether one was claimed."""
    with _connect(db_path) as db:
        job = db.execute("""
            UPDATE reviews SET status = 'running'
            WHERE id = (SELECT id FROM reviews WHERE status = 'queued' ORDER BY id LIMIT 1)
            RETURNING id, url
            """).fetchone()
    if job is None:
        return False

    try:
        report = process(job["url"])
        encoded = _encode_report(report)
        status = "partial" if report["limits"] else "completed"
        error = None
    except Exception:  # noqa: BLE001 -- A failed processor must leave a terminal job state.
        status, encoded, error = "failed", None, _FAILED

    with _connect(db_path) as db:
        db.execute(
            "UPDATE reviews SET status = ?, report = ?, error = ? WHERE id = ? AND status = 'running'",
            (status, encoded, error, job["id"]),
        )
    return True


def _origin(url, allow_path=False):
    try:
        parts = urlsplit(url)
        default_port = {"http": 80, "https": 443}.get(parts.scheme)
        if (
            default_port is not None
            and parts.hostname
            and parts.username is None
            and (allow_path or not (parts.path or parts.query or parts.fragment))
        ):
            port = parts.port
            return parts.scheme, parts.hostname, default_port if port is None else port
    except ValueError:
        pass
    return None


def _same_origin(environ):
    if environ.get("HTTP_SEC_FETCH_SITE") in {"cross-site", "same-site"}:
        return False
    origin = environ.get("HTTP_ORIGIN")
    referer = environ.get("HTTP_REFERER")
    if origin is None and referer is None:
        return True
    expected = _origin(application_uri(environ), allow_path=True)
    supplied = _origin(origin) if origin is not None else _origin(referer, allow_path=True)
    return expected is not None and expected == supplied


def _cookie_value(environ):
    cookies = SimpleCookie()
    try:
        cookies.load(environ.get("HTTP_COOKIE", ""))
    except CookieError:
        return ""
    cookie = cookies.get(_CSRF_COOKIE)
    return cookie.value if cookie and re.fullmatch(r"[A-Za-z0-9_-]{43}", cookie.value) else ""


def _form_data(environ):
    content_type = environ.get("CONTENT_TYPE", "").partition(";")[0].strip().lower()
    if content_type != "application/x-www-form-urlencoded":
        return HTTPStatus.UNSUPPORTED_MEDIA_TYPE, {}
    length = environ.get("CONTENT_LENGTH", "")
    if not re.fullmatch(r"[0-9]{1,10}", length):
        return HTTPStatus.BAD_REQUEST, {}
    size = int(length)
    if size > _FORM_LIMIT:
        return HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {}
    try:
        raw = environ["wsgi.input"].read(size)
        if len(raw) != size:
            return HTTPStatus.BAD_REQUEST, {}
        fields = parse_qs(
            raw.decode("utf-8"), keep_blank_values=True, strict_parsing=True,
            errors="strict", max_num_fields=8,
        )
        if any(len(values) != 1 for values in fields.values()):
            return HTTPStatus.BAD_REQUEST, {}
    except ValueError:
        return HTTPStatus.BAD_REQUEST, {}
    return HTTPStatus.OK, {name: values[0] for name, values in fields.items()}


def _page(title, body):
    return f"""<!doctype html>
<html lang="it">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} · Jidoka Code</title>
<style>
  :root {{ color-scheme: light dark }}
  body {{ font: 1rem/1.55 system-ui, sans-serif; margin: 1.5rem auto; padding: 0 1rem;
          max-width: 48rem; overflow-wrap: anywhere }}
  input, button {{ font: inherit }}
  input[type="url"] {{ box-sizing: border-box; width: 100%; padding: .5rem }}
  button {{ padding: .4rem .9rem }}
  section {{ margin-block: 2rem }}
  li + li {{ margin-top: .65rem }}
  dd {{ margin: 0 0 .4rem }}
  .error {{ border-inline-start: .25rem solid currentColor; padding-inline-start: .75rem }}
  .evidence {{ white-space: pre-wrap }}
</style>
<header><a href="/">Jidoka Code</a></header>
<main>{body}</main>
</html>"""


def _respond(start_response, status, page="", headers=()):
    body = page.encode("utf-8", errors="replace")
    start_response(f"{status.value} {status.phrase}", [
        ("Content-Type", "text/html; charset=utf-8"),
        ("Content-Length", str(len(body))),
        ("Cache-Control", "no-store"),
        ("Content-Security-Policy", (
            "default-src 'none'; style-src 'unsafe-inline'; "
            "form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
        )),
        ("Referrer-Policy", "same-origin"),
        ("X-Content-Type-Options", "nosniff"),
        *headers,
    ])
    return [body]


def _error_page(start_response, status, message, headers=()):
    return _respond(start_response, status, _page(
        "Errore", f'<h1>{message}</h1><p><a href="/">Torna alla pagina iniziale</a></p>',
    ), headers)


def _home(db_path, provider_label, token, value="", error=""):
    with _connect(db_path) as db:
        history = db.execute("SELECT id, url, status, created_at FROM reviews ORDER BY id DESC").fetchall()
    entries = "".join(
        f'<li><a href="/reviews/{job["id"]}">{escape(job["url"])}</a>'
        f' · {_STATUSES[job["status"]]} · {job["created_at"]} UTC</li>'
        for job in history
    )
    history_html = f"<ul>{entries}</ul>" if entries else "<p>Nessuna review registrata.</p>"
    error_html = f'<p class="error" role="alert">{error}</p>' if error else ""
    return _page("Nuova review", f"""
<h1>Nuova review</h1>
{error_html}
<form action="/" method="post">
  <input type="hidden" name="csrf_token" value="{token}">
  <label for="url">URL della pull request GitHub</label>
  <input id="url" name="url" type="url" value="{escape(value)}" required>
  <p>Il codice da analizzare verrà inviato a <strong>{escape(provider_label)}</strong>.</p>
  <p><label><input name="consent" type="checkbox" value="yes" required>
    Acconsento all’invio del codice a questo provider.</label></p>
  <button type="submit">Avvia la review</button>
</form>
<section><h2>Cronologia</h2>{history_html}</section>
""")


def _position(report, item):
    path, line = item["path"], item["line"]
    label = f"{escape(str(path))}, riga {escape(str(line))}"
    repo, head = report["repo"], report["head"]
    if (
        re.fullmatch(_REPO, repo)
        and re.fullmatch(r"[0-9a-fA-F]{40}", head)
        and isinstance(path, str)
        and all(part not in {"", ".", ".."} for part in path.split("/"))
        and type(line) is int and line > 0
    ):
        return f'<a href="https://github.com/{repo}/blob/{head}/{quote(path, safe="/")}#L{line}">{label}</a>'
    return label


def _report_html(report):
    focus = "".join(
        f'<li><p>{_position(report, item)}</p><dl>'
        f'<dt>Controllo</dt><dd>{escape(str(item["checked"]))}</dd>'
        f'<dt>Esito</dt><dd>{escape(str(item["outcome"]))}</dd>'
        f'<dt>Azione</dt><dd>{escape(str(item["action"]))}</dd></dl></li>'
        for item in report["focus"][:3]
    )
    findings = "".join(
        f'<li><h3>{escape(str(item["title"]))}</h3>'
        f'<p>{_position(report, item)} · {_ATTRIBUTION.get(str(item["attribution"]), _ATTRIBUTION["unknown"])}</p>'
        f'<dl><dt>Impatto</dt><dd>{escape(str(item["impact"]))}</dd>'
        f'<dt>Prova</dt><dd class="evidence">{escape(str(item["evidence"]))}</dd></dl></li>'
        for item in report["findings"]
    )
    limits = "".join(f"<li>{escape(str(limit))}</li>" for limit in report["limits"])
    focus_html = f"<ol>{focus}</ol>" if focus else "<p>Nessuna indicazione prioritaria.</p>"
    if findings:
        findings_html = f"<ul>{findings}</ul>"
    elif limits:
        findings_html = "<p>Nessun problema verificato nel materiale esaminato.</p>"
    else:
        findings_html = "<p>Nessun problema verificato.</p>"
    limits_html = f"<ul>{limits}</ul>" if limits else "<p>Nessun limite segnalato.</p>"
    scan = report.get("scan")
    scan_html = ""
    if scan:
        covered = ", ".join(scan["covered"]) or "Nessun file"
        signals = "".join(
            f'<li>{escape(signal["rule"])} · {_position(report, signal)}</li>'
            for signal in scan["signals"]
        )
        scan_html = (
            f'<details><summary>Scansione Semgrep</summary>'
            f'<p>Versione: {escape(scan["version"] or "non disponibile")}</p>'
            f'<p>File esaminati: {escape(covered)}</p>'
            + (f'<ul>{signals}</ul>' if signals else '')
            + '</details>'
        )
    return f"""
<section><h2>Dove concentrarti</h2>{focus_html}</section>
<dl>
  <dt>Repository</dt><dd>{escape(report["repo"])}</dd>
  <dt>Revisione base</dt><dd><code>{escape(report["base"])}</code></dd>
  <dt>Revisione esaminata</dt><dd><code>{escape(report["head"])}</code></dd>
</dl>
<section><h2>Problemi verificati</h2>{findings_html}</section>
<section><h2>Limiti di copertura</h2>{limits_html}{scan_html}</section>
"""


def _review_page(job):
    if job["status"] == "failed":
        details = f'<p class="error" role="alert">{escape(job["error"])}</p>'
    elif job["status"] in {"queued", "running"}:
        details = f'<p><a href="/reviews/{job["id"]}">Aggiorna lo stato</a></p>'
    else:
        details = _report_html(json.loads(job["report"]))
    return _page(f'Review {job["id"]}', f"""
<h1>Review {job["id"]}</h1>
<p>Stato: <strong>{_STATUSES[job["status"]]}</strong></p>
<p><a href="{escape(job["url"])}">{escape(job["url"])}</a></p>
<p>{job["created_at"]} UTC · Provider: {escape(job["provider"])}</p>
{details}
<p><a href="/">Torna alla cronologia</a></p>
""")


def create_app(db_path: str | Path, provider_label: str):
    """Create the WSGI app and initialize the review database."""
    with _connect(db_path) as db:
        _init_db(db)
    secret = secrets.token_bytes(32)

    def form_token(cookie):
        return hmac.digest(secret, cookie.encode("ascii"), "sha256").hex()

    def app(environ, start_response):
        path, method = environ["PATH_INFO"], environ["REQUEST_METHOD"]
        if path == "/" and method == "GET":
            cookie = _cookie_value(environ)
            headers = []
            if not cookie:
                cookie = secrets.token_urlsafe(32)
                secure = "; Secure" if environ["wsgi.url_scheme"] == "https" else ""
                headers.append((
                    "Set-Cookie", f"{_CSRF_COOKIE}={cookie}; Path=/; HttpOnly; SameSite=Strict{secure}",
                ))
            page = _home(db_path, provider_label, form_token(cookie))
            return _respond(start_response, HTTPStatus.OK, page, headers)

        if path == "/" and method == "POST":
            forbidden = "Invio del modulo non autorizzato. Riapri la pagina iniziale e riprova."
            cookie = _cookie_value(environ)
            if not cookie or not _same_origin(environ):
                return _error_page(start_response, HTTPStatus.FORBIDDEN, forbidden)
            status, fields = _form_data(environ)
            if status != HTTPStatus.OK:
                return _error_page(start_response, status, "Impossibile leggere il modulo.")
            token = form_token(cookie)
            if not hmac.compare_digest(fields.get("csrf_token", "").encode(), token.encode()):
                return _error_page(start_response, HTTPStatus.FORBIDDEN, forbidden)

            value = fields.get("url", "")
            match = _PULL_URL.fullmatch(value.strip())
            if fields.get("consent") != "yes":
                error = "Conferma l’invio del codice al provider prima di avviare la review."
            elif match is None:
                error = "Inserisci l’URL HTTPS di una pull request su github.com."
            else:
                repo, number = match.groups()
                url = f"https://github.com/{repo}/pull/{number}"
                with _connect(db_path) as db:
                    job_id = db.execute(
                        "INSERT INTO reviews (url, provider, status) VALUES (?, ?, 'queued')",
                        (url, provider_label),
                    ).lastrowid
                location = f"/reviews/{job_id}"
                return _respond(
                    start_response, HTTPStatus.SEE_OTHER,
                    _page("Review in coda", f'<p><a href="{location}">Apri la review</a></p>'),
                    [("Location", location)],
                )
            return _respond(start_response, HTTPStatus.BAD_REQUEST,
                            _home(db_path, provider_label, token, value, error))

        match = _REVIEW_PATH.fullmatch(path)
        job_id = int(match[1]) if match else 0
        if method == "GET" and 0 < job_id <= 2**63 - 1:
            with _connect(db_path) as db:
                job = db.execute("SELECT * FROM reviews WHERE id = ?", (job_id,)).fetchone()
            if job:
                return _respond(start_response, HTTPStatus.OK, _review_page(job))
        if path == "/" or (match and method != "GET"):
            allow = "GET, POST" if path == "/" else "GET"
            return _error_page(start_response, HTTPStatus.METHOD_NOT_ALLOWED,
                               "Metodo non consentito.", [("Allow", allow)])
        return _error_page(start_response, HTTPStatus.NOT_FOUND, "Pagina non trovata.")

    return app
