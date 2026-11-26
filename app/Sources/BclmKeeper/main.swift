// BclmKeeper —— 菜单栏应用：为官方电池图标补充「充电上限」相关的扩展功能。
//
// 安全边界：应用本身不需要任何特权。读电量/充电状态用 IOKit 公开接口
// （IOPowerSources，与官方菜单同源）；读 SMC 当前上限值用 bclm read（读取无需 root）；
// 所有操作只写 ~/.local/state/bclm-keeper/ 下的标记文件，由 root 守护
// （com.bclm-keeper.daemon，每 30 秒）落地执行。守护未安装时菜单项仍可点击，但不会生效。
//
// 本机（MacBookPro11,3）的菜单栏停点约为「上限值 + 4」；不同机型可能不同。
import AppKit
import IOKit.ps
import ServiceManagement

// MARK: - 常量

let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/state/bclm-keeper")
let fullFlagURL = stateDir.appendingPathComponent("full-charge")
let limitURL = stateDir.appendingPathComponent("limit")
let keeperLogURL = URL(fileURLWithPath: "/var/log/bclm-keeper.log")
let daemonLabel = "com.bclm-keeper.daemon"
let defaultLimit = 77
let limitPresets: [Int] = [50, 60, 66, 70, 77, 80, 85, 90, 100]
let bclmCandidates = ["/Library/PrivilegedHelperTools/bclm", "/usr/local/bin/bclm"]
let batterySettingsURL = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")

// MARK: - 电池读取（公开接口）

struct BatteryInfo {
    let percent: Int        // 与官方菜单一致的显示百分比
    let charging: Bool
    let onAC: Bool
    let minutesToFull: Int? // 系统估计的充满分钟数（仅充电时有）
}

func readBattery() -> BatteryInfo? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
        return nil
    }
    for src in sources {
        guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
              desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
        let pct = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        // kIOPSTimeToFullKey 常量未导出到 Swift 接口，用其原始键名（IOPowerSources.h）
        let mins = desc["Time to Full"] as? Int
        return BatteryInfo(percent: pct, charging: charging, onAC: onAC, minutesToFull: mins)
    }
    return nil
}

// MARK: - 状态读取

func runCommand(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run(); p.waitUntilExit() } catch { return nil }
    guard p.terminationStatus == 0 else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// SMC 里当前的 BCLM 值；bclm 不存在时返回 nil（读不需要 root）
func readBclmValue() -> Int? {
    for path in bclmCandidates where FileManager.default.isExecutableFile(atPath: path) {
        if let v = runCommand(path, ["read"]) { return Int(v) }
    }
    return nil
}

func daemonLoaded() -> Bool {
    runCommand("/bin/launchctl", ["print", "system/\(daemonLabel)"]) != nil
}

/// 用户设定的平时上限（状态文件里），没有则返回默认值
func limitSetting() -> Int {
    guard let text = try? String(contentsOf: limitURL, encoding: .utf8),
          let v = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          (50...100).contains(v) else { return defaultLimit }
    return v
}

func fullRequestedAt() -> Date? {
    let attrs = try? FileManager.default.attributesOfItem(atPath: fullFlagURL.path)
    return attrs?[.modificationDate] as? Date
}

func isBundledApp() -> Bool {
    Bundle.main.bundleURL.pathExtension == "app"
}

// MARK: - 操作（只写用户状态文件，由 root 守护落地）

func requestFullCharge() {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: fullFlagURL.path, contents: nil)
}

func cancelFullCharge() {
    try? FileManager.default.removeItem(at: fullFlagURL)
}

