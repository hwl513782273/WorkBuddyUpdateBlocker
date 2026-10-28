#!/bin/zsh
# WorkBuddy 更新屏蔽器 v1.19 正式版 构建
# 主题：方案优先级重排（目录锁 + 待装包清理为首选，域名屏蔽 + 守护降为备用）
# ①首次安装（缓存目录不存在）时先创建目录再上锁 ②锁定状态按真实权限回读校验
# ③清理待装包时自动临时解锁 → 清理 → 自动锁回 ④UI 主次分明：左主推、右备用
set -e
cd "$(dirname "$0")"

VER="1.19"
MIN_MAC_ARM="11.0"
MIN_MAC_X64="12.0"
STAGE=$(mktemp -d /tmp/wbbuild.XXXXXX)
APP_NAME="WorkBuddy更新屏蔽器"

make_app() {
  local APP="$1" MIN="$2"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WorkBuddy 更新屏蔽器</string>
    <key>CFBundleDisplayName</key><string>WorkBuddy 更新屏蔽器</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key><string>com.banqiu.wbupdateblocker</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VER</string>
    <key>CFBundleVersion</key><string>$VER</string>
    <key>LSMinimumSystemVersion</key><string>$MIN</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
  [ -f AppIcon.icns ] && cp -f AppIcon.icns "$APP/Contents/Resources/"
}

# ====== ARM64 ======
APP_ARM="$STAGE/$APP_NAME.app"
make_app "$APP_ARM" "$MIN_MAC_ARM"
swiftc -O -parse-as-library \
  -framework SwiftUI -framework AppKit -framework Cocoa -framework Combine \
  main_v1.19.swift -o "$APP_ARM/Contents/MacOS/$APP_NAME"
echo "✅ ARM64 编译 OK"

# ====== X86_64 ======
APP_X64="$STAGE/$APP_NAME-intel.app"
make_app "$APP_X64" "$MIN_MAC_X64"
swiftc -O -parse-as-library -target x86_64-apple-macosx12.0 \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -framework SwiftUI -framework AppKit -framework Cocoa -framework Combine \
  main_v1.19.swift -o "$APP_X64/Contents/MacOS/$APP_NAME"
echo "✅ X86_64 编译 OK"

# ====== ad-hoc 签名 ======
codesign --force --deep --sign - "$APP_ARM"
codesign --force --deep --sign - "$APP_X64"
codesign -v "$APP_ARM" && echo "✅ ARM64 签名 OK"
codesign -v "$APP_X64" && echo "✅ X86_64 签名 OK"

echo "$STAGE" > /tmp/wbbuild_stage_path.txt

# ====== DMG ======
DMG_ARM="11.0-WorkBuddyUpdateBlocker-${VER}-arm64.dmg"
DMG_X64="12.0-WorkBuddyUpdateBlocker-${VER}-x86_64.dmg"
hdiutil create -volname "WorkBuddy 更新屏蔽器" -srcfolder "$APP_ARM" -format UDZO "$DMG_ARM" >/dev/null
hdiutil create -volname "WorkBuddy 更新屏蔽器" -srcfolder "$APP_X64" -format UDZO "$DMG_X64" >/dev/null
echo "✅ DMG 已生成：$DMG_ARM / $DMG_X64"

# ====== 装本机（旧版先移废纸篓，不 rm）======
if [ -d "/Applications/$APP_NAME.app" ]; then
  mv "/Applications/$APP_NAME.app" "$HOME/.Trash/$APP_NAME-$(date +%Y%m%d-%H%M%S).app" || true
fi
cp -R "$APP_ARM" "/Applications/$APP_NAME.app"
xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app" 2>/dev/null || true
echo "✅ 已装本机：/Applications/$APP_NAME.app"

# ====== 交付目录（additive）======
DEST="/Users/banqiu/Downloads/workbuddy 项目/实用工具/workbuddy 屏蔽更新器"
mkdir -p "$DEST"
cp -f "$DMG_ARM" "$DEST/" 2>/dev/null || true
cp -f "$DMG_X64" "$DEST/" 2>/dev/null || true
cp -f main_v1.19.swift "$DEST/main_v1.19.swift" 2>/dev/null || true
cp -f build_v1.19.sh "$DEST/build_v1.19.sh" 2>/dev/null || true
mkdir -p "$DEST/产物"
cp -f "$DMG_ARM" "$DEST/产物/" 2>/dev/null || true
cp -f "$DMG_X64" "$DEST/产物/" 2>/dev/null || true

# 工作区 DMG（additive-only）
mkdir -p "/Users/banqiu/WorkBuddy/DMG"
cp -f "$DMG_ARM" "/Users/banqiu/WorkBuddy/DMG/" 2>/dev/null || true
cp -f "$DMG_X64" "/Users/banqiu/WorkBuddy/DMG/" 2>/dev/null || true

echo "STAGE=$STAGE"
echo "✅ v1.19 正式版 构建完成"
