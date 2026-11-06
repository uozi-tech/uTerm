import Foundation

/// 设置页状态的语义色调。两端各自把它换成自己的配色（mac `UD.*`、iOS `M.*`），
/// 状态 → 色调的判断只写一份。
nonisolated enum SettingsTone: Sendable, Equatable {
    /// 次要灰：未开启 / 未登录 / 空闲等待。
    case muted
    /// 正文次级色：停着但不算异常。
    case neutral
    /// 主色：进行中 / 正常工作。
    case active
    /// 橙：出错但可恢复。
    case warning
    case success
    case danger
}

/// iCloud 与局域网同步状态在设置页上的图标、色调与说明（两端共用）。
/// 状态文案本身在 `CloudKitSyncStatus.label` / `LANSyncCoordinator.Status.label`。
enum SyncStatusPresentation {
    static func cloud(_ status: CloudKitSyncStatus) -> (symbol: String, tone: SettingsTone) {
        let tone: SettingsTone
        switch status {
        case .localOnly, .signedOut, .waiting:
            tone = .muted
        case .failed:
            tone = .warning
        case .connecting, .downloading, .uploading, .synced:
            tone = .active
        }
        return (status.symbol, tone)
    }

    static func lan(_ status: LANSyncCoordinator.Status) -> (symbol: String, tone: SettingsTone) {
        switch status {
        case .ready: return ("wifi", .active)
        case .waitingForConfirmation: return ("hourglass", .active)
        case .syncing: return ("arrow.up.circle", .active)
        case .error: return ("exclamationmark.triangle", .warning)
        case .stopped, .searching, .hosting: return ("wifi.slash", .muted)
        }
    }

    /// 「iCloud 同步」行的说明。
    static func cloudHint(loggedIn: Bool) -> String {
        loggedIn
            ? "iCloud 在后台独立同步；局域网同步在同一 Wi-Fi 下由 Mac 主动发起并加密传输。"
            : "未登录 iCloud，跨设备同步只能走下面的局域网通道。"
    }

    /// 「同步诊断」行的副标题：能看细节时一句话提示有没有出错，否则直接报基础状态。
    /// 整段错误原文不放这里（CloudKit 的错误动辄三行，会把右侧按钮挤没），进「查看事件…」弹窗看。
    static func diagnosticsSubtitle(status: CloudKitSyncStatus, lastError: String?) -> String {
        guard status.isCloudActive else { return status.label }
        return lastError == nil ? "查看最近同步事件 · 复制日志" : "最近一次同步出错，点右侧查看详情与日志"
    }
}
