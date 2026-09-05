#!/usr/bin/env python3
# 推送 v1.17 源码到 GitHub main 分支 + 创建 Release v1.17 并上传双架构 DMG
import os, sys, base64, json, time, urllib.request, urllib.error, urllib.parse

TOKEN = open("/tmp/gh_token.txt").read().strip()
OWNER = "hwl513782273"
REPO = "WorkBuddyUpdateBlocker"
API = "https://api.github.com"
BASE = f"{API}/repos/{OWNER}/{REPO}/contents"
ROOT = "/Users/banqiu/WorkBuddy/DMG/NoUpdateWB"

# 需要更新的源码文件（main.swift/Info.plist/README 已存在带 sha；build_v1.17_release.sh 新增）
SRC = ["main.swift", "Info.plist", "README.md", "build_v1.17_release.sh", "LICENSE", "AppIcon.png", "AppIcon.icns"]

ASSETS = [
    "11.0-WorkBuddyUpdateBlocker-1.17-arm64.dmg",
    "12.0-WorkBuddyUpdateBlocker-1.17-x86_64.dmg",
]

BODY = """## WorkBuddy 更新屏蔽器 v1.17

阻断 WorkBuddy（腾讯 Electron 版）强制自动更新的 macOS 原生工具。

### 本版本更新 / What's new (since v1.9)
- **窗口固定尺寸 + 自适应缩放**：锁定 720×840（左右分栏），不同分辨率屏幕自动等比缩放，无滚动条。
- **图标恢复**：修复此前图标丢失，已正确绑定 `AppIcon.icns`。
- **手动备份更新包**：点击后将下载目录里新的 `.zip` 备份到指定文件夹；与「禁止下载模式」互斥，并同步清理解压暂存 `extracted/`、用 1 秒浮窗提示「请重新开启屏蔽」。
- **手动清理下载缓存与解压暂存**：一键将 `downloads/`（下载缓存）与 `extracted/`（解压暂存）移入废纸篓（可恢复）。
- **底部空白优化**：状态/日志区为空时不占位，界面更紧凑。
- Intel 版（`12.0-...-x86_64.dmg`，macOS 12.0+）已在真机实测通过。

### 两种阻断模式（任选或组合）
- **更改域名模式**：在 `/etc/hosts` 中将更新包下载域名 `download.codebuddy.cn` 解析到 `0.0.0.0`，从源头阻断更新下载（不影响 AI / 核心功能）。
- **禁止下载模式**：将下载缓存 `downloads/` 与解压暂存 `extracted/` 权限设为 `000`，双重阻断下载与解压安装。

### 其它功能
一键启用/禁用屏蔽（管理员授权）、重启 WorkBuddy、检查更新下载目录、手动备份更新包、手动清理缓存。顶部实时显示两个模式各自的开启状态。

### 包体命名规则
`支持最低版本-软件名-版本-架构`：
- `11.0-WorkBuddyUpdateBlocker-1.17-arm64.dmg`（Apple Silicon，macOS 11.0+）
- `12.0-WorkBuddyUpdateBlocker-1.17-x86_64.dmg`（Intel，macOS 12.0+，实机测试通过）

> 发行版为 ad-hoc 签名、未公证，首次打开请右键「打开」放行 Gatekeeper。

详见仓库 README。"""

def req(method, url, data=None, binary=None, ctype=None, retries=4):
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
            code = getattr(e, "code", "?")
            print(f"  retry {i+1}: {method} {url} -> HTTP {code}")
            time.sleep(3)
    raise last

# 1. 推送源码
def get_sha(path):
    try:
        out = req("GET", f"{BASE}/{urllib.parse.quote(path)}")
        return json.loads(out).get("sha")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise

for f in SRC:
    path = os.path.join(ROOT, f)
    if not os.path.isfile(path):
        print(f"SKIP (missing) {f}")
        continue
    with open(path, "rb") as fh:
        content = base64.b64encode(fh.read()).decode("ascii")
    sha = get_sha(f)
    body = {"message": f"Update {f} for v1.17", "content": content, "branch": "main"}
    if sha:
        body["sha"] = sha
    data = json.dumps(body).encode("utf-8")
    try:
        out = req("PUT", f"{BASE}/{urllib.parse.quote(f)}", data)
        d = json.loads(out)
        print(f"OK   {f}  ({'sha='+sha[:7] if sha else 'NEW'})  ->  {d.get('content',{}).get('path')}")
    except Exception as e:
        print(f"ERR  {f}  {e}")
        sys.exit(1)

# 2. 创建 Release
payload = json.dumps({
    "tag_name": "v1.17",
    "name": "v1.17",
    "body": BODY,
    "target_commitish": "main",
    "draft": False,
    "prerelease": False,
}).encode("utf-8")
out = req("POST", f"{API}/repos/{OWNER}/{REPO}/releases", payload)
rel = json.loads(out)
rid = rel["id"]
print("\nRelease 创建:", rel.get("html_url"), "id=", rid)

# 3. 上传资产
for name in ASSETS:
    path = os.path.join(ROOT, name)
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

print("\nDONE. Release: https://github.com/%s/%s/releases/tag/v1.17" % (OWNER, REPO))
