import UDesignKit
import SwiftUI

/// 分组色解析（对齐 macOS `ServerGroupBadgeTint`）：组名 → `ServerGroup.colorHex` → Color。
/// 无组 / 无色时返回 nil（调用方回退强调色或中性）。
enum MGroupTint {
    /// **一趟**把 `ServerGroup` 表解析成「组名 → Color」，供列表整屏共用。
    ///
    /// 改前是 `color(for:in:)`：调用方先拿一个 `[String: String]` 的 hex 字典，
    /// 而列表里那个字典是**计算属性** —— 每渲染一行就重建一遍整张表
    /// （O(行 × 组)），再逐行解析一次十六进制。
    /// 现在在 body 里求一次，行体只做一次字典查表。
    static func colors(for groups: [ServerGroup]) -> [String: Color] {
        var out: [String: Color] = [:]
        out.reserveCapacity(groups.count)
        for g in groups where out[g.name] == nil {
            let rgb = groupHexRGB(g.colorHex)
            out[g.name] = Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
        }
        return out
    }

    /// 查表版：`colors(for:)` 的结果 + 组名 → 组色（无组 / 无色 → nil）。
    static func color(for groupName: String?, colors: [String: Color]) -> Color? {
        guard let groupName, !groupName.isEmpty else { return nil }
        return colors[groupName]
    }
}

/// 分组标签 chip（对齐 macOS `UDGroupChip`，v2 填充即边界）：有组色时 文字=组色 / 底=组色 14%；
/// 无组色回退中性（text3 / fillSoft——常嵌在 fillFaint 卡片里，深一档才成形）。不描边。
struct MGroupChip: View {
    let label: String
    var tint: Color? = nil

    init(_ label: String, tint: Color? = nil) {
        self.label = label
        self.tint = tint
    }

    var body: some View {
        let fill: Color = tint?.opacity(0.14) ?? UD.fillSoft
        return Text(label)
            .font(M.sans(11, weight: .medium))
            .foregroundStyle(tint ?? M.text3)
            .padding(.vertical, 2).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
    }
}
