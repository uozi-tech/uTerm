import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 「粘贴到 Mac」的内容怎么打包（手机与 Mac 主控端共用；读剪贴板 / 相册各端自己做）。
///
/// 一条粘贴消息要放进一帧（`RemoteDesktopPaste.maxContentBytes`）。PNG / JPEG 原样装得下就原样发（截图里的字
/// 保持锐利）；装不下或是 HEIC、TIFF 等格式（不少 Mac app 从剪贴板读不了 HEIC）就重新编码：先试 PNG，再转 JPEG，
/// 质量逐级降，还不够再逐级缩小边长。重新编码时按 EXIF 方向转正：竖拍的照片不能横着到那台 Mac 上。
nonisolated enum RemoteDesktopPasteEncoding {
    enum Failure: LocalizedError, Equatable {
        case empty
        case noImage
        case unreadableImage
        case textTooLong

        var errorDescription: String? {
            switch self {
            case .empty: return String(localized: "剪贴板里没有图片或文字")
            case .noImage: return String(localized: "剪贴板里没有图片")
            case .unreadableImage: return String(localized: "无法读取这张图片")
            case .textTooLong: return String(localized: "文字太长，一次最多粘贴约 3.8 MB")
            }
        }
    }

    static func text(_ text: String, limit: Int = RemoteDesktopPaste.maxContentBytes) throws -> RemoteDesktopPaste {
        guard text.utf8.count <= limit else { throw Failure.textTooLong }
        return .text(text)
    }

    /// 一张图片的原始数据（剪贴板 / 相册）。重新编码在后台线程做。
    static func image(data: Data, limit: Int = RemoteDesktopPaste.maxContentBytes) async throws -> RemoteDesktopPaste {
        if data.count <= limit {
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png(data) }
            if data.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg(data) }
        }
        PasteProgressReporter.report(PasteProgress(.encoding))
        return try await Task.detached(priority: .userInitiated) { try encode(data, limit: limit) }.value
    }

    static func encode(_ data: Data, limit: Int) throws -> RemoteDesktopPaste {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw Failure.unreadableImage
        }
        let longEdge = pixelLongEdge(source)
        // 全尺寸也走缩略图接口：只有它按 EXIF 方向转正（`CGImageSourceCreateImageAtIndex` 不转）。
        guard let full = longEdge.flatMap({ oriented(source, maxPixel: $0) })
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unreadableImage }
        if let png = encoded(full, type: .png, quality: nil), png.count <= limit { return .png(png) }
        let fullEdge = CGFloat(max(full.width, full.height))
        var edge = fullEdge
        for _ in 0..<6 {
            let image = edge >= fullEdge ? full : oriented(source, maxPixel: edge) ?? full
            for quality in [0.9, 0.8, 0.65] {
                if let jpeg = encoded(image, type: .jpeg, quality: quality), jpeg.count <= limit { return .jpeg(jpeg) }
            }
            edge = (edge * 0.75).rounded()
        }
        throw Failure.unreadableImage
    }

    private static func pixelLongEdge(_ source: CGImageSource) -> CGFloat? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        return CGFloat(max(width, height))
    }

    private static func oriented(_ source: CGImageSource, maxPixel: CGFloat) -> CGImage? {
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

    /// 粘过去之后给用户看的一句提示。
    static func sentNote(_ content: RemoteDesktopPaste) -> String {
        switch content {
        case .text: return String(localized: "已把文字粘贴到 Mac")
        case .png, .jpeg: return String(localized: "已把图片粘贴到 Mac")
        }
    }

    /// 那台 Mac 上拷贝的内容回传过来之后给用户看的一句提示。`here`：拷贝到了哪里（「手机」「这台 Mac」）；
    /// `source`：被看的那台怎么称呼（「Mac」「那台 Mac」）。
    static func receivedNote(_ content: RemoteDesktopClipboard, source: String, here: String) -> String {
        switch content {
        case .text:
            return String(localized: "已拷贝到\(here)")
        case .tooLarge(let bytes):
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return String(localized: "\(source) 上拷贝的内容太大（\(size)），没有拷贝到\(here)")
        }
    }
}
