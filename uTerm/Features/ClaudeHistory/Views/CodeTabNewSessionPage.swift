import AppKit
import SwiftUI
import UDesignKit

/// Code 标签页右边的「新会话」起始页：选目录、选工具（不止一种时）、开始。什么都没选时（刚打开、点了侧栏顶上的「＋」、
/// 跑着的会话结束了）右边就是它。居中一小块，不铺成整页表单（同各家 Desktop 新会话那一页：一个文件夹选择器，选好再开始）。
///
/// 目录：候选现算（`CodeTabModel.newSessionDirectoryChoices`），选了写回 `newSessionDirectory`；最后一项「选择文件夹…」
/// 本机用系统的文件夹面板，SSH 主机弹一个小面板输入路径（经这个标签页的文件通道核对）。
/// 工具：`newSessionTools`（依赖目录），默认上一次用的那种（`DefaultsKey.codeNewSessionTool`，只存本机）。
struct CodeTabNewSessionPage: View {
    let code: CodeTabModel
    let history: AgentHistoryModel

    @AppStorage(DefaultsKey.codeNewSessionTool) private var storedTool = ""
    /// 输入路径的小面板（SSH 主机）。开着时不为 nil。
    @State private var pathEntry: CodeTabPathEntryRequest?

    /// 表单那一块的宽度。
    static let formWidth: CGFloat = 360

    var body: some View {
        let directory = code.newSessionDirectory
        let tools = history.newSessionTools(directory: directory)
        let tool = AgentHistoryNewSessionPlaces.preferredTool(stored: storedTool, among: tools)
        VStack(spacing: 0) {
            Image(systemName: "plus.bubble")
                .font(.largeTitle)
                .foregroundStyle(UD.text3)
            Text(AgentHistoryText.newSession)
                .font(.headline)
                .foregroundStyle(UD.text)
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 12) {
                field(AgentHistoryText.newSessionDirectoryLabel) { directoryPicker(directory) }
                if tools.count > 1, let tool {
                    field(AgentHistoryText.newSessionToolLabel) { toolPicker(tools, selected: tool) }
                }
            }
            .frame(width: Self.formWidth)
            .padding(.top, 20)
            UDButton(title: AgentHistoryText.newSessionStartTitle(tool: tool, toolCount: tools.count),
                     fillsWidth: true) {
                start(tool, in: directory)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(tool == nil || directory == nil)
            .frame(width: Self.formWidth)
            .padding(.top, 18)
            if let reason = AgentHistoryText.newSessionBlockedReason(directory: directory, tools: tools) {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(UD.text3)
                    .multilineTextAlignment(.center)
                    .frame(width: Self.formWidth)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .sheet(item: $pathEntry) { request in
            CodeTabPathSheet(entry: request.entry, connection: code.connection) { path in
                code.chooseNewSessionDirectory(path)
                pathEntry = nil
            } onCancel: {
                pathEntry = nil
            }
        }
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(UD.text4)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    // MARK: 目录

    private func directoryPicker(_ directory: String?) -> some View {
        let home = code.connection?.homeDirectory
        let label = directory.map { AgentHistoryNewSessionPlaces.displayPath($0, home: home) }
            ?? AgentHistoryText.newSessionNoDirectory
        return UDDropdown(anchor: .leading) { open in
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(UD.text3)
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(directory == nil ? UD.text3 : UD.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UD.text3)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous)
                .fill(open ? UD.button2Hover : UD.button2))
            .contentShape(RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous))
        } content: {
            // 点开时才算候选（本机那一份要逐个看目录还在不在）。
            UDMenu(width: Self.formWidth, items: code.newSessionDirectoryChoices.map { choice in
                UDMenuItem(label: AgentHistoryNewSessionPlaces.displayPath(choice, home: home),
                           active: choice == directory) {
                    code.chooseNewSessionDirectory(choice)
                }
            } + [.divider(), UDMenuItem(label: AgentHistoryText.chooseFolder, systemImage: "folder.badge.plus") {
                chooseFolder(current: directory, home: home)
            }])
        }
        // 悬停看全路径（显示的可能被中间截断、主目录缩成了 `~`）。
        .help(directory ?? AgentHistoryText.newSessionNoDirectory)
        .accessibilityLabel(Text(AgentHistoryText.newSessionDirectoryLabel))
        .accessibilityValue(Text(label))
    }

    /// 「选择文件夹…」：本机是系统的文件夹面板，SSH 主机是输入路径的小面板。
    private func chooseFolder(current: String?, home: String?) {
        switch code.directoryChooser {
        case .localFolder:
            // 下一拍再弹：菜单浮层还在收起。
            DispatchQueue.main.async {
                if let path = Self.runFolderPanel(startingAt: current ?? home) { code.chooseNewSessionDirectory(path) }
            }
        case .typedPath:
            pathEntry = CodeTabPathEntryRequest(entry: AgentHistoryPathEntry(
                text: current.map { AgentHistoryNewSessionPlaces.displayPath($0, home: home) } ?? ""))
        }
    }

    /// 只能选目录。App 带沙盒，面板给的是用户选的那个目录的访问权；这里只要它的路径字符串：shell 由辅助程序在沙盒外起，
    /// `cd` 进去用不着安全书签，所以不存书签。
    private static func runFolderPanel(startingAt directory: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = AgentHistoryText.chooseFolderPrompt
        if let directory { panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL.path
    }

    // MARK: 工具

    private func toolPicker(_ tools: [AgentHistoryTool], selected: AgentHistoryTool) -> some View {
        UDSegmented(selection: Binding(get: { selected }, set: { storedTool = $0.rawValue }),
                    options: tools.map { (value: $0, label: $0.displayName) }, fillsWidth: true)
            .accessibilityLabel(Text(AgentHistoryText.newSessionToolLabel))
    }

    private func start(_ tool: AgentHistoryTool?, in directory: String?) {
        guard let tool, let directory else { return }
        storedTool = tool.rawValue
        code.startNewSession(tool: tool, in: directory)
    }
}

/// 输入路径小面板的一次请求（`.sheet(item:)` 要 `Identifiable`）。
struct CodeTabPathEntryRequest: Identifiable {
    let id = UUID()
    let entry: AgentHistoryPathEntry
}

/// SSH 主机上「选择文件夹…」：输入一个路径（`~` 照主机上的主目录展开），确认前经文件通道核对存在、是目录；
/// 核对不过给一句说明，面板不关。
struct CodeTabPathSheet: View {
    @Bindable var entry: AgentHistoryPathEntry
    let connection: AgentHistoryConnection?
    let onChoose: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AgentHistoryText.enterPathTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(UD.text)
            VStack(alignment: .leading, spacing: 6) {
                UDTextField(placeholder: AgentHistoryText.enterPathPlaceholder, text: $entry.text,
                            errorMessage: entry.message, autoFocus: true, monospaced: true)
                if entry.message == nil {
                    Text(AgentHistoryText.enterPathHint)
                        .font(.system(size: 12))
                        .foregroundStyle(UD.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                UDButton(title: String(localized: "取消"), style: .secondary, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                UDButton(title: AgentHistoryText.chooseFolderPrompt, isLoading: entry.isChecking) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(entry.text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(UD.bg)
    }

    private func submit() {
        Task {
            if let path = await entry.submit(using: connection) { onChoose(path) }
        }
    }
}
