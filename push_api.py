#!/usr/bin/env python3
import os, sys, base64, json, time, urllib.request, urllib.error, urllib.parse

TOKEN = os.environ["TOKEN"]
OWNER = "hwl513782273"
REPO = "WorkBuddyUpdateBlocker"
API = "https://api.github.com"
BASE = f"{API}/repos/{OWNER}/{REPO}/contents"

ROOT = "/Users/banqiu/WorkBuddy/DMG/NoUpdateWB"
FILES = [
    "README.md", "LICENSE", "AppIcon.png", "AppIcon.icns", "Info.plist",
    "main.swift", "make_icon.py", ".gitignore",
    "build_v1.4.sh", "build_v1.5.sh", "build_v1.6.sh",
    "build_v1.7.sh", "build_v1.8.sh", "build_v1.8_release.sh",
]

def req(method, url, data=None, retries=3):
    last = None
    for i in range(retries):
        try:
            r = urllib.request.Request(url, data=data, method=method)
            r.add_header("Authorization", f"Bearer {TOKEN}")
            r.add_header("Accept", "application/vnd.github+json")
            r.add_header("User-Agent", "workbuddy-push")
            if data is not None:
                r.add_header("Content-Type", "application/json")
            with urllib.request.urlopen(r, timeout=60) as resp:
                return resp.read().decode("utf-8")
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as e:
            last = e
            time.sleep(2)
    raise last

def exists(path):
    try:
        req("GET", f"{BASE}/{urllib.parse.quote(path)}")
        return True
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False
        raise

for f in FILES:
    if exists(f):
        print(f"SKIP (exists) {f}")
        continue
    path = os.path.join(ROOT, f)
    if not os.path.isfile(path):
        print(f"SKIP (missing) {f}")
        continue
    with open(path, "rb") as fh:
        content = base64.b64encode(fh.read()).decode("ascii")
    body = json.dumps({
        "message": f"Add {f}",
        "content": content,
        "branch": "main",
    }).encode("utf-8")
    try:
        out = req("PUT", f"{BASE}/{urllib.parse.quote(f)}", body)
        d = json.loads(out)
        print(f"OK   {f}  ->  {d.get('content',{}).get('path')}")
    except Exception as e:
        print(f"ERR  {f}  {e}")
        sys.exit(1)

try:
    out = req("GET", f"{API}/repos/{OWNER}/{REPO}")
    d = json.loads(out)
    print("\nREPO:", d.get("full_name"), "default_branch:", d.get("default_branch"), "pushed_at:", d.get("pushed_at"))
except Exception as ex:
    print("verify err:", ex)
