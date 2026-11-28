// BclmKeeper —— 菜单栏应用：为官方电池图标补充「充电上限」相关的扩展功能。
//
// 安全边界：应用本身不需要任何特权。读电量/充电状态用 IOKit 公开接口
// （IOPowerSources，与官方菜单同源）；读 SMC 当前上限值用 bclm read（读取无需 root）；
// 所有操作只写 ~/.local/state/bclm-keeper/ 下的标记文件，由 root 守护
// （com.bclm-keeper.daemon，每 30 秒）落地执行。守护未安装时菜单项仍可点击，但不会生效。
//
// 应用显示的电量是**真实电量**（内核原始 mAh / 满充 mAh），所以「充电上限选 70」就停在 70。
// macOS 自己的菜单栏百分比按曲线被抬高（实测原始 76.5% 时显示 80%），两者不一致是正常的。
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
let bclmCandidates = ["/Library/PrivilegedHelperTools/bclm", "/usr/local/bin/bclm"]
let batterySettingsURL = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")

// MARK: - 菜单栏电池图标

/// 菜单栏电池图标（模板图，自动适配明暗菜单栏）：优先用系统自己的零件拼装，取不到时回退手绘。
///
/// 系统电池图标（ControlCenter.app，SwiftUI 绘制）不是一张整图，而是「代码画的电量块 +
/// 几个矢量零件」。零件规格（2026-11-26 用 `assetutil --info` 读 Assets.car）：
///   battery-outline 23×12pt 外框   battery-cap 2×12pt 电池头
///   battery-bolt / battery-plug 11×14pt 闪电 / 插头图形（比外框高 2）
///   battery-bolt-mask / battery-plug-mask 11×14pt 同形状、略大一圈的图形
///
/// 画法（对照系统图标的屏幕截图逐像素还原）：
///   1. 在外框内侧画一个**实心电量块**（圆角矩形，宽度 = 电量%）。它是代码画的，没有对应零件
///   2. 用 mask（比图形大一圈）把电量块挖出一个闪电/插头形缺口
///   3. 把图形本身（bolt / plug，不带 mask 后缀的那个）画回缺口里
///      mask 与图形之间那一圈就是系统图标里「图形与电量块之间的细缝」
///   4. 最外层画外框 + 电池头
/// 不充电且用电池时只有 1、4 两步。三种状态都带电量块。
///
/// 应用**不打包**任何系统图形：运行时用 Bundle(path:).image(forResource:) 从用户本机的
/// ControlCenter.app 读取零件，所以这里只有零件名和几何，没有图片文件。
///
/// 实现上用亮度遮罩做挖空，而不是合成模式：
///   · 模板图的 alpha 在整个矩形范围内都是 1（它靠亮度表达形状，黑=图形），
///     所以拿 alpha 当遮罩等于「全部保留」，什么也挖不掉；
///   · destinationOut + 直接 draw 模板图也不可靠（模板图被按填充色画成实心）。
/// 正确做法：把零件画到白色不透明底上 → 转单通道灰度 → 反相（图形处变白）→
/// `ctx.clip(to:mask:)` + `.clear` 混合，在「允许画」的区域涂透明。
///
/// 之前错过四版，都是凭推断改代码：①把闪电当实心图形叠在外框上 ②误以为系统不画电量块
/// ③挖空后忘了把图形画回去 ④拿 alpha 当遮罩。零件名和混合模式只能提示有哪些手段，
/// 真实效果必须拿屏幕截图逐像素对照（见 luminanceMask 的注释）。
///
/// 零件名没有公开文档，Apple 未来可能改：所以取不到时回退到手绘版，功能不受影响。
enum BatteryGlyph { case none, bolt, plug }

struct OfficialBatteryParts {
    static let bundlePath = "/System/Library/CoreServices/ControlCenter.app"
    // 外框 23×12、电池头 2×12、闪电/插头 11×14（比外框高 2）
    static let bodySize = CGSize(width: 23, height: 12)
    static let capSize = CGSize(width: 2, height: 12)
    static let glyphSize = CGSize(width: 11, height: 14)
    static let capGap: CGFloat = 1

