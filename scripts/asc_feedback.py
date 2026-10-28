#!/usr/bin/env python3
"""Dump App Store Connect review state and feedback for Skim (iOS + macOS) to JSON (read-only).
Usage: python3 scripts/asc_feedback.py /path/to/skim/repo out.json
"""
import json, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc_api import Client

repo, out = sys.argv[1], sys.argv[2]
client = Client(repo)
get, get_all = client.get, client.get_all

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
