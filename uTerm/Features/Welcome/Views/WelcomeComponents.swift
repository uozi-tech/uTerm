import UDesignKit
// uTerm/Views/WelcomeComponents.swift
import SwiftUI

/// 欢迎页（设计稿 Variant A）共享的小组件与格式化工具。
/// 列表行 `ServerRow` 与详情面板 `HostDetailPanel` 复用这里的 `KbdChip` /
/// `WelcomeFormat`，避免重复实现。

/// 键位提示小胶囊（设计稿 Kbd）。等宽、软底，浅深自适应。
struct KbdChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(UD.text2)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(UD.fillSoft)
            )
    }
}

/// 欢迎页用的相对时间格式化（「上次连接」/ 行尾时间）。
enum WelcomeFormat {
    /// `nil` → 「从未」，否则按当前 locale 输出「2 小时前 / 昨天 / 刚刚」之类。
    static func relative(_ date: Date?) -> String {
        guard let date else { return "从未" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
