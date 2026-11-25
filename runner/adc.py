"""Expose a single short-lived ADC access token through the GCE metadata protocol.

The worker's root process can read the mounted credential. The AGY user can
obtain the access token for this job but cannot read or renew the credential.
"""
import datetime
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import unquote, urlsplit

import google.auth
from google.auth.transport.requests import Request

scope = "https://www.googleapis.com/auth/cloud-platform"
credentials, _ = google.auth.load_credentials_from_file("/authority/adc.json", scopes=[scope])
credentials.refresh(Request())
project = os.environ["GOOGLE_CLOUD_QUOTA_PROJECT"]
email = getattr(credentials, "service_account_email", None) or "default"
expiry = credentials.expiry
if expiry.tzinfo is None:
    expiry = expiry.replace(tzinfo=datetime.timezone.utc)
token = credentials.token


class Metadata(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = unquote(urlsplit(self.path).path)
        if self.headers.get("Metadata-Flavor") != "Google" and path != "/":
            self.send_error(403)
            return
        base = "/computeMetadata/v1/"
        account = base + "instance/service-accounts/default/"
        named_account = base + "instance/service-accounts/" + email + "/"
        if path.startswith(named_account):
            path = account + path[len(named_account):]
        values = {
            "/": "",
            base + "project/project-id": project,
            base + "instance/service-accounts/": "default/\n",
            account: {"email": email, "aliases": ["default"], "scopes": [scope]},
            account + "email": email,
            account + "scopes": scope,
            account + "token": {
                "access_token": token,
                "token_type": "Bearer",
                "expires_in": max(0, int((expiry - datetime.datetime.now(datetime.timezone.utc)).total_seconds())),
            },
        }
        if path not in values:
            self.send_error(404)
            return
        value = values[path]
        body = (value if isinstance(value, str) else json.dumps(value)).encode()
        self.send_response(200)
        self.send_header("Metadata-Flavor", "Google")
        self.send_header("Content-Type", "text/plain" if isinstance(value, str) else "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = HTTPServer(("127.0.0.1", 0), Metadata)
print(server.server_port, flush=True)
server.serve_forever()
