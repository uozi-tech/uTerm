import AppKit

/// 被控的 Mac 上此刻的系统光标（不管是哪个 app 设的）：给主控端当本机光标用。
///
/// `NSCursor.currentSystem` 每次都给一个新对象，不能按对象比；指纹取最小那张位图的像素加热点，
/// 一次不到 1 ms。图取 2 倍那张（没有就最大的）编成 PNG，只在指纹变了时做。
@MainActor
enum RemoteSystemCursor {
    static func signature() -> Int? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        var hasher = Hasher()
        hasher.combine(cursor.hotSpot.x)
        hasher.combine(cursor.hotSpot.y)
        hasher.combine(cursor.image.size.width)
        hasher.combine(cursor.image.size.height)
        if let rep = cursor.image.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .min(by: { $0.pixelsWide < $1.pixelsWide }),
            let data = rep.bitmapData {
            hasher.combine(Data(bytes: data, count: rep.bytesPerRow * rep.pixelsHigh))
        } else if let tiff = cursor.image.tiffRepresentation {
            hasher.combine(tiff)
        }
        return hasher.finalize()
    }

    static func image() -> RemoteDesktopCursorImage? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        let size = cursor.image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let bitmaps = cursor.image.representations.compactMap { $0 as? NSBitmapImageRep }
        let target = bitmaps.first { $0.pixelsWide == Int(size.width * 2) } ?? bitmaps.max { $0.pixelsWide < $1.pixelsWide }
        guard let cgImage = target?.cgImage ?? cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        guard let png else { return nil }
        return RemoteDesktopCursorImage(png: png, width: size.width, height: size.height,
                                        hotX: cursor.hotSpot.x, hotY: cursor.hotSpot.y)
    }
}
