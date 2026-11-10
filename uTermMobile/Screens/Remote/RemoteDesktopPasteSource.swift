import UIKit

/// 远程桌面「粘贴到 Mac」与终端「贴图片」的内容来源：手机剪贴板里的图片 / 文字，或相册里选的一张图。
/// 怎么打包（太大的图怎么压、HEIC 转 JPEG）与 Mac 主控端共用 `RemoteDesktopPasteEncoding`。
nonisolated enum RemoteDesktopPasteSource {
    /// 读手机剪贴板，图片优先（同时有图和字时多半是在复制图片）。第一次读时系统会问「允许粘贴」。
    @MainActor
    static func clipboard() async throws -> RemoteDesktopPaste {
        let board = UIPasteboard.general
        if board.hasImages {
            // 先拿原始数据：原本就是 PNG / JPEG 时不用重新编码。
            if let data = board.data(forPasteboardType: "public.png") ?? board.data(forPasteboardType: "public.jpeg")
                ?? board.image.flatMap(Self.uprightPNG) {
                return try await RemoteDesktopPasteEncoding.image(data: data)
            }
        }
        if board.hasStrings, let text = board.string, !text.isEmpty {
            return try RemoteDesktopPasteEncoding.text(text)
        }
        throw RemoteDesktopPasteEncoding.Failure.empty
    }

    /// 终端贴图：只要剪贴板里的图片。
    @MainActor
    static func clipboardImage() async throws -> TerminalImage {
        guard UIPasteboard.general.hasImages, let image = try await clipboard().terminalImage else {
            throw RemoteDesktopPasteEncoding.Failure.noImage
        }
        return image
    }

    /// 终端贴图：相册里选的一张。
    static func terminalImage(data: Data) async throws -> TerminalImage {
        guard let image = try await RemoteDesktopPasteEncoding.image(data: data).terminalImage else {
            throw RemoteDesktopPasteEncoding.Failure.unreadableImage
        }
        return image
    }

    /// 剪贴板里只有 `UIImage`、没有原始数据时：按它的方向画正再出 PNG（PNG 不带方向，直接 `pngData()` 会横着）。
    private static func uprightPNG(_ image: UIImage) -> Data? {
        guard image.imageOrientation != .up else { return image.pngData() }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

extension RemoteDesktopPaste {
    /// 图片内容换成终端贴图用的形状；文字为 nil。
    nonisolated var terminalImage: TerminalImage? {
        switch self {
        case .png(let data): return TerminalImage(format: .png, data: data)
        case .jpeg(let data): return TerminalImage(format: .jpeg, data: data)
        case .text: return nil
        }
    }
}
