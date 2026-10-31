import UDesignKit
import SwiftUI

/// Provider 编辑表单。
/// - name / kind / baseURL / model 字段绑到 SwiftData @Model（自动持久）。
/// - model 只能从 provider 实时返回的模型列表里选（`ProviderModelList`）：打开时、
///   改 kind / Base URL / API Key 后自动拉，也可手动刷新；不预置、不手填。
/// - kind 切换若 baseURL 当前等于另一 kind 的预置，自动替为本 kind 的预置；
///   用户已自定义的 baseURL 不动。
/// - apiKey 不在 SwiftData，由本视图持有 @State keyDraft，「保存 Key」
///   按钮直接调 AgentKeychain.save(_:for:)。
struct ProviderEditView: View {
    @Bindable var provider: AIProvider
    @State private var keyDraft = ""
    @State private var keySaveError: String?
    @State private var keySaved = false
    @State private var testInFlight = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var models = ProviderModelList()

    private let keychain = AgentKeychain()

    /// 显式 String 而非字面量 —— `help(_:)` 有 LocalizedStringKey / StringProtocol
    /// 两个 overload，字面量 prefer LocalizedStringKey，会把 `https://...` 当
    /// markdown URL 解析成 attributed string 触发 runtime warning：
    /// "Only unstyled text can be used with help(_:)"
    /// 已知 String 类型走 StringProtocol overload 跳过 markdown 解析。
    private let baseURLHelpText: String =
        "不含路径段。OpenAI-兼容端点按同样规则填，如 https://api.deepseek.com、http://localhost:11434。"

    /// Base URL 必填；远程端点须 HTTPS，loopback 开发服务可用 HTTP。
    private var baseURLError: String? {
        let trimmed = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Base URL 不能为空" }
        return ProviderEndpointPolicy.validationMessage(
            configuredBaseURL: trimmed, kind: provider.kind)
    }

    /// 名称必填；空时返回错误文案。
    private var nameError: String? {
        provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "名称不能为空" : nil
    }

