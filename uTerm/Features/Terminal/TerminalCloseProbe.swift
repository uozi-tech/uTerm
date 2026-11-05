import Foundation

/// 关终端标签前的「前台还有没有程序在跑」探测（macOS / iOS 共用）。
///
/// 只管探测和防重复；确认弹窗的形式（mac 的 NSAlert、iOS 的确认框状态）留在各端。
@MainActor
final class TerminalCloseProbe {
    /// 正在探测（含探测完、调用方还在拿主意）的会话。探测要走一趟网络，连按关闭不重复发起。
    private var probing: Set<AnyHashable> = []

    init() {}

    /// 这个会话是不是正在探测。
    func isProbing(_ id: some Hashable) -> Bool { probing.contains(AnyHashable(id)) }

    /// 探测一次，把结果交给 `then`：`nil` = 没有在跑的程序，直接关；否则按这条提示问用户。
    /// 同一个 `id` 已经在探测时什么都不做，返回 false。`then` 执行期间 `id` 仍算在探测中
    /// （mac 的确认 sheet 开着时再按 ⌘W 不会叠第二个）。
    @discardableResult
    func probe(_ id: some Hashable,
               activity: () async -> TerminalActivity,
               then decide: (TerminalClosePrompt?) async -> Void) async -> Bool {
        let key = AnyHashable(id)
        guard probing.insert(key).inserted else { return false }
        defer { probing.remove(key) }
        let result = await activity()
        await decide(result.closePrompt)
        return true
    }

    /// 关标签前问后端：前台还有没有程序在跑。没连上就没有程序可中断。
    ///
    /// `alternateScreen` 在探测回来之后才读：探测要走一趟网络，期间程序可能已经切了屏。
    static func foregroundActivity(
        connected: Bool,
        backend: (any TerminalBackend)?,
        alternateScreen: () -> Bool
    ) async -> TerminalActivity {
        guard connected, let backend else { return .idle }
        let probed = await backend.foregroundActivity()
        return probed.resolved(alternateScreen: alternateScreen())
    }
}
