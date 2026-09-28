import CoreData
import Foundation
import Observation
import UDesignKit

/// CloudKit 同步可观测器（macOS + iOS 共用）。
///
/// SwiftData 的 `cloudKitDatabase: .automatic` 底层是 `NSPersistentCloudKitContainer`，
/// 它会向 `NotificationCenter.default` 发 `eventChangedNotification`（setup / import / export
/// 的开始与结束）。SwiftData 不暴露这个容器，所以**按通知名订阅**即可——无私有 API、
/// 无需改 entitlement，App Store / Developer-ID 均合规。
///
/// 职责：
/// 1. 把每个事件写进 `AppLogger`（category `sync`，Console.app 可见——macOS「高级 ›
///    显示日志」即过滤此 subsystem）；
/// 2. 暴露 `@Observable` 的实时状态（`phase` / `lastError` / `lastSyncedAt`）给设置页展示；
/// 3. 留一份最近事件环形缓冲（`recentEvents`）供 app 内诊断 / 复制——iOS 无 Console 时尤有用。
///
/// 启动一次即可（`start()` 幂等）：macOS 在 `uTermApp`、iOS 在 `MobileApp` 注入并 `start()`。
@MainActor @Observable
final class CloudKitSyncMonitor {
    /// 当前同步阶段。`.idle` = 空闲（含从未同步）；其余为某类事件正在进行 / 最近失败。
    enum Phase: Equatable { case idle, setup, importing, exporting, error }

    /// 一条诊断记录（时间 + 文本），供 `recentEvents` 与复制用。
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    private(set) var phase: Phase = .idle
    private(set) var lastError: String?
    private(set) var lastSyncedAt: Date?
    private(set) var hasEverSynced = false
    /// 最近事件环形缓冲（最多 `maxEvents` 条，新的在末尾）。
    private(set) var recentEvents: [Entry] = []

    private var observer: NSObjectProtocol?
    private static let maxEvents = 80

    /// 幂等启动：订阅 CloudKit 镜像事件通知。重复调用安全（已订阅则直接返回）。
    func start() {
        guard observer == nil else { return }
        AppLogger.info("CloudKit sync monitor started", category: "sync")
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            // 在 nonisolated 回调里先把事件拆成 Sendable 原语，再跳主 actor 落地——
            // 直接把非 Sendable 的 Notification / Event 捕获进 @MainActor 闭包会触发 Swift 6
            // 数据竞争诊断（"sending 'note' risks causing data races"）。
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
            let kind: String
            switch event.type {
            case .setup:  kind = "setup"
            case .import: kind = "import"
            case .export: kind = "export"
            @unknown default: kind = "unknown"
            }
            let isStart = event.endDate == nil          // endDate == nil 表示「开始 / 进行中」
            let dur = event.endDate.map { $0.timeIntervalSince(event.startDate) } ?? 0
            let endDate = event.endDate
            let succeeded = event.succeeded
            // 只取 localizedDescription（描述操作本身：配额 / 未登录 / 网络 / schema / 限流），
            // 不取 error.userInfo——个别 CloudKit 错误会把 recordName 塞进去。同步行不含明文记录。
            let errorDesc = event.error?.localizedDescription
            // queue: .main → 回调在主线程，assumeIsolated 不会 trap；此处仅捕获 Sendable 值 + weak self。
            MainActor.assumeIsolated {
                self?.apply(kind: kind, isStart: isStart, succeeded: succeeded,
                            durSeconds: dur, endDate: endDate, errorDesc: errorDesc)
            }
        }
    }

    /// 在主 actor 上落地一个已拆解的事件（入参全 Sendable）。
    private func apply(kind: String, isStart: Bool, succeeded: Bool,
                       durSeconds: TimeInterval, endDate: Date?, errorDesc: String?) {
        if isStart {
            switch kind {
            case "setup":  phase = .setup
            case "import": phase = .importing
            case "export": phase = .exporting
            default: break
            }
            record("\(kind) 开始")
            AppLogger.info("CloudKit \(kind) started", category: "sync")
            return
        }
        let durText = UFormat.duration(seconds: durSeconds)
        if succeeded {
            phase = .idle
            lastSyncedAt = endDate
            hasEverSynced = true
            lastError = nil
            record("\(kind) 完成 · \(durText)")
            AppLogger.info("CloudKit \(kind) ok in \(durText)", category: "sync")
        } else {
            let desc = errorDesc ?? "未知错误"
            phase = .error
            lastError = desc
            record("\(kind) 失败 · \(desc)")
            AppLogger.error("CloudKit \(kind) FAILED: \(desc)", category: "sync")
        }
    }

    private func record(_ text: String) {
        recentEvents.append(Entry(date: Date(), text: text))
        if recentEvents.count > Self.maxEvents {
            recentEvents.removeFirst(recentEvents.count - Self.maxEvents)
        }
    }

    /// 复制用：把最近事件拼成纯文本（时间 + 文本，旧→新）。
    func exportText() -> String {
        let lines = recentEvents.map { "\(UFormat.time($0.date))  \($0.text)" }
        return lines.isEmpty ? "（暂无同步事件）" : lines.joined(separator: "\n")
    }
}
