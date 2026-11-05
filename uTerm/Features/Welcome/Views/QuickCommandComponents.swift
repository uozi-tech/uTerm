import UDesignKit
import SwiftUI

/// 快捷命令的 macOS 小件（复刻原型 `pages/quick-commands.jsx`）。纯展示组件只读 `UD` token；
/// 两端共用的纯逻辑（主机引用 / 目标解析 / 校验与文案）在 `QuickCommandLogic.swift`。

// MARK: - AI 介入开关行（详情 / 表单共用 chrome）

/// 「AI 介入」开关行：sparkles + 调用方内容 + 紫色 `UDToggle`，开启时紫色高亮底/边。
/// 详情与表单共用此 chrome，仅内容文案不同（消除两处近乎一致的重复）。
struct QCAiToggleRow<Content: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(isOn ? UD.aiAccent : UD.text3)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            UDToggle($isOn, tint: UD.aiAccent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isOn ? UD.aiAccent.opacity(0.11) : UD.fillFaint))
    }
}

// MARK: - 图标 Shapes（复刻原型自绘 SVG）

/// `>_` 终端提示符字形（chevron + 下划线），14 单位坐标系，描边绘制。
struct PromptChevronShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let s = rect.width / 14
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(3, 4)); path.addLine(to: p(5.6, 6.6)); path.addLine(to: p(3, 9.2))
        path.move(to: p(7.4, 9.6)); path.addLine(to: p(11, 9.6))
        return path
    }
}

/// 并行图标：两路右向箭头（14 单位坐标系）。
struct ParallelArrowsShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let s = rect.width / 14
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        // 上行
        path.move(to: p(2, 4.3)); path.addLine(to: p(9.2, 4.3))
        path.move(to: p(7.3, 2.2)); path.addLine(to: p(9.6, 4.3)); path.addLine(to: p(7.3, 6.4))
        // 下行
        path.move(to: p(2, 9.7)); path.addLine(to: p(9.2, 9.7))
        path.move(to: p(7.3, 7.6)); path.addLine(to: p(9.6, 9.7)); path.addLine(to: p(7.3, 11.8))
        return path
    }
}

/// 并行图标视图（描边）。
struct QCParallelIcon: View {
    var size: CGFloat = 11
    var color: Color = UD.success
    var body: some View {
        ParallelArrowsShape()
            .stroke(color, style: StrokeStyle(lineWidth: size * 1.2 / 14, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

// MARK: - 提示符字形图标 PromptGlyph

/// `>_` 字形图标块。AI 介入时染固定紫 `UD.aiAccent`，否则用连接强调色 `UD.accent`。
/// 圆角方块（tint 14% 底 + tint 字形），用于列表行 / 详情头 / 空态。
struct QCPromptGlyph: View {
    var size: CGFloat = 30
    var ai: Bool = false

    private var tint: Color { ai ? UD.aiAccent : UD.accent }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 8 / 30, style: .continuous)
            .fill(tint.opacity(0.14))
            .overlay(
                PromptChevronShape()
                    .stroke(tint, style: StrokeStyle(lineWidth: size * 1.5 / 30,
                                                     lineCap: .round, lineJoin: .round))
                    .frame(width: size * 14 / 30, height: size * 14 / 30)
            )
            .frame(width: size, height: size)
    }
}

// MARK: - AI 介入徽标

/// 「AI 介入」徽标（固定紫 tint 底 + sparkles）。`compact` 为列表行用的更小尺寸。
struct QCAiBadge: View {
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: compact ? 9 : 10))
            Text("AI 介入")
                .font(.system(size: compact ? 10.5 : 11, weight: .medium))
                .tracking(0.2)
        }
        .foregroundStyle(UD.aiAccent)
        .padding(.horizontal, compact ? 6 : 9)
        .padding(.vertical, compact ? 2 : 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(UD.aiAccent.opacity(0.13))
        )
        .fixedSize()
    }
}

// MARK: - 服务器徽标

/// 服务器徽标：单台 = 名称芯片（绿点 + 名）；多台 = 绿色「⇄ N 台并行」。
struct QCServersBadge: View {
    let count: Int
    let firstName: String?

    var body: some View {
        if count <= 1, let firstName {
            HStack(spacing: 6) {
                Circle().fill(UD.success).frame(width: 5, height: 5)
                Text(firstName)
                    .font(.system(size: 11))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)
            }
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(UD.fillFaint)
            )
            .fixedSize()
        } else if count > 1 {
            HStack(spacing: 6) {
                QCParallelIcon(size: 11, color: UD.success)
                Text("\(count) 台并行")
                    .font(.system(size: 11))
                    .foregroundStyle(UD.text2)
            }
            .padding(.leading, 8)
            .padding(.trailing, 9)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(UD.success.opacity(0.14))
            )
            .fixedSize()
        }
    }
}

/// 「并行执行」小标记（详情目标服务器区，多台时显示）。
struct QCParallelTag: View {
    var body: some View {
        HStack(spacing: 4) {
            QCParallelIcon(size: 10, color: UD.success)
            Text("并行执行")
                .font(.system(size: 10.5))
                .foregroundStyle(UD.success)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 1)
        .background(Capsule().fill(UD.success.opacity(0.14)))
    }
}
