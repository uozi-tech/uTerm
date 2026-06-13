import SwiftUI
import SwiftData

/// 终端窗口的「纯 Agent 模式」：用自然语言驱动运维。对齐设计稿 `pages/terminal-agent.jsx`。
///
/// 布局：上下文条（主机 · 历史 · 新对话）→ 居中对话区（max 760；空状态居中、命令卡
/// 整宽 = 真实 `run_command` 工具调用；每条回复下方「猜你想问」动态追问）→ 输入区
/// （安全档位拨盘 + 模型胶囊 + 发送）。
/// 复用 `AssistantModel`（真实流式 + 工具审批 + 追问生成）与 DesignKit `UDToolCall` / `UDComposer`。
struct TerminalAgentView: View {
    @Bindable var model: AssistantModel
    let host: String
    let serverContext: String
    @Binding var safety: AgentSafety
    @Binding var activeProviderIDString: String
    let onOpenSettings: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]

    var body: some View {
        Group {
            if model.providers.isEmpty {
                emptyProviderState
            } else {
                VStack(spacing: 0) {
                    contextBar
                    conversation
                    composer
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UD.bg)
        .onAppear { model.attach(context: modelContext) }
        // 「自动执行」档位：进入「待确认」即自动批准首个 pending（逐条迭代——每条执行
        // 完后状态机若仍有 pending 会再回到 .awaitingApproval，触发本回调批准下一条）。
        .onChange(of: model.state) { old, now in
            // 「自动执行」档位：进入待确认即自动批准首个 pending（逐条迭代）。
            if safety.autoApprovesPending, now == .awaitingApproval,
               let id = firstPendingToolCallID() {
                Task { await model.approveAndRun(id: id) }
            }
            // 回复落定（流式/执行 → idle 或 非自动的待确认）→ 刷新「猜你想问」追问。
            let wasActive = (old == .streaming || old == .running)
            let settled = now == .idle || (now == .awaitingApproval && !safety.autoApprovesPending)
            if wasActive && settled, model.messages.last?.role == .assistant {
                model.refreshFollowUps(serverContext: serverContext)
            }
        }
    }

    // MARK: - 上下文条

    private var contextBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(UD.text3)
            Text("上下文").font(.system(size: 11.5)).foregroundStyle(UD.text2)
            Text(host).font(UD.mono(11)).foregroundStyle(UD.text3)
            Spacer(minLength: 8)

            Menu {
                if sessions.isEmpty {
                    Text("还没有历史会话")
                } else {
                    ForEach(sessions) { s in
                        Button(s.title.isEmpty ? "新对话" : s.title) { model.load(s) }
                    }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12)).foregroundStyle(UD.text3)
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("会话历史")

            Button { model.startNewSession() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12)).foregroundStyle(UD.text3)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("新对话").accessibilityLabel("新对话")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(UD.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }

    // MARK: - 对话区

    @ViewBuilder
    private var conversation: some View {
        if model.messages.isEmpty {
            // 空状态：居中铺满（不进 ScrollView），避免内容偏上 + 出现滚动条。
            emptyState
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.messages) { messageRow($0) }
                        // 最后一条是助手 → 其下方「猜你想问」动态追问。
                        if model.messages.last?.role == .assistant {
                            followUpsView
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .frame(maxHeight: .infinity)
                // 默认贴底；新消息 / 流式增量 / 工具状态变化 / 追问出现都滚到底（工具卡输出
                // 增长不改 message.text，故还要听 messages.count 与 state）。
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.messages.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: model.messages.last?.text) { _, _ in scrollToBottom(proxy) }
                .onChange(of: model.state) { _, _ in scrollToBottom(proxy) }
                .onChange(of: model.followUps) { _, _ in scrollToBottom(proxy) }
                .onChange(of: model.followUpsLoading) { _, _ in scrollToBottom(proxy) }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    @ViewBuilder
    private func messageRow(_ m: ChatMessage) -> some View {
        if m.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(m.text)
                    .font(.system(size: 13))
                    .foregroundStyle(UD.text)
                    .textSelection(.enabled)
                    .padding(.vertical, 10).padding(.horizontal, 13)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(UD.accent.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(UD.accent.opacity(0.22), lineWidth: 1))
            }
            .id(m.id)
        } else {
            // 文本带头像；命令卡整宽（不跟随头像缩进 → 左右对称，去掉头像下方竖直空槽）。
            VStack(alignment: .leading, spacing: 8) {
                if !m.text.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        agentAvatar
                        StreamingMarkdownView(text: m.text, isStreaming: isStreamingTail(m))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if !isStreamingTail(m) && m.toolCalls.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        agentAvatar
                        Text("…").font(.system(size: 13)).foregroundStyle(UD.text3)
                    }
                }
                ForEach(m.toolCalls) { call in
                    UDToolCall(
                        label: call.explanation ?? "运行命令",
                        command: call.command,
                        status: udStatus(call),
                        // 自动执行档位下卡片按钮禁用（由 onChange 自动批准）。
                        approvalEnabled: model.state == .awaitingApproval && !safety.autoApprovesPending,
                        onRun: { Task { await model.approveAndRun(id: call.id) } },
                        onSkip: { Task { await model.skip(id: call.id) } })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(m.id)
        }
    }

    private var agentAvatar: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 12))
            .foregroundStyle(UD.accent)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 7).fill(UD.accent.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UD.accent.opacity(0.28), lineWidth: 1))
    }

    private func isStreamingTail(_ m: ChatMessage) -> Bool {
        m.id == model.messages.last?.id && model.state == .streaming
    }

    private func udStatus(_ call: ToolCallState) -> UDToolCall.Status {
        switch call.status {
        case .pending: return .pending
        case .running: return .running
        case .done, .failed, .skipped: return .done(output: call.output)
        }
    }

    private func firstPendingToolCallID() -> String? {
        for m in model.messages {
            if let c = m.toolCalls.first(where: { $0.status == .pending }) { return c.id }
        }
        return nil
    }

    // MARK: - 「猜你想问」动态追问（替换写死建议）

    @ViewBuilder
    private var followUpsView: some View {
        // 流式 / 执行中不显示（回复尚未落定）。
        if model.state != .streaming && model.state != .running {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11)).foregroundStyle(UD.accent.opacity(0.85))
                    Text("猜你想问").font(.system(size: 11)).tracking(0.3).foregroundStyle(UD.text4)
                    Spacer(minLength: 8)
                    Button { model.refreshFollowUps(serverContext: serverContext) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10))
                            Text("换一批").font(.system(size: 11))
                        }
                        .foregroundStyle(UD.text3)
                        .padding(.horizontal, 8).frame(height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(UD.border, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("换一批").disabled(model.followUpsLoading)
                }

                if model.followUpsLoading {
                    WrapLayout(spacing: 8, lineSpacing: 8, alignment: .leading) {
                        ForEach([CGFloat(64), 92, 78], id: \.self) { w in
                            Capsule().fill(UD.fillFaint)
                                .overlay(Capsule().strokeBorder(UD.border, lineWidth: 1))
                                .frame(width: w, height: 30)
                                .modifier(SkeletonShimmer())
                        }
                    }
                } else {
                    WrapLayout(spacing: 8, lineSpacing: 8, alignment: .leading) {
                        ForEach(model.followUps, id: \.self) { s in
                            Button { model.input = s } label: { followUpChip(s) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
            // 进入视图且对话已落定但尚无追问 → 生成一次（覆盖载入历史会话的情形；与状态
            // 落定的 onChange 互不重复——后者已置 loading=true，这里被 guard 跳过）。
            .onAppear {
                if (model.state == .idle || model.state == .awaitingApproval),
                   model.followUps.isEmpty, !model.followUpsLoading {
                    model.refreshFollowUps(serverContext: serverContext)
                }
            }
        }
    }

    private func followUpChip(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(UD.accent)
            Text(text).font(.system(size: 12)).foregroundStyle(UD.text2)
        }
        .padding(.vertical, 6).padding(.horizontal, 12)
        .background(Capsule().fill(UD.accent.opacity(0.06)))
        .overlay(Capsule().strokeBorder(UD.accent.opacity(0.20), lineWidth: 1))
        .contentShape(Capsule())
    }

    // MARK: - 空状态（按诊断 / 配置 / 部署分组的示例，居中）

    private var emptyState: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24)).foregroundStyle(UD.accent)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 14).fill(UD.accent.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(UD.accent.opacity(0.28), lineWidth: 1))
                VStack(spacing: 5) {
                    Text("用自然语言操作 \(host)")
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(UD.text)
                        .multilineTextAlignment(.center)
                    Text("描述你想做的事，Agent 会翻译成命令、征求确认后在远端执行。")
                        .font(.system(size: 12.5)).foregroundStyle(UD.text3)
                        .multilineTextAlignment(.center)
                }
            }

            VStack(spacing: 14) {
                ForEach(Self.emptyGroups, id: \.tag) { group in
                    VStack(spacing: 8) {
                        // 分组标题居中
                        Text(group.tag)
                            .font(.system(size: 10.5, weight: .medium))
                            .tracking(0.5).foregroundStyle(UD.text4)
                            .frame(maxWidth: .infinity, alignment: .center)
                        // 气泡居中换行
                        WrapLayout(spacing: 8, lineSpacing: 8, alignment: .center) {
                            ForEach(group.items, id: \.self) { item in
                                Button { model.input = item } label: { exampleChip(item) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 430)
        }
        .frame(maxWidth: .infinity)
    }

    private func exampleChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(UD.text2)
            .multilineTextAlignment(.center)
            .padding(.vertical, 7).padding(.horizontal, 11)
            .background(RoundedRectangle(cornerRadius: 8).fill(UD.fillFaint))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UD.border, lineWidth: 1))
            .contentShape(Rectangle())
    }

    // MARK: - 输入区

    private var composer: some View {
        // 写死建议条已移除 —— 改为每条助手回复下方的「猜你想问」动态追问（见 followUpsView）。
        UDComposer(
            text: $model.input,
            placeholder: "用自然语言描述你想做的事…  例如：把 nginx 日志限制到 100M",
            queueing: model.isBusy,
            onSend: { Task { await model.submit(serverContext: serverContext) } },
            onAttach: attachContext
        ) {
            HStack(spacing: 6) {
                SafetyDial(safety: $safety)
                modelPill
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 14)
        .background(UD.bg)
        .overlay(alignment: .top) { Rectangle().fill(UD.border).frame(height: 1) }
    }

    private func attachContext() {
        let snippet = "上下文：\n\(serverContext)"
        if model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.input = snippet
        } else {
            model.input += "\n\n\(snippet)"
        }
    }

    private var modelPill: some View {
        Menu {
            ForEach(model.providers) { p in
                Button {
                    activeProviderIDString = p.id.uuidString
                } label: {
                    let label = p.model.isEmpty ? p.name : "\(p.name) · \(p.model)"
                    if p.id == model.activeProvider?.id {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
            Divider()
            Button("管理…") { onOpenSettings() }
        } label: {
            UDModelPillLabel(modelPillLabel)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private var modelPillLabel: String {
        let raw = model.activeProvider.map { $0.model.isEmpty ? $0.name : $0.model } ?? "未选择"
        return raw.count > 22 ? String(raw.prefix(21)) + "…" : raw
    }

    // MARK: - 0 provider 空状态

    private var emptyProviderState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(UD.text3)
            Text("还没添加 AI Provider").font(.headline).foregroundStyle(UD.text)
            Text("在 Settings 添加一个 Anthropic / OpenAI 配置。")
                .font(.caption).foregroundStyle(UD.text3).multilineTextAlignment(.center)
            UDButton(title: "打开 Settings", systemImage: "gearshape") { onOpenSettings() }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 示例数据（建议 / 空状态分组）

    private struct EmptyGroup { let tag: String; let items: [String] }
    private static let emptyGroups: [EmptyGroup] = [
        .init(tag: "诊断", items: ["根分区是什么占满的", "最近的 5xx 集中在什么时间", "CPU 突然飙高是哪个进程"]),
        .init(tag: "配置", items: ["给 upstream 加上 keepalive", "把 SSH 端口改成 2222", "开启 gzip 压缩"]),
        .init(tag: "部署", items: ["拉取最新代码并重启服务", "回滚到上一个版本", "查看 systemd 服务状态"]),
    ]
}

// MARK: - 安全档位拨盘

/// 输入区左下角的「自然语言 → 执行」信任拨盘（设计稿 terminal-agent.jsx 的安全档位）。
struct SafetyDial: View {
    @Binding var safety: AgentSafety

    var body: some View {
        Menu {
            ForEach(AgentSafety.allCases) { s in
                Button { safety = s } label: {
                    if s == safety {
                        Label(s.label, systemImage: "checkmark")
                    } else {
                        Text(s.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 11)).foregroundStyle(UD.accent)
                Text(safety.label).font(.system(size: 11.5)).foregroundStyle(UD.text2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(UD.text4)
            }
            .padding(.leading, 9).padding(.trailing, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(UD.fillFaint))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(UD.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(safety.detail)
    }
}

// MARK: - 加载骨架呼吸

/// 「猜你想问」加载时骨架气泡的轻微呼吸（尊重 Reduce Motion）。
private struct SkeletonShimmer: ViewModifier {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion ? 0.6 : (on ? 0.4 : 0.75))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true }
            }
    }
}
