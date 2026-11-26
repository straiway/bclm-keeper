#!/bin/bash
# keeper.sh 与 bclm-keeper 命令的离线测试：用假的 bclm / ioreg / sysctl 在临时沙箱里跑，
# 全程不碰真实 SMC，也不需要 root。用法：bash test_keeper.sh
set -u

HERE=$(cd "$(/usr/bin/dirname "$0")" && /bin/pwd)
KEEPER=$HERE/../daemon/keeper.sh
CLI=$HERE/../cli/bclm-keeper
TMDIR="$HERE/../tmp"    # 过程文件写仓库 tmp/（gitignore 已忽略），不写 /tmp
/bin/mkdir -p "$TMDIR"
SB=$(/usr/bin/mktemp -d "$TMDIR/bclm-keeper-test.XXXXXX")
trap '/bin/rm -rf "$SB"' EXIT
/bin/mkdir -p "$SB/bin" "$SB/db" "$SB/state" "$SB/uhome"

# 假 bclm：当前值存 $SB/value，每次 write 追加到 $SB/writes；$SB/fail 存在时写不进去。
# 和真 bclm 一样，write 失败也返回 0。
/bin/cat > "$SB/bin/bclm" <<'EOF'
#!/bin/bash
SB=${SB_DIR:?}
case "$1" in
    read)
        if [ -e "$SB/readfail" ]; then
            echo 'keyNotFound(code: "BCLM")'
        else
            /bin/cat "$SB/value" 2>/dev/null
            echo
        fi
        ;;
    write)
        echo "$2" >> "$SB/writes"
        [ -e "$SB/fail" ] || echo "$2" > "$SB/value"
        ;;
esac
exit 0
EOF

# 假 ioreg：把 $SB/batt（每行「键 值」）输出成 ioreg 顶层键的样式
/bin/cat > "$SB/bin/ioreg" <<'EOF'
#!/bin/bash
while read -r k v; do
    echo "    \"$k\" = $v"
done < "${SB_DIR:?}/batt"
EOF

