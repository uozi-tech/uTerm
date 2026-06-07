import SwiftUI

/// 命令面板浮层（纯展示）——像素级还原设计稿 command-palette.jsx。
/// 只吃绑定与回调，不依赖任何 domain model；可在 Gallery 用静态数据演示。
/// 宽 560、圆角 14、UD.overlayHi 底 + UD.border 单层细边 + .menu 弹层阴影；搜索头 / 结果区(maxHeight 380) / 底栏。
struct UDCommandPalette: View {
    @Binding var query: String
    let sections: [CommandPaletteSection]
    let selectedID: String?
    var onMove: (Int) -> Void = { _ in }
    var onHover: (String) -> Void = { _ in }
    var onExecute: () -> Void = {}
    var onClose: () -> Void = {}
    var isSearching: Bool = false

    @FocusState private var searchFocused: Bool

    private var hasResults: Bool { !sections.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            hairline
            resultsArea
            hairline
            footer
        }
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(UD.overlayHi)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(UD.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // 浮层只配一条细边 + 柔和弹层阴影；不用窗口级阴影（那一档自带 0 0 0 1px 描边环，
        // 与外描边叠成 ~2px 粗边）。.menu 随主题自适应，浅色给轻投影。
        .udShadow(.menu)
        .background(escHotkey)
        .onAppear { searchFocused = true }
    }

    private var hairline: some View {
        Rectangle().fill(UD.border).frame(height: 1)
    }

    // MARK: 搜索头

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(UD.text3)
            TextField("搜索主机、文件、命令…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(UD.text)
                .focused($searchFocused)
                .onSubmit { onExecute() }
                .onKeyPress(.upArrow)   { onMove(-1); return .handled }
                .onKeyPress(.downArrow) { onMove(1);  return .handled }
                .accessibilityLabel("搜索主机、文件、命令")
                .accessibilityAddTraits(.isSearchField)
            if isSearching {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            UDKbd("⌘K")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: 结果区

    private var resultsArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if !hasResults {
                    CommandPaletteEmpty(query: query)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Text(section.label)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(UD.text4)
                                .kerning(0.6)
                                .padding(.top, 8)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.items) { item in
                                CommandPaletteRow(
                                    item: item, query: query,
                                    selected: selectedID == item.id,
                                    onHover: { onHover(item.id) },
                                    onTap: { onHover(item.id); onExecute() })
                                    .id(item.id)
                            }
                        }
                    }
                    .padding(6)
                    // 候选列表整体作为一个无障碍容器（VoiceOver 念为列表）。
                    .accessibilityElement(children: .contain)
                }
            }
            // 键盘上下移动选中项时把高亮项滚动入视。
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(maxHeight: 380)
    }

    // MARK: 底栏

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) { UDKbd("↑"); UDKbd("↓"); Text("移动") }
            HStack(spacing: 5) { UDKbd("↵"); Text("选择") }
            Spacer()
            HStack(spacing: 5) { UDKbd("esc"); Text("取消") }
        }
        .font(.system(size: 11))
        .foregroundStyle(UD.text3)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // 下沉面板色（次级面板）：深色比卡片主体略暗、浅色略灰，始终呈凹陷条；
        // 不写死半透明黑（浅色下会糊成脏灰带）。键帽走自适应的 UDKbd，无需在此处理。
        .background(UD.panel)
    }

    // esc 关闭（隐藏零尺寸按钮承载 cancelAction）。
    private var escHotkey: some View {
        Button("") { onClose() }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

// MARK: - 行

private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let query: String
    let selected: Bool
    let onHover: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CommandPaletteKindIcon(kind: item.kind)
            VStack(alignment: .leading, spacing: 2) {
                commandPaletteHighlighted(
                    item.title, query: query,
                    base: selected ? UD.text : UD.text2,
                    size: 13.5, weight: .medium, mono: false)
                if !item.detail.isEmpty {
                    commandPaletteHighlighted(
                        item.detail, query: query,
                        base: selected ? UD.text3 : UD.text4,
                        size: 11.5, weight: .regular,
                        mono: item.kind == .host || item.kind == .file)
                }
            }
            Spacer(minLength: 8)
            Text(item.hint)
                .font(.system(size: 11))
                .foregroundStyle(UD.text3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? UD.accent.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? UD.accent.opacity(0.33) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { if $0 { onHover() } }
        .onTapGesture { onTap() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityText: String {
        var parts = [item.title]
        if !item.detail.isEmpty { parts.append(item.detail) }
        if !item.hint.isEmpty { parts.append(item.hint) }
        return parts.joined(separator: "，")
    }
}

// MARK: - 类型图标

private struct CommandPaletteKindIcon: View {
    let kind: CommandPaletteKind

    var body: some View {
        let isHost = kind == .host
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isHost ? UD.accent.opacity(0.10) : UD.dyn(.white(0.04), .black(0.04)))
            .frame(width: 26, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(UD.border, lineWidth: 1)
            )
            .overlay(
                Image(systemName: kind.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(isHost ? UD.accent : UD.text2)
            )
    }
}

// MARK: - 命中高亮

/// 把首个命中的子串染成 accent（前景 + 半透明底 + 加粗），返回 Text。
private func commandPaletteHighlighted(_ text: String, query: String, base: Color,
                               size: CGFloat, weight: Font.Weight, mono: Bool) -> Text {
    let baseFont: Font = mono ? .system(size: size, weight: weight, design: .monospaced)
                              : .system(size: size, weight: weight)
    var attr = AttributedString(text)
    attr.foregroundColor = base
    attr.font = baseFont

    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !q.isEmpty,
       let range = text.range(of: q, options: .caseInsensitive) {
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        let lo = attr.index(attr.startIndex, offsetByCharacters: lower)
        let hi = attr.index(lo, offsetByCharacters: length)
        let hlFont: Font = mono ? .system(size: size, weight: .semibold, design: .monospaced)
                                : .system(size: size, weight: .semibold)
        attr[lo..<hi].foregroundColor = UD.accent
        attr[lo..<hi].backgroundColor = UD.accent.opacity(0.13)
        attr[lo..<hi].font = hlFont
    }
    return Text(attr)
}

// MARK: - 空状态

private struct CommandPaletteEmpty: View {
    let query: String

    var body: some View {
        VStack(spacing: 8) {
            Text("没有匹配「\(Text(verbatim: query).foregroundColor(UD.text2))」的结果")
                .font(.system(size: 13))
                .foregroundStyle(UD.text3)
            Text("试试 host、md、导入")
                .font(.system(size: 11))
                .foregroundStyle(UD.text4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 12)
    }
}

#Preview("UDCommandPalette") {
    struct Wrap: View {
        @State private var query = ""
        private var sections: [CommandPaletteSection] {
            groupCommandPalette([
                CommandPaletteItem(id: "h1", kind: .host, title: "demo-server",
                                   detail: "root@203.0.113.10", hint: "连接") {},
                CommandPaletteItem(id: "c1", kind: .command, title: "新建主机…",
                                   detail: "创建一台新服务器", hint: "⌘N") {},
                CommandPaletteItem(id: "f1", kind: .file, title: "main.go",
                                   detail: "~/src/main.go", hint: "打开") {},
                CommandPaletteItem(id: "s1", kind: .setting, title: "设置 · 终端",
                                   detail: "字体、颜色、行距", hint: "↵") {},
            ])
        }
        var body: some View {
            UDCommandPalette(query: $query, sections: sections, selectedID: "h1")
                .padding(40)
                .background(UD.bg)
        }
    }
    return Wrap()
}
