import UIKit

/// 远程桌面「粘贴到 Mac」与终端「贴图片」的内容来源：手机剪贴板里的图片 / 文字，或相册里选的一张图。
///
/// 一条粘贴消息要放进一帧（`RemoteDesktopPaste.maxContentBytes`），所以图片在手机上先压好：
/// PNG / JPEG 原样能装下就原样发（截图里的字保持锐利）；装不下或是 HEIC 等格式（不少 Mac app
/// 从剪贴板读不了 HEIC）就转 JPEG，质量逐级降，还不够再逐级缩小边长。全程在后台线程做。
nonisolated enum RemoteDesktopPasteSource {
    enum Failure: LocalizedError {
        case empty
        case noImage
        case unreadableImage
        case textTooLong

        var errorDescription: String? {
            switch self {
            case .empty: return "剪贴板里没有图片或文字"
            case .noImage: return "剪贴板里没有图片"
            case .unreadableImage: return "这张图片读不出来"
            case .textTooLong: return "文字太长，一次最多粘贴约 3.8 MB"
            }
        }
    }

    /// 读手机剪贴板，图片优先（同时有图和字时多半是在复制图片）。第一次读时系统会问「允许粘贴」。
    @MainActor
    static func clipboard() async throws -> RemoteDesktopPaste {
        let board = UIPasteboard.general
        if board.hasImages {
            // 先拿原始数据：原本就是 PNG / JPEG 时不用重新编码。
            if let data = board.data(forPasteboardType: "public.png") ?? board.data(forPasteboardType: "public.jpeg") {
                return try await image(data: data)
            }
            if let image = board.image { return try await encode(image) }
        }
        if board.hasStrings, let text = board.string, !text.isEmpty {
            guard text.utf8.count <= RemoteDesktopPaste.maxContentBytes else { throw Failure.textTooLong }
            return .text(text)
        }
        throw Failure.empty
    }

    /// 终端贴图：只要剪贴板里的图片。
    @MainActor
    static func clipboardImage() async throws -> TerminalImage {
        guard UIPasteboard.general.hasImages, let image = try await clipboard().terminalImage else {
            throw Failure.noImage
        }
        return image
    }

    /// 终端贴图：相册里选的一张。
    static func terminalImage(data: Data) async throws -> TerminalImage {
        guard let image = try await image(data: data).terminalImage else { throw Failure.unreadableImage }
        return image
    }

    /// 一张图片的原始数据（相册 / 剪贴板）。
    static func image(data: Data) async throws -> RemoteDesktopPaste {
        if data.count <= RemoteDesktopPaste.maxContentBytes {
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png(data) }
            if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg(data) }
        }
        guard let image = UIImage(data: data) else { throw Failure.unreadableImage }
        return try await encode(image)
    }

    private static func encode(_ image: UIImage) async throws -> RemoteDesktopPaste {
        try await Task.detached(priority: .userInitiated) {
            let limit = RemoteDesktopPaste.maxContentBytes
            if let png = image.pngData(), png.count <= limit { return .png(png) }
            var current = image
            for _ in 0..<6 {
                for quality in [0.9, 0.8, 0.65] {
                    if let jpeg = current.jpegData(compressionQuality: quality), jpeg.count <= limit {
                        return .jpeg(jpeg)
                    }
                }
                current = current.scaled(by: 0.75)
            }
            throw Failure.unreadableImage
        }.value
    }
}

private extension UIImage {
    nonisolated func scaled(by factor: CGFloat) -> UIImage {
        let target = CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
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
