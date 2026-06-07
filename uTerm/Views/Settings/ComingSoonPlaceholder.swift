import SwiftUI

/// Settings 子 tab 的"即将上线"占位。
///
/// 当对应 setting 落地后（spec 02–10 各覆盖一部分），整文件可删，
/// 同时把对应 SettingsView 的 body 改成实际内容。
struct ComingSoonPlaceholder: View {
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(UD.text3)
                .accessibilityHidden(true)
            Text("\(label) · 敬请期待")
                .font(.system(size: 13))
                .foregroundStyle(UD.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
