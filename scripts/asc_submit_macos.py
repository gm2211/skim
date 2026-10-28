#!/usr/bin/env python3
"""Put the latest processed macOS build up for App Store review.

Dry run by default: prints what it would change. Pass --submit to change App Store Connect.
Usage: python3 scripts/asc_submit_macos.py /path/to/skim/repo --version 0.1.67 [--submit]

Steps: find the processed MAC_OS build for --version, move the editable macOS App Store
version to that version string, attach the build, write the App Review notes from
app-store-connect/review-notes-macos.txt, then submit through the existing unresolved
review submission (the reply to the earlier rejection) or a new one.
"""
import argparse, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc_api import Client

ap = argparse.ArgumentParser()
ap.add_argument("repo")
ap.add_argument("--version", required=True)
ap.add_argument("--submit", action="store_true")
args = ap.parse_args()
c = Client(args.repo)
notes = open(os.path.join(args.repo, "app-store-connect/review-notes-macos.txt")).read().strip()
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
            "INVALID_BINARY"}


def ok(r, what):
    if "error" in r:
        print(f"FAILED {what}: {json.dumps(r, indent=1)}")
        sys.exit(1)
    return r


def write(method, path, body, what):
    print(f"{'' if args.submit else '[dry run] '}{what}: {method} {path}")
    if args.submit:
        return ok(c.request(method, path, body), what)
    return {}


app = ok(c.get("/v1/apps?filter[bundleId]=com.gm2211.skim"), "find app")["data"][0]
aid = app["id"]

builds = ok(c.get(f"/v1/builds?filter[app]={aid}&filter[preReleaseVersion.platform]=MAC_OS"
                  f"&filter[preReleaseVersion.version]={args.version}&sort=-uploadedDate&limit=5"),
            "find build")["data"]
builds = [b for b in builds if b["attributes"].get("processingState") == "VALID"
          and not b["attributes"].get("expired")]
if not builds:
    sys.exit(f"No processed, unexpired macOS build for {args.version}")
build = builds[0]
print(f"Build: {args.version} ({build['attributes']['version']}) id={build['id']} "
      f"encryption={build['attributes'].get('usesNonExemptEncryption')}")

versions = ok(c.get(f"/v1/apps/{aid}/appStoreVersions?filter[platform]=MAC_OS&limit=20"),
              "list versions")["data"]
for v in versions:
    print(f"  macOS version {v['attributes']['versionString']}: {v['attributes'].get('appStoreState')}")
editable = [v for v in versions if v["attributes"].get("appStoreState") in EDITABLE]
if len(editable) > 1:
    sys.exit("More than one editable macOS version; resolve by hand")
if editable:
    vid = editable[0]["id"]
    if editable[0]["attributes"]["versionString"] != args.version:
        write("PATCH", f"/v1/appStoreVersions/{vid}",
              {"data": {"type": "appStoreVersions", "id": vid,
                        "attributes": {"versionString": args.version}}},
              f"rename version {editable[0]['attributes']['versionString']} -> {args.version}")
else:
    r = write("POST", "/v1/appStoreVersions",
              {"data": {"type": "appStoreVersions",
                        "attributes": {"platform": "MAC_OS", "versionString": args.version},
                        "relationships": {"app": {"data": {"type": "apps", "id": aid}}}}},
              f"create macOS version {args.version}")
    vid = r.get("data", {}).get("id", "<new>")

write("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build",
      {"data": {"type": "builds", "id": build["id"]}}, "attach build")

detail = c.get(f"/v1/appStoreVersions/{vid}/appStoreReviewDetail") if vid != "<new>" else {"data": None}
if detail.get("data"):
    did = detail["data"]["id"]
    write("PATCH", f"/v1/appStoreReviewDetails/{did}",
          {"data": {"type": "appStoreReviewDetails", "id": did, "attributes": {"notes": notes}}},
          "update review notes")
else:
    write("POST", "/v1/appStoreReviewDetails",
          {"data": {"type": "appStoreReviewDetails", "attributes": {"notes": notes},
                    "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}},
          "create review notes")

subs = ok(c.get(f"/v1/reviewSubmissions?filter[app]={aid}&filter[platform]=MAC_OS&limit=20&include=items"),
          "list submissions")
open_subs = [s for s in subs["data"]
             if s["attributes"].get("state") in {"UNRESOLVED_ISSUES", "READY_FOR_REVIEW"}]
for s in subs["data"]:
    print(f"  submission {s['id']}: {s['attributes'].get('state')}")
if open_subs:
    sid = open_subs[0]["id"]
    items = ok(c.get(f"/v1/reviewSubmissions/{sid}/items?include=appStoreVersion"), "list items")["data"]
    has_version = any((i.get("relationships", {}).get("appStoreVersion", {}).get("data") or {}).get("id") == vid
                      for i in items)
    print(f"Reusing submission {sid} ({len(items)} items, has version: {has_version})")
else:
    r = write("POST", "/v1/reviewSubmissions",
              {"data": {"type": "reviewSubmissions", "attributes": {"platform": "MAC_OS"},
                        "relationships": {"app": {"data": {"type": "apps", "id": aid}}}}},
              "create review submission")
    sid, has_version = r.get("data", {}).get("id", "<new>"), False
if not has_version:
    write("POST", "/v1/reviewSubmissionItems",
          {"data": {"type": "reviewSubmissionItems",
                    "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sid}},
                                      "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}},
          "add version to submission")
write("PATCH", f"/v1/reviewSubmissions/{sid}",
      {"data": {"type": "reviewSubmissions", "id": sid, "attributes": {"submitted": True}}},
      "submit for review")
if args.submit:
    print(json.dumps(c.get(f"/v1/reviewSubmissions/{sid}").get("data", {}).get("attributes"), indent=1))
