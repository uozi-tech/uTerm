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
    func mContextMenu<Items: View>(@ViewBuilder items: () -> Items) -> some View {
        contextMenu {
            Group { items() }.tint(nil)
        }
    }
}
