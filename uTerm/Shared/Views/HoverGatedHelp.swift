import SwiftUI

extension View {
    /// 悬停门控的 `.help`。
    ///
    /// `.help(_:)` 会给挂点注册一块**常驻**的 tooltip 区域，而 `NSToolTipManager`
    /// 在每个滚动 tick 上全量重算整窗的 tooltip 区域 —— 区域越多，滚动越贵
    /// （uTable `docs/swiftui-scroll-perf-playbook.md` §四 第 3 层、§五·十四）。
    /// 列表 / 消息流这类「同一形状重复几十上百次」的地方，改成只在鼠标真的落在
    /// 这一行上时才挂 tooltip：交互体验不变（tooltip 本来就只有悬停才弹），
    /// 但不悬停的行一块区域都不注册。
    ///
    /// 调用方自己维护 `isHovering`（一行一个 `onHover` 就够，别每个元件一个）。
    ///
    /// 文案是 `@autoclosure`：调用点常写成
    /// `"最近连接失败：\(issue)"`、`"累计 ↑ \(fmt(up)) · ↓ \(fmt(down))"` 这类
    /// **每次 body 求值都要拼一遍**的插值串。门控挡住的只是 tooltip 区域，
    /// 挡不住实参求值 —— 上千行 × 一行几处，不悬停的行照样逐帧拼字符串。
    /// 改成延迟求值后，只有真悬停的那一行付这笔账。
    @ViewBuilder
    func help(whenHovering isHovering: Bool, _ text: @autoclosure () -> String) -> some View {
        // 空串守卫仍在，但只在 active 分支里求值一次（不悬停时一次都不求）。
        let resolved = isHovering ? text() : ""
        if resolved.isEmpty {
            self
        } else {
            self.help(resolved)
        }
    }
}
