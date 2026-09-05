#!/bin/zsh
# WorkBuddy 更新屏蔽器 - v1.17 构建（双架构 + 安装 + 交付）
# 说明：在 v1.15-beta 窗口（720×840 左右分栏 + 图标恢复）基础上，「仅」修底部空白。
# ①窗口恢复 v1.15 尺寸 720×840（左右分栏，不是 v1.16 的 372×784 窄窗）
# ②优化底部空白：message/checkResult 改为「空时不显示」，删掉原来两个固定高度占位 Spacer
# ③图标保持恢复状态（CFBundleIconFile + 复制 AppIcon.icns）
set -e
cd "$(dirname "$0")"

VER="1.17"
MIN_MAC_ARM="11.0"
MIN_MAC_X64="12.0"

# 关键词（v1.17 全部需要命中）
declare -a KW=(
  "WorkBuddy 更新屏蔽器"
  "请打开 workbuddy 检测更新 查看效果"
  "手动备份更新包"
  "手动清理下载缓存与解压暂存"
  "请重新开启屏蔽"
  "清理解压暂存"
  "已清理 downloads/"
)

# ====== ARM64（本机） ======
APP_ARM="WorkBuddy更新屏蔽器.app"
rm -rf "$APP_ARM"
mkdir -p "$APP_ARM/Contents/MacOS" "$APP_ARM/Contents/Resources"
cat > "$APP_ARM/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WorkBuddy 更新屏蔽器</string>
    <key>CFBundleDisplayName</key><string>WorkBuddy 更新屏蔽器</string>
    <key>CFBundleExecutable</key><string>WorkBuddy更新屏蔽器</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key><string>com.banqiu.wbupdateblocker</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VER</string>
    <key>CFBundleVersion</key><string>$VER</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MAC_ARM</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
if [ -f AppIcon.icns ]; then cp -f AppIcon.icns "$APP_ARM/Contents/Resources/"; fi

swiftc -O -parse-as-library \
  -framework SwiftUI -framework AppKit -framework Cocoa -framework Combine \
  main.swift -o "$APP_ARM/Contents/MacOS/WorkBuddy更新屏蔽器"

echo "✅ ARM64 编译 OK"

# ====== X86_64（交叉编译，min 12.0） ======
APP_X64="WorkBuddy更新屏蔽器-intel.app"
rm -rf "$APP_X64"
mkdir -p "$APP_X64/Contents/MacOS" "$APP_X64/Contents/Resources"
cat > "$APP_X64/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WorkBuddy 更新屏蔽器</string>
    <key>CFBundleDisplayName</key><string>WorkBuddy 更新屏蔽器</string>
    <key>CFBundleExecutable</key><string>WorkBuddy更新屏蔽器</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key><string>com.banqiu.wbupdateblocker</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VER</string>
    <key>CFBundleVersion</key><string>$VER</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MAC_X64</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
if [ -f AppIcon.icns ]; then cp -f AppIcon.icns "$APP_X64/Contents/Resources/"; fi

swiftc -O -parse-as-library \
  -target x86_64-apple-macosx12.0 \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -framework SwiftUI -framework AppKit -framework Cocoa -framework Combine \
  main.swift -o "$APP_X64/Contents/MacOS/WorkBuddy更新屏蔽器"

echo "✅ X86_64 交叉编译 OK"

# ====== 签名 ======
codesign --force --deep --sign - "$APP_ARM"
codesign --force --deep --sign - "$APP_X64"

