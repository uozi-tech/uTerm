import AppKit

// 包内辅助程序的图标：uTerm 图标右下角加一个角标，让系统设置「辅助功能」等列表里它们和 uTerm 分得开。
//   远控进程 uTermRemoteHost.app：蓝底「手机 + 信号」（与设置侧栏「远程控制」同一个符号）
//   终端 holder uterm-holder.app：绿底终端符号
// 改了 uTerm 的图标就两个都重跑一遍：
//   swiftc -O scripts/render-helper-icon.swift -o /tmp/render-icon
//   /tmp/render-icon uTerm/Assets.xcassets/AppIcon.appiconset/icon_512@2x.png uTermRemoteHost/Assets.xcassets/AppIcon.appiconset
//   /tmp/render-icon uTerm/Assets.xcassets/AppIcon.appiconset/icon_512@2x.png /tmp/holder.iconset apple.terminal green iconset
//   iconutil -c icns /tmp/holder.iconset -o Config/uterm-holder/AppIcon.icns
let args = CommandLine.arguments
let base = NSImage(contentsOfFile: args[1])!
let out = URL(fileURLWithPath: args[2])
let symbolName = args.count > 3 ? args[3] : "iphone.radiowaves.left.and.right"
let green = args.count > 4 && args[4] == "green"
/// iconutil 要的文件名（icon_16x16.png）与资源目录的不同（icon_16.png）。
let iconsetNames = args.count > 5 && args[5] == "iconset"
let (top, bottom) = green
    ? (NSColor(srgbRed: 0.24, green: 0.78, blue: 0.47, alpha: 1), NSColor(srgbRed: 0.13, green: 0.64, blue: 0.36, alpha: 1))
    : (NSColor(srgbRed: 0.33, green: 0.58, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.20, green: 0.45, blue: 0.95, alpha: 1))

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    base.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    // 角标：右下角的圆，蓝色同图标里的光标，外圈一道深色描边与底图分开。
    let d = s * 0.40
    let rect = NSRect(x: s - d - s * 0.015, y: s * 0.015, width: d, height: d)
    NSColor(srgbRed: 0.10, green: 0.10, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(ovalIn: rect).fill()
    let inner = rect.insetBy(dx: d * 0.07, dy: d * 0.07)
    let gradient = NSGradient(starting: top, ending: bottom)!
    gradient.draw(in: NSBezierPath(ovalIn: inner), angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: inner.width * 0.40, weight: .semibold)
        .applying(.init(hierarchicalColor: .white))
    let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let sz = symbol.size
    symbol.draw(in: NSRect(x: inner.midX - sz.width / 2, y: inner.midY - sz.height / 2, width: sz.width, height: sz.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, size) in [("icon_16", 16), ("icon_16@2x", 32), ("icon_32", 32), ("icon_32@2x", 64), ("icon_128", 128),
                     ("icon_128@2x", 256), ("icon_256", 256), ("icon_256@2x", 512), ("icon_512", 512), ("icon_512@2x", 1024)] {
    var file = name
    if iconsetNames {
        let points = name.hasSuffix("@2x") ? size / 2 : size
        file = "icon_\(points)x\(points)" + (name.hasSuffix("@2x") ? "@2x" : "")
    }
    try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    try! render(size: size).write(to: out.appendingPathComponent("\(file).png"))
}
