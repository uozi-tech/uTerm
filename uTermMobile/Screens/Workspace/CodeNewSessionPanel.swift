import SwiftUI

/// Code 标签页「＋」弹出的新会话面板的状态：选的目录、候选、是不是在输入路径。面板关掉就扔，不存（选了目录写回
/// 标签页的 `directory`，它随归档存着）。候选与核对的规则两端共用（`AgentHistoryNewSessionPlaces` /
/// `AgentHistoryDirectoryInput`），这里只是 iOS 面板的那一份状态。
@MainActor
@Observable
final class CodeNewSessionDraft: Identifiable {
    let id = UUID()
    var directory: String?
    /// 候选目录（现算的）；配对的 Mac 最近的工作区问回来之后再补一次。
    var choices: [String]
    /// 那台主机上的主目录（显示时缩成 `~`）。
    var home: String?
    /// 在输入路径（面板里就地换成输入框，不下钻）。
    var typing: AgentHistoryPathEntry?

    init(directory: String?, choices: [String], home: String?) {
        self.directory = directory
        self.choices = choices
        self.home = home
    }

    func display(_ path: String) -> String { AgentHistoryNewSessionPlaces.displayPath(path, home: home) }
}

/// 「＋」的新会话面板（`mBottomPanel` 呈现）：上面选目录（候选 + 「输入路径…」），不止一种工具时选工具，底下「开始」。
/// 输入路径就地换成输入框（面板里不下钻，免得用系统内联导航栏）。
struct CodeNewSessionPanel: View {
    let draft: CodeNewSessionDraft
    let history: AgentHistoryModel
    let connection: AgentHistoryConnection
    let hostName: String
    let onStart: (_ tool: AgentHistoryTool, _ directory: String) -> Void

    @AppStorage(DefaultsKey.codeNewSessionTool) private var storedTool = ""

    /// 候选多时列表最多这么高，再多在里面滚（面板高度由内容决定，不能被十个目录撑到屏外）。
    private static let listMaxHeight: CGFloat = 264
    private static let rowHeight: CGFloat = 46

    var body: some View {
        let tools = history.newSessionTools(directory: draft.directory)
        let tool = AgentHistoryNewSessionPlaces.preferredTool(stored: storedTool, among: tools)
        VStack(alignment: .leading, spacing: 0) {
            Text(AgentHistoryText.newSession)
                .font(M.sans(21, weight: .bold)).foregroundStyle(M.text)
            Text(hostName)
                .font(M.sans(13.5)).foregroundStyle(M.text3).lineLimit(1)
                .padding(.top, 3)
            if let entry = draft.typing {
                pathInput(entry).padding(.top, 18)
            } else {
                MSectionCap(text: AgentHistoryText.newSessionDirectoryLabel).padding(.top, 18)
                directoryList.padding(.top, 8)
                if tools.count > 1, let tool {
                    MSectionCap(text: AgentHistoryText.newSessionToolLabel).padding(.top, 16)
                    MSegmented(items: tools.map { (value: $0, label: $0.displayName) },
                               selection: Binding(get: { tool }, set: { storedTool = $0.rawValue }))
                        .padding(.top, 8)
                }
                MBtn(title: AgentHistoryText.newSessionStartTitle(tool: tool, toolCount: tools.count), icon: "term",
                     full: true, height: 50, disabled: tool == nil || draft.directory == nil) {
                    guard let tool, let directory = draft.directory else { return }
                    storedTool = tool.rawValue
                    onStart(tool, directory)
                }
                .padding(.top, 20)
                if let reason = AgentHistoryText.newSessionBlockedReason(directory: draft.directory, tools: tools) {
                    Text(reason)
                        .font(M.sans(12.5)).foregroundStyle(M.text3)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 目录

    private var directoryList: some View {
        let rows = draft.choices.count + 1
        let height = min(CGFloat(rows) * Self.rowHeight, Self.listMaxHeight)
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(draft.choices, id: \.self) { choice in
                    directoryRow(draft.display(choice), icon: "folder", selected: choice == draft.directory) {
                        draft.directory = choice
                    }
                    MRowDivider()
                }
                directoryRow(AgentHistoryText.enterPath, icon: "edit", selected: false) {
                    draft.typing = AgentHistoryPathEntry(text: draft.directory.map(draft.display) ?? "")
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: height)
        .background(M.fillFaint)
        .clipShape(RoundedRectangle(cornerRadius: MRadius.lg))
    }

    private func directoryRow(_ title: String, icon: String, selected: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MIcon(name: icon, size: 15, color: M.text3)
                Text(title)
                    .font(M.mono(14)).foregroundStyle(M.text)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected { MIcon(name: "check", size: 14, color: M.text, weight: .semibold) }
            }
            .padding(.horizontal, 14)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: 输入路径

    private func pathInput(_ entry: AgentHistoryPathEntry) -> some View {
        @Bindable var entry = entry
        return VStack(alignment: .leading, spacing: 8) {
            MSectionCap(text: AgentHistoryText.enterPathTitle)
            MInput(text: $entry.text, placeholder: AgentHistoryText.enterPathPlaceholder, mono: true,
                   keyboard: .asciiCapable, autofocus: true)
                .submitLabel(.done)
                .onSubmit { submit(entry) }
            Text(entry.message ?? AgentHistoryText.enterPathHint)
                .font(M.sans(12.5)).foregroundStyle(entry.message == nil ? M.text3 : M.danger)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                MBtn(title: String(localized: "取消"), kind: .secondary, full: true, height: 46) {
                    draft.typing = nil
                }
                MBtn(title: entry.isChecking ? String(localized: "正在检查…") : AgentHistoryText.chooseFolderPrompt,
                     full: true, height: 46,
                     disabled: entry.isChecking || entry.text.trimmingCharacters(in: .whitespaces).isEmpty) {
                    submit(entry)
                }
            }
            .padding(.top, 8)
        }
    }

    private func submit(_ entry: AgentHistoryPathEntry) {
        Task {
            guard let path = await entry.submit(using: connection) else { return }
            if !draft.choices.contains(path) { draft.choices.insert(path, at: 0) }
            draft.directory = path
            draft.typing = nil
        }
    }
}
