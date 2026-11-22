import CoreGraphics
import Foundation
import ImageIO

/// 远程主机上的图（图片预览、Markdown 里引用的图）解码之前先看声明的像素尺寸。两端共用。
///
/// 文件大小有上限不等于解出来小：一张 1.5 MB 的全零 PNG 就能是 2 万 × 2 万像素（实测 ImageIO 照实报出尺寸），整张
/// 解码要 1.6 GB，直接把 App 撑死（iOS 被系统杀掉）。图来自主机，内容不可信，所以超过 `maxPixels` 的一律不解；
/// 读不出尺寸的（只有文件头、截断的）也不解。
/// SVG 不归这里（Mac 用无网络权限的 WebView 按限定尺寸拍快照，`MarkdownImageDecoder`）。
nonisolated enum RemoteImageGuard {
    /// 5000 万像素：8K 截图（7680 × 4320 ≈ 3300 万）放得下，解码约 200 MB。
    static let maxPixels = 50_000_000

    /// 声明的像素尺寸；不是能识别的位图、读不出尺寸时为 nil。
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// 可以解码：读得出尺寸，且像素总数不超过上限。
    static func admits(_ data: Data, maxPixels: Int = RemoteImageGuard.maxPixels) -> Bool {
        guard let size = pixelSize(of: data) else { return false }
        return size.width * size.height <= Double(maxPixels)
    }

    /// 把声明的尺寸缩到长边不超过 `maxLongEdge`、面积不超过 `maxPixels`，保持宽高比；不放大。给按声明尺寸画的矢量图用
    /// （Mac 的 SVG 快照）。尺寸不合法时为 `.zero`。
    static func fittedSize(_ declared: CGSize, maxLongEdge: CGFloat) -> CGSize {
        guard declared.width.isFinite, declared.height.isFinite, declared.width > 0, declared.height > 0 else {
            return .zero
        }
        let byEdge = maxLongEdge / max(declared.width, declared.height)
        let byArea = (CGFloat(maxPixels) / (declared.width * declared.height)).squareRoot()
        let scale = min(1, byEdge, byArea)
        return CGSize(width: max(1, (declared.width * scale).rounded()),
                      height: max(1, (declared.height * scale).rounded()))
    }

    /// 解码并缩到长边不超过 `maxPixelSize`（按 EXIF 方向转正）。不放行（`admits`）或解不开返回 nil。
    static func decode(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard admits(data), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
