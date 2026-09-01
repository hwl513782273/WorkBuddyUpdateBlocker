#!/bin/zsh
# WorkBuddy 更新屏蔽器 v1.8 Intel(x86_64) 构建脚本
# 目标: 支持 macOS 12+ 的 Intel 芯片 Mac
# 命名约定: 支持最低版本-软件名-版本-架构  => 12.0-WorkBuddyUpdateBlocker-1.8-x86_64.dmg
setopt nullglob 2>/dev/null || true

SRC="/Users/banqiu/WorkBuddy/DMG/NoUpdateWB"
STAGE="$SRC/WorkBuddy更新屏蔽器-intel.app"      # 暂存 app（不与 arm64 版冲突）
DST="/Users/banqiu/Downloads/workbuddy 项目/workbuddy 屏蔽更新器"
DEST="/Applications/WorkBuddy更新屏蔽器-intel.app"
MINVER="12.0"
ARCH="x86_64"

cd "$SRC" || { echo "无法进入工程目录"; exit 1 }

# 0. 关掉本地可能运行的实例
pkill -f "$STAGE/Contents/MacOS/WorkBuddy更新屏蔽器" 2>/dev/null
sleep 1

# 1. 准备 .app 骨架
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp Info.plist "$STAGE/Contents/Info.plist"
# Intel 包最低支持 macOS 12.0
/usr/libexec/PlistBuddy -c "Set LSMinimumSystemVersion $MINVER" "$STAGE/Contents/Info.plist"
# 保证 bundle id / 版本一致（与 arm64 同 id，便于同一台机器并存可改名）
/usr/libexec/PlistBuddy -c "Set CFBundleName WorkBuddy更新屏蔽器(Intel)" "$STAGE/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add CFBundleName string WorkBuddy更新屏蔽器(Intel)" "$STAGE/Contents/Info.plist"
cp AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
echo "== Intel 包 min version: $(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$STAGE/Contents/Info.plist") =="

# 2. 编译 x86_64（macOS $MINVER 起），rpath 指向自身 Frameworks 以防万一
echo "== 编译 x86_64 (min $MINVER) =="
swiftc -O -parse-as-library -target $ARCH-apple-macosx$MINVER \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -framework SwiftUI -framework AppKit -framework Cocoa -framework Combine \
  main.swift -o "$STAGE/Contents/MacOS/WorkBuddy更新屏蔽器" 2> /tmp/wb_intel.log
if [ ! -f "$STAGE/Contents/MacOS/WorkBuddy更新屏蔽器" ]; then
  echo "❌ 编译失败"; tail -30 /tmp/wb_intel.log; exit 1
fi
echo "✅ 编译 OK: $(lipo -info "$STAGE/Contents/MacOS/WorkBuddy更新屏蔽器")"

# 3. 设置图标并签名
/usr/libexec/PlistBuddy -c "Set CFBundleIconFile AppIcon" "$STAGE/Contents/Info.plist" 2>/dev/null
xattr -cr "$STAGE"
codesign --force --deep --sign - "$STAGE" 2>&1 | tail -1

# 4. 打包 DMG（按命名约定）
DMG="12.0-WorkBuddyUpdateBlocker-1.8-x86_64.dmg"
rm -f "$DMG"
hdiutil create -volname "WorkBuddy更新屏蔽器" -srcfolder "$STAGE" -ov -format UDZO "$DMG" 2>&1 | tail -2
for v in /Volumes/WorkBuddy更新屏蔽器*; do [ -d "$v" ] && hdiutil detach "$v" -force 2>/dev/null; done

# 5. 校验
echo "== 签名: $(codesign --verify --verbose "$STAGE" 2>&1 | tail -1) =="
BIN="$STAGE/Contents/MacOS/WorkBuddy更新屏蔽器"
echo "== 架构: $(lipo -info "$BIN") =="
echo "== 二进制关键词扫描 =="
/Users/banqiu/.workbuddy/binaries/python/versions/3.13.12/bin/python3 - "$BIN" <<'PY'
import sys
d=open(sys.argv[1],'rb').read().decode('utf-8','ignore')
for kw in ["更改域名模式","禁止下载模式","自动备份更新包","启用屏蔽","禁用屏蔽","download.codebuddy.cn","com.workbuddy.workbuddy.BundleMigration","trashItem"]:
    print(f"  [{kw}]: {d.count(kw)}")
PY

# 6. 安装到 /Applications（Intel 包，旧版移废纸篓，处理废纸篓同名）
[ -d ~/.Trash/WorkBuddy更新屏蔽器-intel.app ] && mv ~/.Trash/WorkBuddy更新屏蔽器-intel.app ~/.Trash/WorkBuddy更新屏蔽器-intel.old.$(date +%s).app
[ -d "$DEST" ] && mv "$DEST" ~/.Trash/
cp -R "$STAGE" /Applications/
xattr -dr com.apple.quarantine "$DEST"
echo "== 已安装: $DEST =="

# 7. 交付（只增不删改：Intel 用独立后缀，不覆盖现有 v1.8 文件）
mkdir -p "$DST"
cp "$DMG" "$DST/"
cp -R "$STAGE" "$DST/WorkBuddy更新屏蔽器_v1.8-intel.app"
cp main.swift "$DST/main_v1.8_intel.swift"
cp Info.plist "$DST/Info_v1.8_intel.plist"
echo "== 交付完成 =="
ls -la "$DST" | grep -iE "intel|v1\.8"

echo "DMG_LOCAL_PATH=$SRC/$DMG"