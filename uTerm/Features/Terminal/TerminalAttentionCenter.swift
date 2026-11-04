import AppKit
import SwiftUI
import UDesignKit
import UserNotifications

/// 一条要发给系统通知中心的内容。副标题（哪个标签）由 `TerminalAttentionCenter` 补。
nonisolated struct TerminalAttention: Equatable, Sendable {
    let title: String
    let body: String

    private static let maxTextLength = 256

    /// `OSC 9 ; 正文`（iTerm2 通知）。`9;4` 是进度，由 SwiftTerm 处理；`数字;` 开头的其余
    /// 形式是 ConEmu 的扩展指令，不是给人看的正文。
    static func osc9(_ data: ArraySlice<UInt8>) -> TerminalAttention? {
        let text = String(decoding: data, as: UTF8.self)
        guard text.firstMatch(of: /^\d+;/) == nil else { return nil }
        return make(title: "", body: text)
    }

    /// `OSC 777 ; notify ; 标题 ; 正文`（Ghostty、urxvt）。
    static func osc777(_ data: ArraySlice<UInt8>) -> TerminalAttention? {
        let parts = String(decoding: data, as: UTF8.self)
            .split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "notify" else { return nil }
        return make(title: String(parts[1]), body: String(parts[2]))
    }

    private static func make(title: String, body: String) -> TerminalAttention? {
        let title = cleaned(title)
        let body = cleaned(body)
        guard !title.isEmpty || !body.isEmpty else { return nil }
        return TerminalAttention(title: title.isEmpty ? String(localized: "终端通知") : title, body: body)
    }

    /// 内容来自远端程序：去掉控制字符，防止换行等伪造通知的版式。
    private static func cleaned(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars)).prefix(maxTextLength).trimmingCharacters(in: .whitespaces)
    }
}

/// 同一条会话的通知限频，防止程序循环刷屏。被丢掉的那条不会丢信息：标签状态仍在。
nonisolated struct TerminalAttentionRateLimiter: Sendable {
    private static let minimumInterval: TimeInterval = 2

    private var lastPosted: [UUID: Date] = [:]

    mutating func allows(_ sessionID: UUID, at now: Date) -> Bool {
        if let last = lastPosted[sessionID], now.timeIntervalSince(last) < Self.minimumInterval {
            return false
        }
        lastPosted[sessionID] = now
        return true
    }
}

/// 把会话的提醒发到系统通知中心，并在用户点通知时回到对应标签。
///
/// 只有已登记到 `TerminalSessionRegistry` 的会话才发：要靠它拿标签名和回跳目标。
@MainActor
final class TerminalAttentionCenter: NSObject {
    static let shared = TerminalAttentionCenter()

    private nonisolated static let sessionIDKey = "sessionID"

    private weak var registry: TerminalSessionRegistry?
    private var rateLimiter = TerminalAttentionRateLimiter()

    /// 通知中心的 delegate 要在 app 启动完成前设好，否则点通知拉起 app 时收不到回调。
    func start(registry: TerminalSessionRegistry) {
        self.registry = registry
        UNUserNotificationCenter.current().delegate = self
    }

    func post(_ attention: TerminalAttention, from session: TerminalSession) {
        guard let registry, let sessionID = registry.sessionID(of: session),
              rateLimiter.allows(sessionID, at: Date()) else { return }

        let content = UNMutableNotificationContent()
        content.title = attention.title
        content.subtitle = registry.entries.first { $0.id == sessionID }?.title ?? ""
        content.body = attention.body
        content.sound = .default
        content.userInfo = [Self.sessionIDKey: sessionID.uuidString]
        let request = UNNotificationRequest(identifier: Self.identifier(for: sessionID),
                                            content: content,
                                            trigger: nil)
        Task {
            // 第一次发通知时才问授权；之后再调用不会重复弹窗。被拒绝就只剩标签状态。
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    /// 用户已经回到这条会话，通知中心里它的旧通知没有意义了。
    func withdraw(from session: TerminalSession) {
        guard let sessionID = registry?.sessionID(of: session) else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.identifier(for: sessionID)])
    }

    private func reveal(sessionID: UUID) {
        registry?.requestReveal(sessionID: sessionID)
    }

    /// 同一条会话共用一个 identifier：新通知替换旧的，通知中心里不会堆一串。
    private static func identifier(for sessionID: UUID) -> String {
        "terminal-attention-\(sessionID.uuidString)"
    }
}

extension TerminalAttentionCenter: UNUserNotificationCenterDelegate {
    /// app 在前台时也显示：提醒来自用户没在看的标签，它可能在另一个窗口里。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let text = response.notification.request.content.userInfo[Self.sessionIDKey] as? String
        if let sessionID = text.flatMap(UUID.init(uuidString:)) {
            Task { @MainActor in self.reveal(sessionID: sessionID) }
        }
        completionHandler()
    }
}

extension NSWindow {
    /// 把窗口带到最前并激活 app，包括 app 退到后台（`.accessory`）的情况。
    func bringToFront() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if isMiniaturized { deminiaturize(nil) }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
