import UDesignKit
import SwiftUI
import SwiftData

/// 快捷命令面板：左列表 + 右详情/表单（复刻原型 `pages/quick-commands.jsx`）。
/// 沿用欢迎页「左列表 + 右详情」隐喻，全部走 DesignKit `UD` token。
struct QuickCommandList: View {
    /// 已有服务器（多选 + 目标解析用）。由 WelcomeView 传入。
    let hosts: [ServerProfile]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    @Query(sort: \QuickCommand.sortOrder) private var commands: [QuickCommand]

    @State private var selectedID: UUID?
    @State private var mode: Mode = .view
    @State private var runner = QuickCommandRunner()

    enum Mode: Equatable { case view, create, edit }

    private var store: QuickCommandStore { QuickCommandStore(context: modelContext) }

    /// 表单可选服务器：剔除「仅 SFTP」主机（禁命令执行，不能作为快捷命令目标）。
    private var hostRefs: [QuickCommandHostRef] {
        hosts.filter { !$0.sftpOnly }.map {
            QuickCommandHostRef(id: $0.id,
                                name: QuickCommandTargets.displayName($0),
                                group: $0.group,
                                username: $0.username,
                                host: $0.host,
                                port: $0.port)
        }
    }

    private var selected: QuickCommand? {
        guard let selectedID else { return nil }
        return commands.first { $0.id == selectedID }
    }

