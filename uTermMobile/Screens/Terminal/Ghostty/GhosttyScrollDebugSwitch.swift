#if DEBUG
import Foundation
import GhosttyTerminal

/// 调试（只在 Debug 构建里认）：系统滚动途中引擎的 wakeup 要不要在主线程同步重画（libghostty-spm 补丁 #20 的 A/B），
/// 同一个包里凭手感比。启动参数：
/// - `-GhosttySyncDrawDuringScroll YES`：一律同步重画（补丁 #20 之前）；
/// - `-GhosttySyncDrawDuringScroll touching`：只在手指按着 / 拖着时不画，减速照旧画；
/// - `-GhosttySyncDrawDuringScroll moving`：滚动动着时都不画、wakeup 也不开 display link（补丁 #20，默认）；
/// - `-GhosttySyncDrawDuringScroll moving-link`：不画，但 wakeup 照旧开 display link（补丁 #20 的第一版）；
/// - 不写：用包里的默认（`UTermScrollTrace.defaultScrollWakeupSyncDraw`）。
/// 也可以 `defaults write` 同一个键（真机上就是启动参数）。
enum GhosttyScrollDebugSwitch {
    static func apply(_ defaults: UserDefaults = .standard) {
        guard let raw = defaults.string(forKey: DefaultsKey.ghosttySyncDrawDuringScroll)?.lowercased(), !raw.isEmpty else { return }
        let policy: UTermScrollTrace.ScrollWakeupSyncDraw? = switch raw {
        case "yes", "1", "true": .always
        case "no", "0", "false": .deferWhileMoving
        default: UTermScrollTrace.ScrollWakeupSyncDraw(rawValue: raw)
        }
        guard let policy else { return }
        UTermScrollTrace.scrollWakeupSyncDraw = policy
        FileHandle.standardError.write(Data("[ghostty-scroll] wakeup sync draw during scroll: \(policy.rawValue)\n".utf8))
    }
}
#endif
