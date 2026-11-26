#!/bin/bash
# bclm-keeper：电池充电上限守护，由 launchd 以 root 运行（com.straiway.bclm-keeper.plist）。
#
# 做两件事：
#   1. 自愈：SMC 里的 BCLM 不等于平时上限就重写；每次开机后的前 BOOT_APPLY_RUNS 次运行
#      再各重写一次。后一条是因为 bclm 自带的开机启动项在开机极早期执行，实测 BFCL
#      写不进去，指示灯会一直停在橙色。
#   2. 一次性充满：用户建了请求标记就临时把上限写成 100；电池真正充满（原始电量达到
#      满充电量的 FULL_PERMILLE‰ 且不充电，连续 FULL_CONFIRM_RUNS 次运行确认）后恢复
#      平时上限；超过 FULL_TIMEOUT_HOURS 仍未充满、或用户撤掉标记，也恢复。
#      不能用菜单栏百分比或 FullyCharged 判满：原始电量约 96% 时菜单栏就显示「100%; charged」。
#
# 安全边界：只执行 root 属主的文件，外部命令一律绝对路径；用户可控的输入只有
# 「请求标记是否存在」和「上限数字」（严格校验为 50~100 的整数，否则用默认值）。
# 带默认值的路径变量只给离线测试用——launchd 不带用户环境启动本脚本，线上始终是默认值。
# 注意：本机的 /bin/bash 是 3.2，set -u 下「$变量」后面紧跟中文会被当成变量名的一部分而报
# unbound variable，所以字符串里变量后面有中文时必须写 ${变量}。test_keeper.sh 末尾有扫描。

set -u
umask 022

BCLM=${BCLM:-/Library/PrivilegedHelperTools/bclm}
IOREG=${IOREG:-/usr/sbin/ioreg}
SYSCTL=${SYSCTL:-/usr/sbin/sysctl}
STAT=${STAT:-/usr/bin/stat}
DATE=${DATE:-/bin/date}
DB_DIR=${DB_DIR:-/var/db/bclm-keeper}
LOG=${LOG:-/var/log/bclm-keeper.log}
FULL_TIMEOUT_HOURS=${FULL_TIMEOUT_HOURS:-24}
DRY_RUN=${KEEPER_DRY_RUN:-0}
DEFAULT_LIMIT=77
BOOT_APPLY_RUNS=3
FULL_PERMILLE=990
FULL_CONFIRM_RUNS=2

usage() {
    echo "用法：bclm-keeper --state-dir <用户状态目录>" >&2
    exit 64
}

