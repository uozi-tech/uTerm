import UDesignKit
import SwiftUI

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
            .background(RoundedRectangle(cornerRadius: MRadius.xs, style: .continuous).fill(fill))
    }
}
