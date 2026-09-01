#!/bin/zsh
# WorkBuddy 更新屏蔽器 v1.4-beta 构建脚本
# 用法: zsh build_v1.4.sh
setopt nullglob 2>/dev/null || true

SRC="/Users/banqiu/WorkBuddy/DMG/NoUpdateWB"
APP="$SRC/WorkBuddy更新屏蔽器.app"
DST="/Users/banqiu/Downloads/workbuddy 项目/workbuddy 屏蔽更新器"
DEST="/Applications/WorkBuddy更新屏蔽器.app"

cd "$SRC" || { echo "无法进入工程目录"; exit 1; }

# 0. 先关掉本地可能运行的实例
pkill -f "$APP/Contents/MacOS/WorkBuddy更新屏蔽器" 2>/dev/null
sleep 1

# 1. 同步 Info.plist 进 .app 包
cp Info.plist "$APP/Contents/Info.plist"
echo "== 包内版本: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist") =="

# 2. 编译
echo "== 编译 v1.4-beta =="
swiftc -O -parse-as-library -framework SwiftUI -framework AppKit -framework Cocoa -framework Combine \
  main.swift -o "$APP/Contents/MacOS/WorkBuddy更新屏蔽器" 2>&1 | tail -30
[ ${PIPESTATUS[0]} -ne 0 ] && { echo "COMPILE FAILED"; exit 1; }

# 3. 签名 + 去隔离
xattr -cr "$APP"
codesign --force --deep --sign - "$APP" 2>&1 | tail -1

# 4. 打包 DMG
rm -f "WorkBuddy更新屏蔽器_v1.4-beta.dmg"
hdiutil create -volname "WorkBuddy更新屏蔽器" -srcfolder "$APP" -ov -format UDZO "WorkBuddy更新屏蔽器_v1.4-beta.dmg" 2>&1 | tail -2

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
for kw in "com.workbuddy.workbuddy.BundleMigration" "选择更新包备份目录" "自动备份更新包" "禁止下载缓存读写"; do
  echo "  二进制含[$kw]: $(strings "$BIN" | grep -c "$kw")"
done

# 8. 冒烟
open "$DEST"
sleep 3
pgrep -fl "WorkBuddy更新屏蔽器" | head || echo "(无进程)"
pkill -f "$APP/Contents/MacOS/WorkBuddy更新屏蔽器" 2>/dev/null
sleep 1
pgrep -fl "WorkBuddy更新屏蔽器" && echo "仍在运行" || echo "冒烟OK"

# 9. 交付（只增不删改：v1.4 新文件名，v1.0/1.1/1.2/1.3 保留）
mkdir -p "$DST"
cp "WorkBuddy更新屏蔽器_v1.4-beta.dmg" "$DST/"
cp -R "$APP" "$DST/WorkBuddy更新屏蔽器_v1.4-beta.app"
cp main.swift "$DST/main_v1.4.swift"
cp Info.plist "$DST/Info_v1.4.plist"
echo "== 交付完成 =="
ls -la "$DST" | grep -E "v1\.[0-4]"
