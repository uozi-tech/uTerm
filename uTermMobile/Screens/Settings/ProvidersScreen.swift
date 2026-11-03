import SwiftUI
import SwiftData

/// 设置 › 模型服务：AI provider 列表（对齐 macOS 设置的「模型服务」页）。
/// 左滑删除、编辑模式拖动排序（排序即 Agent 输入区模型菜单的分组顺序）、点行进编辑页。
/// 增删排序与校验走共享的 `ProviderManagement`，两端同一份逻辑。
///
/// 从 Agent 输入区「管理模型服务…」以 sheet 打开时传 `showsDone: true`，自带一层导航栈。
struct ProvidersScreen: View {
    var showsDone = false

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\AIProvider.sortOrder)]) private var providers: [AIProvider]
    @State private var adding = false

    var body: some View {
        if showsDone {
            NavigationStack { content }
        } else {
            content
        }
    }

    private var content: some View {
        Group {
            if providers.isEmpty {
                MEmptyState(icon: "spark", title: "还没有模型服务",
                            message: "添加 Anthropic 或 OpenAI 兼容服务，Agent 就能协助你操作主机。",
                            actionTitle: "添加模型服务", action: { adding = true })
            } else {
                list
            }
        }
        .background(M.canvas)
        .navigationTitle("模型服务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
            if !providers.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("添加模型服务")
            }
        }
        .sheet(isPresented: $adding) { NewProviderSheet().mSheetContentMargins(.form) }
        .onAppear { AgentModelDirectory.refresh(providers) }
    }

    private var list: some View {
        List {
            Section {
                ForEach(providers) { provider in
                    NavigationLink { ProviderEditScreen(provider: provider) } label: {
                        ProviderListRow(provider: provider)
                    }
                    .listRowBackground(M.card)
                    // 左滑按钮只放图标；系统 .onDelete 的左滑带「删除」文字，它只留给编辑模式的减号。
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            ProviderManagement.delete(provider, in: context)
                        } label: { Image(systemName: "trash") }
                            .accessibilityLabel("删除")
                    }
                }
                .onDelete { offsets in
                    for index in offsets { ProviderManagement.delete(providers[index], in: context) }
                }
                .onMove { source, destination in
                    ProviderManagement.move(providers, fromOffsets: source, toOffset: destination, in: context)
                }
            } footer: {
                Text("顺序即 Agent 模型菜单里的分组顺序。具体用哪个模型，在 Agent 输入区的模型菜单里切换——那里列出所有服务的全部可用模型。")
            }
        }
        .scrollContentBackground(.hidden)
    }
}

/// 列表行：首字母头像 + 名称 + 类型 · 地址 + 缺 Key 时的警示。不显示模型（见 `ProviderManagement.summary`）。
private struct ProviderListRow: View {
    let provider: AIProvider
    @Environment(\.mAccent) private var accent

