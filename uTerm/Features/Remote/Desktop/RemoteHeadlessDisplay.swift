import AppKit
import CoreGraphics
import Foundation
import ObjectiveC

/// 没接显示器的 Mac：系统给一块占位屏（厂商号 'unkn'、型号 'virt'），只有 1920×1080 的 1 倍模式，远程看过去
/// 文字又粗又糊。远程桌面开流前把它换成视网膜的：
///
/// - 占位屏自己带同点数的 2 倍模式时，用公开 API 换过去。
/// - 否则建一块 1920×1080 点、3840×2160 像素的虚拟屏（私有类 `CGVirtualDisplay`，沙盒里可用，调研 §16）。
///   它一出现，系统就撤掉占位屏，它成为唯一的主屏，窗口都在它上面。之后不随每次开流建拆，免得窗口来回搬；
///   接上真显示器时立刻拆掉，不然那块看不见的屏会成为扩展屏，窗口和光标都能跑进去。
///
/// 接着真显示器（或不止一块屏）时一律不碰。
///
/// 系统「屏幕共享」以高性能模式连着时，它会建一块独占的虚拟屏（厂商号 'aapl'、型号 0x1234）：别的显示器
/// （包括我们的虚拟屏）一律被断开，而那块屏 ScreenCaptureKit 又采不到。这时什么都做不了，只能如实告诉对方。
@MainActor
enum RemoteHeadlessDisplay {
    /// 'unkn'：无显示器时系统占位屏的厂商号；型号是 'virt'。
    nonisolated static let placeholderVendor: UInt32 = 0x756E_6B6E
    nonisolated static let placeholderModel: UInt32 = 0x7669_7274
    /// 系统「屏幕共享」建的独占虚拟屏：厂商号 'aapl'、型号 0x1234。
    nonisolated static let screenSharingVendor: UInt32 = 0x6161_706C
    nonisolated static let screenSharingModel: UInt32 = 0x1234
    /// 虚拟屏的点数，与占位屏一样，窗口位置不乱。
    nonisolated static let virtualSize = (width: 1920, height: 1080)

    nonisolated struct Mode: Equatable, Sendable {
        var width: Int
        var height: Int
        var pixelWidth: Int
        var pixelHeight: Int
        var usable = true
    }

    nonisolated enum Plan: Equatable, Sendable {
        case none
        /// 换成占位屏自己的 2 倍模式（`available` 里的下标）。
        case switchMode(Int)
        /// 建一块 2 倍虚拟屏。
        case createVirtual
    }

    /// 无显示器的 Mac 该怎么变清晰。只看唯一一块在线、非内建、当前 1 倍的占位屏。
    nonisolated static func plan(vendor: UInt32, model: UInt32, builtin: Bool, onlineDisplays: Int,
                                 current: Mode, available: [Mode]) -> Plan {
        guard onlineDisplays == 1, !builtin, vendor == placeholderVendor, model == placeholderModel,
              current.pixelWidth == current.width else { return .none }
        if let index = hiDPIUpgrade(current: current, available: available) { return .switchMode(index) }
        return .createVirtual
    }

    /// 现在是 1 倍时，同点数的 2 倍模式在 `available` 里的下标；已经是 2 倍或没有这样的模式时为 nil。
    nonisolated static func hiDPIUpgrade(current: Mode, available: [Mode]) -> Int? {
        guard current.pixelWidth == current.width else { return nil }
        return available.firstIndex { mode in
            mode.usable && mode.width == current.width && mode.height == current.height
                && mode.pixelWidth == 2 * mode.width && mode.pixelHeight == 2 * mode.height
        }
    }