# 假 sysctl：开机时间取 $SB/boot
/bin/cat > "$SB/bin/sysctl" <<'EOF'
#!/bin/bash
echo "{ sec = $(/bin/cat "${SB_DIR:?}/boot"), usec = 0 } Mon Nov 25 00:00:00 2026"
EOF
/bin/chmod 0755 "$SB/bin"/*

pass=0
fail=0
ok() {
    pass=$((pass + 1))
    echo "  ok    $1"
}
bad() {
    fail=$((fail + 1))
    echo "  FAIL  $1"
    [ $# -ge 3 ] && echo "        期望：$2" && echo "        实际：$3"
}
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}
assert_rc() {
    # $2 是上一条命令的退出码；0 表示断言成立
    if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "成立" "退出码 $2"; fi
}
assert_grep() {
    if /usr/bin/grep -qE -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1" "日志含 /$2/" "无匹配"; fi
}
assert_not_grep() {
    if /usr/bin/grep -qE -- "$2" "$3" 2>/dev/null; then bad "$1" "日志不含 /$2/" "有匹配"; else ok "$1"; fi
}
writes() {
    local n
    [ -f "$SB/writes" ] || { echo 0; return; }
    n=$(/usr/bin/wc -l < "$SB/writes" | /usr/bin/tr -d ' ')
    echo "${n:-0}"
}
last_write() {
    /usr/bin/tail -n 1 "$SB/writes" 2>/dev/null
}
set_batt() {
    # $1 原始电量 mAh  $2 满充电量 mAh  $3 是否充电  $4 是否接电源
    printf 'AppleRawCurrentCapacity %s\nMaxCapacity %s\nIsCharging %s\nExternalConnected %s\n' \
        "$1" "$2" "$3" "$4" > "$SB/batt"
}
reset() {
    # $1 = BCLM 初值；清空所有状态
    /bin/rm -f "$SB/value" "$SB/writes" "$SB/readfail" "$SB/fail" "$SB/keeper.log" "$SB/boot" "$SB/batt"
    /bin/rm -rf "$SB/db" "$SB/state" "$SB/uhome"
    /bin/mkdir -p "$SB/db" "$SB/state" "$SB/uhome"
    echo "$1" > "$SB/value"
    echo 1000 > "$SB/boot"
    set_batt 5834 7601 No Yes
}
run() {
    env SB_DIR="$SB" BCLM="$SB/bin/bclm" IOREG="$SB/bin/ioreg" SYSCTL="$SB/bin/sysctl" \
        DB_DIR="$SB/db" LOG="$SB/keeper.log" "$@" /bin/bash "$KEEPER" --state-dir "$SB/state"
}
run_n() {
    local i
    i=0
    while [ "$i" -lt "$1" ]; do run "${@:2}"; i=$((i + 1)); done
}
settle() {
    run_n 4    # 走完开机后头 3 次重写，进入平稳期
}
flag() {
    : > "$SB/state/full-charge"
}
cli() {
    env SB_DIR="$SB" BCLM_KEEPER_STATE_DIR="$SB/state" BCLM="$SB/bin/bclm" LOG="$SB/keeper.log" \
        HOME="$SB/uhome" /bin/bash "$CLI" "$@"
}

echo "== 语法 =="
for f in ../daemon/keeper.sh ../cli/bclm-keeper ../script/install.sh ../script/uninstall.sh test_keeper.sh; do
    /bin/bash -n "$HERE/$f"; assert_eq "bash -n $f" 0 "$?"
done
/usr/bin/plutil -lint "$HERE/../daemon/com.bclm-keeper.daemon.plist" >/dev/null; assert_eq "plutil -lint plist" 0 "$?"
# 本机 /bin/bash 是 3.2：set -u 下「$变量」后面紧跟中文会被当成变量名的一部分而报
# unbound variable，所以必须写 ${变量}。这里扫一遍，发现就失败。
leak=$(LC_ALL=C /usr/bin/grep -nE '\$([A-Za-z_][A-Za-z0-9_]*|[0-9])[^ -~]' \
    "$HERE/../daemon/keeper.sh" "$HERE/../cli/bclm-keeper" "$HERE/../script/install.sh" "$HERE/../script/uninstall.sh" "$HERE/test_keeper.sh")
assert_eq "没有「\$变量 后紧跟中文」的写法" "" "$leak"

echo "== 守护：平时 =="
reset 77
run_n 3
assert_eq "开机后头 3 次运行各写一次平时上限" 3 "$(writes)"
assert_grep "第 1 次的日志" '写入上限 77（原值 77，本次开机第 1 次运行）$' "$SB/keeper.log"
run
assert_eq "第 4 次起不再重复写" 3 "$(writes)"

reset 77
settle
echo 100 > "$SB/value"
run
assert_eq "BCLM 被复位后自动写回" 77 "$(last_write)"
assert_eq "写回后值正确" 77 "$(/bin/cat "$SB/value")"
assert_eq "自愈只写一次" 4 "$(writes)"

reset 77
echo 66 > "$SB/state/limit"
run
assert_eq "上限设定文件生效" 66 "$(last_write)"

reset 80
echo abc > "$SB/state/limit"
run
assert_eq "非数字的上限设定回退默认值" 77 "$(last_write)"
reset 80
echo 49 > "$SB/state/limit"
run
assert_eq "低于 50 的上限设定回退默认值" 77 "$(last_write)"
reset 80
echo 101 > "$SB/state/limit"
run
assert_eq "高于 100 的上限设定回退默认值" 77 "$(last_write)"
reset 80
echo " 66 " > "$SB/state/limit"
run
assert_eq "带空白的上限设定被接受" 66 "$(last_write)"

reset 77
settle
: > "$SB/readfail"
run
assert_eq "读 BCLM 失败时不写" 3 "$(writes)"
assert_grep "读 BCLM 失败有日志" "读 BCLM 失败" "$SB/keeper.log"

reset 100
: > "$SB/fail"
run
assert_eq "写失败时值不变" 100 "$(/bin/cat "$SB/value")"
assert_grep "写失败有日志" "bclm write 77 失败" "$SB/keeper.log"

reset 77
settle
echo 2000 > "$SB/boot"
run_n 3
assert_eq "重新开机后又是 3 次重写" 6 "$(writes)"
run
assert_eq "之后停止" 6 "$(writes)"

echo "== 守护：一次性充满 =="
reset 77
settle
flag
run
assert_eq "请求后临时写 100" 100 "$(last_write)"
assert_grep "解除上限有日志" "临时解除上限（原值 77）" "$SB/keeper.log"
[ -e "$SB/state/full-charge" ]; assert_rc "请求标记保留" $?

set_batt 5834 7601 Yes Yes
run_n 3
assert_eq "充电途中不恢复" 100 "$(last_write)"
[ -e "$SB/state/full-charge" ]; assert_rc "充电途中标记仍在" $?

set_batt 7328 7601 No Yes
run_n 3
assert_eq "原始电量 96.4% 的保持不算充满（此时菜单栏已显示 100%）" 100 "$(last_write)"
[ -e "$SB/state/full-charge" ]; assert_rc "保持期间标记仍在" $?

set_batt 7600 7601 No No
run_n 3
assert_eq "用电池时不判充满" 100 "$(last_write)"
[ -e "$SB/state/full-charge" ]; assert_rc "用电池时标记仍在" $?

set_batt 7600 7601 No Yes
run
assert_eq "第一次确认不恢复" 100 "$(last_write)"
[ -e "$SB/state/full-charge" ]; assert_rc "第一次确认时标记仍在" $?
run
assert_eq "第二次确认后恢复平时上限" 77 "$(last_write)"
[ ! -e "$SB/state/full-charge" ]; assert_rc "恢复后清除请求标记" $?
assert_grep "已充满有日志" "已充满（原始电量 7600/7601），恢复上限 77$" "$SB/keeper.log"

reset 100
flag
/usr/bin/touch -t "$(/bin/date -v-25H '+%Y%m%d%H%M')" "$SB/state/full-charge"
set_batt 5834 7601 Yes Yes
run
assert_eq "超过 24 小时未充满则恢复" 77 "$(last_write)"
[ ! -e "$SB/state/full-charge" ]; assert_rc "超时恢复后清除请求标记" $?
assert_grep "超时有日志" "超过 24 小时未充满" "$SB/keeper.log"

reset 100
flag
set_batt 5834 7601 Yes Yes
run
assert_eq "未超时且未充满时不动" "" "$(last_write)"
[ -e "$SB/state/full-charge" ]; assert_rc "等待期间标记仍在" $?

reset 100
flag
run
/bin/rm -f "$SB/state/full-charge"
run
assert_eq "取消请求后恢复平时上限" 77 "$(last_write)"

reset 100
flag
echo 2000 > "$SB/boot"
run_n 4
assert_eq "一次性充满期间不做开机重写" "" "$(last_write)"

reset 77
settle
echo 66 > "$SB/state/limit"
run
flag
run
set_batt 7600 7601 No Yes
run_n 2
assert_eq "充满后恢复到设定的上限，而不是默认值" 66 "$(last_write)"

reset 100
flag
set_batt 7600 7601 No Yes
run_n 2
assert_eq "请求时已是 100 则直接判充满" 77 "$(last_write)"

reset 100
: > "$SB/fail"
flag
set_batt 7600 7601 No Yes
run_n 2
[ -e "$SB/state/full-charge" ]; assert_rc "恢复写失败时保留请求标记，等下次重试" $?
assert_grep "恢复失败有日志" "bclm write 77 失败" "$SB/keeper.log"

echo "== 守护：演练模式与参数 =="
reset 77
flag
set_batt 7600 7601 No Yes
run_n 3 KEEPER_DRY_RUN=1
assert_eq "演练模式不调用写入" "" "$(/bin/cat "$SB/writes" 2>/dev/null)"
assert_eq "演练模式下 BCLM 不变" 77 "$(/bin/cat "$SB/value")"
assert_grep "演练有日志" "演练：不执行 bclm write" "$SB/keeper.log"
[ -e "$SB/state/full-charge" ]; assert_rc "演练模式不清除请求标记" $?
assert_grep "演练不清标记也有日志" "演练：不清除请求标记" "$SB/keeper.log"

reset 77
env SB_DIR="$SB" BCLM="$SB/bin/bclm" /bin/bash "$KEEPER" >/dev/null 2>&1
assert_eq "缺少 --state-dir 的退出码" 64 "$?"
env SB_DIR="$SB" BCLM="$SB/bin/bclm" /bin/bash "$KEEPER" --state-dir relative >/dev/null 2>&1
assert_eq "相对路径被拒绝" 64 "$?"
assert_eq "参数错误时不写 SMC" "" "$(/bin/cat "$SB/writes" 2>/dev/null)"

echo "== 命令 =="
reset 77
out=$(cli full); assert_eq "full 的退出码" 0 "$?"
assert_grep "full 有提示" "已请求一次性充满" <(echo "$out")
[ -e "$SB/state/full-charge" ]; assert_rc "full 创建请求标记" $?
out=$(cli full); assert_grep "重复 full 有提示" "已经在进行中了" <(echo "$out")
out=$(cli status); assert_eq "status 的退出码" 0 "$?"
assert_grep "status 显示进行中" "一次性充满：进行中" <(echo "$out")
assert_grep "status 显示当前上限" "当前上限（SMC 里的 BCLM）：77" <(echo "$out")
assert_grep "status 显示默认上限" "平时上限设定：77（默认）" <(echo "$out")
out=$(cli cancel); assert_eq "cancel 的退出码" 0 "$?"
[ ! -e "$SB/state/full-charge" ]; assert_rc "cancel 清除请求标记" $?
out=$(cli status); assert_grep "status 显示未请求" "一次性充满：未请求" <(echo "$out")

for bad_val in 49 101 abc 7.7 ""; do
    cli set "$bad_val" >/dev/null 2>&1; assert_eq "set '$bad_val' 被拒绝" 64 "$?"
done
[ ! -e "$SB/state/limit" ]; assert_rc "被拒绝的 set 不写文件" $?
out=$(cli set 70); assert_eq "set 70 的退出码" 0 "$?"
assert_grep "set 的提示" "菜单栏停点约为 74%" <(echo "$out")
assert_eq "set 写入文件" 70 "$(/bin/cat "$SB/state/limit")"

out=$(cli log 2 2>&1); assert_eq "还没有日志时 log 的退出码" 1 "$?"
assert_grep "还没有日志时有提示" "还没有日志" <(echo "$out")
run_n 2
out=$(cli log 2); assert_eq "log 的退出码" 0 "$?"
assert_eq "log 按行数截取" 2 "$(echo "$out" | /usr/bin/grep -c '')"
out=$(cli log); assert_eq "log 默认取全部" 2 "$(echo "$out" | /usr/bin/grep -c '')"
run
out=$(cli log 1); assert_eq "log 只要最后 1 行" 1 "$(echo "$out" | /usr/bin/grep -c '')"
cli bogus >/dev/null 2>&1; assert_eq "未知子命令报用法错误" 64 "$?"
cli set >/dev/null 2>&1; assert_eq "set 缺参数报用法错误" 64 "$?"
cli >/dev/null 2>&1; assert_eq "无参数报用法错误" 64 "$?"

env SB_DIR="$SB" BCLM="$SB/bin/bclm" LOG="$SB/keeper.log" HOME="$SB/uhome" /bin/bash "$CLI" full >/dev/null
[ -e "$SB/uhome/.local/state/bclm-keeper/full-charge" ]; assert_rc "状态目录默认在 \$HOME 下" $?

echo
echo "通过 ${pass}，失败 ${fail}"
[ "$fail" -eq 0 ]
