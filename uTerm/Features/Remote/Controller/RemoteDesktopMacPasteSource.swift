import AppKit
import UniformTypeIdentifiers

/// Mac 控 Mac 的剪贴板：本机剪贴板 → 粘贴到那台 Mac（`RemoteDesktopPaste`），那台 Mac 拷贝的文字 → 本机剪贴板。
///
/// 只认图片与文字。拷贝的是文件（Finder 里 ⌘C）时不接管 ⌘V，照常把按键发过去：粘出来的是那台 Mac
/// 自己剪贴板里的东西。怎么打包（太大的图怎么压）与手机端共用 `RemoteDesktopPasteEncoding`。
nonisolated enum RemoteDesktopMacPasteSource {
    /// 剪贴板里能粘过去的内容。没有图片也没有文字（或拷贝的是文件）返回 nil。
    @MainActor
    static func read(_ board: NSPasteboard = .general) async throws -> RemoteDesktopPaste? {
        let types = board.types ?? []
        if types.contains(.fileURL) { return nil }
        if let data = board.data(forType: .png) ?? board.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
            ?? board.data(forType: .tiff) {
            return try await RemoteDesktopPasteEncoding.image(data: data)
        }
        if let text = board.string(forType: .string), !text.isEmpty {
            return try RemoteDesktopPasteEncoding.text(text)
        }
        return nil
    }

    /// 那台 Mac 上拷贝的文字放进本机剪贴板。返回给用户看的一句提示。
    @MainActor
    @discardableResult
    static func receive(_ content: RemoteDesktopClipboard, into board: NSPasteboard = .general) -> String {
        if case .text(let text) = content {
            board.clearContents()
            board.setString(text, forType: .string)
        }
        return RemoteDesktopPasteEncoding.receivedNote(content, source: String(localized: "那台 Mac"),
                                                       here: String(localized: "这台 Mac"))
    }
}
