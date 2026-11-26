// 生成应用图标底图（1024×1024 PNG）：绿色渐变圆角方块 + 白色电池（3/4 电量）+ 深绿闪电。
// 全程纯 CoreGraphics + ImageIO，不经 NSBitmapImageRep/NSGraphicsContext 桥接（后者曾产生
// 底缘裁切异常，2026-11-26 实测）。由 script/make-icon.sh 调用并组装成 .icns；也可单独运行：
//   swift script/make-icon.swift tmp/icon-1024.png
import AppKit
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let S: CGFloat = 1024

func cgc(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!
}

// 画布：预乘 RGBA 的 CGContext，原点在左下
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write("创建 CGContext 失败\n".data(using: .utf8)!); exit(1)
}

// 背景：macOS 标准图标内容约占画布 82%（824/1024，四周留 10% 边）；超椭圆圆角（22.37% 曲率）。
// 第一版铺满全画布，用户反馈"比别的应用图标大一圈"（2026-11-26），改为标准留边。
let content: CGFloat = S * 0.82
let off = (S - content) / 2
ctx.addPath(CGPath(roundedRect: CGRect(x: off, y: off, width: content, height: content),
                   cornerWidth: content * 0.2237, cornerHeight: content * 0.2237, transform: nil))
ctx.clip()
let strips = 256
let stripH = S / CGFloat(strips)
let topC = (0.42, 0.80, 0.52), botC = (0.10, 0.52, 0.27)
for i in 0..<strips {
    let t = CGFloat(i) / CGFloat(strips - 1)
    let r = topC.0 + (botC.0 - topC.0) * t
    let g = topC.1 + (botC.1 - topC.1) * t
    let b = topC.2 + (botC.2 - topC.2) * t
    ctx.setFillColor(cgc(Double(r), Double(g), Double(b)))
    ctx.fill(CGRect(x: 0, y: CGFloat(i) * stripH, width: S, height: stripH + 1))
}

// 白色电池主体：描边圆角矩形 + 右端电池头 + 3/4 电量填充
let white = cgc(1, 1, 1)
let bodyW = S * 0.545, bodyH = S * 0.29
let bodyX = (S - bodyW) / 2 - S * 0.025, bodyY = (S - bodyH) / 2
let body = CGRect(x: bodyX, y: bodyY, width: bodyW, height: bodyH)
ctx.addPath(CGPath(roundedRect: body, cornerWidth: bodyH * 0.24, cornerHeight: bodyH * 0.24, transform: nil))
ctx.setLineWidth(S * 0.036)
ctx.setStrokeColor(white)
ctx.strokePath()
let inset: CGFloat = S * 0.034
ctx.addPath(CGPath(roundedRect: CGRect(x: body.minX + inset, y: body.minY + inset,
                                       width: (bodyW - inset * 2) * 0.75, height: bodyH - inset * 2),
                   cornerWidth: (bodyH - inset * 2) * 0.18, cornerHeight: (bodyH - inset * 2) * 0.18,
                   transform: nil))
ctx.setFillColor(white)
ctx.fillPath()
let capH = bodyH * 0.42, capW = S * 0.036
ctx.addPath(CGPath(roundedRect: CGRect(x: body.maxX + S * 0.015, y: bodyY + (bodyH - capH) / 2,
                                       width: capW, height: capH),
                   cornerWidth: capW * 0.45, cornerHeight: capW * 0.45, transform: nil))
ctx.setFillColor(white)
ctx.fillPath()

// 深绿闪电，叠在白色电池填充上（白色闪电在白填充上不可见）
let bw = S * 0.21, bh = S * 0.34
let bx = S / 2 - bw / 2, by = S / 2 - bh / 2
let pts: [(CGFloat, CGFloat)] = [(0.62, 1.0), (0.14, 0.44), (0.46, 0.44),
                                 (0.36, 0.02), (0.88, 0.60), (0.56, 0.60)]
ctx.beginPath()
for (i, p) in pts.enumerated() {
    let pt = CGPoint(x: bx + p.0 * bw, y: by + p.1 * bh)
    if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
}
ctx.closePath()
ctx.setFillColor(cgc(0.07, 0.42, 0.20))
ctx.fillPath()

// 写出 PNG（ImageIO）
guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write("创建 PNG 输出失败\n".data(using: .utf8)!); exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
if !CGImageDestinationFinalize(dest) {
    FileHandle.standardError.write("PNG 写入失败\n".data(using: .utf8)!); exit(1)
}
print("icon base written: \(out)")
