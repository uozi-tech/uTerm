import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Mac 控 Mac 的剪贴板：本机剪贴板 → 粘贴到那台 Mac（`RemoteDesktopPaste`），那台 Mac 拷贝的文字 → 本机剪贴板。
///
/// 只认图片与文字。拷贝的是文件（Finder 里 ⌘C）时不接管 ⌘V，照常把按键发过去：粘出来的是那台 Mac
/// 自己剪贴板里的东西。图片超过一条消息的上限时在后台转 JPEG、逐级降质量再缩边长（与手机端同一规则）。
nonisolated enum RemoteDesktopMacPasteSource {
    enum Failure: LocalizedError, Equatable {
        case unreadableImage
        case textTooLong

        var errorDescription: String? {
            switch self {
            case .unreadableImage: return String(localized: "这张图片读不出来")
            case .textTooLong: return String(localized: "文字太长，一次最多粘贴约 3.8 MB")
            }
        }
    }

    /// 剪贴板里能粘过去的内容。没有图片也没有文字（或拷贝的是文件）返回 nil。
    @MainActor
    static func read(_ board: NSPasteboard = .general) async throws -> RemoteDesktopPaste? {
        let types = board.types ?? []
        if types.contains(.fileURL) { return nil }
        if let data = board.data(forType: .png) ?? board.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
            ?? board.data(forType: .tiff) {
            return try await image(data: data)
        }
        if let text = board.string(forType: .string), !text.isEmpty {
            return try self.text(text)
        }
        return nil
    }

    static func text(_ text: String) throws -> RemoteDesktopPaste {
        guard text.utf8.count <= RemoteDesktopPaste.maxContentBytes else { throw Failure.textTooLong }
        return .text(text)
    }

    /// PNG / JPEG 装得下就原样发（截图里的字保持锐利），否则（TIFF、太大）重新编码。
    static func image(data: Data, limit: Int = RemoteDesktopPaste.maxContentBytes) async throws -> RemoteDesktopPaste {
        if data.count <= limit {
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png(data) }
            if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg(data) }
        }
        return try await Task.detached(priority: .userInitiated) { try encode(data, limit: limit) }.value
    }

    private static func encode(_ data: Data, limit: Int) throws -> RemoteDesktopPaste {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unreadableImage }
        if let png = encoded(full, type: .png, quality: nil), png.count <= limit { return .png(png) }
        var edge = CGFloat(max(full.width, full.height))
        for _ in 0..<6 {
            let image = edge >= CGFloat(max(full.width, full.height)) ? full : thumbnail(source, maxPixel: edge) ?? full
            for quality in [0.9, 0.8, 0.65] {
                if let jpeg = encoded(image, type: .jpeg, quality: quality), jpeg.count <= limit { return .jpeg(jpeg) }
            }
            edge = (edge * 0.75).rounded()
        }
        throw Failure.unreadableImage
    }

    private static func thumbnail(_ source: CGImageSource, maxPixel: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encoded(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// 那台 Mac 上拷贝的文字放进本机剪贴板。返回给用户看的一句提示。
    @MainActor
    @discardableResult
    static func receive(_ content: RemoteDesktopClipboard, into board: NSPasteboard = .general) -> String {
        switch content {
        case .text(let text):
            board.clearContents()
            board.setString(text, forType: .string)
            return String(localized: "已拷贝到这台 Mac")
        case .tooLarge(let bytes):
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return String(localized: "那台 Mac 上拷贝的内容太大（\(size)），没有拷贝过来")
        }
    }
}
