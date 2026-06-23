import Foundation
import SwiftData

/// 全局端口转发的「启动自动化」编排器。App 级 `@State`，注入 environment，
/// 与 `ForwardingCoordinator` 协作（本类只管「序列相位 + 主开关」，真正建隧道仍走协调器）。
///
/// 触发时机两处，共用 `runSequence`：
/// - **真实启动**：`WelcomeView.task` 在 app 起来后调 `autoTriggerIfNeeded`（每进程一次）。
/// - **手动重连**：全局面板横幅的「重新连接」按钮调 `runSequence`。
///
/// 序列**顺序、逐条**推进（对齐 spec §4.2「让用户看清每条隧道的过程」）：起一条 →
/// 等它落定（`.active`/`.error`，封顶 45s 防卡死）→ 起下一条。过程态由
/// `ForwardingCoordinator.status(_:)` 经 `gfRunState(...)` 实时反映到行上的 `GfRunChip`。
/// 失败判定不需预检：主机离线 / 目标不可达 / 端口被拒都会被协调器分类成 `.error`。
@MainActor
@Observable
final class GlobalForwardingModel {
    /// 主开关持久化键（应用级自启总闸）。缺键默认 **开**（只作用于用户显式标记的规则，故安全）。
    private static let autoKey = "globalForwarding.launchAtAppStart.enabled"

    /// 启动序列相位（驱动横幅副文案与行上过程态芯片的显隐）。
    var phase: GFPhase = .idle

    /// 「uTerm 启动时自动建立隧道」总开关。关闭后不跑启动序列。
    var autoStartEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoStartEnabled, forKey: Self.autoKey)
            // 关掉总闸 = 立即中止在飞序列 + 清掉过程态（验收 #4：关闭后不跑序列，
            // 不能只挡新序列、放任在飞的那条继续逐条起隧道）。复位 .idle 也顺带清掉
            // 上一轮 .done 的残留汇总，避免「已关闭」与「X 已建立」并存的误导。
            // didSet 不会在 init 的赋值时触发，故初始化读 UserDefaults 不会反向写。
            if !autoStartEnabled {
                runTask?.cancel()
                runTask = nil
                phase = .idle
            }
        }
    }

    /// 启动序列只在每进程自动触发一次（`WelcomeView` 可能被多次实例化 / 重开）。
    @ObservationIgnored private var didAutoTrigger = false
    /// 当前在跑的序列 Task（由本模型持有，故 `WelcomeView` 关闭也不打断）。
    @ObservationIgnored private var runTask: Task<Void, Never>?

    init() {
        autoStartEnabled = (UserDefaults.standard.object(forKey: Self.autoKey) as? Bool) ?? true
    }

    /// 一条待自启的规则 + 其所属主机（在 `@MainActor` 上构造与使用，无需 `Sendable`）。
    struct LaunchItem {
        let rule: ForwardingRuleSnapshot
        let server: ServerProfile
    }

    /// App 启动后调用一次：若总开关开着且有标记规则，跑启动序列。
    func autoTriggerIfNeeded(items: [LaunchItem],
                             coordinator: ForwardingCoordinator,
                             relay: HostKeyChallengeRelay,
                             container: ModelContainer) {
        guard !didAutoTrigger else { return }
        didAutoTrigger = true
        guard autoStartEnabled, !items.isEmpty else { return }
        runSequence(items: items, coordinator: coordinator, relay: relay, container: container)
    }

    /// 跑一轮启动序列（自动触发 / 手动「重新连接」共用）。顺序逐条起、逐条等落定。
    func runSequence(items: [LaunchItem],
                     coordinator: ForwardingCoordinator,
                     relay: HostKeyChallengeRelay,
                     container: ModelContainer) {
        runTask?.cancel()
        guard !items.isEmpty else { phase = .idle; return }
        phase = .running
        runTask = Task { @MainActor [weak self] in
            for item in items {
                if Task.isCancelled { return }
                // 已活跃的隧道不重起（对齐单主机页 toggle 约定：active 不重连）。
                // 手动「重新连接」点一次只补未建立 / 失败的，不抖断已建好的连接。
                if case .active = coordinator.status(item.rule.id) { continue }
                // 起隧道（fire-and-forget：协调器内部自跑 Task，回报状态进 runtime）。
                coordinator.start(item.rule, on: item.server,
                                  relay: relay, modelContainer: container)
                // 等这条落定再起下一条 —— 用户能逐条看到 等待→连接中→已建立/失败。
                await Self.awaitSettle(item.rule.id, coordinator: coordinator)
            }
            self?.phase = .done
        }
    }

    /// 轮询等某条规则落定到终态（`.active`/`.error`）。封顶 45s：即便某条卡在建连，
    /// 也不会无限拖住后面的队列（真实连接耗时通常远小于此）。
    private static func awaitSettle(_ id: UUID, coordinator: ForwardingCoordinator) async {
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            switch coordinator.status(id) {
            case .active, .error: return
            default: break
            }
            if clock.now - start > .seconds(45) { return }
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
        }
    }
}
