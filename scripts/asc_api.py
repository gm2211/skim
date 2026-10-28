"""Minimal App Store Connect API client (stdlib only; signs the JWT with `openssl`).

Reads ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH from the environment or from
<repo>/.env.testflight.local.
"""
import base64, json, os, subprocess, time, urllib.error, urllib.request

BASE = "https://api.appstoreconnect.apple.com"


def _b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _der_to_raw(der):
    # ECDSA DER SEQUENCE{INTEGER r, INTEGER s} -> 64-byte r||s
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)

    def read_int(i):
        assert der[i] == 2
        n = der[i + 1]
        return der[i + 2:i + 2 + n].lstrip(b"\x00").rjust(32, b"\x00"), i + 2 + n

    r, i = read_int(i)
    s, _ = read_int(i)
    return r + s


class Client:
    def __init__(self, repo):
        env = dict(os.environ)
        envf = os.path.join(repo, ".env.testflight.local")
        if os.path.exists(envf):
            for line in open(envf):
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    env.setdefault(k.strip(), v.strip().strip('"').strip("'"))
        self.kid, self.iss = env["ASC_KEY_ID"], env["ASC_ISSUER_ID"]
        self.key = os.path.expanduser(env["ASC_KEY_PATH"])
        self._tok, self._exp = None, 0

    def token(self):
        now = int(time.time())
        if not self._tok or now > self._exp - 60:
            h = _b64(json.dumps({"alg": "ES256", "kid": self.kid, "typ": "JWT"}).encode())
            p = _b64(json.dumps({"iss": self.iss, "iat": now, "exp": now + 1100,
                                 "aud": "appstoreconnect-v1"}).encode())
            msg = f"{h}.{p}".encode()
            der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", self.key], input=msg,
                                 capture_output=True, check=True).stdout
            self._tok, self._exp = f"{h}.{p}.{_b64(_der_to_raw(der))}", now + 1100
        return self._tok

    def request(self, method, path, body=None):
        url = path if path.startswith("http") else BASE + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": "Bearer " + self.token(), "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            return {"error": e.code, "method": method, "url": url,
                    "body": e.read().decode(errors="replace")[:4000]}

    def get(self, path):
        return self.request("GET", path)

    def get_all(self, path, cap=400):
        data, inc, nxt = [], [], path
        while nxt and len(data) < cap:
            r = self.get(nxt)
            if "error" in r:
                return r
            data += r.get("data", [])
            inc += r.get("included", [])
            nxt = r.get("links", {}).get("next")
        return {"data": data, "included": inc}
