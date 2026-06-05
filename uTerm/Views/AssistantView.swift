import SwiftUI
import SwiftData

enum AssistantInputBarLayout {
    /// 底栏图标钮（附加 / 发送）点击区，对齐设计稿 28×28。
    nonisolated static let attachHitSize: CGFloat = 28
    nonisolated static let attachIconSize: CGFloat = 12
    nonisolated static let attachCornerRadius: CGFloat = 7
    /// 发送钮与附加钮同尺寸（28²），保持底栏对称。
    nonisolated static let sendButtonHeight: CGFloat = 28
    nonisolated static let keycapHeight: CGFloat = 20
    nonisolated static let sendContentAlignment: VerticalAlignment = .center
}

/// AI 助手聊天面板。布局对齐工作区设计稿（`workspace.jsx`）的 Agent inspector
/// 最终形态（Cursor 风格）：
/// - 顶栏：✦ + 会话标题（点开 → 会话历史下拉）+ 新建对话。
/// - 聊天区：对话直接平铺在标题下——用户气泡 / 助手裸文本 + 流式光标（无角色标签、无 meta 行）。
/// - 输入区：圆角卡片，底栏左侧模型胶囊 `● <模型> ▾`，右侧附件 + ↩ 发送（去掉上方分割线）。
///
/// 0 provider：空状态 + 「打开 Settings」按钮。
struct AssistantView: View {
    /// 当前活动服务器的简述，进 system prompt（无则空串）。
    let serverContext: String
    /// meta 行展示的服务器短名（无则只显示「当前会话」）。
    var serverName: String = ""
    @Bindable var model: AssistantModel
    @Binding var activeProviderIDString: String

