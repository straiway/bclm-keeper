#!/bin/bash
# 生成 AppIcon.icns：Swift/CoreGraphics 画 1024 底图 → sips 出全部尺寸 → iconutil 组装。
# 产物 app/Assets/AppIcon.icns（入库；script/build-app.sh 构建时拷进 .app）。用法：
#     bash script/make-icon.sh
set -eu

HERE=$(cd "$(/usr/bin/dirname "$0")/.." && /bin/pwd)
T="$HERE/tmp"
ICONSET="$T/AppIcon.iconset"

/bin/mkdir -p "$T" "$ICONSET" "$HERE/app/Assets"
/usr/bin/xcrun swift "$HERE/script/make-icon.swift" "$T/icon-1024.png"
for f in "$ICONSET"/*; do [ -e "$f" ] && /bin/rm -f "$f"; done

size() {  # $1 = 文件名 $2 = 边长（px）
    /usr/bin/sips -z "$2" "$2" "$T/icon-1024.png" --out "$ICONSET/$1" >/dev/null
}
size icon_16x16.png 16
size icon_16x16@2x.png 32
size icon_32x32.png 32
size icon_32x32@2x.png 64
size icon_128x128.png 128
size icon_128x128@2x.png 256
size icon_256x256.png 256
size icon_256x256@2x.png 512
size icon_512x512.png 512
size icon_512x512@2x.png 1024

/usr/bin/iconutil -c icns "$ICONSET" -o "$HERE/app/Assets/AppIcon.icns"
/usr/bin/file "$HERE/app/Assets/AppIcon.icns"
echo "生成完成：app/Assets/AppIcon.icns"
