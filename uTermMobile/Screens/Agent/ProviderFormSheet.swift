import SwiftUI
import SwiftData

/// 新建 AI Provider（写 `AIProvider` + 钥匙串 API Key）。
/// 模型只能从 provider 实时返回的列表里选（`ProviderModelList`），不预置、不手填。
struct ProviderFormSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: ProviderKind = .anthropic
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var models = ProviderModelList()

    /// 停止输入 Base URL / API Key 多久后再去拉模型列表。
    private static let typingDebounce: Duration = .milliseconds(600)

    private var modelsRequest: ProviderModelList.Request {
        .init(kind: kind, baseURL: baseURL, apiKey: apiKey.trimmingCharacters(in: .whitespaces))
    }

    private var baseURLError: String? {
        ProviderEndpointPolicy.validationMessage(configuredBaseURL: baseURL, kind: kind)
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        !model.isEmpty &&
        baseURLError == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    MInsetGroup(header: "类型") {
                        Picker("类型", selection: $kind) {
                            ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented).padding(12)
                    }

                    MInsetGroup(header: "基本") {
                        formRow("名称", "如 Claude / DeepSeek", $name, autocap: .sentences, last: false)
                        formRow("Base URL", ProviderPreset.defaultBaseURL(for: kind), $baseURL, last: true)
                    }
                    if let baseURLError {
                        Text(baseURLError)
                            .font(M.sans(12)).foregroundStyle(M.danger)
                            .padding(.horizontal, 20)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        MSectionCap(text: "API Key").padding(.horizontal, 20)
                        MInput(text: $apiKey, placeholder: "sk-…", mono: true, secure: true, revealable: true)
                            .padding(.horizontal, 16)
                        Text("保存在当前设备钥匙串；请求时仅发送给所选 Provider。")
                            .font(M.sans(12)).foregroundStyle(M.text4).padding(.horizontal, 20)
                    }

                    modelSection
                }
                .padding(.vertical, 12)
            }
            .background(M.canvas)
            .onAppear { models.load(modelsRequest) }
            .onChange(of: kind) { models.load(modelsRequest) }
            .onChange(of: baseURL) { models.load(modelsRequest, debounce: Self.typingDebounce) }
            .onChange(of: apiKey) { models.load(modelsRequest, debounce: Self.typingDebounce) }
            // 列表到了而还没选：取第一个；已有选择不动。
            .onChange(of: models.phase) { _, phase in
                if model.isEmpty, case .loaded(let ids) = phase, let first = ids.first {
                    model = first
                }
            }
            .navigationTitle("添加 Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!valid).fontWeight(.semibold)
                }
            }
        }
    }

    /// 模型：下拉来自 provider 的 `/v1/models`；状态行给加载中 / 失败（可重试）/ 空列表。
    private var modelSection: some View {
        let choices = ProviderModelChoices(phase: models.phase, saved: model)
        return MInsetGroup(header: "模型") {
            HStack(spacing: 10) {
                Text("模型").font(M.sans(15)).foregroundStyle(M.text)
                Spacer(minLength: 8)
                if choices.models.isEmpty {
                    Text(models.isLoading ? "获取中…" : "—")
                        .font(M.mono(13)).foregroundStyle(M.text4)
                } else {
                    Picker("模型", selection: $model) {
                        ForEach(choices.models, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                Button { models.load(modelsRequest) } label: {
                    if models.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise").foregroundStyle(M.accent)
                    }
                }
                .disabled(models.isLoading || models.phase == .idle)
                .accessibilityLabel("刷新模型列表")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            if let status = modelStatus {
                MRowDivider()
                Text(status.text)
                    .font(M.sans(12)).foregroundStyle(status.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    /// 加载中 / 失败 / 空列表时在模型行下多一行说明；失败与空列表靠行尾刷新钮重试。
    private var modelStatus: (text: String, color: Color)? {
        switch models.phase {
        case .idle:
            return ("填好 Base URL 与 API Key 后自动获取可用模型。", M.text4)
        case .loading:
            return ("正在获取模型列表…", M.text4)
        case .failed(let reason):
            return (reason, M.danger)
        case .loaded(let ids) where ids.isEmpty:
            return ("服务器没有返回任何模型。", M.warning)
        case .loaded:
            return nil
        }
    }

    @ViewBuilder
    private func formRow(_ label: String, _ placeholder: String, _ binding: Binding<String>,
                         autocap: TextInputAutocapitalization = .never, last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(M.sans(15)).foregroundStyle(M.text).frame(width: 92, alignment: .leading)
                TextField(placeholder, text: binding)
                    .font(M.sans(15)).foregroundStyle(M.text)
                    .textInputAutocapitalization(autocap).autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            if !last { MRowDivider() }
        }
    }

    private func save() {
        let next = ((try? context.fetch(FetchDescriptor<AIProvider>()))?.map(\.sortOrder).max() ?? -1) + 1
        let provider = AIProvider(name: name.trimmingCharacters(in: .whitespaces),
                                  kind: kind,
                                  baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                                  model: model.trimmingCharacters(in: .whitespaces),
                                  sortOrder: next)
        context.insert(provider)
        try? context.save()
        try? AgentKeychain().save(apiKey.trimmingCharacters(in: .whitespaces), for: provider.id)
        dismiss()
    }
}
