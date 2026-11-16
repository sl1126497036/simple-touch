// 生成 SimpleTouch 图标（1024x1024 PNG）
// 用法: swift tools/makeicon.swift <输出路径>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon_1024.png"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: Int(S), height: Int(S),
    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("无法创建绘图上下文") }

ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// ---- 背景圆角方形 ----
let margin: CGFloat = 100
let rect = CGRect(x: margin, y: margin, width: S - margin * 2, height: S - margin * 2)
let radius: CGFloat = 186
let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

let gradient = CGGradient(colorsSpace: cs, colors: [
    rgb(74, 108, 245), rgb(151, 68, 214)
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.minX, y: rect.maxY),
    end: CGPoint(x: rect.maxX, y: rect.minY),
    options: []
)

// 背景高光
let glow = CGGradient(colorsSpace: cs, colors: [
    rgb(255, 255, 255, 0.20), rgb(255, 255, 255, 0)
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: S * 0.32, y: S * 0.78), startRadius: 0,
    endCenter: CGPoint(x: S * 0.32, y: S * 0.78), endRadius: S * 0.55,
    options: []
)
ctx.restoreGState()

// ---- 鼠标轮廓 ----
let mw: CGFloat = 466
let mh: CGFloat = 606
let mx = (S - mw) / 2
let my = (S - mh) / 2 - 10
let mouseRect = CGRect(x: mx, y: my, width: mw, height: mh)
let mousePath = CGPath(roundedRect: mouseRect, cornerWidth: mw / 2, cornerHeight: mw / 2, transform: nil)

ctx.setStrokeColor(rgb(255, 255, 255, 0.96))
ctx.setLineWidth(21)
ctx.setLineJoin(.round)
ctx.addPath(mousePath)
ctx.strokePath()

// 顶部分隔弧线的直线段
let dividerY = my + mh * 0.545
ctx.setLineWidth(14)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: mx + 36, y: dividerY))
ctx.addLine(to: CGPoint(x: mx + mw - 36, y: dividerY))
ctx.strokePath()

// ---- 三个触点 ----
let dotR: CGFloat = 38
let dotY = my + mh * 0.715
for dx in [-116.0, 0.0, 116.0] {
    let center = CGPoint(x: S / 2 + CGFloat(dx), y: dotY)
    // 外发光
    let dotGlow = CGGradient(colorsSpace: cs, colors: [
        rgb(255, 255, 255, 0.55), rgb(255, 255, 255, 0)
    ] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.drawRadialGradient(
        dotGlow,
        startCenter: center, startRadius: 0,
        endCenter: center, endRadius: dotR * 3.2,
        options: []
    )
    ctx.restoreGState()

    ctx.setFillColor(rgb(255, 255, 255))
    ctx.fillEllipse(in: CGRect(
        x: center.x - dotR, y: center.y - dotR,
        width: dotR * 2, height: dotR * 2
    ))
}

// ---- 输出 ----
guard let image = ctx.makeImage() else { fatalError("渲染失败") }
let url = URL(fileURLWithPath: outPath)
guard let dest = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil
) else { fatalError("无法写入") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("写入失败") }
print("已生成: \(outPath)")