    let outline: NSImage, cap: NSImage
    let bolt: NSImage, boltMask: NSImage, plug: NSImage, plugMask: NSImage

    /// 从系统 bundle 取零件；任何一个缺失都返回 nil（调用方回退手绘）。
    static func load() -> OfficialBatteryParts? {
        guard let b = Bundle(path: bundlePath),
              let outline = b.image(forResource: "battery-outline"),
              let cap = b.image(forResource: "battery-cap"),
              let bolt = b.image(forResource: "battery-bolt"),
              let boltMask = b.image(forResource: "battery-bolt-mask"),
              let plug = b.image(forResource: "battery-plug"),
              let plugMask = b.image(forResource: "battery-plug-mask") else { return nil }
        return OfficialBatteryParts(outline: outline, cap: cap,
                                    bolt: bolt, boltMask: boltMask, plug: plug, plugMask: plugMask)
    }

    /// 画布：外框 + 间隙 + 电池头，四周各留 1pt；高度按闪电（比外框高 2）留足
    var canvasSize: CGSize {
        CGSize(width: Self.bodySize.width + Self.capGap + Self.capSize.width + 2,
               height: max(Self.bodySize.height, Self.glyphSize.height) + 2)
    }

    /// 把一个零件（模板图）栅格化成 CoreGraphics 可用的**亮度遮罩**（单通道灰度、无 alpha）。
    ///
    /// 模板图的 alpha 在整个矩形范围内都是 1（它靠亮度表达形状：黑=图形），所以不能拿
    /// alpha 当遮罩——那样等于「全部保留」，什么也挖不掉。这里把它画到**白色不透明**底上
    /// 再转成灰度位图：默认黑（图形）处遮罩不通过；`invert: true` 时反相，图形处通过。
    static func luminanceMask(of image: NSImage, pixelW: Int, pixelH: Int, invert: Bool = false) -> CGImage? {
        guard let rgb = CGContext(data: nil, width: pixelW, height: pixelH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        rgb.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 1, 1, 1])!)
        rgb.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: rgb, flipped: false)
        NSColor.black.setFill()
        image.draw(in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        NSGraphicsContext.restoreGraphicsState()
        guard let drawn = rgb.makeImage() else { return nil }
        // 转成单通道灰度图（亮度遮罩要求每像素 1 字节、无 alpha）
        guard let gray = CGContext(data: nil, width: pixelW, height: pixelH, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        if invert {
            // 反相：先画原图，再用 difference 混合铺一层白 → 黑变白、白变黑
            gray.draw(drawn, in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
            gray.setBlendMode(.difference)
            gray.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceGray(), components: [1, 1])!)
            gray.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        } else {
            gray.draw(drawn, in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        }
        return gray.makeImage()
    }

    func render(levelPercent: Int, glyph: BatteryGlyph) -> NSImage? {
        let W = canvasSize.width, H = canvasSize.height
        let scale: CGFloat = 2
        let pw = Int(W * scale), ph = Int(H * scale)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 0, 1])!)

        let ox: CGFloat = 1, oy: CGFloat = (H - Self.bodySize.height) / 2
        let bodyRect = CGRect(origin: CGPoint(x: ox, y: oy), size: Self.bodySize)
        let capRect = CGRect(origin: CGPoint(x: ox + Self.bodySize.width + Self.capGap, y: oy), size: Self.capSize)
        // 闪电/插头相对外框水平居中、垂直居中（上下各超出外框 1pt）
        let glyphRect = CGRect(x: ox + (Self.bodySize.width - Self.glyphSize.width) / 2,
                               y: (H - Self.glyphSize.height) / 2,
                               width: Self.glyphSize.width, height: Self.glyphSize.height)
        // 画布坐标系（左下原点）下的 glyph 区域，单位像素，用于遮罩定位
        let gx = Int((glyphRect.minX) * scale), gy = Int((glyphRect.minY) * scale)
        let gw = Int(Self.glyphSize.width * scale), gh = Int(Self.glyphSize.height * scale)

        // 1) 实心电量块（贴外框内侧的圆角矩形，宽度 = 电量%）
        let level = CGFloat(max(0, min(100, levelPercent))) / 100
        if level > 0 {
            let inset: CGFloat = 2.0
            let fillRect = CGRect(x: ox + inset, y: oy + inset,
                                  width: (Self.bodySize.width - inset * 2) * level,
                                  height: Self.bodySize.height - inset * 2)
            ctx.addPath(CGPath(roundedRect: fillRect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            ctx.fillPath()
        }

        // 2) 用 mask（比图形大一圈）把电量块挖出图形形状的缺口
        //    亮度遮罩语义：白=允许画，黑=不允许画。图形在零件里是黑色的，所以把遮罩
        //    **反相**（图形处变白）后，用 clear 混合在「允许画」的区域涂透明，
        //    就正好把图形形状从电量块里挖掉。
        let maskImage: NSImage?
        let glyphImage: NSImage?
        switch glyph {
        case .bolt: (maskImage, glyphImage) = (boltMask, bolt)
        case .plug: (maskImage, glyphImage) = (plugMask, plug)
        case .none: (maskImage, glyphImage) = (nil, nil)
        }
        if let maskImage, let mask = Self.luminanceMask(of: maskImage, pixelW: gw, pixelH: gh, invert: true) {
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.clip(to: CGRect(x: CGFloat(gx) / scale, y: CGFloat(gy) / scale,
                                width: Self.glyphSize.width, height: Self.glyphSize.height),
                      mask: mask)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))     // ctx 已按 scale 缩放，这里用 pt 坐标
            ctx.restoreGState()
        }

        // 3) 把图形画回缺口里
        if let glyphImage {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSColor.black.setFill()
            glyphImage.draw(in: glyphRect)
            NSGraphicsContext.restoreGraphicsState()
        }

        // 4) 外框 + 电池头
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSColor.black.setFill()
        outline.draw(in: bodyRect)
        cap.draw(in: capRect)
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage() else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: W, height: H))
        img.isTemplate = true
        return img
    }
}

