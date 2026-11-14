import AppKit

// 远控进程（uTermRemoteHost.app）的图标：uTerm 图标右下角加一个「手机 + 信号」角标（与设置侧栏「远程控制」同一个符号），
// 让系统设置「辅助功能」等列表里它和 uTerm、uterm-holder 分得开。改了 uTerm 的图标就重跑一遍：
//   swiftc -O scripts/render-remote-host-icon.swift -o /tmp/render-icon
//   /tmp/render-icon uTerm/Assets.xcassets/AppIcon.appiconset/icon_512@2x.png uTermRemoteHost/Assets.xcassets/AppIcon.appiconset
let args = CommandLine.arguments
let base = NSImage(contentsOfFile: args[1])!
let out = URL(fileURLWithPath: args[2])

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
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.33, green: 0.58, blue: 1.0, alpha: 1),
                              ending: NSColor(srgbRed: 0.20, green: 0.45, blue: 0.95, alpha: 1))!
    gradient.draw(in: NSBezierPath(ovalIn: inner), angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: inner.width * 0.40, weight: .semibold)
        .applying(.init(hierarchicalColor: .white))
    let symbol = NSImage(systemSymbolName: "iphone.radiowaves.left.and.right", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let sz = symbol.size
    symbol.draw(in: NSRect(x: inner.midX - sz.width / 2, y: inner.midY - sz.height / 2, width: sz.width, height: sz.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, size) in [("icon_16", 16), ("icon_16@2x", 32), ("icon_32", 32), ("icon_32@2x", 64), ("icon_128", 128),
                     ("icon_128@2x", 256), ("icon_256", 256), ("icon_256@2x", 512), ("icon_512", 512), ("icon_512@2x", 1024)] {
    try! render(size: size).write(to: out.appendingPathComponent("\(name).png"))
}
