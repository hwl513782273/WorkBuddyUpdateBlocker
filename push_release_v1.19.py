#!/usr/bin/env python3
# 为 WorkBuddy 更新屏蔽器 v1.19 创建 GitHub Release 并上传双架构 DMG
# 用法：
#   GH_TOKEN=ghp_xxx python3 push_release_v1.19.py
#   或：echo ghp_xxx > /tmp/gh_token.txt && python3 push_release_v1.19.py
import os, sys, json, time, subprocess, urllib.request, urllib.error, urllib.parse

TOKEN = os.environ.get("GH_TOKEN", "").strip()
if not TOKEN and os.path.isfile("/tmp/gh_token.txt"):
    TOKEN = open("/tmp/gh_token.txt").read().strip()
if not TOKEN:
    print("缺少 token：请设置 GH_TOKEN 或写入 /tmp/gh_token.txt")
    sys.exit(1)

OWNER, REPO = "hwl513782273", "WorkBuddyUpdateBlocker"
API = "https://api.github.com"
TAG = "v1.19"
ROOT = os.path.dirname(os.path.abspath(__file__))

ASSETS = [
    os.path.join(ROOT, "11.0-WorkBuddyUpdateBlocker-1.19-arm64.dmg"),
    os.path.join(ROOT, "12.0-WorkBuddyUpdateBlocker-1.19-x86_64.dmg"),
]

BODY = """## WorkBuddy 更新屏蔽器 v1.19（正式版）

阻断 WorkBuddy（腾讯 Electron 版）强制自动更新的 macOS 原生工具。
本版把**方案优先级彻底重排**：目录锁 + 待装包清理成为首选，域名屏蔽 + 守护降为备用。

### ⭐ 首选：目录锁 + 待装包清理
- **首次安装也能生效**：从未更新过的机器上 `~/Library/Caches/<bundleid>.BundleMigration/{downloads,extracted}` 往往还不存在。现在点「启用目录锁」会**先自动创建缺失目录再 `chmod 000`**，修掉了旧版把权限打在空路径上、静默失效的问题。
- **锁定状态真实回读**：锁完用 `stat -f %A` 逐目录读回，两个目录都确实是 `000` 才亮绿灯；失败会明确显示 `downloads:失败 / extracted:失败`。
- **清理待装更新包更彻底**：`downloads/*`、`extracted/*`、`pending-update.json`、`install-in-progress.json`、`/Applications/.WorkBuddy.app.installing.*` 一并移入废纸篓（可恢复）；**目录处于锁定状态时会先临时解锁 → 清理 → 自动锁回**；检测到正在安装（`phase=installing` 且进程存活）时拒绝执行。
- **不需要改 `/etc/hosts`、不装守护、不影响技能市场等 CDN 资源**，随时一键解除。

### 🔧 备用：域名屏蔽 + 开机守护（移到右侧「备用」）
- `/etc/hosts` 屏蔽 `download.codebuddy.cn`（密码框授权），可选装 LaunchDaemon 每 5 分钟补回 hosts；「关闭守护并还原」一步清零。
- 只有当目录锁在你的机器上不奏效时再启用，副作用是同一 CDN 的技能市场图标等可能加载不出。

### 🖥 界面调整
- 左侧主推方案加「优先推荐」徽标 + 绿色卡片强调；右侧备用方案整体弱化（更小字号与按钮）。
- 状态栏顺序改为「目录锁 → 域名屏蔽 → 开机守护」，并新增一行锁定明细（如 `downloads/ 000 · extracted/ 000`）。
- **窗口高度收紧到 618pt、提示区常驻**，消除此前上下两大块空白；操作结果固定一行显示，界面不再跳动。

### 📦 包体
- `11.0-WorkBuddyUpdateBlocker-1.19-arm64.dmg` — Apple Silicon，macOS 11.0+
- `12.0-WorkBuddyUpdateBlocker-1.19-x86_64.dmg` — Intel，macOS 12.0+

> ad-hoc 签名、未公证，首次打开请右键「打开」放行 Gatekeeper。

详见仓库 README。"""


def req(method, url, data=None, binary=None, ctype=None, retries=4):
    last = None
    for i in range(retries):
        try:
            r = urllib.request.Request(url, data=data, method=method)
            r.add_header("Authorization", "Bearer " + TOKEN)
            r.add_header("Accept", "application/vnd.github+json")
            r.add_header("User-Agent", "workbuddy-release")
            if data is not None:
                r.add_header("Content-Type", "application/json")
            if binary is not None:
                r.add_header("Content-Type", ctype or "application/octet-stream")
            with urllib.request.urlopen(r, timeout=300) as resp:
                return resp.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")[:300]
            print("  HTTP %s %s %s\n  %s" % (e.code, method, url, body))
            if e.code in (401, 403, 404, 422):
                raise
            last = e
            time.sleep(3)
        except (urllib.error.URLError, TimeoutError) as e:
            last = e
            time.sleep(3)
    raise last


# 1) 若已存在同 tag 的 release，复用；否则创建
existing = None
try:
    rels = json.loads(req("GET", "%s/repos/%s/%s/releases?per_page=30" % (API, OWNER, REPO)))
    for r in rels:
        if r.get("tag_name") == TAG:
            existing = r
            break
except Exception as e:
    print("读取已有 release 失败：", e)
    sys.exit(1)

if existing:
    rid = existing["id"]
    print("复用已有 release:", existing.get("html_url"), "id=", rid)
    have = {a["name"] for a in existing.get("assets", [])}
else:
    payload = json.dumps({
        "tag_name": TAG,
        "name": "v1.19 正式版 · 目录锁 + 待装包清理成首选",
        "body": BODY,
        "target_commitish": "main",
        "draft": False,
        "prerelease": False,
    }).encode("utf-8")
    rel = json.loads(req("POST", "%s/repos/%s/%s/releases" % (API, OWNER, REPO), payload))
    rid = rel["id"]
    have = set()
    print("Release 创建:", rel.get("html_url"), "id=", rid)

# 2) 上传资产（用 curl --data-binary：urllib 直传会被 GitHub 判成 size=0 而 422）
def upload(path, name, rid):
    url = "https://uploads.github.com/repos/%s/%s/releases/%d/assets?name=%s" % (
        OWNER, REPO, rid, urllib.parse.quote(name))
    out = subprocess.run([
        "/usr/bin/curl", "-s", "-X", "POST", "--data-binary", "@" + path,
        "-H", "Authorization: Bearer " + TOKEN,
        "-H", "Content-Type: application/x-apple-diskimage",
        "-H", "Accept: application/vnd.github+json",
        url,
    ], capture_output=True, text=True, timeout=600)
    if out.returncode != 0:
        raise RuntimeError("curl 失败 rc=%s %s" % (out.returncode, out.stderr[:200]))
    d = json.loads(out.stdout)
    if "id" not in d:
        raise RuntimeError("上传被拒: %s" % out.stdout[:300])
    return d


for path in ASSETS:
    name = os.path.basename(path)
    if name in have:
        print("已存在，跳过:", name)
        continue
    if not os.path.isfile(path):
        print("资产缺失:", path)
        continue
    asset = upload(path, name, rid)
    print("上传完成:", asset.get("name"), asset.get("size"), asset.get("browser_download_url"))

print("\nDONE → https://github.com/%s/%s/releases/tag/%s" % (OWNER, REPO, TAG))
