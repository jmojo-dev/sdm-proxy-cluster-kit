# -*- coding: utf-8 -*-
# Mock Delinea Secret Server for tests/check (python 2.7 and 3.x).
# 127.0.0.1:8080 /SecretServer/...  plus a bare TCP listener on 127.0.0.1:8443
# (stands in for the worker's bind port).
import json, socket, threading
try:
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from urllib.parse import parse_qs
except ImportError:
    from BaseHTTPServer import BaseHTTPRequestHandler, HTTPServer
    from urlparse import parse_qs

SECRET = {"id": 1234, "name": "svc-rdp-test", "secretTemplateId": 6001, "active": True,
  "checkOutEnabled": False, "autoChangeEnabled": True, "items": [
  {"itemId": 1, "fieldName": "Domain", "slug": "domain", "isPassword": False, "isFile": False, "isNotes": False, "itemValue": "CORP.example.com"},
  {"itemId": 2, "fieldName": "Username", "slug": "username", "isPassword": False, "isFile": False, "isNotes": False, "itemValue": "CORP\\svc-rdp-test"},
  {"itemId": 3, "fieldName": "Password", "slug": "password", "isPassword": True, "isFile": False, "isNotes": False, "itemValue": u"Tröp&amp;Pa&ss "},
  {"itemId": 4, "fieldName": "API Token", "slug": "api-token", "isPassword": False, "isFile": False, "isNotes": False, "itemValue": "tokVALUEdonotprint"},
  {"itemId": 5, "fieldName": "Notes", "slug": "notes", "isPassword": False, "isFile": False, "isNotes": True, "itemValue": "line1\nline2\ttab \\ back"}]}

class H(BaseHTTPRequestHandler):
    def j(self, code, obj, raw=None):
        b = raw if raw is not None else json.dumps(obj).encode("utf-8")
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_HEAD(self):
        self.send_response(200); self.end_headers()
    def do_GET(self):
        if self.path == "/SecretServer/api/v1/healthcheck":
            return self.j(200, {"healthy": True})
        if self.path.startswith("/SecretServer/api/v1/secrets/"):
            if self.headers.get("Authorization") != "Bearer tok123":
                return self.j(401, {"message": "bad token"})
            if self.path.endswith("/1234") or "secretPath=%2FPOC%2Fsvc-rdp-test" in self.path:
                raw = json.dumps(SECRET, indent=1).replace("&", "\\u0026").encode("utf-8")
                return self.j(200, None, raw)
            return self.j(400, {"errorCode": "API_AccessDenied"})
        self.j(404, {})
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = parse_qs(self.rfile.read(n).decode("utf-8"))
        if self.path == "/SecretServer/oauth2/token":
            ok = body.get("username") == ["svc_sdm"] and body.get("password") == ["S3cr&t +%x"]
            return self.j(200 if ok else 400, {"access_token": "tok123", "expires_in": 1200} if ok else {"error": "invalid_grant"})
        self.j(404, {})
    def log_message(self, *a):
        pass

def bind_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 8443)); s.listen(5)
    while True:
        c, _ = s.accept(); c.close()

t = threading.Thread(target=bind_port); t.daemon = True; t.start()
HTTPServer(("127.0.0.1", 8080), H).serve_forever()
