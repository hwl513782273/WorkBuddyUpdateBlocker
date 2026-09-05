#!/usr/bin/env python3
import os, sys, json, time, urllib.request, urllib.error, urllib.parse

TOKEN = os.environ["TOKEN"]
OWNER = "hwl513782273"
REPO = "WorkBuddyUpdateBlocker"
API = "https://api.github.com"
ASSET_LOCAL = "/tmp/11.0-WorkBuddy更新屏蔽器-1.8-arm64.dmg"
ASSET_NAME = "11.0-WorkBuddy更新屏蔽器-1.8-arm64.dmg"

BODY = """## WorkBuddy 更新屏蔽器 v1.8

阻断 WorkBuddy（腾讯 Electron 版）强制自动更新的 macOS 原生工具。

**两种阻断模式（任选或组合）**
- **更改域名模式**：在 `/etc/hosts` 中将更新包下载域名 `download.codebuddy.cn` 解析到 `0.0.0.0`，从源头阻断更新下载（不影响 AI / 核心功能）。
- **禁止下载模式**：将下载缓存 `downloads/` 与解压暂存 `extracted/` 权限设为 `000`，双重阻断下载与解压安装。

**其它功能**：一键启用/禁用屏蔽（管理员授权）、重启 WorkBuddy、检查更新下载目录、自动备份更新包到指定文件夹。

**包体命名规则**：`支持最低版本-软件名-版本-架构`（本包 = macOS 11.0+ / arm64）。
> 发行版为 ad-hoc 签名、未公证，首次打开请右键「打开」放行 Gatekeeper。

详见仓库 README。"""

def req(method, url, data=None, binary=None, ctype=None, retries=3):
    last = None
    for i in range(retries):
        try:
            r = urllib.request.Request(url, data=data, method=method)
            r.add_header("Authorization", f"Bearer {TOKEN}")
            r.add_header("Accept", "application/vnd.github+json")
            r.add_header("User-Agent", "workbuddy-release")
            if data is not None:
                r.add_header("Content-Type", "application/json")
            if binary is not None:
                r.add_header("Content-Type", ctype or "application/octet-stream")
            with urllib.request.urlopen(r, timeout=120) as resp:
                return resp.read().decode("utf-8")
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as e:
            last = e
            time.sleep(2)
    raise last

# 1. 创建 Release
payload = json.dumps({
    "tag_name": "v1.8",
    "name": "v1.8",
    "body": BODY,
    "target_commitish": "main",
    "draft": False,
    "prerelease": False,
}).encode("utf-8")
out = req("POST", f"{API}/repos/{OWNER}/{REPO}/releases", payload)
rel = json.loads(out)
rid = rel["id"]
print("Release 创建:", rel.get("html_url"), "id=", rid)

# 2. 上传资产
name_enc = urllib.parse.quote(ASSET_NAME)
with open(ASSET_LOCAL, "rb") as fh:
    data = fh.read()
upload_url = f"https://uploads.github.com/repos/{OWNER}/{REPO}/releases/{rid}/assets?name={name_enc}"
out2 = req("POST", upload_url, binary=data, ctype="application/octet-stream")
asset = json.loads(out2)
print("Asset 上传:", asset.get("name"), "size=", asset.get("size"), "url=", asset.get("browser_download_url"))
