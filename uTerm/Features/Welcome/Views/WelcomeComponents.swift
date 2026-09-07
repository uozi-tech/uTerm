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
    /// 共享格式化器。**别改回「每次现建一个」** —— 这个方法在 `ServerRow` 里是
    /// 逐行调用的，2000 台的列表滚一屏就要现建几十个 `RelativeDateTimeFormatter`。
    /// 与 `QuickCommandFormat` 里的两个 `DateFormatter` 同一处方；
    /// 仅 MainActor 的欢迎页视图调用，故 `@MainActor` 静态存储，
    /// 避开 `RelativeDateTimeFormatter` 非 Sendable。
    @MainActor private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    /// `nil` → 「从未」，否则按当前 locale 输出「2 小时前 / 昨天 / 刚刚」之类。
    @MainActor static func relative(_ date: Date?) -> String {
        guard let date else { return "从未" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
