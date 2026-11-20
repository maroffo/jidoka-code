"""JSON chat transport for the operator's explicitly configured provider."""

import json
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Provider:
    def __init__(self, endpoint: str, model: str, api_key: str):
        url = urlsplit(endpoint)
        if not url.hostname or url.username or url.password or url.query or url.fragment:
            raise ValueError("Invalid provider endpoint")
        if url.scheme != "https" and not (
            url.scheme == "http" and url.hostname in {"localhost", "127.0.0.1", "::1"}
        ):
            raise ValueError("Use HTTPS or a loopback provider")
        if not model.strip():
            raise ValueError("Missing provider model")
        self.endpoint = endpoint
        self.label = f"{endpoint} ({model})"
        self.model = model
        self.api_key = api_key
        self.client = build_opener(_NoRedirect())

    def ask(self, system: str, data: dict) -> dict:
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": json.dumps(data, ensure_ascii=False)},
            ],
            "response_format": {"type": "json_object"},
        }
        body = json.dumps(payload).encode()
        if len(body) > 1_000_000:
            raise ValueError("Provider input exceeds size limit")
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        req = Request(self.endpoint, data=body, headers=headers, method="POST")
        try:
            with self.client.open(req, timeout=60) as response:
                raw = response.read(1_000_001)
            if len(raw) > 1_000_000:
                raise ValueError("Oversized response")
            choice = json.loads(raw)["choices"][0]
            if choice.get("finish_reason") != "stop":
                raise ValueError("Incomplete response")
            result = json.loads(choice["message"]["content"])
            if not isinstance(result, dict):
                raise TypeError("Expected object")
        except (OSError, HTTPError, URLError, ValueError, KeyError, IndexError, TypeError):
            raise RuntimeError("Provider request failed or returned incomplete JSON") from None
        return result
