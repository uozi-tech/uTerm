import SwiftUI

/// 设置 › 终端 › 键盘条短语：AI 面板里的启动命令、提示词、斜杠命令。左滑删除、编辑模式拖动排序、每组末行直接添加。
/// 数据与规则在共享的 `TerminalPhrases`，这里只画。
///
/// 从键盘条面板的「编辑短语…」以 sheet 打开时传 `showsDone: true`，自带一层导航栈。
struct TerminalPhrasesScreen: View {
    var showsDone = false

    @Environment(\.dismiss) private var dismiss
    @AppStorage(DefaultsKey.terminalKeyBarPhrases) private var raw = ""
    @State private var drafts: [TerminalPhraseKind: String] = [:]
    @State private var rejection: TerminalPhrases.AddResult?

    var body: some View {
        if showsDone {
            NavigationStack { content }
        } else {
            content
        }
    }

    private var phrases: TerminalPhrases { TerminalPhrases.decode(raw) }

    private func update(_ change: (inout TerminalPhrases) -> Void) {
        var next = phrases
        change(&next)
        raw = next.encoded
    }

    private var content: some View {
        List {
            ForEach(TerminalPhraseKind.allCases) { kind in
                section(kind)
            }
        }
        .scrollContentBackground(.hidden)
        .background(M.canvas)
        .navigationTitle("键盘条短语")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) { resetMenu }
        }
        .alert(rejectionTitle, isPresented: Binding(get: { rejection != nil }, set: { if !$0 { rejection = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(rejectionMessage)
        }
    }

    private func section(_ kind: TerminalPhraseKind) -> some View {
        Section {
            ForEach(phrases[kind], id: \.self) { phrase in
                Text(verbatim: phrase)
                    .font(kind == .prompt ? M.sans(15) : M.mono(14))
                    .foregroundStyle(M.text)
                    .lineLimit(2)
                    .listRowBackground(M.card)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            update { all in all[kind].removeAll { $0 == phrase } }
                        } label: { Image(systemName: "trash") }
                            .accessibilityLabel("删除")
                    }
            }
            .onDelete { offsets in update { $0.remove(atOffsets: offsets, from: kind) } }
            .onMove { source, destination in update { $0.move(fromOffsets: source, toOffset: destination, in: kind) } }
            addRow(kind)
        } header: {
            Text(kind.title)
        } footer: {
            Text(kind.footer)
        }
    }

    private func addRow(_ kind: TerminalPhraseKind) -> some View {
        let draft = Binding(get: { drafts[kind] ?? "" }, set: { drafts[kind] = $0 })
        let isCommand = kind != .prompt
        return HStack(spacing: 10) {
            TextField(kind.placeholder, text: draft)
                .font(isCommand ? M.mono(14) : M.sans(15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(isCommand)
                .keyboardType(isCommand ? .asciiCapable : .default)
                .submitLabel(.done)
                .onSubmit { add(kind) }
            Button { add(kind) } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 20))
            }
            .buttonStyle(.borderless)
            .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("添加")
        }
        .listRowBackground(M.card)
        .moveDisabled(true)
        .deleteDisabled(true)
    }

    private func add(_ kind: TerminalPhraseKind) {
        var next = phrases
        let result = next.add(drafts[kind] ?? "", to: kind)
        switch result {
        case .added:
            raw = next.encoded
            drafts[kind] = ""
        case .empty:
            break
        default:
            rejection = result
        }
    }

    private var resetMenu: some View {
        MMenu {
            ForEach(TerminalPhraseKind.allCases) { kind in
                Button {
                    update { $0.reset(kind) }
                } label: { Text("恢复默认的「\(kind.title)」") }
            }
            Divider()
            Button(role: .destructive) { raw = "" } label: {
                Label("全部恢复默认", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
        .accessibilityLabel("恢复默认")
    }

    private var rejectionTitle: String {
        switch rejection {
        case .duplicate: String(localized: "这一组里已经有这条了")
        case .multiline: String(localized: "短语只能有一行")
        case .tooLong: String(localized: "短语太长")
        case .full: String(localized: "这一组已经满了")
        case .added, .empty, nil: ""
        }
    }

    private var rejectionMessage: String {
        switch rejection {
        case .multiline: String(localized: "换行会让命令在半截就提交。")
        case .tooLong: String(localized: "一条最多 \(TerminalPhrases.maxLength) 个字符。")
        case .full: String(localized: "一组最多 \(TerminalPhrases.maxPerKind) 条，先删掉几条不用的。")
        case .duplicate, .added, .empty, nil: ""
        }
    }
}

private extension TerminalPhraseKind {
    var title: String {
        switch self {
        case .launch: String(localized: "启动")
        case .prompt: String(localized: "提示词")
        case .slash: String(localized: "斜杠命令")
        }
    }

    var footer: String {
        switch self {
        case .launch: String(localized: "在 shell 里启动 AI 命令行，点一下输入并回车。没在跑 AI 命令行时排在面板最前面。")
        case .prompt: String(localized: "点一下发送并提交；长按可以只填入、不发送。")
        case .slash: String(localized: "Claude Code 与 Codex 的斜杠命令。")
        }
    }

    var placeholder: String {
        switch self {
        case .launch: String(localized: "添加命令，如 claude --model opus")
        case .prompt: String(localized: "添加提示词")
        case .slash: String(localized: "添加斜杠命令，如 /review")
        }
    }
}
