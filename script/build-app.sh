#!/bin/bash
# 构建 BclmKeeper.app：SPM 编译菜单栏应用，组装 .app 并做 adhoc 签名。
# 产物统一放仓库 build/bin/（不入库，见 .gitignore）。用法：bash script/build-app.sh
set -eu

HERE=$(cd "$(/usr/bin/dirname "$0")/.." && /bin/pwd)
cd "$HERE/app"

echo "== swift build =="
/usr/bin/xcrun swift build -c release --disable-sandbox
BIN=$(/usr/bin/xcrun swift build -c release --show-bin-path)/BclmKeeper
[ -x "$BIN" ] || { echo "错误：没找到编译产物 $BIN" >&2; exit 1; }

APP="$HERE/build/bin/BclmKeeper.app"
/bin/rm -rf "$APP"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp "$BIN" "$APP/Contents/MacOS/BclmKeeper"
if [ -f "$HERE/app/Assets/AppIcon.icns" ]; then
    /bin/cp "$HERE/app/Assets/AppIcon.icns" "$APP/Contents/Resources/"
else
    echo "警告：app/Assets/AppIcon.icns 不存在（可先运行 script/make-icon.sh），应用将无图标" >&2
fi

/bin/cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.bclm-keeper.app</string>
	<key>CFBundleName</key>
	<string>BclmKeeper</string>
	<key>CFBundleExecutable</key>
	<string>BclmKeeper</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
EOF

echo "== codesign (adhoc) =="
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign -dv "$APP" 2>&1 | /usr/bin/grep -E 'Identifier|Signature|flags' || true
echo "构建完成：${APP}"
echo "安装（守护 + 应用，需 root）：sudo bash $(cd "$HERE" && /bin/pwd)/script/install.sh --user $(/usr/bin/stat -f '%Su' "$HERE")"
