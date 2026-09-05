#!/usr/bin/env python3
# 创建 GitHub Release v1.9 并上传两架构 DMG 资产
import os, json, time, urllib.request, urllib.error, urllib.parse

TOKEN = os.environ["TOKEN"]
OWNER = "hwl513782273"
REPO = "WorkBuddyUpdateBlocker"
API = "https://api.github.com"
ROOT = "/Users/banqiu/WorkBuddy/DMG/NoUpdateWB"

ASSETS = [
    ("11.0-WorkBuddyUpdateBlocker-1.9-arm64.dmg", "11.0-WorkBuddyUpdateBlocker-1.9-arm64.dmg"),
    ("12.0-WorkBuddyUpdateBlocker-1.9-x86_64.dmg", "12.0-WorkBuddyUpdateBlocker-1.9-x86_64.dmg"),
]

BODY = """## WorkBuddy 更新屏蔽器 v1.9

阻断 WorkBuddy（腾讯 Electron 版）强制自动更新的 macOS 原生工具。

### 本版本更新 / What's new
- **增加 macOS 12（Intel 芯片）支持**：新增 `12.0-WorkBuddyUpdateBlocker-1.9-x86_64.dmg`，**已在 Intel 真机实测通过**。
- Add **macOS 12 (Intel / x86_64) support**：new `12.0-WorkBuddyUpdateBlocker-1.9-x86_64.dmg`, **verified on a real Intel Mac**.

### 两种阻断模式（任选或组合）
- **更改域名模式**：在 `/etc/hosts` 中将更新包下载域名 `download.codebuddy.cn` 解析到 `0.0.0.0`，从源头阻断更新下载（不影响 AI / 核心功能）。
- **禁止下载模式**：将下载缓存 `downloads/` 与解压暂存 `extracted/` 权限设为 `000`，双重阻断下载与解压安装。

### 其它功能
一键启用/禁用屏蔽（管理员授权）、重启 WorkBuddy、检查更新下载目录、自动备份更新包到指定文件夹。顶部实时显示两个模式各自的开启状态。

### 包体命名规则
`支持最低版本-软件名-版本-架构`：
- `11.0-WorkBuddyUpdateBlocker-1.9-arm64.dmg`（Apple Silicon，macOS 11.0+）
- `12.0-WorkBuddyUpdateBlocker-1.9-x86_64.dmg`（Intel，macOS 12.0+，实机测试通过）

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
            with urllib.request.urlopen(r, timeout=180) as resp:
                return resp.read().decode("utf-8")
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as e:
            last = e
            time.sleep(2)
    raise last

# 1. 创建 Release
payload = json.dumps({
    "tag_name": "v1.9",
    "name": "v1.9",
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
for local, name in ASSETS:
    path = os.path.join(ROOT, local)
    if not os.path.isfile(path):
        print("ERR 资产缺失:", path)
        continue
    name_enc = urllib.parse.quote(name)
    with open(path, "rb") as fh:
        data = fh.read()
    upload_url = f"https://uploads.github.com/repos/{OWNER}/{REPO}/releases/{rid}/assets?name={name_enc}"
    out2 = req("POST", upload_url, binary=data, ctype="application/octet-stream")
    asset = json.loads(out2)
    print("Asset 上传:", asset.get("name"), "size=", asset.get("size"), "url=", asset.get("browser_download_url"))
