import SwiftUI

/// 行内 tooltip 的悬停门控。
///
/// `.help(_:)` 每处都会在平台上留下一块常驻的 tooltip 追踪区。一行挂四五个、
/// 列表再有几百行时，这些追踪区在滚动时要跟着重算，是列表卡顿里一笔看不见的账
/// （uTable 的实测：导入向导文件列表 300 行走悬停门控后单帧 p50 8.25 → 4.96ms、
/// 超预算帧 113 → 20/240，见 `uTable/docs/table-rendering-guide.md` §一·T3·4）。
///
/// 用法：行级只留**一个** `onHover` 记状态，行内每处 tooltip 换成
/// `.help(whenHovering: hover, "……")` —— 鼠标不在这一行时那块追踪区压根不存在，
/// 鼠标进来时才装上；用户看到的 tooltip 行为不变（tooltip 本来就只在悬停时才弹）。
///
/// `@autoclosure` 是为了让不悬停时连文案字符串都不用拼（`flowPlain` 这类要做
/// 字符串插值的尤其值）。
extension View {
    @ViewBuilder
    func help(whenHovering active: Bool, _ text: @autoclosure () -> String) -> some View {
        if active {
            help(text())
        } else {
            self
        }
    }
}