/// 生成菜单栏电池图标。glyph 由调用方按状态决定（充电=bolt，插电未充=plug，否则 none）。
func makeMenuBarBatteryIcon(levelPercent: Int, charging: Bool, onAC: Bool) -> NSImage {
    let glyph: BatteryGlyph = charging ? .bolt : (onAC ? .plug : .none)
    if let parts = OfficialBatteryParts.load(), let img = parts.render(levelPercent: levelPercent, glyph: glyph) {
        return img
    }
    return drawMenuBarBatteryFallback(levelPercent: levelPercent, charging: charging, onAC: onAC)
}

/// 手绘回退版（系统零件取不到时用）。用纯 CoreGraphics 画：圆角细外框 + 按电量填充，
/// 充电时叠一个实心闪电。
///
/// 注意必须用纯 CGContext(data:…) 画、再包成 CGImage：NSGraphicsContext(bitmapImageRep:)
/// 的桥接在本机（OCLP/darwin 24.6.0）上屏后是斜的平行四边形。
/// 另：验证渲染结果时，读位图要按 bytesPerRow 逐行读并做上下翻转——按连续缓冲区读会
/// 得到斜条纹假象，曾因此误判过一版。
func drawMenuBarBatteryFallback(levelPercent: Int, charging: Bool, onAC: Bool) -> NSImage {
    let scale: CGFloat = 2
    // 电池主体约 22.5×11pt（宽高比 ≈ 2.05，对齐系统的短方比例）
    let bodyW: CGFloat = 22.5, bodyH: CGFloat = 11
    let capW: CGFloat = 1.6, capH: CGFloat = 4.4, capGap: CGFloat = 0.8
    let W: CGFloat = bodyW + capGap + capW + 3.0               // 画布（pt），四周留边
    let H: CGFloat = bodyH + 3.0
    let x0: CGFloat = 1.5                                     // 主体左边
    let y0: CGFloat = (H - bodyH) / 2
    let radius: CGFloat = 3.2
    let stroke: CGFloat = 0.8                                 // 外框细线

    guard let ctx = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return NSImage(size: NSSize(width: W, height: H))
    }
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)
    let black = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 0, 1])!
    ctx.setFillColor(black)
    ctx.setStrokeColor(black)
    ctx.setLineWidth(stroke)

    let body = CGRect(x: x0 + stroke / 2, y: y0 + stroke / 2,
                      width: bodyW - stroke, height: bodyH - stroke)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.strokePath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: x0 + bodyW + capGap, y: y0 + (bodyH - capH) / 2,
                                           width: capW, height: capH),
                       cornerWidth: 0.7, cornerHeight: 0.7, transform: nil))
    ctx.fillPath()

    let cx = x0 + bodyW / 2, cy = y0 + bodyH / 2
    if charging {
        let pts: [(CGFloat, CGFloat)] = [(2.0, 6.4), (-5.2, -0.4), (-1.1, -0.4),
                                         (-2.6, -6.6), (5.6, 1.0), (1.2, 1.0)]
        ctx.beginPath()
        for (i, p) in pts.enumerated() {
            let pt = CGPoint(x: cx + p.0, y: cy + p.1)
            if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
        }
        ctx.closePath()
        ctx.fillPath()
    } else {
        let inset: CGFloat = stroke + 0.9
        let innerW = bodyW - inset * 2, innerH = bodyH - inset * 2
        let fillW = innerW * CGFloat(max(0, min(100, levelPercent))) / 100
        if fillW > 0.4 {
            let r = min(1.8, innerH / 2)
            ctx.addPath(CGPath(roundedRect: CGRect(x: x0 + inset, y: y0 + inset, width: fillW, height: innerH),
                               cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.fillPath()
        }
    }
    _ = onAC

    guard let cg = ctx.makeImage() else { return NSImage(size: NSSize(width: W, height: H)) }
    let img = NSImage(cgImage: cg, size: NSSize(width: W, height: H))
    img.isTemplate = true
    return img
}

// MARK: - 控制中心风格滑块

/// 仿控制中心「声音」滑块的自绘 slider cell，与 OfficialBatteryParts 同一思路：
/// 只换皮，不碰交互——拖动、点击轨道跳值、无障碍（AXSlider 可调节）都仍由
/// NSSlider/NSSliderCell 提供，本类只重写绘制。
///
/// 规格 2026-11-27 从系统成品截图与 Assets.car 实测（过程数据在仓库 tmp/slider-parts/，不入库）：
///   · 轨道：胶囊形，高 22pt、圆角 11。Assets.car 里 slider-track 是颜色资产
///     （深色 0.137 灰），经控制中心面板混合后实际呈现为 RGB(69,70,70)（截图实测），
///     这里直接用呈现结果；浅色模式用资产里的 0.91 灰（未实测，仅兜底）。
///     轨道是纯色平涂，用 CG 圆角矩形即可——把 slider-track-mask 素材横向拉伸会
///     使两端圆角变形，数学上等价的胶囊反而精确。
///   · 填充：白色胶囊，上下左右各比轨道缩 1pt（slider-fill 素材本身就是 31×20 缩进
///     在 33×22 里），右端画到旋钮右缘——官方构图是白条一直延伸到旋钮右缘，画到
///     中心会让旋钮左晕在白条末端压出暗带、看起来像缝隙（2026-11-28 用户反馈）。
///     素材若横向拉伸两端圆角同样变形，故也用 CG 绘制。
///   · 旋钮：直径 20pt 白圆带阴影圈，用 ControlCenter.app 的 slider-knob 零件
///     （40×40 画布自带阴影留白）。取不到时回退手绘圆+阴影。
///   · 描边：浅色模式下轨道有一圈 1pt 纯黑 @10% alpha 的细环（slider-track-outline
///     素材逐像素实测：贴轨道外缘内侧，x0-1/y0-1 各 2px @ A26；2026-11-28 用户反馈
///     浅色缺边线后确认）。深色变体全透明，即深色本来就没有边线。环是均匀细线，
///     直接用 CG 描边复现——素材与轨道同尺寸但被拉伸时两端圆环会变形成尖头透镜
///     （2026-11-28 首版就栽在这里，与上面 mask/fill 不拉伸是同一条纪律）。
///   · 左端图标：与轨道同色。官方喇叭图标是挖空效果（露出轨道色），同色平涂视觉等价；
///     且填充没盖住图标时（上限拉到最低）露出的也是轨道色，两种状态行为一致。
///   · 填充/旋钮本色：两种外观均为 255 纯白（官方浅色截图实测素材 248 经面板呈现
///     为 255；直接用素材值会让填充发暗，2026-11-28 修正）。
///   · 轨道是**半透明叠加色**，不是不透明平涂（2026-11-28 用户观察：弹窗底色变化时
///     官方轨道随之变化）：深色 = 白 15.8%（官方面板 34→轨道 69 反推 35/221），
///     浅色 = 黑 10.7%（官方面板 234→轨道 209 反推 25/234）。两个锚点都精确复现，
///     且底色变化时轨道像官方一样跟随。
///   · 左端图标：**填充层上的镂空**（透出下层半透明轨道，随底色变化）——与官方
///     一致（官方深色图标 69=轨道 69、浅色图标 211≈轨道 209）。实现：灰度亮度
///     遮罩（白=字形）+ clip(to:mask:) + destinationOut 填充擦除。遮罩生成必须
///     先铺白底画黑字形再 difference 反转（黑底黑字形反转后全白 → 挖成方块，
///     2026-11-28 首版踩坑）；SF Symbol 字形在图内贴底，按字形 bbox 居中定位。
///     用 CGContext.draw 而非 NSImage.draw 做擦除——后者会重置混合模式。
final class OfficialSliderCell: NSSliderCell {
    static let trackHeight: CGFloat = 22
    static let knobDiameter: CGFloat = 20
    /// 官方旋钮零件，运行时从用户本机 ControlCenter.app 读取（应用不打包）
    static let knobImage: NSImage? = Bundle(path: OfficialBatteryParts.bundlePath)?
        .image(forResource: "slider-knob")

    /// 轨道叠加色：半透明，随底色变化（alpha 由官方面板→轨道的实测锚点反推）。
    /// 深色：白 15.8%（面板 34 → 轨道 69）；浅色：黑 10.7%（面板 234 → 轨道 209）。
    static let trackOverlay = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(white: 1, alpha: 35.0 / 221.0)
        }
        return NSColor(white: 0, alpha: 25.0 / 234.0)
    }

    /// 填充/旋钮本色：两种外观都是 255 纯白（官方浅色截图实测素材 248 经面板呈现
    /// 为 255，深色截图实测 255）
    static let fillColor = NSColor.white

    /// 左端图标色（平涂上色用）：官方实测呈现值，深 69,70,70 / 浅 209,210,211
    /// （与轨道呈现值一致——官方图标是挖空效果，平涂同色视觉等价）
    static let iconColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 69 / 255, green: 70 / 255, blue: 70 / 255, alpha: 1)
        }
        return NSColor(srgbRed: 209 / 255, green: 210 / 255, blue: 211 / 255, alpha: 1)
    }

    init(currentValue: Double, minValue minValue_: Double, maxValue maxValue_: Double,
         target: AnyObject?, action: Selector) {
        super.init()
        self.minValue = minValue_
        self.maxValue = maxValue_
        self.doubleValue = currentValue
        self.target = target
        self.action = action
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// 轨道矩形：在给定矩形内垂直居中、全宽（旋钮在两端可越出轨道，官方行为）
    private static func trackRect(in frame: NSRect) -> NSRect {
        NSRect(x: frame.minX, y: frame.minY + (frame.height - Self.trackHeight) / 2,
               width: frame.width, height: Self.trackHeight)
    }

    /// 旋钮矩形：20pt 见方，中心随值在轨道内滑动（两端时旋钮边缘对齐轨道边缘）
    private func knobRect(in track: NSRect) -> NSRect {
        let t = maxValue > minValue ? CGFloat((doubleValue - minValue) / (maxValue - minValue)) : 0
        return NSRect(x: track.minX + t * (track.width - Self.knobDiameter),
                      y: track.midY - Self.knobDiameter / 2,
                      width: Self.knobDiameter, height: Self.knobDiameter)
    }

    /// AppKit 命中测试/无障碍用的矩形：以 controlView 的 bounds 为绘图矩形。
    /// 绘制路径（draw(withFrame:)）不经过这里——它直接用传入的 frame，
    /// 因为 controlView 要等控件进窗口才由 AppKit 建立，绘制若依赖它会在
    /// 早期渲染时画出零矩形（2026-11-28 离屏测试实证）。
    override func barRect(flipped: Bool) -> NSRect {
        Self.trackRect(in: controlView?.bounds ?? NSRect.zero)
    }

    override func knobRect(flipped: Bool) -> NSRect {
        knobRect(in: barRect(flipped: flipped))
    }

    /// 全部自绘：半透明轨道 → 官方描边 → 白色填充层（含图标镂空）→ 官方旋钮零件。
    /// 不调 super（不走 drawBar/drawKnob）。
    override func draw(withFrame frame: NSRect, in controlView: NSView) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let track = Self.trackRect(in: frame)
        let knob = knobRect(in: track)

        Self.trackOverlay.setFill()
        NSBezierPath(roundedRect: track, xRadius: Self.trackHeight / 2, yRadius: Self.trackHeight / 2).fill()

        // 浅色描边：1pt 纯黑 @10%，贴轨道外缘内侧（与 slider-track-outline 素材
        // 逐像素实测一致）。深色模式没有描边（素材深色变体全透明）。环是均匀细线，
        // 用 CG 描边精确复现；不用拉伸素材——横向拉伸会让两端圆环变形成尖头透镜。
        if controlView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua {
            NSColor.black.withAlphaComponent(0.1).setStroke()
            let p = NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: Self.trackHeight / 2 - 0.5, yRadius: Self.trackHeight / 2 - 0.5)
            p.lineWidth = 1
            p.stroke()
        }

        // 填充：上下左右缩 1pt，右端到旋钮右缘——与官方构图一致（实测官方白条一直
        // 延伸到旋钮右缘）：填充的右圆帽（半径 10）与旋钮圆的右半完全重合，白上叠白；
        // 旋钮左晕淡淡压在填充上（官方同样有），右缘阴影圈压在轨道上。
        // 若只画到旋钮中心，旋钮左半会悬在轨道色上，左晕在白条末端压出一条暗带，
        // 看起来像填充与旋钮之间有缝隙。
        let fillMinX = track.minX + 1
        let fillRight = max(fillMinX, knob.maxX)
        if fillRight > fillMinX {
            Self.fillColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: fillMinX, y: track.minY + 1,
                                             width: fillRight - fillMinX, height: Self.trackHeight - 2),
                         xRadius: (Self.trackHeight - 2) / 2, yRadius: (Self.trackHeight - 2) / 2).fill()
        }

        if let img = Self.knobImage {
            img.draw(in: NSRect(x: knob.midX - img.size.width / 2,
                                y: track.midY - img.size.height / 2,
                                width: img.size.width, height: img.size.height))
        } else {
            // 回退：官方零件取不到时手绘白圆 + 阴影
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 2
            shadow.set()
            Self.fillColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: knob.midX - Self.knobDiameter / 2,
                                        y: track.midY - Self.knobDiameter / 2,
                                        width: Self.knobDiameter, height: Self.knobDiameter)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }


}

