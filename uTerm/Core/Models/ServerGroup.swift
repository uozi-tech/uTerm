import SwiftUI
import SwiftData

/// 服务器分组实体。`name` 作成员键（匹配 `ServerProfile.group`）。
/// 颜色 / 置顶 / 排序为每组元数据。成员归属仍存在 `ServerProfile.group` 字符串里（按名键）。
@Model
final class ServerGroup {
    /// 分组名，作成员键（匹配 `ServerProfile.group`）。
    /// CloudKit 约束：不能用 `@Attribute(.unique)`（同 ServerProfile 等其它模型）——
    /// 唯一性由 `GroupStore.ensure`/`reconcile`（先查再插 / 按名去重）在应用层保证。
    var name: String = ""
    var colorHex: String = "#9aa7b5"
    var isPinned: Bool = false
    var sortOrder: Int = 0

    init(name: String, colorHex: String = "#9aa7b5", isPinned: Bool = false, sortOrder: Int = 0) {
        self.name = name
        self.colorHex = colorHex
        self.isPinned = isPinned
        self.sortOrder = sortOrder
    }

    /// 设计稿 GROUP_COLORS 10 色板。`Sendable [String]` → 可 nonisolated。
    nonisolated static let palette: [String] = [
        "#f87171", "#fb923c", "#fbbf24", "#a3e635", "#34d399",
        "#2dd4bf", "#60a5fa", "#a78bfa", "#f472b6", "#9aa7b5",
    ]

    /// 由 `colorHex` 解析的 SwiftUI 颜色（侧栏彩点用）。
    var color: Color {
        let (r, g, b) = groupHexRGB(colorHex)
        return Color(.sRGB, red: r, green: g, blue: b)
    }
}

/// 解析 "#RRGGBB" / "RRGGBB" → (r,g,b) ∈ 0...1；非法输入回退中性灰 #9aa7b5。
nonisolated func groupHexRGB(_ hex: String) -> (r: Double, g: Double, b: Double) {
    let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard s.count == 6, let v = UInt32(s, radix: 16) else {
        return (154.0/255, 167.0/255, 181.0/255)
    }
    return (Double((v >> 16) & 0xFF)/255, Double((v >> 8) & 0xFF)/255, Double(v & 0xFF)/255)
}