    /// 系统「屏幕共享」的独占虚拟屏正在线：这时屏幕采集一定找不到显示器。
    nonisolated static func screenSharingHoldsDisplay() -> Bool {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).contains {
            CGDisplayVendorNumber($0) == screenSharingVendor && CGDisplayModelNumber($0) == screenSharingModel
        }
    }

    /// 建出来的虚拟屏。持有它，屏幕就在；放掉它，屏幕就撤。
    private static var virtualDisplay: NSObject?
    private static var virtualDisplayID: CGDirectDisplayID = 0
    private static var watchesReconfiguration = false

    /// 虚拟屏在线时出现了别的真显示器：该把虚拟屏拆掉。占位屏与「屏幕共享」的独占屏不算（前者在虚拟屏
    /// 在时不出现，后者会把虚拟屏暂时断开、走了还会接回来）。
    nonisolated static func realDisplayAppeared(ours: CGDirectDisplayID,
                                                online: [(id: CGDirectDisplayID, vendor: UInt32, model: UInt32)])
        -> Bool {
        online.contains { display in
            display.id != ours
                && !(display.vendor == placeholderVendor && display.model == placeholderModel)
                && !(display.vendor == screenSharingVendor && display.model == screenSharingModel)
        }
    }

    private static func onlineDisplays() -> [(id: CGDirectDisplayID, vendor: UInt32, model: UInt32)] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { ($0, CGDisplayVendorNumber($0), CGDisplayModelNumber($0)) }
    }

    /// 接上了真显示器：拆掉虚拟屏。
    private static func releaseIfRealDisplayAppeared() {
        guard virtualDisplay != nil, realDisplayAppeared(ours: virtualDisplayID, online: onlineDisplays()) else {
            return
        }
        virtualDisplay = nil
        virtualDisplayID = 0
        AppLogger.info("远程桌面：接上了显示器，拆掉 2 倍虚拟屏", category: RemoteLog.category)
    }

    private static func watchReconfiguration() {
        guard !watchesReconfiguration else { return }
        watchesReconfiguration = true
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard flags.contains(.addFlag) || flags.contains(.enabledFlag) else { return }
            // 回调在主线程的 run loop 上来，但不保证；拆屏放回主线程做。
            Task { @MainActor in RemoteHeadlessDisplay.releaseIfRealDisplayAppeared() }
        }, nil)
    }

    /// 主屏是 1 倍的占位屏时把它换成 2 倍的。建虚拟屏时等它成为主屏再返回（最多 3 秒）。
    static func ensureHiDPI() async {
        releaseIfRealDisplayAppeared()
        guard virtualDisplay == nil else { return }
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        let main = CGMainDisplayID()
        guard let current = CGDisplayCopyDisplayMode(main) else { return }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(main, options) as? [CGDisplayMode]) ?? []
        switch plan(vendor: CGDisplayVendorNumber(main), model: CGDisplayModelNumber(main),
                    builtin: CGDisplayIsBuiltin(main) != 0, onlineDisplays: Int(count),
                    current: mode(current), available: modes.map(mode)) {
        case .none:
            return
        case .switchMode(let index):
            switchMode(main, to: modes[index])
        case .createVirtual:
            await createVirtualDisplay()
        }
    }

    private static func switchMode(_ display: CGDirectDisplayID, to target: CGDisplayMode) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        guard CGConfigureDisplayWithDisplayMode(config, display, target, nil) == .success,
              CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            CGCancelDisplayConfiguration(config)
            AppLogger.info("远程桌面：没能把无显示器的占位屏换成 2 倍", category: RemoteLog.category)
            return
        }
        AppLogger.info("远程桌面：无显示器，占位屏换成 \(target.width)×\(target.height) 的 2 倍模式",
                       category: RemoteLog.category)
    }

    private static func createVirtualDisplay() async {
        guard let display = makeVirtualDisplay() else {
            AppLogger.info("远程桌面：无显示器，没能建 2 倍虚拟屏（系统不支持？）", category: RemoteLog.category)
            return
        }
        virtualDisplay = display
        let id = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
        virtualDisplayID = id
        watchReconfiguration()
        // 系统要一会儿才撤掉占位屏、把虚拟屏设成主屏；在那之前开流会采到旧屏。
        var waited = 0
        while CGMainDisplayID() != id, waited < 60 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        let ready = CGMainDisplayID() == id
        AppLogger.info("远程桌面：无显示器，建了 \(virtualSize.width)×\(virtualSize.height) 的 2 倍虚拟屏"
                       + (ready ? "" : "（还没成为主屏）"), category: RemoteLog.category)
    }

    /// 经 ObjC 运行时建 `CGVirtualDisplay`：描述符 → 显示器 → 设置（hiDPI + 一个模式）。任何一步对不上返回 nil。
    private static func makeVirtualDisplay() -> NSObject? {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type else { return nil }
        let width = virtualSize.width, height = virtualSize.height
        let descriptor = descriptorClass.init()
        descriptor.setValue(String(localized: "uTerm 远程显示器"), forKey: "name")
        descriptor.setValue(width * 2, forKey: "maxPixelsWide")
        descriptor.setValue(height * 2, forKey: "maxPixelsHigh")
        // 27 英寸 16:9 的物理尺寸：系统按它算像素密度，配合 2 倍模式显示为视网膜。
        descriptor.setValue(NSValue(size: NSSize(width: 597, height: 336)), forKey: "sizeInMillimeters")
        descriptor.setValue(0x7554, forKey: "vendorID")
        descriptor.setValue(0x0001, forKey: "productID")
        descriptor.setValue(1, forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        let alloc = NSSelectorFromString("alloc")
        let initDisplay = NSSelectorFromString("initWithDescriptor:")
        guard displayClass.instancesRespond(to: initDisplay),
              let allocated = (displayClass as AnyObject).perform(alloc)?.takeUnretainedValue(),
              // init 系列返回的是 +1：按 retained 接，放掉 `virtualDisplay` 时它才真的释放、屏幕才撤。
              let display = allocated.perform(initDisplay, with: descriptor)?.takeRetainedValue() as? NSObject
        else { return nil }

        let initMode = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let apply = NSSelectorFromString("applySettings:")
        guard let modeMethod = class_getInstanceMethod(modeClass, initMode),
              let applyMethod = class_getInstanceMethod(displayClass, apply),
              let modeAllocated = (modeClass as AnyObject).perform(alloc)?.takeUnretainedValue() else { return nil }
        typealias InitMode = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<AnyObject>
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let mode = unsafeBitCast(method_getImplementation(modeMethod), to: InitMode.self)(
            modeAllocated, initMode, UInt(width), UInt(height), 60).takeRetainedValue()
        let settings = settingsClass.init()
        settings.setValue(2, forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")
        guard unsafeBitCast(method_getImplementation(applyMethod), to: Apply.self)(display, apply, settings) else {
            return nil
        }
        return display
    }

    private static func mode(_ mode: CGDisplayMode) -> Mode {
        Mode(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
             usable: mode.isUsableForDesktopGUI())
    }
}