log() {
    printf '%s %s\n' "$("$DATE" '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

read_batt() {
    # $1 = AppleSmartBattery 的键名；只取顶层键（字典内的同名键写法是 "K"=v，匹配不到）
    "$IOREG" -rn AppleSmartBattery | /usr/bin/grep -E "^ *\"$1\" = " \
        | /usr/bin/head -n 1 | /usr/bin/awk -F'= ' '{print $2}'
}

read_bclm() {
    "$BCLM" read 2>/dev/null | /usr/bin/tr -d '[:space:]'
}

write_limit() {
    # $1 = 50~100。bclm 即使写失败也返回 0，所以必须回读确认。
    if [ "$DRY_RUN" = 1 ]; then
        log "演练：不执行 bclm write $1"
        return 0
    fi
    "$BCLM" write "$1" >/dev/null 2>&1
    if [ "$(read_bclm)" = "$1" ]; then
        return 0
    fi
    log "bclm write ${1} 失败（回读值不是 ${1}）"
    return 1
}

remove_request() {
    # 清请求标记。演练模式下不清，否则在真机上演练会把用户的请求吞掉而不办事。
    if [ "$DRY_RUN" = 1 ]; then
        log "演练：不清除请求标记"
        return 0
    fi
    /bin/rm -f "$@"
}

boot_id() {
    "$SYSCTL" -n kern.boottime | /usr/bin/sed -E 's/^\{ sec = ([0-9]+),.*$/\1/'
}

# db_get <名字>：读一个非负整数，读不到或格式不对返回 0
db_get() {
    local v
    v=$(/bin/cat "$DB_DIR/$1" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

db_put() {
    echo "$2" > "$DB_DIR/$1"
}

state_dir=
while [ $# -gt 0 ]; do
    case "$1" in
        --state-dir) [ $# -ge 2 ] || usage; state_dir=$2; shift 2 ;;
        *) usage ;;
    esac
done
case "$state_dir" in /*) ;; *) usage ;; esac

/bin/mkdir -p "$DB_DIR" 2>/dev/null

limit=$(/bin/cat "$state_dir/limit" 2>/dev/null | /usr/bin/tr -d '[:space:]')
case "$limit" in ''|*[!0-9]*) limit=$DEFAULT_LIMIT ;; esac
if [ "$limit" -lt 50 ] || [ "$limit" -gt 100 ]; then
    limit=$DEFAULT_LIMIT
fi

cur=$(read_bclm)
case "$cur" in
    ''|*[!0-9]*) log "读 BCLM 失败（输出：${cur:-空}），本次跳过"; exit 0 ;;
esac

flag="$state_dir/full-charge"

if [ -e "$flag" ]; then
    # ---- 一次性充满进行中：此分支里不碰平时上限 ----
    if [ "$cur" != 100 ] && write_limit 100; then
        log "一次性充满：临时解除上限（原值 ${cur}）"
        cur=100
    fi
    [ "$cur" = 100 ] || exit 0

    raw=$(read_batt AppleRawCurrentCapacity)
    max=$(read_batt MaxCapacity)
    charging=$(read_batt IsCharging)
    ac=$(read_batt ExternalConnected)
    case "$raw$max" in ''|*[!0-9]*) raw=0; max=0 ;; esac

    if [ "$ac" = Yes ] && [ "$charging" = No ] && [ "$max" -gt 0 ] \
            && [ $((raw * 1000)) -ge $((max * FULL_PERMILLE)) ]; then
        streak=$(( $(db_get full-streak) + 1 ))
        db_put full-streak "$streak"
        if [ "$streak" -ge $FULL_CONFIRM_RUNS ] && write_limit "$limit"; then
            remove_request "$flag" "$DB_DIR/full-streak"
            log "一次性充满：已充满（原始电量 ${raw}/${max}），恢复上限 $limit"
        fi
        exit 0
    fi
    /bin/rm -f "$DB_DIR/full-streak"

    req=$("$STAT" -f %m "$flag" 2>/dev/null)
    case "$req" in ''|*[!0-9]*) req=0 ;; esac
    if [ "$req" -gt 0 ] \
            && [ $(( $("$DATE" +%s) - req )) -ge $((FULL_TIMEOUT_HOURS * 3600)) ]; then
        if write_limit "$limit"; then
            remove_request "$flag"
            log "一次性充满：超过 ${FULL_TIMEOUT_HOURS} 小时未充满（原始电量 ${raw}/${max}），恢复上限 ${limit}"
        fi
    fi
    exit 0
fi

# ---- 平时：自愈 + 开机后头几次重写 ----
boot=$(boot_id)
case "$boot" in ''|*[!0-9]*) boot= ;; esac
if [ -n "$boot" ] && [ "$boot" != "$(db_get boot)" ]; then
    db_put boot "$boot"
    db_put boot-runs 0
fi
runs=$(db_get boot-runs)
if [ "$cur" != "$limit" ] || [ "$runs" -lt "$BOOT_APPLY_RUNS" ]; then
    if write_limit "$limit"; then
        log "写入上限 ${limit}（原值 ${cur}，本次开机第 $((runs + 1)) 次运行）"
    fi
fi
db_put boot-runs $((runs + 1))