    /// 待保存的 API Key 草稿（去空白）。
    private var keyDraftTrimmed: String {
        keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SettingsScroll {
            SettingsGroup(title: "基本") {
                ProviderFormField(label: "名称") {
                    UDTextField(placeholder: "名称",
                                text: $provider.name,
                                errorMessage: nameError)
                        .frame(width: 320)
                        .accessibilityLabel("名称")
                        .accessibilityValue(nameError ?? provider.name)
                }

                ProviderFormField(label: "类型") {
                    UDSegmented(
                        selection: kindBinding,
                        options: ProviderKind.allCases.map { (value: $0, label: $0.displayName) }
                    )
                }

                ProviderFormField(label: "Base URL", hint: baseURLHelpText) {
                    UDTextField(placeholder: "如 https://api.openai.com",
                                text: $provider.baseURL,
                                errorMessage: baseURLError)
                        .frame(width: 360)
                        .help(baseURLHelpText)
                        .accessibilityLabel("Base URL")
                        .accessibilityValue(baseURLError ?? provider.baseURL)
                }
            }

            SettingsGroup(title: "模型") {
                ProviderFormField(label: "模型", hint: "列表实时取自该 provider 的 /v1/models 接口。") {
                    ProviderModelPicker(
                        list: models,
                        selection: provider.model,
                        onSelect: { provider.model = $0 },
                        onRefresh: { models.load(modelsRequest) }
                    )
                }
            }

            SettingsGroup(title: "API Key") {
                ProviderFormField(label: "密钥") {
                    VStack(alignment: .leading, spacing: 8) {
                        UDTextField(
                            placeholder: "粘贴新 key 后按下方保存",
                            text: $keyDraft,
                            isSecure: true,
                            revealable: true
                        )
                        .frame(width: 360)
                        .accessibilityLabel("API Key")
                        .accessibilityValue(keyDraftTrimmed.isEmpty ? "未输入" : "已输入新 key")

                        HStack(spacing: 10) {
                            UDButton(title: "保存 Key", style: .secondary) { saveKey() }
                                .disabled(keyDraftTrimmed.isEmpty)
                            keyStatus
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            SettingsGroup(title: "诊断") {
                HStack(spacing: 10) {
                    UDButton(title: "测试连接", style: .secondary) {
                        Task { await testConnection() }
                    }
                    .disabled(testInFlight || baseURLError != nil)

                    if testInFlight {
                        UDIndeterminateBar()
                            .frame(width: 72)
                    }
                    if let r = testResult {
                        statusLabel(r.message, ok: r.ok)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .id(provider.id)              // 切换选中行时重建本视图，清空 keyDraft 等本地状态。
        .onChange(of: provider.id) { _, _ in
            keyDraft = ""
            keySaved = false
            keySaveError = nil
            testInFlight = false
            testResult = nil
        }
        .onAppear { models.load(modelsRequest) }
        .onChange(of: provider.kindRaw) { models.load(modelsRequest) }
        .onChange(of: provider.baseURL) { models.load(modelsRequest, debounce: Self.typingDebounce) }
        // 保存 Key 会清空草稿，同样落到这里 —— 改用钥匙串里的新 key 重拉。
        .onChange(of: keyDraft) { models.load(modelsRequest, debounce: Self.typingDebounce) }
        // 还没选过模型：取列表第一个，免得 provider 带着空 model 去发请求；已有选择不动。
        .onChange(of: models.phase) { _, phase in
            if provider.model.isEmpty, case .loaded(let ids) = phase, let first = ids.first {
                provider.model = first
            }
        }
    }

    /// 停止输入 Base URL / API Key 多久后再去拉模型列表。
    private static let typingDebounce: Duration = .milliseconds(600)

    /// 拉模型列表用的 key：未保存的草稿优先（便于先试再存），否则用钥匙串里的。
    private var modelsRequest: ProviderModelList.Request {
        let key = keyDraftTrimmed.isEmpty ? (keychain.load(for: provider.id) ?? "") : keyDraftTrimmed
        return .init(kind: provider.kind, baseURL: provider.baseURL, apiKey: key)
    }

    @ViewBuilder
    private var keyStatus: some View {
        if keySaved {
            statusLabel("已保存", ok: true)
        }
        if let err = keySaveError {
            statusLabel(err, ok: false)
        }
        if keychain.load(for: provider.id) != nil {
            Text("已有 Key")
                .font(UD.caption)
                .foregroundStyle(UD.text3)
        } else {
            Text("尚未设置 Key")
                .font(UD.caption)
                .foregroundStyle(UD.warning)
        }
    }

    private func statusLabel(_ message: String, ok: Bool) -> some View {
        Label(message, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .font(UD.caption)
            .foregroundStyle(ok ? UD.success : UD.danger)
            .lineLimit(1)
    }

    /// kind 改时若 baseURL 是另一 kind 的预置，自动同步过来；用户已自定义的 baseURL 不动。
    private var kindBinding: Binding<ProviderKind> {
        Binding(
            get: { provider.kind },
            set: { newKind in
                let oldDefault = ProviderPreset.defaultBaseURL(for: provider.kind)
                if provider.baseURL == oldDefault {
                    provider.baseURL = ProviderPreset.defaultBaseURL(for: newKind)
                }
                provider.kindRaw = newKind.rawValue
            })
    }

    private func testConnection() async {
        testInFlight = true
        defer { testInFlight = false }
        // 用未保存的 keyDraft（若有）覆盖 keychain 中的 key——便于先试再保存。
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (keychain.load(for: provider.id) ?? "")
            : keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            testResult = (false, "请先填或保存 API Key")
            return
        }
        guard !provider.model.isEmpty else {
            testResult = (false, "请先选择模型")
            return
        }
        guard case .success(let baseURL) = ProviderEndpointPolicy.resolve(
            configuredBaseURL: provider.baseURL, kind: provider.kind) else {
            testResult = (false, baseURLError ?? "Base URL 非法或不安全")
            return
        }
        let config = LLMRequestConfig(model: provider.model, baseURL: baseURL, apiKey: key)
        let client = LLMClientFactory.make(for: provider)
        do {
            var sawAnything = false
            for try await _ in client.stream(
                messages: [ChatMessage(role: .user, text: "ping")],
                system: "reply with the single word pong",
                config: config) {
                sawAnything = true
            }
            testResult = (sawAnything,
                          sawAnything ? "连接 OK" : "连接通了但模型未返回内容，换个模型试试")
        } catch let e as LLMClientError {
            switch e {
            case .httpError(let s, let body):
                testResult = (false, "HTTP \(s)：\(body.prefix(120))")
            case .invalidResponse:
                testResult = (false, "服务器返回了无法解析的响应")
            case .streamIdleTimeout:
                testResult = (false, "响应流长时间没有新输出")
            case .streamError(let detail):
                testResult = (false, "服务端中途报错：\(detail.prefix(120))")
            case .incompleteStream:
                testResult = (false, "连接在回复说完之前断开")
            case .outputLimitReached:
                // 能撞到输出上限说明链路与所选模型都是通的。
                testResult = (true, "连接 OK")
            }
        } catch {
            testResult = (false, "请求失败：\(FriendlyError.describe(error))")
        }
    }

    private func saveKey() {
        let k = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        do {
            try keychain.save(k, for: provider.id)
            keyDraft = ""
            keySaveError = nil
            keySaved = true
        } catch {
            keySaveError = "保存到钥匙串失败：\(error)"
            keySaved = false
        }
    }
}

/// 模型下拉 —— 选项只来自 `ProviderModelList` 实时拉到的列表。
/// 一行「下拉 + 刷新」，下面一行状态：加载中 / 失败（原因 + 重试）/ 空列表 /
/// 已存模型不在新列表里（仍留在下拉首项并打警示）。
private struct ProviderModelPicker: View {
    let list: ProviderModelList
    let selection: String
    let onSelect: (String) -> Void
    let onRefresh: () -> Void

    var body: some View {
        let choices = ProviderModelChoices(phase: list.phase, saved: selection)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                UDDropdown(becomesKey: true) { _ in
                    trigger
                } content: {
                    ProviderModelMenu(choices: choices, selection: selection, onSelect: onSelect)
                }
                .disabled(choices.models.isEmpty)
                .accessibilityLabel("模型")
                .accessibilityValue(selection.isEmpty ? "未选择" : selection)

                UDButton(title: "刷新", style: .link,
                         systemImage: list.isLoading ? nil : "arrow.clockwise",
                         isLoading: list.isLoading,
                         action: onRefresh)
                    .disabled(list.isLoading || list.phase == .idle)
                    .help("重新向 provider 拉取可用模型")
            }
            status(choices)
        }
    }

    private var trigger: some View {
        HStack(spacing: 8) {
            Text(selection.isEmpty ? (list.isLoading ? "获取中…" : "选择模型") : selection)
                .font(UD.mono(12))
                .foregroundStyle(selection.isEmpty ? UD.text4 : UD.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(UD.text3)
        }
        .padding(.horizontal, 10)
        .frame(width: 320, height: 30)
        .background(RoundedRectangle(cornerRadius: UD.Radius.md).fill(UD.inputBg))
        .overlay(RoundedRectangle(cornerRadius: UD.Radius.md).stroke(UD.border, lineWidth: 1))
    }

    @ViewBuilder
    private func status(_ choices: ProviderModelChoices) -> some View {
        switch list.phase {
        case .idle:
            EmptyView()
        case .loading:
            statusText("正在获取模型列表…", color: UD.text3)
        case .failed(let reason):
            retryLine(reason, color: UD.danger)
        case .loaded(let ids) where ids.isEmpty:
            retryLine("服务器没有返回任何模型", color: UD.warning)
        case .loaded:
            if choices.savedIsMissing {
                statusText("当前模型「\(selection)」不在服务器返回的列表里，仍按原样使用；可改选列表中的模型。",
                           color: UD.warning)
            }
        }
    }

    private func retryLine(_ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusText(text, color: color)
            UDButton(title: "重试", style: .link, action: onRefresh)
        }
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(UD.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420, alignment: .leading)
    }
}

/// 下拉浮层：模型多时（OpenRouter 动辄几百个）顶部带搜索框。
private struct ProviderModelMenu: View {
    let choices: ProviderModelChoices
    let selection: String
    let onSelect: (String) -> Void

    @State private var query = ""

    private static let width: CGFloat = 320
    private static let searchThreshold = 10

    var body: some View {
        let filtered = choices.filtered(by: query)
        VStack(alignment: .leading, spacing: 6) {
            if choices.models.count > Self.searchThreshold {
                card {
                    UDTextField(placeholder: "搜索模型", text: $query, autoFocus: true, monospaced: true)
                        .autocorrectionDisabled()
                        .padding(6)
                }
            }
            if filtered.isEmpty {
                card {
                    Text("没有匹配的模型")
                        .font(.system(size: 12))
                        .foregroundStyle(UD.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            } else {
                UDMenu(width: Self.width, items: filtered.map { model in
                    let stale = choices.savedIsMissing && model == selection
                    return UDMenuItem(label: stale ? "\(model)（不在列表中）" : model,
                                      systemImage: stale ? "exclamationmark.triangle" : nil,
                                      active: model == selection) { onSelect(model) }
                })
            }
        }
    }

    /// 与 `UDMenu` 同款外壳（overlay 实底 + 发丝边 + 9pt 圆角）。
    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(width: Self.width)
            .background(RoundedRectangle(cornerRadius: 9).fill(UD.overlay))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UD.border, lineWidth: 1))
    }
}

private struct ProviderFormField<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(UD.text2)
            content()
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(UD.text4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }
}
