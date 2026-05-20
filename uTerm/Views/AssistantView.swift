import SwiftUI

/// AI 助手聊天面板。
struct AssistantView: View {
    /// 当前活动服务器的简述，进 system prompt（无则空串）。
    let serverContext: String
    @Bindable var model: AssistantModel

    @State private var keyDraft = ""

    var body: some View {
        Group {
            if model.hasAPIKey {
                chat
            } else {
                apiKeyEntry
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var apiKeyEntry: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
            Text("设置 Anthropic API Key").font(.headline)
            Text("AI 助手需要你的 Anthropic API Key。它将保存在 macOS 钥匙串。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            SecureField("sk-ant-…", text: $keyDraft)
                .textFieldStyle(.roundedBorder)
            Button("保存") {
                let k = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !k.isEmpty else { return }
                model.saveAPIKey(k)
                if !model.keySaveFailed { keyDraft = "" }
            }
            .buttonStyle(.borderedProminent)
            if model.keySaveFailed {
                Text("保存到钥匙串失败，请重试。")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.messages) { message in
                            messageRow(message)
                        }
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
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            Text(message.text.isEmpty ? "…" : message.text)
                .textSelection(.enabled)
                .padding(8)
                .background(message.role == .user
                            ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if message.role == .assistant { Spacer(minLength: 32) }
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
