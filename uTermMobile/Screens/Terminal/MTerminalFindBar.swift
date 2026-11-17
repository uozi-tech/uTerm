import SwiftUI

/// 终端的查找栏（iOS）：浮在终端顶上，不占终端的行数（行数一变就是一次 SIGWINCH）。状态与引擎之间的往来在两端共用的
/// `TerminalSearch`，高亮由 surface 自己画。
///
/// 入口：键盘条上紧跟 esc / tab 的放大镜、标签的长按菜单、硬件键盘 ⌘F（⌘G / ⇧⌘G 跳转，见 `MGhosttyTerminalView.keyCommands`）。
/// 键盘上的「搜索」键往上找（更早的输出），之后键盘不收起，可以接着按。
struct MTerminalFindBar: View {
    let search: TerminalSearch
    /// 关掉时查找框有焦点（用户在打字）：把键盘还给终端。
    let onDismiss: (_ hadFocus: Bool) -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var search = search
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(M.text3)
                .padding(.leading, 12)
            TextField("查找", text: $search.query)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($fieldFocused)
                .onSubmit {
                    search.next()
                    // 提交会让 TextField 交出焦点、收起键盘；查找时多半还要接着往上翻，留住它。
                    fieldFocused = true
                }
            if let counter = search.counterText {
                Text(counter)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(search.total == 0 ? M.danger : M.text3)
                    .lineLimit(1)
                    .fixedSize()
            }
            iconButton("chevron.up", label: "往上找") { search.next() }
            iconButton("chevron.down", label: "往下找") { search.previous() }
            iconButton("xmark", label: "关闭查找") {
                let hadFocus = fieldFocused
                search.dismiss()
                onDismiss(hadFocus)
            }
            .padding(.trailing, 2)
        }
        .frame(height: 40)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .onAppear { fieldFocused = true }
        .onChange(of: search.focusRequest) { _, _ in fieldFocused = true }
    }

    private func iconButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(M.text2)
                .frame(width: 36, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}
