import SwiftUI

/// 分组色解析（对齐 macOS `ServerGroupBadgeTint`）：组名 → `ServerGroup.colorHex` → Color。
/// 无组 / 无色时返回 nil（调用方回退强调色或中性）。
enum MGroupTint {
    static func color(for groupName: String?, in groupColorHexes: [String: String]) -> Color? {
        guard let groupName, !groupName.isEmpty,
              let hex = groupColorHexes[groupName] else { return nil }
        let rgb = groupHexRGB(hex)
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

/// 分组标签 chip（对齐 macOS `UDGroupChip`）：有组色时 文字=组色 / 底=组色 10% / 描边=组色 42%；
/// 无组色回退中性（text3 / 透明 / border）。
struct MGroupChip: View {
    let label: String
    var tint: Color? = nil

    init(_ label: String, tint: Color? = nil) {
        self.label = label
        self.tint = tint
    }

    var body: some View {
        let fill: Color = tint?.opacity(0.10) ?? .clear
        let stroke: Color = tint?.opacity(0.42) ?? M.border
        return Text(label)
            .font(M.sans(11, weight: .medium))
            .foregroundStyle(tint ?? M.text3)
            .padding(.vertical, 2).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }
}