func writeLimit(_ v: Int) {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    try? String(v).write(to: limitURL, atomically: true, encoding: .utf8)
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.updateIcon()
        }
    }

    /// 菜单即将展开时重建全部内容
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    // MARK: 图标

    private func updateIcon() {
        let b = readBattery()
        let pct = b?.percent
        if let btn = statusItem.button {
            btn.title = pct.map { "\($0)%" } ?? "--"
            let symbol = b.map { $0.charging ? "bolt.fill" : ($0.onAC ? "plug.fill" : "battery.100") }
            btn.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            if let b {
                let src = b.onAC ? "电源适配器" : "电池"
                btn.toolTip = "BclmKeeper：\(b.percent)% · \(src)" + (b.charging ? " · 充电中" : "")
            }
        }
    }

    // MARK: 菜单构建

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func action(_ title: String, _ sel: Selector, obj: Any? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        if let obj { it.representedObject = obj }
        return it
    }

    private func rebuild(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        let limit = limitSetting()

        // 状态区（与官方菜单同口径）
        if let b = readBattery() {
            let src = b.onAC ? "电源适配器" : "电池"
            let state = b.charging ? "充电中" : (b.onAC ? "已接电源，未在充电" : "正在使用电池")
            var line = "电池 \(b.percent)% · \(src) · \(state)"
            if b.charging, let mins = b.minutesToFull, mins > 0 { line += "（约 \(mins) 分钟充满）" }
            menu.addItem(disabled(line))
        } else {
            menu.addItem(disabled("电池：读取失败"))
        }
        if let cur = readBclmValue() {
            if let at = fullRequestedAt(), cur == 100 {
                menu.addItem(disabled("上限已临时解除（充满请求进行中）"))
                _ = at
            } else {
                menu.addItem(disabled("充电上限 \(limit) · SMC 当前值 \(cur) · 停点约 \(limit + 4)%"))
            }
        } else {
            menu.addItem(disabled("bclm 未安装——无法读取 SMC 上限值"))
        }
        menu.addItem(disabled(daemonLoaded() ? "守护运行中（每 30 秒自检）"
                                             : "⚠️ 守护未运行，操作不会生效——请先安装"))
        menu.addItem(.separator())

        // 一次性充满
        if fullRequestedAt() != nil {
            menu.addItem(disabled("已请求充满，完成后自动恢复 \(limit)"))
            menu.addItem(action("取消请求", #selector(doCancelFull(_:))))
        } else {
            menu.addItem(action("立即充满到 100%", #selector(doRequestFull(_:))))
        }

        // 充电上限
        let limitItem = NSMenuItem(title: "充电上限（菜单栏停点约为值 + 4）", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for v in limitPresets {
            let it = action(v == 100 ? "100（不限制）" : "\(v)", #selector(doSetLimit(_:)), obj: v)
            if v == limit { it.state = .on }
            sub.addItem(it)
        }
        limitItem.submenu = sub
        menu.addItem(limitItem)
        menu.addItem(.separator())

        // 附属入口
        menu.addItem(action("打开电池设置…", #selector(doOpenBatterySettings(_:))))
        menu.addItem(action("查看守护日志", #selector(doOpenLog(_:))))

        // 登录自启动（仅安装成 .app 后可用，SMAppService 注册无需密码）
        if isBundledApp() {
            let on = SMAppService.mainApp.status == .enabled
            let it = action("登录时自动启动", #selector(doToggleLoginItem(_:)))
            it.state = on ? .on : .off
            menu.addItem(it)
        }
        menu.addItem(.separator())
        menu.addItem(action("退出 BclmKeeper", #selector(doQuit(_:))))
    }

    // MARK: 动作

    @objc private func doRequestFull(_ sender: NSMenuItem) {
        requestFullCharge()
        if let menu = statusItem.menu { rebuild(menu) }
    }

    @objc private func doCancelFull(_ sender: NSMenuItem) {
        cancelFullCharge()
        if let menu = statusItem.menu { rebuild(menu) }
    }

    @objc private func doSetLimit(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Int else { return }
        writeLimit(v)
        if let menu = statusItem.menu { rebuild(menu) }
    }

    @objc private func doOpenBatterySettings(_ sender: NSMenuItem) {
        if let url = batterySettingsURL { NSWorkspace.shared.open(url) }
    }

    @objc private func doOpenLog(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(keeperLogURL)
    }

    @objc private func doToggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "切换登录自启动失败"
            a.informativeText = "\(error)"
            a.runModal()
        }
        if let menu = statusItem.menu { rebuild(menu) }
    }

    @objc private func doQuit(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(self)
    }
}

// MARK: - 启动

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 菜单栏应用，不占 Dock
app.run()