    @Environment(\.openSettings) private var openSettings
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]

    @State private var showSessions = false

    var body: some View {
        Group {
            if model.providers.isEmpty {
                emptyState
            } else {
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        header
                        chat
                    }
                    if showSessions {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { showSessions = false }
                        sessionsDropdown
                            .padding(.top, 38)
                            .padding(.horizontal, 12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.attach(context: modelContext) }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(UD.accent)

            Button {
                showSessions.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(model.sessionTitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(UD.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(UD.text3)
                        .rotationEffect(.degrees(showSessions ? 180 : 0))
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(showSessions ? UD.fillSoft : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                model.startNewSession()
                showSessions = false
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UD.text3)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("新建对话")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 36)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }

    // MARK: - 模型选择胶囊（输入区底栏，Cursor 风格 ● <模型> ▾）

    /// 底栏模型胶囊：原 meta 行的 provider 选择器，移到输入框页脚（设计稿 chat8）。
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
            Button("管理…") { openSettings() }
        } label: {
            UDModelPillLabel(modelPillLabel)
        }
        // .button + plain 渲染完整自定义 label（含蓝点 + 末尾 ▾ + 描边胶囊）；
        // .borderlessButton 会把自定义 label 压扁成纯文本 + 前置系统箭头。
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 胶囊文案：优先显示模型名（如 `claude-sonnet`），否则 provider 名；过长则省略。
    private var modelPillLabel: String {
        let raw: String
        if let p = model.activeProvider {
            raw = p.model.isEmpty ? p.name : p.model
        } else {
            raw = "未选择"
        }
        return raw.count > 22 ? String(raw.prefix(21)) + "…" : raw
    }

    // MARK: - 会话历史下拉

    private var sessionsDropdown: some View {
        VStack(spacing: 0) {
            Text("会话历史")
                .font(.system(size: 10.5))
                .tracking(0.5)
                .foregroundStyle(UD.text4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(UD.border).frame(height: 1)
                }

            if sessions.isEmpty {
                Text("还没有历史会话")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UD.text4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(sessions) { sessionRow($0) }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 280)
            }

            Button {
                model.startNewSession()
                showSessions = false
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 11))
                    Text("新建对话").font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(UD.text2)
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) {
                Rectangle().fill(UD.border).frame(height: 1)
            }
        }
        .background(UD.panelHi)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9).strokeBorder(UD.borderHi, lineWidth: 1))
        .shadow(color: UD.dyn(.black(0.55), .black(0.18)), radius: 18, x: 0, y: 14)
    }

    private func sessionRow(_ s: ChatSession) -> some View {
        let isActive = s.id == model.currentSession?.id
        return Button {
            model.load(s)
            showSessions = false
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(s.title.isEmpty ? "新对话" : s.title)
                        .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? UD.text : UD.text2)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(relativeTime(s.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(UD.text4)
                }
                if !s.preview.isEmpty {
                    Text(s.preview)
                        .font(.system(size: 11))
                        .foregroundStyle(UD.text4)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? UD.accent.opacity(0.10) : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isActive ? UD.accent.opacity(0.20) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("删除", role: .destructive) { delete(s) }
        }
    }

    private func delete(_ s: ChatSession) {
        if s.id == model.currentSession?.id { model.startNewSession() }
        modelContext.delete(s)
        try? modelContext.save()
    }

    private func relativeTime(_ date: Date) -> String {
        let now = Date()
        let cal = Calendar.current
        if now.timeIntervalSince(date) < 60 { return "刚刚" }
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return "今天 \(f.string(from: date))"
        }
        if cal.isDateInYesterday(date) { return "昨天" }
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: date),
                                      to: cal.startOfDay(for: now)).day ?? 0
        if days < 7 { return "\(days) 天前" }
        let f = DateFormatter(); f.dateFormat = "M/d"
        return f.string(from: date)
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.largeTitle).foregroundStyle(UD.text3)
            Text("还没添加 AI Provider")
                .font(.headline).foregroundStyle(UD.text)
            Text("在 Settings 添加一个 Anthropic / OpenAI 配置。")
                .font(.caption).foregroundStyle(UD.text3)
                .multilineTextAlignment(.center)
            UDButton(title: "打开 Settings", systemImage: "gearshape") {
                openSettings()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 聊天区

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.messages) { messageRow($0) }
                    }
                    .padding(EdgeInsets(top: 14, leading: 14, bottom: 8, trailing: 14))
                }
                .onChange(of: model.messages.last?.text) { _, _ in scrollToBottom(proxy) }
                .onChange(of: model.messages.last?.id) { _, _ in scrollToBottom(proxy) }
            }
            inputBar
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if let last = model.messages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        let isStreamingTail = !isUser
            && message.id == model.messages.last?.id
            && model.state == .streaming
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if isUser {
                    Text(message.text)
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .foregroundStyle(UD.text2)
                } else if message.text.isEmpty && !isStreamingTail {
                    Text("…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(UD.text3)
                } else {
                    StreamingMarkdownView(text: message.text, isStreaming: isStreamingTail)
                        .textSelection(.enabled)
                }
                if isStreamingTail {
                    StreamingCaret()
                }
            }
            .padding(.vertical, isUser ? 10 : 0)
            .padding(.horizontal, isUser ? 12 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isUser ? UD.fillFaint : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isUser ? UD.border : .clear, lineWidth: 1))

            ForEach(message.toolCalls) { call in
                UDToolCall(
                    label: call.explanation ?? "运行命令",
                    command: call.command,
                    status: udStatus(call),
                    onRun: { Task { await model.approveAndRun(id: call.id) } },
                    onSkip: { Task { await model.skip(id: call.id) } }
                )
            }
        }
        .id(message.id)
    }

    private func udStatus(_ call: ToolCallState) -> UDToolCall.Status {
        switch call.status {
        case .pending, .running: return .pending
        case .done, .failed, .skipped: return .done(output: call.output)
        }
    }

    // MARK: - 输入区

    private var inputBar: some View {
        UDComposer(
            text: $model.input,
            onSend: sendIfPossible,
            onAttach: attachCurrentContext,
            modelControl: { modelPill }
        )
        .padding(10)
    }

    private func sendIfPossible() {
        guard model.state != .streaming else { return }
        Task { await model.send(serverContext: serverContext) }
    }

    private func attachCurrentContext() {
        let snippet = currentContextSnippet()
        guard !snippet.isEmpty else { return }
        if model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.input = snippet
        } else {
            model.input += "\n\n\(snippet)"
        }
    }

    private func currentContextSnippet() -> String {
        let context = serverContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            return "上下文：\n\(context)"
        }
        let name = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "" : "当前服务器：\(name)"
    }
}

/// 流式输出时的闪烁光标。
private struct StreamingCaret: View {
    @State private var on = true
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(UD.accent)
            .frame(width: 4, height: 12)
            .opacity(on ? 1 : 0.15)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    on = false
                }
            }
    }
}
