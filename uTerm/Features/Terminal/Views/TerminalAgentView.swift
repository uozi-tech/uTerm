import SwiftUI
import SwiftData

/// 终端窗口的「纯 Agent 模式」：用自然语言驱动运维。对齐设计稿 `pages/terminal-agent.jsx`。
///
/// 布局：上下文条（主机 · 历史 · 新对话）→ 居中对话区（max 760，命令卡 = 真实
/// `run_command` 工具调用）→ 输入区（安全档位拨盘 + 模型胶囊 + 建议 + 发送）。
/// 复用 `AssistantModel`（真实流式 + 工具审批）与 DesignKit `UDToolCall` / `UDComposer`。
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
        .onChange(of: model.state) { _, now in
            guard safety.autoApprovesPending, now == .awaitingApproval,
                  let id = firstPendingToolCallID() else { return }
            Task { await model.approveAndRun(id: id) }
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
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.messages) { messageRow($0) }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .frame(maxHeight: .infinity)
                // 默认贴底；新消息 / 流式增量 / 工具状态变化都滚到底（工具卡输出增长不改
                // message.text，故还要听 messages.count 与 state）。
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.messages.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: model.messages.last?.text) { _, _ in scrollToBottom(proxy) }
                .onChange(of: model.state) { _, _ in scrollToBottom(proxy) }
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
            HStack(alignment: .top, spacing: 10) {
                agentAvatar
                VStack(alignment: .leading, spacing: 6) {
                    if !m.text.isEmpty {
                        StreamingMarkdownView(text: m.text, isStreaming: isStreamingTail(m))
                            .textSelection(.enabled)
                    } else if !isStreamingTail(m) && m.toolCalls.isEmpty {
                        Text("…").font(.system(size: 13)).foregroundStyle(UD.text3)
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
            }
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

    // MARK: - 空状态（按诊断 / 配置 / 部署分组的示例）

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
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.tag)
                            .font(.system(size: 10.5, weight: .medium))
                            .tracking(0.5).foregroundStyle(UD.text4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)],
                                  alignment: .leading, spacing: 8) {
                            ForEach(group.items, id: \.self) { item in
                                Button { model.input = item } label: {
                                    Text(item)
                                        .font(.system(size: 12)).foregroundStyle(UD.text2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 7).padding(.horizontal, 11)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(UD.fillFaint))
                                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UD.border, lineWidth: 1))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 输入区

    private var composer: some View {
        VStack(spacing: 9) {
            if !model.messages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.suggestions, id: \.self) { s in
                            Button { model.input = s } label: {
                                Text(s)
                                    .font(.system(size: 11.5)).foregroundStyle(UD.text3)
                                    .padding(.vertical, 5).padding(.horizontal, 10)
                                    .background(Capsule().fill(UD.fillFaint))
                                    .overlay(Capsule().strokeBorder(UD.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

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
    private static let suggestions: [String] = [
        "看看内存占用最高的 5 个进程",
        "为什么 14 点前后 502 变多",
        "把 nginx 日志大小限制到 100M",
        "重启 nginx 并验证健康检查",
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
