// FingerPath 图标生成脚本：swift render_icon.swift <输出.png>
// 深色底 + 一排按手指配色的起始键（F / J 加粗框和凸点）+ 一条从 F 弯到上排 R 的虚线「手指路线」。
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
// Okabe-Ito 色弱友好配色：小指紫红、无名指深绿、中指天蓝、食指黄
let pinky = color(0.80, 0.47, 0.65), ring = color(0.0, 0.62, 0.45)
let middle = color(0.34, 0.71, 0.91), index = color(0.94, 0.89, 0.26)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
color(0.12, 0.13, 0.17).setFill()
bodyPath.fill()
ctx.restoreGState()
ctx.saveGState()
bodyPath.addClip()
NSGradient(starting: color(0.20, 0.22, 0.28), ending: color(0.09, 0.10, 0.13))!.draw(in: body, angle: -90)
ctx.restoreGState()

// 一排起始键 A S D F | J K L ;
let keyW: CGFloat = 78, keyH: CGFloat = 96, gapX: CGFloat = 12, handGap: CGFloat = 40
let colors = [pinky, ring, middle, index, index, middle, ring, pinky]
let totalW = keyW * 8 + gapX * 6 + handGap
var x = 512 - totalW / 2
let baseY: CGFloat = 330
var fKey = CGRect.zero
for i in 0..<8 {
    let rect = CGRect(x: x, y: baseY, width: keyW, height: keyH)
    let key = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
    colors[i].setFill()
    key.fill()
    if i == 3 || i == 4 {
        // F / J：加粗白框 + 凸点
        NSColor.white.setStroke()
        key.lineWidth = 9
        key.stroke()
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: CGRect(x: rect.midX - 17, y: rect.minY + 18, width: 34, height: 9),
                     xRadius: 4.5, yRadius: 4.5).fill()
        if i == 3 { fKey = rect }
    }
    x += keyW + (i == 3 ? handGap : gapX)
}

// 上排目标键 R（食指往左上够）
let rKey = CGRect(x: fKey.minX - 46, y: 610, width: keyW, height: keyH)
let r = NSBezierPath(roundedRect: rKey, xRadius: 18, yRadius: 18)
index.withAlphaComponent(0.35).setFill()
r.fill()
index.setStroke()
r.lineWidth = 6
r.stroke()

// 手指路线：从 F 弯到 R 的虚线 + 箭头
let path = NSBezierPath()
let start = CGPoint(x: fKey.midX, y: fKey.maxY + 22)
let end = CGPoint(x: rKey.midX + 6, y: rKey.minY - 26)
path.move(to: start)
path.curve(to: end, controlPoint1: CGPoint(x: start.x + 120, y: start.y + 90),
           controlPoint2: CGPoint(x: end.x + 110, y: end.y - 60))
NSColor.white.setStroke()
path.lineWidth = 14
path.lineCapStyle = .round
path.setLineDash([6, 30], count: 2, phase: 0)
path.stroke()
// 箭头
let arrow = NSBezierPath()
arrow.move(to: CGPoint(x: end.x - 30, y: end.y - 18))
arrow.line(to: end)
arrow.line(to: CGPoint(x: end.x + 26, y: end.y - 26))
arrow.lineWidth = 14
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.stroke()

// 手指编号 1…10（起始键下方小字）
let numbers = ["1", "2", "3", "4", "7", "8", "9", "10"]
x = 512 - totalW / 2
for i in 0..<8 {
    let text = NSAttributedString(string: numbers[i], attributes: [
        .font: NSFont.systemFont(ofSize: 40, weight: .heavy),
        .foregroundColor: NSColor.white.withAlphaComponent(0.85),
    ])
    let s = text.size()
    text.draw(at: CGPoint(x: x + keyW / 2 - s.width / 2, y: baseY - 72))
    x += keyW + (i == 3 ? handGap : gapX)
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
