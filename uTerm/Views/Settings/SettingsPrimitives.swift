import SwiftUI

/// 设置 tab 的滚动容器。外边距 + 区组之间 28pt spacing。
///
/// 用法：
///     SettingsScroll {
///         SettingsGroup(title: "启动") { ... }
///         SettingsGroup(title: "外观") { ... }
///     }
struct SettingsScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                content()
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 设置区组。上方 ALL-CAPS 灰字标题（10.5pt 字距 0.6），下方内容堆叠 4pt 间距。
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(AppTheme.Palette.textMuted)
            VStack(alignment: .leading, spacing: 4) {
                content()
            }
        }
    }
}

/// 设置行。左侧 label（可带 hint），右侧控件。最小高度 36，纵向 padding 4。
struct SettingsRow<Trailing: View>: View {
    let label: String
    let hint: String?
    @ViewBuilder let trailing: () -> Trailing

    init(label: String, hint: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.label = label
        self.hint = hint
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppTheme.Palette.textMuted)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            trailing()
        }
        .frame(minHeight: 36)
        .padding(.vertical, 4)
    }
}
