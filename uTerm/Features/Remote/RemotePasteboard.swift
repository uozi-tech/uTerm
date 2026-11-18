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

nonisolated extension RemotePasteboard {
    /// 把一个文件按「文件」放进剪贴板（同在访达里拷贝）。沙盒里的进程放自己容器里的文件，别的 app 也读得到：
    /// 系统替读的一方开好访问权限（2026-11-17 探针：沙盒内外的进程都读到了，写的进程退出后也读得到）。
    static func write(file url: URL, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }
}

/// 远程桌面里主控端传来的文件（视频）落在哪。测试换成记录器。在连接队列上用。
nonisolated protocol RemotePastedFileReceiving: AnyObject, Sendable {
    /// 收一块。这个文件收齐了返回它的位置，否则 nil。
    func receive(_ chunk: RemoteDesktopPasteFileChunk) -> URL?
}

/// 边收边写进本进程临时目录里的文件（沙盒里就是容器的 tmp）：每个文件单独一个文件夹，名字用主控端给的。
///
/// 链路可靠有序，所以偏移必须正好接上；接不上就是对端出错，没收完的那个扔掉。收齐的文件留着——它在剪贴板里，
/// 用户过一会儿还可能再贴一次——超过一天的在下一次有文件来时清掉。
nonisolated final class RemotePastedFileReceiver: RemotePastedFileReceiving, @unchecked Sendable {
    static let keepSeconds: TimeInterval = 24 * 3600

    private struct Incoming {
        let id: UInt32
        let total: UInt64
        var written: UInt64
        let url: URL
        let handle: FileHandle
    }

    private let root: URL
    private let lock = NSLock()
    private var current: Incoming?

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("PastedFiles", isDirectory: true)) {
        self.root = root
    }

    deinit {
        if let current { Self.discard(current) }
    }

    func receive(_ chunk: RemoteDesktopPasteFileChunk) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if chunk.offset == 0 {
            // 新的一个文件顶掉没传完的那个。
            drop()
            guard chunk.total > 0, chunk.total <= RemoteDesktopPasteFileChunk.maxTotalBytes else { return nil }
            purgeOld()
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let url = folder.appendingPathComponent(Self.safeName(chunk.name))
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
                current = Incoming(id: chunk.pasteID, total: chunk.total, written: 0, url: url,
                                   handle: try FileHandle(forWritingTo: url))
            } catch {
                try? FileManager.default.removeItem(at: folder)
                return nil
            }
        }
        guard var incoming = current, chunk.pasteID == incoming.id, chunk.total == incoming.total,
              chunk.offset == incoming.written, incoming.written + UInt64(chunk.bytes.count) <= incoming.total,
              (try? incoming.handle.write(contentsOf: chunk.bytes)) != nil else {
            drop()
            return nil
        }
        incoming.written += UInt64(chunk.bytes.count)
        current = incoming
        guard incoming.written == incoming.total else { return nil }
        current = nil
        try? incoming.handle.close()
        return incoming.url
    }

    private func drop() {
        if let current { Self.discard(current) }
        current = nil
    }

    private static func discard(_ incoming: Incoming) {
        try? incoming.handle.close()
        try? FileManager.default.removeItem(at: incoming.url.deletingLastPathComponent())
    }

    /// 清掉放了超过一天的。
    private func purgeOld() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return }
        let cutoff = Date().addingTimeInterval(-Self.keepSeconds)
        for folder in folders {
            guard let modified = try? folder.resourceValues(forKeys: Set(keys)).contentModificationDate, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// 主控端给的文件名只取最后一段，去掉路径分隔符和控制字符；空的、全是点的给个默认名。
    static func safeName(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == ":" }).last.map(String.init) ?? ""
        let cleaned = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, cleaned.contains(where: { $0 != "." }) else { return "video.mov" }
        return String(cleaned.prefix(200))
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
