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

/// 远程桌面回传剪贴板时读的 Mac 系统剪贴板。
///
/// 读它可能卡很久：通用剪贴板（接力）来的内容还在别的设备上，一读系统就要去取，图片要几十秒，取不到要等到
/// 超时（2026-11-17：Duo 上拷了一张图，Mac 这边 30 秒后才报取不到）。所以调用方不能在连接队列上读
///（见 `RemoteDesktopStreamer` 的剪贴板回传），这里也尽量不去碰接力来的内容。
nonisolated final class RemoteSystemClipboard: RemoteDesktopClipboardSource {
    var changeCount: Int { NSPasteboard.general.changeCount }

    func text() -> String? {
        let pasteboard = NSPasteboard.general
        guard let types = pasteboard.types, Self.shouldReadText(types: types.map(\.rawValue)) else { return nil }
        return pasteboard.string(forType: .string)
    }

    /// 系统给接力来的内容加的标记类型。
    static let remoteClipboardType = "com.apple.is-remote-clipboard"

    /// 值不值得去读文字：接力来的不读（内容在别的设备上，多半就是主控端自己刚拷的，读它只会白等）；
    /// 没有文字类型的不读（图片、文件：读文字会让系统去试各种转换，接力来的图片因此被整张取过来）。
    static func shouldReadText(types: [String]) -> Bool {
        !types.contains(remoteClipboardType) && types.contains(NSPasteboard.PasteboardType.string.rawValue)
    }
}
