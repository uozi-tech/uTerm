#if DEBUG
import Foundation

/// Mock 名称样式。供 Tweaks 旋钮与工厂共用。
enum MockNameStyle: Hashable {
    case normal   // 常规短名
    case long     // 超长名（压测截断 / 换行）
    case mixed    // 常规 + 超长 + 特殊字符 混排
}

/// Tweaks 调试用：按旋钮参数构造一批 **未插入 modelContext** 的 `ServerProfile`，
/// 仅供欢迎页 view-only 渲染，不写入真实 SwiftData 库。
///
/// 所有 id 与日期均确定性（按序号），同参数 → 同输出，使列表 identity 稳定，
/// 故上层每次现算即可、无需缓存。
enum MockServerFactory {
    /// 锚定时间戳 2023-11-14T22:13:20Z。确定性，避免依赖 `Date()` 当前时刻。
    private nonisolated(unsafe) static let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    /// 计数在内部钳到合法区间：serverCount 0...50；groupCount 0...6（0 → 全 nil）；
    /// pinnedCount / recentCount 0...serverCount（取前 N 条）。
    nonisolated static func make(serverCount: Int,
                                 groupCount: Int,
                                 pinnedCount: Int,
                                 recentCount: Int,
                                 nameStyle: MockNameStyle) -> [ServerProfile] {
        let n = clamp(serverCount, 0, 50)
        let g = clamp(groupCount, 0, 6)
        let pinned = clamp(pinnedCount, 0, n)
        let recent = clamp(recentCount, 0, n)

        return (0..<n).map { i in
            let p = ServerProfile()
            p.id = deterministicID(i)
            p.name = name(for: i, style: nameStyle)
            p.host = "10.0.\(i / 256).\(i % 256)"
            p.username = "deploy"
            p.port = (i % 5 == 0) ? 2222 : 22
            p.sortOrder = i
            p.group = (g == 0) ? nil : groupName(i % g)
            p.isPinned = i < pinned
            p.lastConnectedAt = i < recent ? anchor.addingTimeInterval(-Double(i) * 86_400) : nil
            return p
        }
    }

    // MARK: helpers

    private nonisolated static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }

    /// 确定性 UUID：用序号填末段（i ≤ 49，12 位十进制必为合法 hex）。
    private nonisolated static func deterministicID(_ i: Int) -> UUID {
        let suffix = String(format: "%012d", i)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }

    private nonisolated static func groupName(_ idx: Int) -> String {
        let names = ["production", "staging", "dev", "edge", "db", "cache"]
        return names[idx % names.count]
    }

    private nonisolated static func name(for i: Int, style: MockNameStyle) -> String {
        let long = "very-long-hostname-for-truncation-test-node-\(i)-region-ap-southeast-1"
        switch style {
        case .normal: return "host-\(i)"
        case .long:   return long
        case .mixed:
            switch i % 3 {
            case 0:  return "host-\(i)"
            case 1:  return long
            default: return "✦ spéçial-\(i) 🚀"
            }
        }
    }
}
#endif