// MARK: - 电池读取（公开接口）

struct BatteryInfo {
    /// **真实电量**：内核的 AppleRawCurrentCapacity / MaxCapacity，也就是电池实际充了多少。
    /// 菜单、悬停提示、图标填充一律用它，这样「充电上限选 70」就停在 70，不用换算。
    let percent: Int
    /// macOS 自己显示的百分比（IOPowerSources 的 Current Capacity）。它按一条曲线被抬高了：
    /// 实测原始 76.5% 时显示 80%，满电时两者才重合。只用于和系统对照，不用于任何显示。
    let systemPercent: Int
    let charging: Bool      // 与系统图标同口径：只看 IOPowerSources 的 "Is Charging"
    let onAC: Bool
    let minutesToFull: Int? // 系统估计的充满分钟数（仅充电时有）
}

/// 从内核的 AppleSmartBattery 服务读原始电量（当前 mAh、满充 mAh）。不需要权限，也不起子进程。
func readRawCapacity() -> (current: Int, max: Int)? {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                       IOServiceMatching("AppleSmartBattery"), &iter) == kIOReturnSuccess else {
        return nil
    }
    defer { IOObjectRelease(iter) }
    while true {
        let service = IOIteratorNext(iter)
        if service == 0 { break }
        defer { IOObjectRelease(service) }
        let cur = IORegistryEntryCreateCFProperty(service, "AppleRawCurrentCapacity" as CFString,
                                                  kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        let max = IORegistryEntryCreateCFProperty(service, "MaxCapacity" as CFString,
                                                  kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        if let cur, let max, max > 0 { return (cur, max) }
    }
    return nil
}

func readBattery() -> BatteryInfo? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
        return nil
    }
    for src in sources {
        guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
              desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
        let systemPct = desc["Current Capacity"] as? Int ?? 0
        let onAC = (desc["Power Source State"] as? String) == "AC Power"
        // 键名用 IOPowerSources.h 的原始字符串（kIOPSTimeToFullKey 未导出到 Swift）。
        //
        // 充电判定只看 "Is Charging"，与系统电池图标读的是同一份数据源（IOPowerSources）。
        // 曾加过「且电流 > 0」的条件：那是从一次采样里推出来的，依据不足，而且会让菜单
        // 文案与系统对不上（系统显示充电中、本应用显示未在充电），已撤销。
        // 之前与系统图标「闪电/插头对不上」的真正原因是图标 10 秒才刷新一次，已改为
        // 电源变化事件驱动（见 AppDelegate）。
        let charging = desc["Is Charging"] as? Bool ?? false
        let mins = desc["Time to Full Charge"] as? Int
        // 真实电量取内核原始值；万一读不到（非标准机型），退回系统显示值，至少有数可显示。
        let pct: Int
        if let raw = readRawCapacity() {
            pct = Int((Double(raw.current) / Double(raw.max) * 100).rounded())
        } else {
            pct = systemPct
        }
        return BatteryInfo(percent: pct, systemPercent: systemPct, charging: charging, onAC: onAC, minutesToFull: mins)
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

/// 电源信息变化的通知回调（C 函数指针，不能捕获上下文）：切回主线程刷新图标。
func powerSourceChanged() {
    DispatchQueue.main.async {
        (NSApplication.shared.delegate as? AppDelegate)?.refreshIconFromNotification()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var powerSourceRunLoopSource: CFRunLoopSource?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        // 电源信息一变化系统就回调（与系统电池图标同源同时机），不再靠定时器轮询。
        // 之前的 10 秒定时器会让图标最多滞后 10 秒：电池在充电上限附近每隔几秒就
        // 在充/停之间翻转，用户截图时就会看到「我的显示闪电、系统显示插头」。
        // IOPSNotificationCreateRunLoopSource 的回调是 C 函数指针，不能捕获上下文，
        // 所以用顶层函数 powerSourceChanged()，它自己找到 delegate 去刷新。
        if let rs = IOPSNotificationCreateRunLoopSource({ _ in powerSourceChanged() },
                                                         nil)?.takeRetainedValue() {
            powerSourceRunLoopSource = rs
            // CFRunLoopSource 不能用 RunLoop.add（那只接受 Timer），要用 CoreFoundation 的接口
            CFRunLoopAddSource(CFRunLoopGetMain(), rs, .commonModes)
        } else {
            // 拿不到通知源时退回轮询
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.updateIcon()
            }
        }
    }

    /// 菜单即将展开时重建全部内容
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    // MARK: 图标


    /// 供电源变化通知调用
    func refreshIconFromNotification() { updateIcon() }

    private func updateIcon() {
        let b = readBattery()
        if let btn = statusItem.button {
            btn.title = ""   // 不显示百分比文字，省菜单栏空间；电量看悬停提示/菜单
            btn.image = makeMenuBarBatteryIcon(levelPercent: b?.percent ?? 0,
                                               charging: b?.charging ?? false,
                                               onAC: b?.onAC ?? false)
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
                let it = disabled("充电上限 \(limit)%（到这个值就停）· 当前生效 \(cur)")
                statusLineItem = it
                menu.addItem(it)
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

        // 充电上限：滑块行（仿控制中心「声音」滑块）
        menu.addItem(makeLimitSliderRow(current: limit))
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

    // 滑块行相关：拖动时实时更新右侧百分比与状态行，停止拖动 0.35 秒后才写状态文件
    // （守护每 30 秒才读一次，拖动过程中连续写文件没有意义）
    private var statusLineItem: NSMenuItem?
    private var sliderPercentLabel: NSTextField?
    private var pendingLimitWrite: DispatchWorkItem?

    /// 构造「充电上限」滑块行。样式仿控制中心的「声音」滑块（OfficialSliderCell）：
    /// 半透明胶囊轨道、白色填充（左端电池符号平涂上色）、官方旋钮零件，
    /// 右端显示当前百分比。
    private func makeLimitSliderRow(current: Int) -> NSMenuItem {
        let row = NSMenuItem()
        let W: CGFloat = 300, H: CGFloat = 36
        let container = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        // 轨道左缘与菜单标题文字左缘对齐（实测标题字形左缘距菜单窗口 ~25pt，
        // 容器 x 直接用 25 即可对上）；右缘到 242，给百分比标签（x=W-52 起）留 6pt 间隙
        let trackLeft: CGFloat = 25
        let trackRight: CGFloat = W - 58
        let slider = NSSlider(frame: NSRect(x: trackLeft, y: 0, width: trackRight - trackLeft, height: H))
        slider.cell = OfficialSliderCell(currentValue: Double(current), minValue: 50, maxValue: 100,
                                         target: self, action: #selector(limitSliderChanged(_:)))
        slider.isContinuous = true
        slider.setAccessibilityLabel("充电上限")
        container.addSubview(slider)

        // 左端电池符号：平涂上色（色值=官方实测呈现值，深 69/浅 209，与轨道一致）
        let icon = NSImageView(frame: NSRect(x: trackLeft + 5, y: (H - 14) / 2, width: 18, height: 14))
        icon.image = NSImage(systemSymbolName: "battery.100", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        icon.contentTintColor = OfficialSliderCell.iconColor
        container.addSubview(icon)

        // 右端百分比
        let label = NSTextField(labelWithString: "\(current)%")
        label.frame = NSRect(x: W - 52, y: (H - 16) / 2, width: 44, height: 16)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        container.addSubview(label)
        sliderPercentLabel = label

        row.view = container
        return row
    }

    /// 滑块拖动回调：更新显示；停止拖动后一次性写入状态文件（防抖）。
    @objc private func limitSliderChanged(_ sender: NSSlider) {
        let v = Int(sender.doubleValue.rounded())
        sliderPercentLabel?.stringValue = "\(v)%"
        let cur = readBclmValue().map(String.init) ?? "?"
        statusLineItem?.title = "充电上限 \(v)%（到这个值就停）· 当前生效 \(cur)"
        pendingLimitWrite?.cancel()
        let w = DispatchWorkItem { writeLimit(v) }        // 顶层函数，按名字直接调用
        pendingLimitWrite = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
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
