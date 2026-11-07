import Foundation
#if os(macOS)
import IOKit
#endif

/// 本机在远控里是哪类设备。只作展示（列表图标、文案），信任与能力都不看它。
nonisolated enum RemoteDevicePlatform: String, Sendable {
    case mac
    case mobile

    static var current: RemoteDevicePlatform {
        #if os(macOS)
        .mac
        #else
        .mobile
        #endif
    }
}

/// 本机机型的商品名（「iPhone 16 Pro」「iPad Air (13-inch) (M3)」），给远控 / 局域网同步对端看的。
///
/// iOS 16 起 `UIDevice.current.name` 不再返回用户起的名字，只回「iPhone」/「iPad」（要拿真名须向苹果申请
/// `com.apple.developer.device-information.user-assigned-device-name`）。几台手机在 Mac 上全叫「iPhone」没法区分，
/// 社区通行的退路是按硬件标识（`utsname.machine`，如 `iPhone17,1`）查商品名，也就是 DeviceKit 的做法。
/// 表照抄 DeviceKit 的 `Device.generated.swift`，只留 iOS 18（本 App 最低版本）装得上的机型；
/// 新机型发布后补表即可，查不到的返回 nil、调用方退回系统给的通用名，不会显示错的型号。
nonisolated enum RemoteDeviceModel {
    /// 本机的商品名；查不到的新机型返回 nil。
    static func current() -> String? {
        #if canImport(UIKit)
        marketingName(for: hardwareIdentifier())
        #elseif os(macOS)
        macProductName()
        #else
        nil
        #endif
    }

    #if os(macOS)
    /// Mac 的商品名（「MacBook Pro (14-inch, M5 Pro)」）：Apple 芯片的设备树里直接有，不用查表。
    /// Intel Mac 没有这个节点，返回 nil。
    private static func macProductName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
    #endif

    static func marketingName(for identifier: String) -> String? {
        table[identifier]
    }

    #if canImport(UIKit)
    /// 真机读 `utsname.machine`；模拟器读到的是 `arm64`，真正模拟的机型在环境变量里。
    private static func hardwareIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
    #endif

    private static let table: [String: String] = {
        var table: [String: String] = [:]
        for (identifiers, name) in entries {
            for identifier in identifiers { table[identifier] = name }
        }
        return table
    }()

    private static let entries: [([String], String)] = [
        // iPhone
        (["iPhone19,3", "iPhone19,7"], "iPhone 18 Pro Max"),
        (["iPhone19,2"], "iPhone 18 Pro"),
        (["iPhone19,4"], "iPhone Duo"),
        (["iPhone18,5"], "iPhone 17e"),
        (["iPhone18,4"], "iPhone Air"),
        (["iPhone18,2"], "iPhone 17 Pro Max"),
        (["iPhone18,1"], "iPhone 17 Pro"),
        (["iPhone18,3"], "iPhone 17"),
        (["iPhone17,5"], "iPhone 16e"),
        (["iPhone17,2"], "iPhone 16 Pro Max"),
        (["iPhone17,1"], "iPhone 16 Pro"),
        (["iPhone17,4"], "iPhone 16 Plus"),
        (["iPhone17,3"], "iPhone 16"),
        (["iPhone16,2"], "iPhone 15 Pro Max"),
        (["iPhone16,1"], "iPhone 15 Pro"),
        (["iPhone15,5"], "iPhone 15 Plus"),
        (["iPhone15,4"], "iPhone 15"),
        (["iPhone15,3"], "iPhone 14 Pro Max"),
        (["iPhone15,2"], "iPhone 14 Pro"),
        (["iPhone14,8"], "iPhone 14 Plus"),
        (["iPhone14,7"], "iPhone 14"),
        (["iPhone14,6"], "iPhone SE (3rd generation)"),
        (["iPhone14,3"], "iPhone 13 Pro Max"),
        (["iPhone14,2"], "iPhone 13 Pro"),
        (["iPhone14,4"], "iPhone 13 mini"),
        (["iPhone14,5"], "iPhone 13"),
        (["iPhone13,4"], "iPhone 12 Pro Max"),
        (["iPhone13,3"], "iPhone 12 Pro"),
        (["iPhone13,1"], "iPhone 12 mini"),
        (["iPhone13,2"], "iPhone 12"),
        (["iPhone12,8"], "iPhone SE (2nd generation)"),
        (["iPhone12,5"], "iPhone 11 Pro Max"),
        (["iPhone12,3"], "iPhone 11 Pro"),
        (["iPhone12,1"], "iPhone 11"),
        (["iPhone11,8"], "iPhone XR"),
        (["iPhone11,4", "iPhone11,6"], "iPhone XS Max"),
        (["iPhone11,2"], "iPhone XS"),
        // iPad
        (["iPad17,3", "iPad17,4"], "iPad Pro (13-inch) (M5)"),
        (["iPad17,1", "iPad17,2"], "iPad Pro (11-inch) (M5)"),
        (["iPad16,5", "iPad16,6"], "iPad Pro (13-inch) (M4)"),
        (["iPad16,3", "iPad16,4"], "iPad Pro (11-inch) (M4)"),
        (["iPad16,10", "iPad16,11"], "iPad Air (13-inch) (M4)"),
        (["iPad16,8", "iPad16,9"], "iPad Air (11-inch) (M4)"),
        (["iPad16,1", "iPad16,2"], "iPad mini (A17 Pro)"),
        (["iPad15,7", "iPad15,8"], "iPad (A16)"),
        (["iPad15,5", "iPad15,6"], "iPad Air (13-inch) (M3)"),
        (["iPad15,3", "iPad15,4"], "iPad Air (11-inch) (M3)"),
        (["iPad14,10", "iPad14,11"], "iPad Air (13-inch) (M2)"),
        (["iPad14,8", "iPad14,9"], "iPad Air (11-inch) (M2)"),
        (["iPad14,5", "iPad14,6"], "iPad Pro (12.9-inch) (6th generation)"),
        (["iPad14,3", "iPad14,4"], "iPad Pro (11-inch) (4th generation)"),
        (["iPad14,1", "iPad14,2"], "iPad mini (6th generation)"),
        (["iPad13,18", "iPad13,19"], "iPad (10th generation)"),
        (["iPad13,16", "iPad13,17"], "iPad Air (5th generation)"),
        (["iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11"], "iPad Pro (12.9-inch) (5th generation)"),
        (["iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7"], "iPad Pro (11-inch) (3rd generation)"),
        (["iPad13,1", "iPad13,2"], "iPad Air (4th generation)"),
        (["iPad12,1", "iPad12,2"], "iPad (9th generation)"),
        (["iPad11,6", "iPad11,7"], "iPad (8th generation)"),
        (["iPad11,3", "iPad11,4"], "iPad Air (3rd generation)"),
        (["iPad11,1", "iPad11,2"], "iPad mini (5th generation)"),
        (["iPad8,11", "iPad8,12"], "iPad Pro (12.9-inch) (4th generation)"),
        (["iPad8,9", "iPad8,10"], "iPad Pro (11-inch) (2nd generation)"),
        (["iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8"], "iPad Pro (12.9-inch) (3rd generation)"),
        (["iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4"], "iPad Pro (11-inch)"),
        (["iPad7,11", "iPad7,12"], "iPad (7th generation)"),
    ]
}
