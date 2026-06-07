// Clip an app icon to a rounded rectangle and stamp it onto a file/volume.
//
// The bundle's AppIcon.icns is an opaque, full-bleed white tile. Here each
// rendition is redrawn into the macOS icon grid — the icon body fills 824/1024
// of the canvas with a 100/1024 gutter and a 185.4/824 corner radius (Apple's
// macOS app-icon template) — then NSWorkspace.setIcon writes it as the custom
// icon (also setting the custom-icon flag, which Finder honors).
//
// Usage: swift set-volume-icon.swift <icns-path> <target-path>

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("Usage: set-volume-icon.swift <icns-path> <target-path>\n".utf8))
    exit(1)
}

guard let source = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("cannot load icon: \(args[1])\n".utf8))
    exit(1)
}

// Apple's macOS app-icon template, relative to the full canvas.
let bodyRatio: CGFloat = 824.0 / 1024.0    // icon body fills 824 of 1024
let cornerRatio: CGFloat = 185.4 / 824.0   // corner radius relative to the body
let rounded = NSImage(size: NSSize(width: 512, height: 512))

for px in [16, 32, 64, 128, 256, 512] {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        FileHandle.standardError.write(Data("failed to allocate \(px)px bitmap\n".utf8))
        exit(1)
    }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let body = (CGFloat(px) * bodyRatio).rounded()
    let inset = (CGFloat(px) - body) / 2.0
    let rect = NSRect(x: inset, y: inset, width: body, height: body)
    let radius = body * cornerRatio
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    source.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    rounded.addRepresentation(rep)
}

if !NSWorkspace.shared.setIcon(rounded, forFile: args[2], options: []) {
    FileHandle.standardError.write(Data("setIcon failed for: \(args[2])\n".utf8))
    exit(1)
}
