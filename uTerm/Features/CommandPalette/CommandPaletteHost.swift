import SwiftUI

/// 把命令面板挂到任意窗口根视图：⌘K 开关 + 浮层 + 点外关闭。
/// `itemsBuilder` 每次开面板时重新构建，保证主机/最近文件是最新的。
struct CommandPaletteHost: ViewModifier {
    let model: CommandPaletteModel
    var searchProvider: (@MainActor (String) async -> [CommandPaletteItem])?
    let itemsBuilder: () -> [CommandPaletteItem]

    func body(content: Content) -> some View {
        content
            .background(toggleHotkey)
            .overlay {
                if model.isPresented { paletteOverlay }
            }
    }

    // ⌘K 切换（始终在层级里，面板关着也生效）。
    private var toggleHotkey: some View {
        Button("") {
            if model.isPresented {
                model.close()
            } else {
                model.searchProvider = searchProvider
                model.open(items: itemsBuilder())
            }
        }
        .keyboardShortcut("k", modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var paletteOverlay: some View {
        // ZStack 子节点顺序很重要：捕获层在下、面板在上 —— SwiftUI 从顶层子节点开始命中
        // 测试，所以点面板内落在面板上（不关闭），点面板外才落到捕获层（关闭）。切勿调换顺序。
        ZStack(alignment: .top) {
            // 透明点击捕获层：点面板外关闭（背景不变暗，忠于设计稿）。
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.close() }

            UDCommandPalette(
                query: Binding(get: { model.query }, set: { model.setQuery($0) }),
                sections: model.sections,
                selectedID: model.selectedItemID,
                onMove: { model.moveSelection(by: $0) },
                onHover: { model.hover(itemID: $0) },
                onExecute: { model.executeSelected() },
                onClose: { model.close() },
                isSearching: model.isSearching
            )
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.top, 80)
        }
    }
}

extension View {
    /// 在窗口根挂命令面板。`model` 由窗口持有（`@State`），`items` 在开面板时求值。
    /// `searchProvider`（可选）：query → 异步搜索结果，并入面板（如工作区文件搜索）。
    func commandPalette(model: CommandPaletteModel,
                        searchProvider: (@MainActor (String) async -> [CommandPaletteItem])? = nil,
                        items: @escaping () -> [CommandPaletteItem]) -> some View {
        modifier(CommandPaletteHost(model: model, searchProvider: searchProvider, itemsBuilder: items))
    }
}
