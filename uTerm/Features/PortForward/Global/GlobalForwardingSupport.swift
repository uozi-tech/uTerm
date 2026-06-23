import Foundation

/// 全局端口转发面板的**纯逻辑**：分组、启动序列过程态映射、汇总计数。
///
/// 全部 `nonisolated` 值类型 / 自由函数，不依赖 SwiftData / SwiftUI / 主 actor ——
/// 可在单测里直接喂值类型断言（仿 `PortConflictChecker`），无需起内存容器或视图。
///
/// 与运行态的关系：每条规则的实时状态来自 `ForwardingCoordinator.status(_:)`（`TunnelStatus`），
/// 启动序列的整体相位来自 `GlobalForwardingModel.phase`（`GFPhase`）。本文件只做「把这两者
/// 翻译成 UI 想要的离散态」与「按主机聚合 / 计数」，不持有任何状态。

/// 启动自动化序列的整体相位。
nonisolated enum GFPhase: Equatable, Sendable {
    case idle      // 未跑过 / 已重置：行显示静态开关
    case running   // 正在逐条建立：标记自启的行显示过程态芯片
    case done      // 跑完一轮：横幅显示「X 条已建立 · Y 条失败」
}

/// 按主机聚合后的一组（组头 + 该主机的规则，规则保持入参顺序）。
nonisolated struct GFGroup<Host, Rule> {
    let host: Host
    let rules: [Rule]
}

/// 按主机把规则聚合成分组。
///
/// - 组顺序 = `hosts` 顺序（调用方传服务器列表顺序，即 `ServerProfile.sortOrder`）。
/// - **跳过空组**：没有任何规则的主机不出现。
/// - 主机外键对不上的孤儿规则被丢弃（删主机时协调器会清孤儿；这里只是稳妥兜底）。
/// 泛型 + 闭包取键 —— 既能喂 `@Model`，也能在单测里喂轻量值类型。
nonisolated func gfGroupByHost<Host, Rule>(
    hosts: [Host],
    rules: [Rule],
    hostID: (Host) -> UUID,
    ruleServerID: (Rule) -> UUID
) -> [GFGroup<Host, Rule>] {
    var byServer: [UUID: [Rule]] = [:]
    for rule in rules {
        byServer[ruleServerID(rule), default: []].append(rule)
    }
    return hosts.compactMap { host in
        guard let items = byServer[hostID(host)], !items.isEmpty else { return nil }
        return GFGroup(host: host, rules: items)
    }
}

/// 顶部汇总条 / 横幅要用的计数。
nonisolated struct GFSummary: Equatable, Sendable {
    let ruleTotal: Int     // 共 M 条规则
    let activeTotal: Int    // 当前活跃隧道数（status == .active）
    let launchTotal: Int    // 标记「随 uTerm 启动」的规则数
    let upCount: Int        // 自启规则里已建立的数（启动序列汇总用）
    let failCount: Int      // 自启规则里失败的数
}

/// 从「逐条对齐的状态 + 自启标志」算出汇总计数。
/// `statuses[i]` 与 `launchFlags[i]` 必须对应同一条规则（等长）。
nonisolated func gfSummary(statuses: [TunnelStatus], launchFlags: [Bool]) -> GFSummary {
    var active = 0, launch = 0, up = 0, fail = 0
    for (status, isLaunch) in zip(statuses, launchFlags) {
        if status == .active { active += 1 }
        guard isLaunch else { continue }
        launch += 1
        switch status {
        case .active: up += 1
        case .error:  fail += 1
        default: break
        }
    }
    return GFSummary(ruleTotal: min(statuses.count, launchFlags.count),
                     activeTotal: active, launchTotal: launch,
                     upCount: up, failCount: fail)
}

// MARK: - 流量

/// 一条隧道的展示用流量：累计 + 实时速率（B/s）。由面板每秒拉 `TunnelBytes` 快照算差得出。
nonisolated struct GFTrafficStat: Sendable, Equatable {
    let up: UInt64        // 累计上行字节
    let down: UInt64      // 累计下行字节
    let upRate: UInt64    // 上行 B/s（上一秒）
    let downRate: UInt64  // 下行 B/s（上一秒）
    static let zero = GFTrafficStat(up: 0, down: 0, upRate: 0, downRate: 0)
}

/// 人类可读字节（二进制 1024 进制，确定性、可单测；不用 locale 相关的 ByteCountFormatter）。
nonisolated func gfFormatBytes(_ n: UInt64) -> String {
    if n < 1024 { return "\(n) B" }
    let units = ["KB", "MB", "GB", "TB", "PB", "EB"]
    var v = Double(n) / 1024
    var i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    // 边界进位修正：选档用未四舍的 v，但显示是 %.1f；当 v 落在 [1023.95, 1024) 时 %.1f 会进位成
    // 「1024.0 KB」—— 再提一档显示成「1.0 MB」。`(v*10).rounded() >= 10240` 即 v 四舍到 1 位后 ≥1024。
    if i < units.count - 1, (v * 10).rounded() >= 10240 { v /= 1024; i += 1 }
    return String(format: "%.1f %@", v, units[i])
}

/// 速率：`<字节>/s`。
nonisolated func gfFormatRate(_ bytesPerSec: UInt64) -> String {
    "\(gfFormatBytes(bytesPerSec))/s"
}
