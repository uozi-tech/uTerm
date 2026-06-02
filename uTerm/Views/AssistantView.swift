import SwiftUI

/// AI 助手聊天面板。
/// - 0 provider：空状态 + 「打开 Settings」按钮。
/// - ≥1 provider：顶部 provider picker + 聊天区。
struct AssistantView: View {
    /// 当前活动服务器的简述，进 system prompt（无则空串）。
    let serverContext: String
    @Bindable var model: AssistantModel
    @Binding var activeProviderIDString: String

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if model.providers.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    providerHeader
                    Divider()
                    chat
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var providerHeader: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.providers) { p in
                    Button {
                        activeProviderIDString = p.id.uuidString
                    } label: {
                        if p.id == model.activeProvider?.id {
                            Label(p.name, systemImage: "checkmark")
                        } else {
                            Text(p.name)
                        }
                    }
                }
                Divider()
                Button("管理…") { openSettings() }
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text(model.activeProvider?.name ?? "未选择")
                    if let m = model.activeProvider?.model, !m.isEmpty {
                        Text(m).foregroundStyle(.secondary).font(.caption)
                    }
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .help("管理 Provider")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.largeTitle).foregroundStyle(AppTheme.Palette.textMuted)
            Text("还没添加 AI Provider")
                .font(.headline).foregroundStyle(AppTheme.Palette.textPrimary)
            Text("在 Settings 添加一个 Anthropic / OpenAI 配置。")
                .font(.caption).foregroundStyle(AppTheme.Palette.textMuted)
                .multilineTextAlignment(.center)
            Button("打开 Settings") { openSettings() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.messages) { messageRow($0) }
                    }
                    .padding(8)
                }
                .onChange(of: model.messages.last?.text) { _, _ in
                    if let last = model.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            Divider()
            inputBar
        }
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        // 不再用 bgSelected/bgRaised 的颜色差异区分（两者合并成同灰之后几乎
        // 无对比）。改成：共用 bgRaised 底 + accent 描边区分 user / assistant。
        // 大面积仍是灰色（user 反馈"避免大面积撞色"），但描边足以让用户
        // 一眼分辨。
        return HStack {
            if isUser { Spacer(minLength: 32) }
            Text(message.text.isEmpty ? "…" : message.text)
                .textSelection(.enabled)
                .padding(8)
                .background(AppTheme.Palette.bgRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isUser
                                ? AppTheme.Palette.accent.opacity(0.55)
                                : AppTheme.Palette.border,
                            lineWidth: isUser ? 1 : 0.5
                        )
                )
            if !isUser { Spacer(minLength: 32) }
        }
        .id(message.id)
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("问点什么…", text: $model.input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { sendIfPossible() }
            Button {
                sendIfPossible()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(model.state == .streaming)
        }
        .padding(8)
    }

    private func sendIfPossible() {
        guard model.state != .streaming else { return }
        Task { await model.send(serverContext: serverContext) }
    }
}
