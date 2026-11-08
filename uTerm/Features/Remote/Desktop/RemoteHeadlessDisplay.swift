import CoreGraphics
import Foundation

/// 没接显示器的 Mac：系统给一块占位屏，默认 1 倍（1920×1080 点 = 1920×1080 像素），远程看过去文字又粗又糊。
/// 这块占位屏其实带同点数的 2 倍模式（1920×1080 点、3840×2160 像素），远程桌面开流前换过去，画面就是视网膜的。
/// 用的是公开的显示器配置 API，和在「系统设置 › 显示器」里选一样，换过之后一直保持。
/// 接着真显示器（或不止一块屏）时一律不碰，免得改了用户自己的显示器。
@MainActor
enum RemoteHeadlessDisplay {
    /// 占位屏报的厂商号：'aapl'。真苹果显示器的 EDID 厂商号是 0x0610。
    nonisolated static let placeholderVendor: UInt32 = 0x6161_706C

    nonisolated struct Mode: Equatable, Sendable {
        var width: Int
        var height: Int
        var pixelWidth: Int
        var pixelHeight: Int
        var usable = true
    }

    /// 是不是无头 Mac 的占位屏：唯一一块在线的屏、不是内建屏、厂商号是占位屏的。
    nonisolated static func isPlaceholder(vendor: UInt32, builtin: Bool, onlineDisplays: Int) -> Bool {
        onlineDisplays == 1 && !builtin && vendor == placeholderVendor
    }

    /// 现在是 1 倍时，同点数的 2 倍模式在 `available` 里的下标；已经是 2 倍或没有这样的模式时为 nil。
    nonisolated static func hiDPIUpgrade(current: Mode, available: [Mode]) -> Int? {
        guard current.pixelWidth == current.width else { return nil }
        return available.firstIndex { mode in
            mode.usable && mode.width == current.width && mode.height == current.height
                && mode.pixelWidth == 2 * mode.width && mode.pixelHeight == 2 * mode.height
        }
    }

    /// 主屏是占位屏且还是 1 倍时换成 2 倍。返回是否换了。
    @discardableResult
    static func ensureHiDPI() -> Bool {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        let main = CGMainDisplayID()
        guard isPlaceholder(vendor: CGDisplayVendorNumber(main), builtin: CGDisplayIsBuiltin(main) != 0,
                            onlineDisplays: Int(count)),
              let current = CGDisplayCopyDisplayMode(main) else { return false }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(main, options) as? [CGDisplayMode]) ?? []
        guard let index = hiDPIUpgrade(current: mode(current), available: modes.map(mode)) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, main, modes[index], nil) == .success,
              CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            CGCancelDisplayConfiguration(config)
            AppLogger.info("远程桌面：没能把无显示器的占位屏换成 2 倍", category: RemoteLog.category)
            return false
        }
        AppLogger.info("远程桌面：无显示器，占位屏换成 \(current.width)×\(current.height) 的 2 倍模式",
                       category: RemoteLog.category)
        return true
    }

    private static func mode(_ mode: CGDisplayMode) -> Mode {
        Mode(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
             usable: mode.isUsableForDesktopGUI())
    }
}