    var body: some View {
        Group {
            if commands.isEmpty && mode == .view {
                QuickCommandEmptyState { mode = .create }
            } else {
                HStack(spacing: 0) {
                    listColumn
                    rightPanel
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UD.panel)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: commands.map(\.id)) { _, _ in selectFirstIfNeeded() }
    }

    // MARK: 左列表

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Text("快捷命令")
                        .font(.system(size: 12))
                        .foregroundStyle(UD.text3)
                        .tracking(0.3)
                    Text("· \(commands.count)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(UD.text4)
                }
                Spacer()
                UDButton(title: String(localized: "新建命令"), style: .primary, systemImage: "plus") {
                    startCreate()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            // 分区方案 v3：列表头并入卡顶，无底线。
            .frame(height: 44)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(commands) { cmd in
                        QuickCommandRow(command: cmd,
                                        serverCount: cmd.serverIDs.count,
                                        firstServerName: firstServerName(for: cmd),
                                        selected: selectedID == cmd.id && mode == .view) {
                            selectedID = cmd.id
                            mode = .view
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 右栏（详情 / 表单）

    @ViewBuilder
    private var rightPanel: some View {
        switch mode {
        case .create:
            QuickCommandForm(hostRefs: hostRefs, initial: nil,
                             onCancel: { mode = .view },
                             onSave: { saveCreate($0) })
            .id("create")
            .transition(.move(edge: .trailing).combined(with: .opacity))
        case .edit:
            if let selected {
                QuickCommandForm(hostRefs: hostRefs, initial: selected,
                                 onCancel: { mode = .view },
                                 onSave: { saveEdit(selected, $0) })
                .id("edit-\(selected.id)")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        case .view:
            if let selected {
                QuickCommandDetail(command: selected,
                                   hosts: hosts,
                                   runner: runner,
                                   onEdit: { mode = .edit },
                                   onToggleAI: { store.setAIAssisted(selected, $0) },
                                   onRun: { run(selected) },
                                   onDelete: { delete(selected) })
                .id(selected.id)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    // MARK: 派生

    private func firstServerName(for cmd: QuickCommand) -> String? {
        guard let first = cmd.serverIDs.first else { return nil }
        return QuickCommandTargets.resolve([first], in: hosts).first?.name
    }

    private func selectFirstIfNeeded() {
        if let selectedID, commands.contains(where: { $0.id == selectedID }) { return }
        selectedID = commands.first?.id
    }

    // MARK: 动作

    private func startCreate() {
        withAnimation(.easeOut(duration: 0.18)) { mode = .create }
    }

    private func saveCreate(_ data: QuickCommandForm.FormData) {
        let cmd = store.create(name: data.name, serverIDs: data.serverIDs,
                               command: data.command, intent: data.intent,
                               aiAssisted: data.aiAssisted)
        selectedID = cmd.id
        withAnimation(.easeOut(duration: 0.18)) { mode = .view }
    }

    private func saveEdit(_ cmd: QuickCommand, _ data: QuickCommandForm.FormData) {
        store.update(cmd, name: data.name, serverIDs: data.serverIDs,
                     command: data.command, intent: data.intent,
                     aiAssisted: data.aiAssisted)
        withAnimation(.easeOut(duration: 0.18)) { mode = .view }
    }

    private func delete(_ cmd: QuickCommand) {
        // 选中相邻项（优先后一条，否则前一条），对齐「删除后自动选中下一条」。
        // 删除前按当前顺序算好，不依赖 @Query 的异步刷新。
        let idx = commands.firstIndex(where: { $0.id == cmd.id })
        let remaining = commands.filter { $0.id != cmd.id }
        store.delete(cmd)
        if let idx, !remaining.isEmpty {
            selectedID = remaining[min(idx, remaining.count - 1)].id
        } else {
            selectedID = remaining.first?.id
        }
        mode = .view
    }

    /// 运行：多台 → 独立并行执行窗口（广播）；单台 + AI → 工作区 Agent；单台 → 真实执行。
    /// 三路均剔除「仅 SFTP」主机 —— 它们禁命令执行，不能作为目标。
    private func run(_ cmd: QuickCommand) {
        let targets = QuickCommandTargets.runnable(cmd.serverIDs, in: hosts)
        guard !targets.isEmpty else { return }

        // 多台 → 独立并行执行窗口（广播 + 逐台结果 / AI 自愈）。运行计数与日志由该窗口
        // 在执行落定后经 QuickCommandStore.recordRun 写入，故此处不再 recordInvocation。
        if targets.count > 1 {
            openWindow(value: ParallelRunWindowID(commandID: cmd.id))
            return
        }

        if cmd.aiAssisted {
            let primary = targets[0]
            // AI 命令以自然语言意图为主预填给 Agent（缺失则退回等效命令）。
            let prefill = QuickCommandLogic.agentPrefill(name: cmd.name, intent: cmd.intent, command: cmd.command)
            QuickCommandInbox.shared.enqueue(serverID: primary.id, command: prefill)
            primary.lastConnectedAt = Date()
            // AI 命令在 Agent 会话里交互执行，无逐台退出码可记 —— 只更新 上次运行/运行次数。
            store.recordInvocation(cmd)
            openWindow(value: WorkspaceWindowID(serverID: primary.id))
        } else {
            // 真实并行执行（结果落库于 runner 内）。Task 继承 MainActor 隔离，
            // 显式丢弃返回值 —— QuickCommandRun 是 @Model，不能作 Task.Success（非 Sendable）。
            let container = modelContext.container
            let store = store
            Task { _ = await runner.run(cmd, targets: targets, store: store, container: container) }
        }
    }
}

// MARK: - 列表行

/// 单条快捷命令行：`>_` 字形图标 + 名称 + `$ 命令` 等宽预览 + 右侧右对齐徽标簇。
struct QuickCommandRow: View {
    let command: QuickCommand
    let serverCount: Int
    let firstServerName: String?
    let selected: Bool
    let onTap: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                QCPromptGlyph(size: 30, ai: command.aiAssisted)

                VStack(alignment: .leading, spacing: 3) {
                    Text(command.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(UD.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    subtitle
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if command.aiAssisted { QCAiBadge(compact: true) }
                    QCServersBadge(count: serverCount, firstName: firstServerName)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(UD.text3)
                    .opacity(hover || selected ? 0.9 : 0)
                    .offset(x: hover || selected ? 0 : -3)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .background(rowBackground)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.14), value: hover)
    }

    /// 副标题：AI 命令显示自然语言意图（前置紫色火花、无 `$`）；非 AI 显示 `$ 命令` 等宽预览。
    @ViewBuilder
    private var subtitle: some View {
        if command.aiAssisted {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(UD.aiAccent)
                Text(QuickCommandLogic.aiIntentText(name: command.name, intent: command.intent))
                    .font(.system(size: 12))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            Text(commandPreview)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var commandPreview: AttributedString {
        var dollar = AttributedString("$ ")
        dollar.foregroundColor = UD.text4
        var rest = AttributedString(command.command)
        rest.foregroundColor = UD.text3
        return dollar + rest
    }

    private var rowBackground: Color {
        if selected { return Color.primary.opacity(0.06) }
        if hover { return Color.primary.opacity(0.028) }
        return .clear
    }
}

// MARK: - 空态

/// 无快捷命令时的大空态（区别于「无搜索结果」）。
struct QuickCommandEmptyState: View {
    let onNew: () -> Void

    /// 「AI 介入」染紫，其余继承 text3。用 AttributedString 避免 Text `+` 拼接（macOS 26 已弃用）。
    private var blurb: AttributedString {
        // 整句一个键（译者能调语序），再把其中的「AI 介入」那段找出来染色。
        let ai = String(localized: "AI 介入")
        let sentence = String(localized: "把常用运维操作存成一条命令，绑定一台或多台主机并行执行，也可以让 \(ai)，自动诊断并续接。",
                              comment: "参数是染色显示的「AI 介入」")
        var text = AttributedString(sentence)
        if let range = text.range(of: ai) {
            text[range].foregroundColor = UD.aiAccent
        }
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            QCPromptGlyph(size: 48, ai: false)
            Text("还没有快捷命令")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(UD.text)
                .padding(.top, 16)
            Text(blurb)
                .font(.system(size: 12.5))
                .foregroundStyle(UD.text3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 360)
                .padding(.top, 8)

            UDButton(title: String(localized: "新建命令"), style: .primary, systemImage: "plus", action: onNew)
                .padding(.top, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
