#!/bin/bash
# 卸载 BclmKeeper。必须以 root 运行：
#     sudo bash script/uninstall.sh --user <用户名>
# 只移除守护与菜单栏应用；SMC 里当前的上限值保持不变。
# 想让 bclm 自带的开机启动项重新接管，卸载后执行：sudo bclm persist
set -eu

LABEL=com.bclm-keeper.daemon
OLD_LABEL=com.straiway.bclm-keeper
BCLM_LABEL=com.zackelia.bclm.plist

usage() {
    echo "用法：sudo bash script/uninstall.sh --user <用户名>" >&2
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

for l in "$LABEL" "$OLD_LABEL"; do
    /bin/launchctl bootout "system/$l" >/dev/null 2>&1 || true
    /bin/rm -f "/Library/LaunchDaemons/$l.plist"
done
/bin/rm -f /Library/PrivilegedHelperTools/bclm-keeper /Library/PrivilegedHelperTools/bclm
/bin/rm -rf /var/db/bclm-keeper /Applications/BclmKeeper.app
if [ -d /usr/local/bin ]; then
    /bin/rm -f /usr/local/bin/bclm-keeper
else
    /bin/rm -f "$home/.local/bin/bclm-keeper"
fi

echo "已卸载守护、启动项、root 属主的 bclm 副本、内部状态、CLI 和菜单栏应用。"
echo "保留了："
echo "  /usr/local/bin/bclm（你自己的 bclm，若存在）"
echo "  ${state_dir}（你的平时上限设定和可能的请求标记）"
echo "  /var/log/bclm-keeper.log（日志）"
smc="读取失败"
for p in /usr/local/bin/bclm /Library/PrivilegedHelperTools/bclm; do
    if [ -x "$p" ]; then smc=$("$p" read 2>/dev/null | /usr/bin/tr -d '[:space:]') && break; fi
done
echo "SMC 里当前的上限值没有动，现在是：${smc}"
echo "要恢复 bclm 自带的开机启动项：sudo bclm persist"
