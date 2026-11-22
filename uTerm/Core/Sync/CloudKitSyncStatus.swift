import Foundation

/// iCloud 同步在设置页上展示的状态（两端共用）：先过「CloudKit 容器建成没有」「登录 iCloud
/// 没有」两道门，再叠 `CloudKitSyncMonitor.phase` 的进行态。文案与 SF Symbol 在这里，
/// **着色留在视图**（两端配色体系不同）。
enum CloudKitSyncStatus: Equatable {
    /// CloudKit 容器没建成、回退了纯本地库（只有 iOS 会走到：mac 不做本地回退）。
    case localOnly
    /// 没登录 iCloud。
    case signedOut
    case connecting
    case downloading
    case uploading
    case failed
    /// 空闲且这次启动以来至少完成过一次同步。
    case synced
    /// 空闲但还没完成过同步（刚启动 / 镜像还没跑）。
    case waiting

    static func resolve(phase: CloudKitSyncMonitor.Phase,
                        lastSyncedAt: Date?,
                        loggedIn: Bool,
                        usingCloudKit: Bool) -> CloudKitSyncStatus {
        guard usingCloudKit else { return .localOnly }
        guard loggedIn else { return .signedOut }
        switch phase {
        case .setup:     return .connecting
        case .importing: return .downloading
        case .exporting: return .uploading
        case .error:     return .failed
        case .idle:      return lastSyncedAt != nil ? .synced : .waiting
        }
    }

    var label: String {
        switch self {
        case .localOnly:   String(localized: "本地存储")
        case .signedOut:   String(localized: "未登录 iCloud")
        case .connecting:  String(localized: "连接中…")
        case .downloading: String(localized: "下载中…")
        case .uploading:   String(localized: "上传中…")
        case .failed:      String(localized: "同步出错")
        case .synced:      String(localized: "已同步")
        case .waiting:     String(localized: "等待同步")
        }
    }

    var symbol: String {
        switch self {
        case .localOnly:   "internaldrive"
        case .signedOut:   "person.crop.circle.badge.xmark"
        case .connecting:  "arrow.triangle.2.circlepath"
        case .downloading: "icloud.and.arrow.down"
        case .uploading:   "icloud.and.arrow.up"
        case .failed:      "exclamationmark.icloud"
        case .synced:      "checkmark.icloud"
        case .waiting:     "icloud"
        }
    }

    /// 能不能往下看同步细节（事件 / 错误）：容器建成且已登录。
    var isCloudActive: Bool { self != .localOnly && self != .signedOut }
}

extension CloudKitSyncMonitor {
    /// 当前展示状态（文案 `.label`、图标 `.symbol`）。`loggedIn` 由调用方读 `FileManager.default.ubiquityIdentityToken`；
    /// `usingCloudKit` 是容器是否以 CloudKit 建成（mac 恒为 true）。
    func status(loggedIn: Bool, usingCloudKit: Bool = true) -> CloudKitSyncStatus {
        CloudKitSyncStatus.resolve(phase: phase, lastSyncedAt: lastSyncedAt,
                                   loggedIn: loggedIn, usingCloudKit: usingCloudKit)
    }
}