    var body: some View {
        let hasKey = ProviderManagement.hasKey(provider)
        HStack(spacing: 12) {
            Text(provider.name.prefix(1).uppercased())
                .font(M.mono(14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: MRadius.sm).fill(accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name.isEmpty ? provider.kind.displayName : provider.name)
                    .font(M.sans(15, weight: .medium)).foregroundStyle(M.text).lineLimit(1)
                Text(ProviderManagement.summary(provider))
                    .font(M.sans(13)).foregroundStyle(M.text3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !hasKey {
                Label("缺 Key", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(M.warning)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(hasKey ? "" : "尚未设置 API Key")
    }
}

// MARK: - 编辑

/// 编辑一条已存在的 provider：名称 / 类型 / Base URL 直接写进 `@Model`（自动持久，经
/// CloudKit 同步到 Mac），API Key 单独「保存」进钥匙串（经 iCloud 钥匙串同步，见 `AgentKeychain`）。
struct ProviderEditScreen: View {
    @Bindable var provider: AIProvider

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""
    @State private var keyStatus: (ok: Bool, message: String)?
    @State private var hasKey = false
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            ProviderBasicsSection(name: $provider.name, kind: kindBinding, baseURL: $provider.baseURL)

            Section {
                ProviderKeyField(text: $keyDraft, placeholder: hasKey ? "粘贴新 Key 以替换" : "sk-…")
                Button("保存 Key", action: saveKey)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("API Key")
            } footer: {
                if let keyStatus {
                    Label(keyStatus.message, systemImage: keyStatus.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(keyStatus.ok ? M.success : M.danger)
                } else {
                    Text(hasKey ? "已有 Key。保存在钥匙串，经 iCloud 钥匙串端到端加密同步。"
                                : "尚未设置 Key。保存在钥匙串，请求时仅发送给该服务。")
                        .foregroundStyle(hasKey ? M.text3 : M.warning)
                }
            }
            .listRowBackground(M.card)

            ProviderDiagnosticsSection(
                canTest: ProviderManagement.baseURLError(provider.baseURL, kind: provider.kind) == nil,
                test: { await ProviderManagement.testConnection(provider, keyDraft: keyDraft) })

            Section {
                Button("删除模型服务", role: .destructive) { confirmingDelete = true }
            }
            .listRowBackground(M.card)
        }
        .scrollContentBackground(.hidden)
        .background(M.canvas)
        .navigationTitle(provider.name.isEmpty ? "模型服务" : provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { hasKey = ProviderManagement.hasKey(provider) }
        .alert("删除「\(provider.name)」？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) {
                ProviderManagement.delete(provider, in: context)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("钥匙串里的 API Key 一并删除，经 iCloud 同步的设备上也会删除。")
        }
    }

    private var kindBinding: Binding<ProviderKind> {
        Binding(get: { provider.kind }, set: { ProviderManagement.setKind($0, on: provider) })
    }

    private func saveKey() {
        do {
            try ProviderManagement.saveKey(keyDraft, for: provider)
            keyDraft = ""
            hasKey = true
            keyStatus = (true, "已保存")
        } catch {
            keyStatus = (false, "保存到钥匙串失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - 新建

/// 新建 provider：先在草稿里填好，保存时才落库 + 写钥匙串（取消不留空壳）。
/// 不在这里选模型——与 macOS 一致，模型在 Agent 输入区的模型菜单里选。
struct NewProviderSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// 新建成功后回调（Agent 面板借此切到新服务）。
    var onCreated: (AIProvider) -> Void = { _ in }

    @State private var name = ""
    @State private var kind: ProviderKind = .anthropic
    @State private var baseURL = ProviderPreset.anthropicBaseURL
    @State private var keyDraft = ""

    private var valid: Bool {
        ProviderManagement.nameError(name) == nil
            && ProviderManagement.baseURLError(baseURL, kind: kind) == nil
            && !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                ProviderBasicsSection(name: $name, kind: kindBinding, baseURL: $baseURL,
                                      reportsEmptyName: false)
                Section {
                    ProviderKeyField(text: $keyDraft, placeholder: "sk-…")
                } header: {
                    Text("API Key")
                } footer: {
                    Text("保存在钥匙串（经 iCloud 钥匙串端到端加密同步），请求时仅发送给该服务。")
                }
                .listRowBackground(M.card)
                ProviderDiagnosticsSection(
                    canTest: ProviderManagement.baseURLError(baseURL, kind: kind) == nil,
                    test: testDraft)
            }
            .scrollContentBackground(.hidden)
            .background(M.canvas)
            .navigationTitle("添加模型服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(!valid).fontWeight(.semibold)
                }
            }
        }
    }

    /// 用草稿试连：临时对象不进库，只为喂给共享的 `testConnection`。
    private func testDraft() async -> ProviderManagement.ConnectionResult {
        let draft = AIProvider(name: name, kind: kind, baseURL: baseURL, model: "")
        return await ProviderManagement.testConnection(draft, keyDraft: keyDraft)
    }

    private var kindBinding: Binding<ProviderKind> {
        Binding(get: { kind }, set: { new in
            baseURL = ProviderManagement.baseURL(baseURL, switchingFrom: kind, to: new)
            kind = new
        })
    }

    private func save() {
        let provider = ProviderManagement.add(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                              kind: kind,
                                              baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                              in: context)
        try? ProviderManagement.saveKey(keyDraft, for: provider)
        onCreated(provider)
        dismiss()
    }
}

// MARK: - 表单片段

/// 名称 / 类型 / Base URL 三行（新建与编辑共用）。
private struct ProviderBasicsSection: View {
    @Binding var name: String
    @Binding var kind: ProviderKind
    @Binding var baseURL: String
    /// 新建表单一打开名称就是空的：那时不报「名称不能为空」（保存钮已经灰着），编辑页才报。
    var reportsEmptyName = true

    var body: some View {
        Section {
            LabeledContent("名称") {
                TextField("如 Claude / DeepSeek", text: $name)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
            }
            Picker("类型", selection: $kind) {
                ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
            }
            LabeledContent("Base URL") {
                TextField(ProviderPreset.defaultBaseURL(for: kind), text: $baseURL)
                    .multilineTextAlignment(.trailing)
                    .font(M.mono(14))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("基本")
        } footer: {
            if let error = (reportsEmptyName ? ProviderManagement.nameError(name) : nil)
                ?? ProviderManagement.baseURLError(baseURL, kind: kind) {
                Text(error).foregroundStyle(M.danger)
            } else {
                // verbatim：字面量会按 Markdown 解析，网址被渲染成可点的链接。
                Text(verbatim: "Base URL 不含路径段。OpenAI 兼容端点按同样规则填，如 https://api.deepseek.com。")
            }
        }
        .listRowBackground(M.card)
    }
}

/// 掩码 Key 输入 + 看原文的眼睛钮。
private struct ProviderKeyField: View {
    @Binding var text: String
    let placeholder: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .font(M.mono(14))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            MRevealButton(revealed: revealed) { revealed.toggle() }
        }
    }
}

/// 测试连接：拉一次 `/v1/models`（`ProviderManagement.testConnection`）。
private struct ProviderDiagnosticsSection: View {
    let canTest: Bool
    let test: () async -> ProviderManagement.ConnectionResult
    @State private var inFlight = false
    @State private var result: ProviderManagement.ConnectionResult?

    var body: some View {
        Section {
            Button {
                Task {
                    inFlight = true
                    result = await test()
                    inFlight = false
                }
            } label: {
                HStack {
                    Text("测试连接")
                    Spacer()
                    if inFlight { ProgressView() }
                }
            }
            .disabled(inFlight || !canTest)
            if let result {
                Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(M.sans(13))
                    .foregroundStyle(result.ok ? M.success : M.danger)
            }
        } header: {
            Text("诊断")
        } footer: {
            Text("模型不在这里选：Agent 输入区的模型菜单会列出所有服务的全部可用模型（取自各自的 /v1/models）。")
        }
        .listRowBackground(M.card)
    }
}
