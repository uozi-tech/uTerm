import UDesignKit
import SwiftUI

/// 设计稿 `new-server.jsx` / `keys.jsx` 里的表单原语翻译成 SwiftUI。
/// 表单控件，外观随全局主题；UD 自适应 token 在深 / 浅模式下均正确呈现。
///
/// 设计稿对应：`FormSection` / `FormField`。输入、按钮、开关、分段、chip 等控件
/// 已迁移到 DesignKit。

// MARK: - section / field 布局

/// 设计稿 `FormSection`：uppercase 小标题 + 一道分隔线 + 右侧可选 slot（如开关）。
struct DarkFormSection<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(UD.text4)
                Rectangle().fill(UD.border).frame(height: 1)
                trailing
            }
            content
        }
    }
}

extension DarkFormSection where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

/// 设计稿 `FormField`：label（+ 可选灰色 hint）压在控件上方。
struct DarkFormField<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(UD.text2)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(UD.text4)
                }
            }
            content
        }
    }
}
