import AppKit
import UniformTypeIdentifiers

/// 手机送来的内容写进 Mac 的系统剪贴板（远程桌面粘贴、本机终端贴图共用）。
/// `NSPasteboard` 可在任意线程用：桌面粘贴在连接队列上调，贴图在后端 actor 上调。
nonisolated enum RemotePasteboard {
    static func write(text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func write(_ image: TerminalImage, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        switch image.format {
        case .png:
            pasteboard.setData(image.data, forType: .png)
        case .jpeg:
            pasteboard.setData(image.data, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
            // 再放一份 PNG：Claude Code 等 CLI 按 PNG 读剪贴板（`the clipboard as «class PNGf»`），
            // 只有 JPEG 时它们读不到图。
            if let png = NSBitmapImageRep(data: image.data)?.representation(using: .png, properties: [:]) {
                pasteboard.setData(png, forType: .png)
            }
        }
    }
}