# ====== 验证 ======
echo "--- 验证 ---"
codesign -dvv "$APP_ARM" 2>&1 | grep -E "Identifier|Format|Satisfies" | head -5
codesign -dvv "$APP_X64" 2>&1 | grep -E "Identifier|Format|Satisfies" | head -5
echo "ARM64 架构：$(file "$APP_ARM/Contents/MacOS/WorkBuddy更新屏蔽器" | grep -oE 'arm64|x86_64')"
echo "X86_64 架构：$(file "$APP_X64/Contents/MacOS/WorkBuddy更新屏蔽器" | grep -oE 'arm64|x86_64')"
BIN="$APP_ARM/Contents/MacOS/WorkBuddy更新屏蔽器"
python3 - "$BIN" <<'PY'
import sys
data=open(sys.argv[1],"rb").read()
kws=["请打开 workbuddy 检测更新 查看效果","手动备份更新包","手动清理下载缓存与解压暂存",
     "请重新开启屏蔽","清理解压暂存","已清理 downloads/","WorkBuddy 更新屏蔽器"]
for k in kws:
    print(f"  [arm64] 关键词 [{k}] × {data.count(k.encode('utf-8'))}")
PY
# 图标校验
echo "ARM64 图标文件：$(ls -la "$APP_ARM/Contents/Resources/AppIcon.icns" 2>/dev/null | awk '{print $5" bytes"}' || echo MISSING)"
python3 - "$APP_ARM" <<'PY'
import subprocess,sys,os
p=sys.argv[1]
pl=os.path.join(p,"Contents/Info.plist")
print("CFBundleIconFile:", subprocess.run(["/usr/libexec/PlistBuddy","-c","Print :CFBundleIconFile",pl],capture_output=True,text=True).stdout.strip() or "MISSING")
PY

# ====== 打包 DMG ======
DMG_ARM="11.0-WorkBuddyUpdateBlocker-${VER}-arm64.dmg"
DMG_X64="12.0-WorkBuddyUpdateBlocker-${VER}-x86_64.dmg"
hdiutil create -volname "WorkBuddy 更新屏蔽器" -srcfolder "$APP_ARM" -ov -format UDZO "$DMG_ARM" >/dev/null
hdiutil create -volname "WorkBuddy 更新屏蔽器" -srcfolder "$APP_X64" -ov -format UDZO "$DMG_X64" >/dev/null
echo "✅ DMG 已生成：$DMG_ARM / $DMG_X64"

# ====== 装本机 arm64 ======
if [ -d "/Applications/$APP_ARM" ]; then
  mv -f "/Applications/$APP_ARM" "$HOME/.Trash/$APP_ARM-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
fi
cp -R "$APP_ARM" "/Applications/$APP_ARM"
xattr -dr com.apple.quarantine "/Applications/$APP_ARM" 2>/dev/null || true
echo "✅ 已装本机：/Applications/$APP_ARM"

# ====== 冒烟测试 ======
"/Applications/$APP_ARM/Contents/MacOS/WorkBuddy更新屏蔽器" >/dev/null 2>&1 &
APP_PID=$!
sleep 2
if kill -0 $APP_PID 2>/dev/null; then
  echo "✅ 冒烟启动 OK（PID=$APP_PID）"
  kill $APP_PID 2>/dev/null || true
  wait $APP_PID 2>/dev/null || true
else
  echo "⚠️  冒烟启动失败"
fi

# ====== 复制到交付目录（按"只增不删改"规则保留历史） ======
DEST="/Users/banqiu/Downloads/workbuddy 项目/workbuddy 屏蔽更新器"
mkdir -p "$DEST"
cp -f "$DMG_ARM" "$DEST/" && cp -f "$DMG_X64" "$DEST/"
cp -R "$APP_ARM" "$DEST/"
cp -R "$APP_X64" "$DEST/"
cp -f main.swift "$DEST/main_v1.17.swift"
cp -f Info.plist "$DEST/Info_v1.17.plist"
cp -f build_v1.17_release.sh "$DEST/build_v1.17_release.sh"
echo "✅ 已复制到交付目录：$DEST"

echo ""
echo "=========================================="
echo "  v1.17 双架构构建完成"
echo "  - 窗口固定尺寸 + 自适应缩放（无滚动条）"
echo "  - 图标恢复（CFBundleIconFile + 复制 icns）"
echo "  - 装本机：/Applications/$APP_ARM"
echo "  - DMG：$DMG_ARM / $DMG_X64"
echo "=========================================="
