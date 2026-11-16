import SwiftUI

/// 系统弹出菜单。工程里的 `Menu` 都走它，不要直接写 `Menu`（`MMenuTintLintTests` 把关）。
///
/// 根视图的 `.tint(M.accent)` 会一路传进菜单项，系统就拿它染图标，`role: .destructive` 的图标也不例外，
/// 结果是「删除」红字配蓝图标、普通项黑字配蓝图标。在菜单内容上清掉 tint，图标和文字才都回到系统配色。
/// 只清内容，触发按钮仍然跟随外层 tint。
struct MMenu<Items: View, MenuLabel: View>: View {
    @ViewBuilder var items: Items
    @ViewBuilder var label: MenuLabel

    var body: some View {
        Menu {
            Group { items }.tint(nil)
        } label: {
            label
        }
    }
}

extension View {
    /// 长按菜单，配色规则同 `MMenu`。
    ///
    /// `preview` 是长按浮起来的那块（和带指针的 iPad 悬停高亮）的轮廓，必须和视图看得见的底板同形，
    /// 连 `style` 一起对上。不给的话系统按视图的命中形状裁：命中区常是撑大的 `Rectangle()`，
    /// 浮起来就成了直角、比底板还高的一块；没写命中形状时又是系统默认的圆角，和底板的圆角对不上。
    func mContextMenu<S: Shape, Items: View>(preview: S, @ViewBuilder items: () -> Items) -> some View {
        contentShape(.contextMenuPreview, preview)
            .contentShape(.hoverEffect, preview)
            .contextMenu {
                Group { items() }.tint(nil)
            }
    }
}

/// 在视图的矩形里竖直居中、只有 `height` 高的圆角矩形：视图为了 44pt 命中区上下撑开了，
/// 浮起 / 拖拽预览却要贴着中间那块看得见的胶囊。
nonisolated struct MCenteredRoundedRect: Shape {
    var cornerRadius: CGFloat
    var height: CGFloat
    var style: RoundedCornerStyle = .continuous

    func path(in rect: CGRect) -> Path {
        let h = min(height, rect.height)
        let box = CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)
        return RoundedRectangle(cornerRadius: cornerRadius, style: style).path(in: box)
    }
}
