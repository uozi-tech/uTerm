import AppKit
import SwiftUI
import UDesignKit

/// 终端的查找栏（Mac）：浮在终端右上角，不占窗格高度（高度一变就是一次 SIGWINCH，全屏程序会整屏重画）。
/// 状态与引擎之间的往来在两端共用的 `TerminalSearch`；高亮由 surface 自己画。
///
/// 键位：↩ / ⌘G 往上找（更早的输出），⇧↩ / ⇧⌘G 往下找，⌘F 选中查找框里的字，esc 关掉并把键盘还给终端。
/// 终端有焦点时的 ⌘F / ⌘G / ⇧⌘G / ⌘E 由终端视图接（`GhosttySurfaceView.findCommand`）。
struct TerminalFindBar: View {
    let search: TerminalSearch
    /// 关掉之后把键盘焦点还给终端。
    let onDismiss: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var search = search
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UD.text3)
            TextField("查找", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 180)
                .focused($fieldFocused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { search.previous() } else { search.next() }
                    return .handled
                }
                .onExitCommand(perform: close)
            if let counter = search.counterText {
                Text(counter)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(search.total == 0 ? UD.danger : UD.text3)
                    .lineLimit(1)
                    .fixedSize()
            }
            iconButton("chevron.up", help: "往上找（↩ 或 ⌘G）",
                       shortcut: fieldFocused ? KeyboardShortcut("g", modifiers: .command) : nil) { search.next() }
            iconButton("chevron.down", help: "往下找（⇧↩ 或 ⇧⌘G）",
                       shortcut: fieldFocused ? KeyboardShortcut("g", modifiers: [.command, .shift]) : nil) {
                search.previous()
            }
            iconButton("xmark", help: "关闭（esc）", shortcut: nil, action: close)
            // 查找框有焦点时再按 ⌘F：选中框里的字（终端有焦点时的 ⌘F 由终端视图接，见 `TerminalSearch.focusRequest`）。
            Button("", action: { search.present() })
                .keyboardShortcut(fieldFocused ? KeyboardShortcut("f", modifiers: .command) : nil)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .buttonStyle(.udPlain)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(UD.overlay, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .udShadow(.sm)
        .padding(.top, 6)
        .padding(.trailing, 14)
        .onAppear(perform: focusField)
        .onChange(of: search.focusRequest) { _, _ in focusField() }
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, shortcut: KeyboardShortcut?,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UD.text2)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .keyboardShortcut(shortcut)
        .help(help)
    }

    private func focusField() {
        fieldFocused = true
        // 再打开 / 再按 ⌘F 时整段选中，直接打字就是换关键词。等这一轮焦点落定再选。
        // 只在焦点真的到了查找框（字段编辑器）时选，否则「全选」会落到终端上。
        DispatchQueue.main.async {
            (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
        }
    }

    private func close() {
        search.dismiss()
        onDismiss()
    }
}

/// 终端右上角浮着的那一栏：查找栏开着时显示它。
struct TerminalFindBarSlot: View {
    let session: TerminalSession

    var body: some View {
        if session.link.search.isPresented {
            TerminalFindBar(search: session.link.search) {
                let view = session.ghostty.view
                view.window?.makeFirstResponder(view)
            }
        }
    }
}
