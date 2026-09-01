#!/bin/zsh
# WorkBuddy 更新屏蔽器 v1.9 双架构构建脚本
#   arm64   -> 本机 /Applications/WorkBuddy更新屏蔽器.app  + 11.0-WorkBuddyUpdateBlocker-1.9-arm64.dmg
#   x86_64  -> /tmp/12.0-WorkBuddyUpdateBlocker-1.9-x86_64.dmg (随后由 ssh 装到远端 macOS12 Intel 机)
setopt nullglob 2>/dev/null || true

SRC="/Users/banqiu/WorkBuddy/DMG/NoUpdateWB"
DST="/Users/banqiu/Downloads/workbuddy 项目/workbuddy 屏蔽更新器"
PY=/Users/banqiu/.workbuddy/binaries/python/versions/3.13.12/bin/python3

cd "$SRC" || { echo "无法进入工程目录"; exit 1 }

# 0. 关掉本地可能运行的实例
pkill -f "WorkBuddy更新屏蔽器" 2>/dev/null
sleep 1

# ===== arm64 =====
APP_ARM="$SRC/WorkBuddy更新屏蔽器.app"
rm -rf "$APP_ARM"
mkdir -p "$APP_ARM/Contents/MacOS" "$APP_ARM/Contents/Resources"
cp Info.plist "$APP_ARM/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set LSMinimumSystemVersion 11.0' "$APP_ARM/Contents/Info.plist" 2>/dev/null
cp AppIcon.icns "$APP_ARM/Contents/Resources/AppIcon.icns" 2>/dev/null
echo "== 编译 arm64 v1.9 =="
swiftc -O -parse-as-library -framework SwiftUI -framework AppKit -framework Cocoa -framework Combine \
  main.swift -o "$APP_ARM/Contents/MacOS/WorkBuddy更新屏蔽器" 2> /tmp/wb_arm64.log
if [ $? -ne 0 ]; then echo "ARM COMPILE FAILED"; tail -30 /tmp/wb_arm64.log; exit 1; fi
xattr -cr "$APP_ARM"
codesign --force --deep --sign - "$APP_ARM" 2>&1 | tail -1

# ===== x86_64 (cross compile, min 12.0) =====
APP_X86="$SRC/WorkBuddy更新屏蔽器-intel.app"
rm -rf "$APP_X86"
mkdir -p "$APP_X86/Contents/MacOS" "$APP_X86/Contents/Resources"
cp Info.plist "$APP_X86/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set LSMinimumSystemVersion 12.0' "$APP_X86/Contents/Info.plist" 2>/dev/null
cp AppIcon.icns "$APP_X86/Contents/Resources/AppIcon.icns" 2>/dev/null
echo "== 编译 x86_64 v1.9 (min 12.0) =="
swiftc -O -parse-as-library -target x86_64-apple-macosx12.0 \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -framework SwiftUI -framework AppKit -framework Cocoa -framework Combine \
  main.swift -o "$APP_X86/Contents/MacOS/WorkBuddy更新屏蔽器" 2> /tmp/wb_x86_64.log
if [ $? -ne 0 ]; then echo "X86 COMPILE FAILED"; tail -30 /tmp/wb_x86_64.log; exit 1; fi
xattr -cr "$APP_X86"
codesign --force --deep --sign - "$APP_X86" 2>&1 | tail -1

# ===== 打包 DMG =====
rm -f "11.0-WorkBuddyUpdateBlocker-1.9-arm64.dmg"
hdiutil create -volname "WorkBuddy更新屏蔽器" -srcfolder "$APP_ARM" -ov -format UDZO "11.0-WorkBuddyUpdateBlocker-1.9-arm64.dmg" 2>&1 | tail -1
for v in /Volumes/WorkBuddy更新屏蔽器*; do [ -d "$v" ] && hdiutil detach "$v" -force 2>/dev/null; done

rm -f "12.0-WorkBuddyUpdateBlocker-1.9-x86_64.dmg"
hdiutil create -volname "WorkBuddy更新屏蔽器" -srcfolder "$APP_X86" -ov -format UDZO "12.0-WorkBuddyUpdateBlocker-1.9-x86_64.dmg" 2>&1 | tail -1
for v in /Volumes/WorkBuddy更新屏蔽器*; do [ -d "$v" ] && hdiutil detach "$v" -force 2>/dev/null; done

# ===== 安装 arm64 到本机 /Applications（旧版移废纸篓）=====
DEST_ARM="/Applications/WorkBuddy更新屏蔽器.app"
[ -d ~/.Trash/WorkBuddy更新屏蔽器.app ] && mv ~/.Trash/WorkBuddy更新屏蔽器.app ~/.Trash/WorkBuddy更新屏蔽器.old.$(date +%s).app
[ -d "$DEST_ARM" ] && mv "$DEST_ARM" ~/.Trash/
cp -R "$APP_ARM" /Applications/
xattr -dr com.apple.quarantine "$DEST_ARM"

# ===== 校验 =====
echo "== arm64 安装版本: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST_ARM/Contents/Info.plist") =="
echo "== arm64 签名: $(codesign --verify --verbose "$DEST_ARM" 2>&1 | tail -1) =="
lipo -info "$DEST_ARM/Contents/MacOS/WorkBuddy更新屏蔽器"
echo "== x86_64 二进制架构 =="
lipo -info "$APP_X86/Contents/MacOS/WorkBuddy更新屏蔽器"
echo "== 二进制关键词扫描 (arm64) =="
$PY - "$DEST_ARM/Contents/MacOS/WorkBuddy更新屏蔽器" <<'PY'
import sys
d=open(sys.argv[1],'rb').read().decode('utf-8','ignore')
for kw in ["更改域名模式","禁止下载模式","自动备份更新包","启用屏蔽","禁用屏蔽","download.codebuddy.cn","com.workbuddy.workbuddy.BundleMigration","trashItem","请打开 workbuddy 检测更新 查看效果"]:
    print(f"  [{kw}]: {d.count(kw)}")
PY

# ===== 交付（只增不删改：带 v1.9 版本号，v1.0~v1.8 全套保留）=====
mkdir -p "$DST"
cp "11.0-WorkBuddyUpdateBlocker-1.9-arm64.dmg" "$DST/"
cp "12.0-WorkBuddyUpdateBlocker-1.9-x86_64.dmg" "$DST/"
cp -R "$APP_ARM" "$DST/WorkBuddy更新屏蔽器_v1.9.app"
cp -R "$APP_X86" "$DST/WorkBuddy更新屏蔽器_v1.9-intel.app"
cp main.swift "$DST/main_v1.9.swift"
cp Info.plist "$DST/Info_v1.9.plist"
echo "== 交付完成 =="
ls -la "$DST" | grep -E "v1\.9"

# ===== arm64 冒烟（启动 3s 后关闭）=====
open "$DEST_ARM"
sleep 3
pgrep -fl "WorkBuddy更新屏蔽器" | head || echo "(无进程)"
pkill -f "WorkBuddy更新屏蔽器" 2>/dev/null
sleep 1
pgrep -fl "WorkBuddy更新屏蔽器" && echo "仍在运行" || echo "arm64 冒烟OK"
