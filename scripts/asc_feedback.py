#!/usr/bin/env python3
"""Dump App Store Connect review state and feedback for Skim (iOS + macOS) to JSON.
Stdlib only; signs the ASC JWT with `openssl`. Reads ASC_KEY_ID / ASC_ISSUER_ID /
ASC_KEY_PATH from the environment or from <repo>/.env.testflight.local.
Usage: python3 scripts/asc_feedback.py /path/to/skim/repo out.json
"""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error

repo, out = sys.argv[1], sys.argv[2]
env = dict(os.environ)
envf = os.path.join(repo, ".env.testflight.local")
if os.path.exists(envf):
    for line in open(envf):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env.setdefault(k.strip(), v.strip().strip('"').strip("'"))
KID, ISS, KEY = env["ASC_KEY_ID"], env["ASC_ISSUER_ID"], os.path.expanduser(env["ASC_KEY_PATH"])

def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def der_to_raw(der):
    # ECDSA DER SEQUENCE{INTEGER r, INTEGER s} -> 64-byte r||s
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7f)
    def read_int(i):
        assert der[i] == 2; n = der[i + 1]; v = der[i + 2:i + 2 + n]
        return v.lstrip(b"\x00").rjust(32, b"\x00"), i + 2 + n
    r, i = read_int(i); s, _ = read_int(i)
    return r + s

def token():
    now = int(time.time())
    h = b64(json.dumps({"alg": "ES256", "kid": KID, "typ": "JWT"}).encode())
    p = b64(json.dumps({"iss": ISS, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"}).encode())
    msg = f"{h}.{p}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", KEY], input=msg, capture_output=True, check=True).stdout
    return f"{h}.{p}.{b64(der_to_raw(der))}"

TOK = token()
def get(path):
    url = path if path.startswith("http") else "https://api.appstoreconnect.apple.com" + path
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + TOK})
    try:
        with urllib.request.urlopen(req, timeout=60) as r: return json.load(r)
    except urllib.error.HTTPError as e:
        return {"error": e.code, "url": url, "body": e.read().decode(errors="replace")[:2000]}

def get_all(path, cap=400):
    data, inc, nxt = [], [], path
    while nxt and len(data) < cap:
        r = get(nxt)
        if "error" in r: return r
        data += r.get("data", []); inc += r.get("included", [])
        nxt = r.get("links", {}).get("next")
    return {"data": data, "included": inc}

result = {"fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
apps = get("/v1/apps?filter[bundleId]=com.gm2211.skim,com.gm2211.skim.native.macos&limit=10")
result["apps"] = apps
for app in apps.get("data", []):
    aid = app["id"]; a = result.setdefault(app["attributes"]["bundleId"], {"id": aid})
    a["appStoreVersions"] = get_all(f"/v1/apps/{aid}/appStoreVersions?limit=20&include=build,appStoreReviewDetail")
    a["reviewSubmissions"] = get_all(f"/v1/reviewSubmissions?filter[app]={aid}&limit=50&include=items")
    a["appInfos"] = get(f"/v1/apps/{aid}/appInfos?include=ageRatingDeclaration,primaryCategory")
    a["betaFeedbackScreenshots"] = get_all(f"/v1/apps/{aid}/betaFeedbackScreenshotSubmissions?limit=100")
    a["betaFeedbackCrashes"] = get_all(f"/v1/apps/{aid}/betaFeedbackCrashSubmissions?limit=100")
    a["customerReviews"] = get_all(f"/v1/apps/{aid}/customerReviews?limit=100&sort=-createdDate")
    builds = get(f"/v1/builds?filter[app]={aid}&sort=-uploadedDate&limit=10&include=betaAppReviewSubmission,preReleaseVersion")
    a["recentBuilds"] = builds
    for v in a["appStoreVersions"].get("data", []):
        vid = v["id"]
        v["_localizations"] = get_all(f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations?limit=50")
json.dump(result, open(out, "w"), indent=1)
summary = []
for k, a in result.items():
    if not isinstance(a, dict) or "appStoreVersions" not in a: continue
    for v in a["appStoreVersions"].get("data", [])[:5]:
        at = v["attributes"]; summary.append(f"{k} {at.get('platform')} {at.get('versionString')} {at.get('appStoreState') or at.get('appVersionState')}")
    for s in a["reviewSubmissions"].get("data", [])[:5]:
        at = s["attributes"]; summary.append(f"{k} submission {s['id']} {at.get('platform')} {at.get('state')} {at.get('submittedDate')}")
    summary.append(f"{k} TF feedback: {len(a['betaFeedbackScreenshots'].get('data', []))} screenshots, {len(a['betaFeedbackCrashes'].get('data', []))} crashes; reviews {len(a['customerReviews'].get('data', []))}")
print("\n".join(summary)); print("wrote", out)
