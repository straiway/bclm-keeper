#!/bin/bash
# 构建 BclmKeeper 一键安装包（pkg）。
# 产物：build/bin/BclmKeeper-<版本>.pkg
#
# 包内容（payload 安装到 /）：
#   /Applications/BclmKeeper.app                    菜单栏应用
#   /usr/local/bin/bclm-keeper                      CLI
#   /usr/local/bin/bclm                             zackelia/bclm（MIT，依赖）
#   /Library/PrivilegedHelperTools/bclm-keeper      root 守护脚本
#   /Library/PrivilegedHelperTools/bclm             root 属主的 bclm 副本
#   /Library/LaunchDaemons/*.plist.template         LaunchDaemon 模板（postinstall 按
#                                                   当前用户状态目录实例化并装载）
#   /usr/local/share/doc/bclm-keeper/LICENSE.bclm   bclm 的 MIT 许可证文本
#
# postinstall（root 执行）：迁移旧启动项、实例化并装载 LaunchDaemon、把 CLI/应用
# 属主改为当前登录用户、立即运行一次守护、打开应用。
#
# 用法：bash script/make-pkg.sh [--skip-app-build]
set -eu

HERE=$(cd "$(/usr/bin/dirname "$0")/.." && /bin/pwd)
cd "$HERE"
BUILD=$HERE/build
STAGE=$BUILD/pkgroot
SCRIPTS=$HERE/script/pkg-scripts
LABEL=com.bclm-keeper.daemon
VER=$(/usr/bin/grep -A1 CFBundleShortVersionString script/build-app.sh | /usr/bin/tail -1 | /usr/bin/sed 's/[^0-9.]//g')
[ -n "$VER" ] || { echo "无法从 build-app.sh 读出版本号" >&2; exit 1; }

# 1. 构建菜单栏应用（build/bin/BclmKeeper.app）
if [ "${1:-}" != "--skip-app-build" ] || [ ! -d "$BUILD/bin/BclmKeeper.app" ]; then
    bash "$HERE/script/build-app.sh"
fi
[ -d "$BUILD/bin/BclmKeeper.app" ] || { echo "应用未构建：$BUILD/bin/BclmKeeper.app" >&2; exit 1; }

# 2. 构建 bclm（zackelia/bclm，MIT；源码缓存于 build/third-party/bclm-src）
BCLM_SRC_DIR=$BUILD/third-party/bclm-src
if [ ! -x "$BCLM_SRC_DIR/.build/release/bclm" ]; then
    /bin/rm -rf "$BCLM_SRC_DIR"
    /usr/bin/git clone --depth 1 https://github.com/zackelia/bclm.git "$BCLM_SRC_DIR"
    (cd "$BCLM_SRC_DIR" && /usr/bin/swift build -c release)
fi
BCLM_COMMIT=$(cd "$BCLM_SRC_DIR" && /usr/bin/git rev-parse HEAD)
echo "bclm 源码：zackelia/bclm @ $BCLM_COMMIT"
echo "bclm sha256：$(/usr/bin/shasum -a 256 "$BCLM_SRC_DIR/.build/release/bclm" | /usr/bin/awk '{print $1}')"

# 3. 组装 payload（属主在 chown 步骤统一修正）
/bin/rm -rf "$STAGE"
/bin/mkdir -p "$STAGE/Applications" \
             "$STAGE/usr/local/bin" \
             "$STAGE/usr/local/share/doc/bclm-keeper" \
             "$STAGE/Library/PrivilegedHelperTools" \
             "$STAGE/Library/LaunchDaemons"
/bin/cp -R "$BUILD/bin/BclmKeeper.app" "$STAGE/Applications/BclmKeeper.app"
/bin/cp "$HERE/cli/bclm-keeper" "$STAGE/usr/local/bin/bclm-keeper"
/bin/cp "$BCLM_SRC_DIR/.build/release/bclm" "$STAGE/usr/local/bin/bclm"
/bin/cp "$BCLM_SRC_DIR/.build/release/bclm" "$STAGE/Library/PrivilegedHelperTools/bclm"
/bin/cp "$HERE/daemon/keeper.sh" "$STAGE/Library/PrivilegedHelperTools/bclm-keeper"
/bin/cp "$HERE/daemon/$LABEL.plist" "$STAGE/Library/PrivilegedHelperTools/$LABEL.plist.template"
/bin/cp "$BCLM_SRC_DIR/LICENSE" "$STAGE/usr/local/share/doc/bclm-keeper/LICENSE.bclm" 2>/dev/null ||
    /bin/cp "$BCLM_SRC_DIR/LICENSE.md" "$STAGE/usr/local/share/doc/bclm-keeper/LICENSE.bclm.md" 2>/dev/null || true

# root 属主（PrivilegedHelperTools/LaunchDaemon 必须 root:wheel；此步需要 sudo）
sudo /usr/sbin/chown -R root:wheel "$STAGE/Library"
sudo /usr/bin/find "$STAGE/Library" -type d -exec /bin/chmod 0755 {} +
sudo /usr/bin/find "$STAGE/Library" -type f -exec /bin/chmod 0644 {} +
sudo /bin/chmod 0755 "$STAGE/Library/PrivilegedHelperTools/bclm" \
                "$STAGE/Library/PrivilegedHelperTools/bclm-keeper"
sudo /usr/sbin/chown -R root:wheel "$STAGE/usr"
sudo /bin/chmod 0755 "$STAGE/usr/local/bin/bclm" "$STAGE/usr/local/bin/bclm-keeper"
sudo /usr/sbin/chown -R root:admin "$STAGE/Applications"

# 4. pkgbuild
[ -x "$SCRIPTS/postinstall" ] || { echo "缺少 $SCRIPTS/postinstall" >&2; exit 1; }
/bin/mkdir -p "$BUILD/bin"
OUT="$BUILD/bin/BclmKeeper-$VER.pkg"
/usr/bin/pkgbuild --root "$STAGE" --scripts "$SCRIPTS" \
    --identifier com.bclm-keeper.pkg --version "$VER" \
    --install-location / --ownership recommended \
    "$OUT"
echo "构建完成：$OUT"
echo "安装测试：sudo installer -pkg $OUT -target /"
