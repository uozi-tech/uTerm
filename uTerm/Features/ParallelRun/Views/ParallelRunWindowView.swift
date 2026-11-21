import UDesignKit
import SwiftUI
import SwiftData

/// 一个并行执行窗口：把一条快捷命令在其绑定的多台服务器上「广播」执行（由
/// `ParallelRunWindowID.commandID` 指定）。自绘扁平 chrome（`WorkspaceWindowChrome`）。
///
/// 结构镜像 `PortForwardWindowView`：`@Query` 取命令与服务器、解析目标，缺失时显占位；
/// chrome / 去顶部安全区 / 主题底都挂在稳定的 `VStack` 上。执行 / 自愈逻辑在
/// `ParallelRunModel`，AI 诊断走 `ParallelAIDoctor`（按当前活动 provider）。
struct ParallelRunWindowView: View {
    let windowID: ParallelRunWindowID?

    /// 界面画廊（`UICatalog`）注入的模型（带假执行器）。App 里恒为 nil。
    init(windowID: ParallelRunWindowID?, catalogModel: ParallelRunModel? = nil) {
        self.windowID = windowID
        _model = State(initialValue: catalogModel)
    }

    @Query private var commands: [QuickCommand]
    @Query private var profiles: [ServerProfile]
    @Query(sort: \AIProvider.sortOrder) private var providers: [AIProvider]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @AppStorage(DefaultsKey.activeProviderID) private var activeProviderIDString: String = ""
    @AppStorage(DefaultsKey.agentSafety) private var agentSafetyRaw: String = AgentSafety.readAuto.rawValue

    @State private var model: ParallelRunModel?

    private var command: QuickCommand? {
        guard let id = windowID?.commandID else { return nil }
        return commands.first { $0.id == id }
    }

    /// 命令绑定且仍可执行（剔除 sftpOnly）的目标，按 serverIDs 顺序。
    private var targets: [ServerProfile] {
        guard let command else { return [] }
        return command.serverIDs
            .compactMap { id in profiles.first { $0.id == id } }
            .filter { !$0.sftpOnly }
    }

    var body: some View {
        content
            .frame(minWidth: 760, minHeight: 540)
            .ignoresSafeArea(.container, edges: .top)
            .background(UD.bg)
            .background(WorkspaceWindowChrome(serverName: chromeTitle))
            .task(id: windowID?.commandID) { buildModelIfNeeded() }
    }

    private var chromeTitle: String {
        ServerChromeTitle.parallelRunWindowTitle(commandName: command?.name)
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            VStack(spacing: 0) {
                ParallelRunTitleBar(commandName: model.commandName,
                                    aiAssisted: model.aiAssisted,
                                    total: model.total,
                                    mode: Binding(get: { model.mode }, set: { model.mode = $0 }),
                                    running: !model.allDone,
                                    onRerun: { model.rerun() },
                                    onClose: { dismiss() })
                ParallelBroadcastBar(text: model.broadcastText,
                                     isIntent: model.broadcastIsIntent,
                                     mode: model.mode,
                                     total: model.total,
                                     doneCount: model.doneCount,
                                     okCount: model.okCount,
                                     failedCount: model.failedCount,
                                     startedAt: model.startedAt,
                                     finishedAt: model.finishedAt)
                Group {
                    if model.mode == .ai {
                        ParallelAgentView(commandName: model.commandName,
                                          aiAssisted: model.aiAssisted,
                                          states: model.states,
                                          synthesis: model.synthesis,
                                          allDone: model.allDone,
                                          onTrustAndRetry: { model.trustAndRetry(serverID: $0) })
                    } else {
                        ParallelShellGrid(states: model.states,
                                          onTrustAndRetry: { model.trustAndRetry(serverID: $0) })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                ParallelStatusBar(mode: model.mode,
                                  total: model.total,
                                  doneCount: model.doneCount,
                                  failedCount: model.failedCount,
                                  allDone: model.allDone)
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 0) {
            // 占位也带一条最小标题栏，红绿灯有处可栖。
            ZStack {
                HStack(spacing: 0) { Color.clear.frame(width: 68); Spacer() }
                Text("并行执行").font(.system(size: 13, weight: .medium)).foregroundStyle(UD.text)
            }
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(WindowDragHandle())
            .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }

            VStack(spacing: 12) {
                Image(systemName: windowID == nil ? "clock" : "exclamationmark.triangle")
                    .font(.system(size: 30)).foregroundStyle(UD.text3)
                Text(placeholderText).font(.system(size: 14)).foregroundStyle(UD.text2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var placeholderText: String {
        if windowID == nil { return "正在恢复…" }
        if command == nil { return "命令已删除" }
        return "没有可执行的目标主机"
    }

    // MARK: - 构建模型

    private func buildModelIfNeeded() {
        guard model == nil, let command, !targets.isEmpty else { return }
        let store = QuickCommandStore(context: modelContext)
        let m = ParallelRunModel(commandID: command.id,
                                 commandName: command.name,
                                 command: command.command,
                                 intent: command.intent,
                                 aiAssisted: command.aiAssisted,
                                 targets: targets,
                                 doctor: command.aiAssisted ? makeDoctor() : nil,
                                 approval: .safety(AgentSafety(rawValue: agentSafetyRaw) ?? .readAuto),
                                 hostLabel: "macOS 原生 SSH 终端",
                                 store: store,
                                 container: modelContext.container)
        model = m
        m.start()
    }

    /// 按当前活动 provider 造模型后端（与 iOS 共用 `ParallelAIDoctor.make`）；
    /// 缺 provider / key / 地址 / 模型则返回 nil（退回模板叙述）。
    private func makeDoctor() -> ParallelAIDoctor? {
        ParallelAIDoctor.make(providers: providers,
                              activeProviderID: UUID(uuidString: activeProviderIDString))
    }
}
