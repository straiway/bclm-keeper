#!/bin/bash
# 安装 BclmKeeper（充电上限守护 + 菜单栏应用）。必须以 root 运行：
#     sudo bash script/install.sh --user <用户名>
# 幂等：重复执行等于重装。自动迁移/清理旧版启动项（com.straiway.bclm-keeper、
# com.zackelia.bclm.plist），bclm 自带的开机重写由本守护接管。
#
# 做这些事：
#   - 把 bclm 二进制和守护脚本复制成 root 属主，放到 /Library/PrivilegedHelperTools/
#     （守护从此不再执行用户可改写的文件）
#   - 写入并加载 /Library/LaunchDaemons/com.bclm-keeper.daemon.plist（每 30 秒运行一次）
#   - 卸掉旧启动项：com.straiway.bclm-keeper（本项目旧标签）与 com.zackelia.bclm.plist
#     （bclm 自带，开机极早期执行，实测 BFCL 写不进去）
#   - 把 CLI 装到 /usr/local/bin/bclm-keeper，创建用户状态目录
#   - 若 build/bin/BclmKeeper.app 已构建，拷贝到 /Applications
#   - 立即运行一次守护并回显状态
#
# SMC 里当前的上限值不会被改动（守护只在其不等于设定值时才写）。
set -eu

HERE=$(cd "$(/usr/bin/dirname "$0")/.." && /bin/pwd)
LABEL=com.bclm-keeper.daemon
PLIST=/Library/LaunchDaemons/$LABEL.plist
HELPER=/Library/PrivilegedHelperTools
OLD_LABEL=com.straiway.bclm-keeper        # 本项目旧标签，自动迁移
BCLM_LABEL=com.zackelia.bclm.plist        # bclm 自带启动项
BCLM_SRC=${BCLM_SRC:-/usr/local/bin/bclm}
LOG=/var/log/bclm-keeper.log
APP_SRC=$HERE/build/bin/BclmKeeper.app
APP_DST=/Applications/BclmKeeper.app

usage() {
    echo "用法：sudo bash script/install.sh --user <用户名>" >&2
    exit 64
}
die() {
    echo "错误：${1}" >&2
    exit 1
}

user=
while [ $# -gt 0 ]; do
    case "$1" in
        --user) [ $# -ge 2 ] || usage; user=$2; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$user" ] || usage
[ "$(/usr/bin/id -u)" = 0 ] || die "必须以 root 运行"
case "$user" in ''|*[!a-zA-Z0-9_.-]*) die "用户名不合法：${user}" ;; esac
home=$(/usr/bin/dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
[ -n "$home" ] || die "找不到用户 ${user} 的主目录"
state_dir=$home/.local/state/bclm-keeper
[ -x "$BCLM_SRC" ] || die "找不到可执行的 bclm：${BCLM_SRC}（需先安装 zackelia/bclm，见 README）"
"$BCLM_SRC" read >/dev/null 2>&1 || die "${BCLM_SRC} read 执行失败"
for f in daemon/keeper.sh daemon/$LABEL.plist cli/bclm-keeper; do
    [ -f "$HERE/$f" ] || die "找不到 $HERE/$f"
done
/usr/bin/plutil -lint "$HERE/daemon/$LABEL.plist" >/dev/null || die "plist 模板不合法"
[ -d /usr/local/bin ] && cli=/usr/local/bin/bclm-keeper || cli=$home/.local/bin/bclm-keeper

# 1. root 属主的执行文件
/bin/mkdir -p "$HELPER"
/usr/bin/install -o root -g wheel -m 0755 "$BCLM_SRC" "$HELPER/bclm"
/usr/bin/install -o root -g wheel -m 0755 "$HERE/daemon/keeper.sh" "$HELPER/bclm-keeper"
tmp="$PLIST.tmp"
/usr/bin/sed "s|__STATE_DIR__|$state_dir|" "$HERE/daemon/$LABEL.plist" > "$tmp"
/usr/bin/install -o root -g wheel -m 0644 "$tmp" "$PLIST"
/bin/rm -f "$tmp"
/bin/mkdir -p /var/db/bclm-keeper
/usr/sbin/chown root:wheel /var/db/bclm-keeper
/bin/chmod 0755 /var/db/bclm-keeper
/usr/bin/touch "$LOG"
/usr/sbin/chown root:wheel "$LOG"
/bin/chmod 0644 "$LOG"

# 2. 卸掉旧启动项（bclm 自带的在开机极早期执行，实测 BFCL 写不进去；
#    且它以 root 运行的是用户可改写的 /usr/local/bin/bclm）
if [ -e "/Library/LaunchDaemons/$OLD_LABEL.plist" ]; then
    /bin/launchctl bootout "system/$OLD_LABEL" >/dev/null 2>&1 || true
    /bin/rm -f "/Library/LaunchDaemons/$OLD_LABEL.plist"
    echo "已迁移旧标签 ${OLD_LABEL} -> ${LABEL}"
fi
"$BCLM_SRC" unpersist >/dev/null 2>&1 || true
/bin/launchctl bootout "system/$BCLM_LABEL" >/dev/null 2>&1 || true
/bin/rm -f "/Library/LaunchDaemons/$BCLM_LABEL"

# 3. 加载守护（重复安装时先卸旧的）
/bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
/bin/launchctl bootstrap system "$PLIST"

# 4. 用户侧：CLI、状态目录、应用
/usr/bin/install -o "$user" -g staff -m 0755 "$HERE/cli/bclm-keeper" "$cli"
/bin/mkdir -p "$state_dir"
/usr/sbin/chown "$user":staff "$state_dir"
if [ -d "$APP_SRC" ]; then
    /bin/rm -rf "$APP_DST"
    /bin/cp -R "$APP_SRC" "$APP_DST"
    /usr/sbin/chown -R "$user":admin "$APP_DST"
    app_line="  应用    $APP_DST"
else
    app_line="  应用    未安装（先运行 script/build-app.sh，或仅用 CLI）"
fi

# 5. 立即运行一次，不必等周期
"$HELPER/bclm-keeper" --state-dir "$state_dir"

echo "已安装："
echo "  守护    $HELPER/bclm-keeper（root:wheel 0755，每 30 秒运行一次）"
echo "  启动项  $PLIST"
echo "  日志    $LOG"
echo "  命令    $cli"
echo "  状态目录 $state_dir"
echo "${app_line}"
echo "  bclm 副本 $(/usr/bin/shasum -a 256 "$HELPER/bclm" | /usr/bin/awk '{print $1}')"
echo
env BCLM_KEEPER_STATE_DIR="$state_dir" "$cli" status
