import SwiftUI
import SwiftData

/// 可嵌入的 Agent 聊天面板：用于终端连接页的「Agent 模式」（对齐 macOS 终端窗口的
/// 终端 ⇄ Agent 切换）。由外部持有 `MobileAgentController`，使会话内容在「终端 / Agent」
/// 来回切换时得以保留；`serverContext` 注入当前主机上下文。无 provider 时引导添加。
struct MobileAgentChat: View {
    /// 由所属终端会话持有，跨模式切换保活对话历史。
    let controller: MobileAgentController
    /// 当前主机描述（如「web-01（root@10.0.0.1:22）」）。
    var serverContext: String? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.mAccent) private var accent
    @Query(sort: [SortDescriptor(\AIProvider.sortOrder)]) private var providers: [AIProvider]

    @State private var selectedProvider: UUID?
    @State private var input = ""
    @State private var addingProvider = false

    private var provider: AIProvider? {
        if let id = selectedProvider, let p = providers.first(where: { $0.id == id }) { return p }
        return providers.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if providers.isEmpty {
                MEmptyState(icon: "spark", title: "配置 AI Provider",
                            message: "添加 Anthropic 或 OpenAI 兼容服务，即可让 Agent 协助你操作这台主机。",
                            actionTitle: "添加 Provider", action: { addingProvider = true })
                .frame(maxHeight: .infinity)
            } else {
                providerBar
                // 输入条作为消息列表的底部安全区 inset：键盘弹出时随安全区上浮，
                // 始终悬于键盘之上（VStack 同级摆放在嵌套 ZStack 里不会被键盘避让上推）。
                messageList
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
        }
        .background(M.bg)
        .sheet(isPresented: $addingProvider) { ProviderFormSheet() }
        .onAppear { controller.contextHint = serverContext }
    }

    /// 顶部细条：当前 provider/model + 切换 / 添加 / 清空菜单。终端页已有主机标题栏，
    /// 故此处不再重复大标题。
    private var providerBar: some View {
        HStack(spacing: 8) {
            MIcon(name: "spark", size: 13, color: accent)
            if let provider {
                Text("\(provider.name) · \(provider.model.isEmpty ? provider.kind.displayName : provider.model)")
                    .font(M.mono(11.5)).foregroundStyle(M.text3).lineLimit(1)
            }
            Spacer(minLength: 6)
            Menu {
                ForEach(providers) { p in
                    Button { selectedProvider = p.id } label: {
                        Label(p.name, systemImage: provider?.id == p.id ? "checkmark" : "")
                    }
                }
                Divider()
                Button { addingProvider = true } label: { Label("添加 Provider", systemImage: "plus") }
                if !controller.messages.isEmpty {
                    Button(role: .destructive) { controller.clear() } label: { Label("清空对话", systemImage: "trash") }
                }
            } label: {
                MIcon(name: "ellipsis", size: 16, color: M.text2).frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(M.border).frame(height: 1) }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if controller.messages.isEmpty {
                        Text("问我任何关于这台主机的运维问题。")
                            .font(M.sans(14)).foregroundStyle(M.text4)
                            .padding(.top, 40)
                    }
                    ForEach(controller.messages) { msg in
                        AgentBubble(message: msg).id(msg.id)
                    }
                    if let err = controller.errorText {
                        Text(err).font(M.sans(12)).foregroundStyle(M.danger)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(M.danger.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: controller.messages.last?.text) {
                if let last = controller.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(alignment: .bottom) {
                TextField("发消息…", text: $input, axis: .vertical)
                    .font(M.sans(15)).foregroundStyle(M.text)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.sentences)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(M.inputBg)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(M.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 20))

            Button {
                if controller.streaming { controller.stop() }
                else if let p = provider { controller.send(input, provider: p); input = "" }
            } label: {
                MIcon(name: controller.streaming ? "x" : "send", size: 18, color: .white)
                    .frame(width: 44, height: 44)
                    .background(canSend || controller.streaming ? accent : M.text4)
                    .clipShape(Circle())
            }
            .disabled(!canSend && !controller.streaming)
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(M.border).frame(height: 1) }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespaces).isEmpty && provider != nil
    }
}

struct AgentBubble: View {
    let message: ChatMessage
    @Environment(\.mAccent) private var accent

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.text.isEmpty && message.role == .assistant ? "…" : message.text)
                    .font(M.sans(15))
                    .foregroundStyle(message.role == .user ? .white : M.text)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(message.role == .user ? accent : M.panel)
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(message.role == .user ? .clear : M.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}
