# BclmKeeper

给老款 Intel MacBook 的电池充电上限管理：菜单栏应用 + root 守护。
把电池的「最高充电百分比」（SMC `BCLM` 键）固定在你设定的值，需要外出时一键「立即充满到 100%」，充满后自动恢复日常上限。

> A charge-limit manager for older Intel MacBooks (SMC `BCLM` key): a menu bar app plus a root daemon. Keep the battery below your daily limit; request a one-shot full charge when you need to travel — the limit is restored automatically when full.

## 适用范围

- **仅限 Intel MacBook**，且 SMC 暴露 `BCLM` 键（2013–2015 款实测：MacBookPro11,3 / Sequoia 15.7.9）。
  Apple Silicon 不适用（充电控制键是 `CHWA`/`CHLS`，已被系统权限保护，见 zackelia/bclm#49）。
- 依赖 [zackelia/bclm](https://github.com/zackelia/bclm)（MIT）：守护以 root 运行它来读写 SMC；读取不需要 root。
  应用与守护都不捆绑该二进制，请自行安装（可从源码构建）。
- OCLP（OpenCore Legacy Patcher）机器可用——本项目作者的开发机就是 OCLP 环境；AlDente 官方不支持 OCLP，这是本工具存在的理由之一。

## 功能

| 功能 | 说明 |
|---|---|
| 日常上限 | `BCLM` 固定为设定值（50–100），SMC 硬件执行，睡眠/关机也生效 |
| 立即充满到 100% | 一次性解除上限，真正充满后（连续确认）自动恢复日常上限 |
| 超时保护 | 请求 24 小时内未充满自动恢复上限；`cancel` 随时取消 |
| 自愈 | 每 30 秒自检，SMC 值被复位就重写；开机后前 3 次运行各重写一次（顺带把充电指示灯键 `BFCL` 修配套，否则 MagSafe 灯会一直橙色） |
| 菜单栏应用 | 显示电量/充电状态（IOPowerSources 公开接口，与官方菜单同口径）；守护未安装时给出提示 |

官方电池菜单里的「使用大量能耗」应用列表来自 powerd 私有数据，第三方无法获取——本应用不试图替代官方电池图标，只做官方没有的扩展功能。

## 安装

### 方式一：安装包（推荐）

从 [Releases](https://github.com/straiway/bclm-keeper/releases) 下载 `BclmKeeper-<版本>.pkg` 双击安装：

- 无需 Xcode/命令行，bclm 依赖已内置（zackelia/bclm，MIT）
- 安装器会要求输入管理员密码，随后自动完成守护装载、CLI 安装并打开菜单栏应用
- 若 Gatekeeper 拦截（「无法验证开发者」）：右键点击 pkg → 打开 → 再点安装，
  或在终端执行 `sudo installer -pkg BclmKeeper-<版本>.pkg -target /`

### 方式二：源码构建

```bash
git clone https://github.com/straiway/bclm-keeper.git
cd bclm-keeper
bash script/build-app.sh                     # 编译菜单栏应用 → build/bin/BclmKeeper.app
sudo bash script/install.sh --user $(whoami)  # 装 root 守护 + 应用 + CLI（幂等，会迁移旧标签）
# 若未安装 zackelia/bclm，先按其 README 从源码构建并安装到 /usr/local/bin/bclm
```

卸载：`sudo bash script/uninstall.sh --user $(whoami)`（SMC 里的值保持不变；要回到 bclm 自带开机启动项再执行 `sudo bclm persist`）。

卸载：`sudo bash script/uninstall.sh --user $(whoami)`（SMC 里的值保持不变；要回到 bclm 自带开机启动项再执行 `sudo bclm persist`）。

## 使用

菜单栏图标（电量百分比 + ⚡/🔌）：

- **立即充满到 100%** / 取消请求
- **充电上限**：50–100 预设值，选多少就最多充到多少。本应用显示的电量是**真实电量**（内核原始容量 / 满充容量）。macOS 自己菜单栏的百分比按曲线被抬高（实测真实 76.5% 时显示 80%），所以本应用的数字会比系统电池图标低几个点，以本应用为准
- 打开电池设置 / 查看守护日志 / 登录时自动启动

命令行（装好后无需密码，效果最迟 30 秒生效）：

```bash
bclm-keeper status      # 查看状态
bclm-keeper full        # 一次性充满
bclm-keeper cancel      # 取消
bclm-keeper set 77      # 改日常上限（50-100）
bclm-keeper log 20      # 看守护日志
```

## 工作原理与安全边界

- 充电由 SMC 固件执行：`BCLM` 是「最高充电百分比」的硬件键，写入后不依赖 macOS 运行。该键无官方文档，属社区逆向结论，**使用风险自担**。
- root 守护（launchd，每 30 秒）**只执行 root 属主的副本**（`/Library/PrivilegedHelperTools/` 下的 `bclm` 与 `bclm-keeper`），不执行用户可改写的文件；每次写入都回读校验。
- 用户可控的输入只有两个状态文件（`~/.local/state/bclm-keeper/`）：请求标记是否存在、上限数字（严格校验 50–100）。
- 菜单栏应用与 CLI 完全无特权，只读显示 + 写上述状态文件。

已知限制：`BCLM` 在部分第三方电池上的表现未逐一验证；写入失败时守护会在下一周期重试并记日志（`/var/log/bclm-keeper.log`）。

## 致谢与许可证

- [zackelia/bclm](https://github.com/zackelia/bclm)（MIT）—— SMC 写入工具；
  其 SMC 层源自 [beltex/SMCKit](https://github.com/beltex/SMCKit)（MIT）。
- 社区对 `BCLM` 键的逆向与讨论（AlDente 等）。

本项目代码以 MIT 许可证发布，见 [LICENSE](LICENSE)。
