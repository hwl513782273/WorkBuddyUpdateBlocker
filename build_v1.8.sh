#!/bin/zsh
# WorkBuddy 更新屏蔽器 v1.8-beta 构建脚本（右栏「禁止下载模式」改为启用/禁用屏蔽按钮）
# 用法: zsh build_v1.8.sh
setopt nullglob 2>/dev/null || true

SRC="/Users/banqiu/WorkBuddy/DMG/NoUpdateWB"
APP="$SRC/WorkBuddy更新屏蔽器.app"
DST="/Users/banqiu/Downloads/workbuddy 项目/workbuddy 屏蔽更新器"
DEST="/Applications/WorkBuddy更新屏蔽器.app"

cd "$SRC" || { echo "无法进入工程目录"; exit 1 }

# 0. 先关掉本地可能运行的实例
pkill -f "$APP/Contents/MacOS/WorkBuddy更新屏蔽器" 2>/dev/null
sleep 1

# 1. 同步 Info.plist 进 .app 包
cp Info.plist "$APP/Contents/Info.plist"
echo "== 包内版本: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist") =="

# 2. 编译（用 $? 判断退出码，规避 zsh PIPESTATUS 差异）
echo "== 编译 v1.8-beta =="
swiftc -O -parse-as-library -framework SwiftUI -framework AppKit -framework Cocoa -framework Combine \
  main.swift -o "$APP/Contents/MacOS/WorkBuddy更新屏蔽器" 2> /tmp/wb_compile_v18.log
if [ $? -ne 0 ]; then
  echo "COMPILE FAILED"; tail -30 /tmp/wb_compile_v18.log; exit 1
fi

# 3. 签名 + 去隔离
xattr -cr "$APP"
codesign --force --deep --sign - "$APP" 2>&1 | tail -1

# 4. 打包 DMG
rm -f "WorkBuddy更新屏蔽器_v1.8-beta.dmg"
hdiutil create -volname "WorkBuddy更新屏蔽器" -srcfolder "$APP" -ov -format UDZO "WorkBuddy更新屏蔽器_v1.8-beta.dmg" 2>&1 | tail -2

# 5. 清理残留挂载卷
for v in /Volumes/WorkBuddy更新屏蔽器*; do [ -d "$v" ] && hdiutil detach "$v" -force 2>/dev/null; done

# 6. 安装到 /Applications（旧版移废纸篓，处理废纸篓同名避免嵌套）
[ -d ~/.Trash/WorkBuddy更新屏蔽器.app ] && mv ~/.Trash/WorkBuddy更新屏蔽器.app ~/.Trash/WorkBuddy更新屏蔽器.old.$(date +%s).app
[ -d "$DEST" ] && mv "$DEST" ~/.Trash/
cp -R "$APP" /Applications/
xattr -dr com.apple.quarantine "$DEST"

# 7. 校验
echo "== 安装版本: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/Contents/Info.plist") =="
echo "== 签名: $(codesign --verify --verbose "$DEST" 2>&1 | tail -1) =="
BIN="$DEST/Contents/MacOS/WorkBuddy更新屏蔽器"
echo "== 二进制 UTF-8 关键词扫描 =="
python3 - "$BIN" <<'PY'
import sys
data=open(sys.argv[1],'rb').read().decode('utf-8','ignore')
for kw in ["更改域名模式","禁止下载模式","自动备份更新包","启用屏蔽","禁用屏蔽","download.codebuddy.cn","com.workbuddy.workbuddy.BundleMigration","trashItem"]:
    print(f"  二进制含[{kw}]: {data.count(kw)}")
PY

# 8. 冒烟（启动后 3 秒关闭，并清理可能残留的实例）
open "$DEST"
sleep 3
pgrep -fl "WorkBuddy更新屏蔽器" | head || echo "(无进程)"
pkill -f "WorkBuddy更新屏蔽器" 2>/dev/null
sleep 1
pgrep -fl "WorkBuddy更新屏蔽器" && echo "仍在运行" || echo "冒烟OK"

# 9. 交付（只增不删改：v1.8 新文件名，v1.0~v1.7 全套保留）
mkdir -p "$DST"
cp "WorkBuddy更新屏蔽器_v1.8-beta.dmg" "$DST/"
cp -R "$APP" "$DST/WorkBuddy更新屏蔽器_v1.8-beta.app"
cp main.swift "$DST/main_v1.8.swift"
cp Info.plist "$DST/Info_v1.8.plist"
echo "== 交付完成 =="
ls -la "$DST" | grep -E "v1\.[0-8]"
