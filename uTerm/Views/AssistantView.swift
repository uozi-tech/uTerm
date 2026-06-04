import SwiftUI
import SwiftData

/// AI 助手聊天面板。布局对齐工作区设计稿的 Agent inspector：
/// - 顶栏：✦ + 会话标题（点开 → 会话历史下拉）+ 新建对话。
/// - meta 行：左服务器上下文，右 provider/模型选择器。
/// - 聊天区：角色标签 + 气泡（用户）/ 平铺（助手）+ 流式光标。
/// - 输入区：圆角卡片 + 附加按钮 + ↩ 发送。
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
                        metaRow
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
                .font(.system(size: 12))
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
                        .font(.system(size: 8, weight: .semibold))
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

    // MARK: - meta 行（服务器上下文 + 模型选择器）

    private var metaRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                Text(metaContext)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            providerPicker
        }
        .font(.system(size: 11))
        .foregroundStyle(UD.text3)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }

    private var metaContext: String {
        serverName.isEmpty ? "当前会话" : "\(serverName) · 当前会话"
    }

    private var providerPicker: some View {
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
            HStack(spacing: 5) {
                Circle().fill(UD.accent).frame(width: 5, height: 5)
                Text(model.activeProvider?.name ?? "未选择")
                    .font(.system(size: 11))
                    .foregroundStyle(UD.text2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(UD.text4)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
            Button("打开 Settings") { openSettings() }
                .buttonStyle(.borderedProminent)
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
            Text(isUser ? "你" : (model.activeProvider?.name ?? "助手"))
                .font(.system(size: 10.5))
                .tracking(0.4)
                .foregroundStyle(UD.text4)

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
            .padding(isUser ? 10 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isUser ? UD.fillFaint : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isUser ? UD.border : .clear, lineWidth: 1))
        }
        .id(message.id)
    }

    // MARK: - 输入区

    private var inputBar: some View {
        VStack(spacing: 10) {
            TextField("问点什么…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.system(size: 13))
                .foregroundStyle(UD.text)
                .onSubmit { sendIfPossible() }

            HStack(spacing: 6) {
                Button {} label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                        .foregroundStyle(UD.text3)
                        .frame(width: 24, height: 24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(UD.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(true)
                .help("附加上下文（即将支持）")

                Spacer()

                Button { sendIfPossible() } label: {
                    HStack(spacing: 5) {
                        Keycap("↩")
                        Text("发送")
                            .font(.system(size: 10.5))
                            .foregroundStyle(UD.text4)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.state == .streaming)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(UD.fillFaint))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UD.border, lineWidth: 1))
        .padding(10)
        .overlay(alignment: .top) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }

    private func sendIfPossible() {
        guard model.state != .streaming else { return }
        Task { await model.send(serverContext: serverContext) }
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

/// 小键帽（如 ↩）。
private struct Keycap: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(UD.text3)
            .frame(minWidth: 16, minHeight: 16)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(UD.fillSoft))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(UD.border, lineWidth: 1))
    }
}
