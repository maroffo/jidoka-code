import io
import json
import unittest
from unittest.mock import Mock

from jidoka.provider import Provider


class ProviderTests(unittest.TestCase):
    def test_credentials_require_safe_destination(self):
        for url in ("http://example.com/chat", "https://user:secret@example.com/chat"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                Provider(url, "test", "secret")

    def test_uses_explicit_model_and_json_input(self):
        provider = Provider("https://example.com/chat", "model-a", "key")
        provider.client = Mock()
        provider.client.open.return_value = io.BytesIO(
            b'{"choices":[{"finish_reason":"stop","message":{"content":"{}"}}]}'
        )
        self.assertEqual(provider.ask("system", {"x": "example"}), {})
        request = provider.client.open.call_args.args[0]
        payload = json.loads(request.data)
        self.assertEqual(payload["model"], "model-a")
        self.assertEqual(json.loads(payload["messages"][1]["content"]), {"x": "example"})

    def test_partial_or_invalid_response_is_error(self):
        provider = Provider("http://localhost:1234/chat", "model", "")
        for body in (b"[]", b'{"choices":[{"finish_reason":"length"}]}', b"bad"):
            with self.subTest(body=body), self.assertRaises(RuntimeError):
                provider.client = Mock()
                provider.client.open.return_value = io.BytesIO(body)
                provider.ask("system", {})

    def test_oversized_request_never_leaves_process(self):
        provider = Provider("https://example.com/chat", "model", "key")
        provider.client = Mock()
        with self.assertRaises(ValueError):
            provider.ask("", {"value": "x" * 1_000_000})
        provider.client.open.assert_not_called()
